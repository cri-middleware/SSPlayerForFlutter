import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/ssruntime_dart.dart';
import 'render/backend/backend_kind.dart';
import 'render/backend/canvas_backend.dart';
import 'render/backend/gpu_backend_factory.dart';
import 'render/backend/gpu_capability.dart';
import 'render/backend/render_backend.dart';
import 'render/backend/render_host.dart';
import 'render/effect.dart';
import 'render/geometry_builder.dart';
import 'render/instance.dart';
import 'render/mask.dart';
import 'render/mask_context.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;
import 'texture_registry.dart';

/// Layer 2 — the Widget-agnostic drawing engine (ports the SDK's
/// `SSInternalPlayer`).
///
/// Owns the FFI [Resource]/[Context] lifecycle, advances time, pulls the
/// per-frame `FrameData` + SoA buffers from the Brain, and drives a
/// [RenderBackend] (Canvas or flutter_gpu) to turn each `DrawBatch` into pixels.
/// It is `dispose`-able and reusable from higher layers (Player) or headless
/// tests. As [RenderHost] it exposes the per-player data the backend draws from.
class SpriteStudioInternalPlayer implements InstanceChild, RenderHost {
  SpriteStudioInternalPlayer._(
    this._context,
    this._resource,
    this.textures,
    this._maskFlags,
    this._effects,
    this._backend,
  ) {
    // Backstop finalizers: if the caller forgets dispose(), the Brain-side
    // Context/Resource are still reclaimed on GC. The Arc refcount inside the
    // runtime makes destroy order irrelevant. The Brain owns its own copy of
    // the `.ssab` bytes (copy mode), so there is no Body-side buffer to keep
    // alive or leak on the GC-only path.
    ssRuntime.registerForGc(this, context: _context, resource: _resource);
  }

  SsContext _context;
  SsResource _resource;

  /// texture_hash → decoded image / shader. Populated by the caller. Public as
  /// part of [RenderHost].
  @override
  final TextureRegistry textures;

  /// Static per-part mask flags (§1-2), read once from the `.ssab` `PartData` at
  /// load — they never change per frame. Empty when the pack has no parts, which
  /// disables the whole mask path.
  final List<MaskPartFlags> _maskFlags;

  /// Static per-part mask role (§1-2); [MaskPartFlags.none] past the part range.
  /// Public as part of [RenderHost] — the backend reads it to peel mask targets.
  @override
  MaskPartFlags flagsFor(int partIndex) => partIndex < _maskFlags.length
      ? _maskFlags[partIndex]
      : MaskPartFlags.none;

  /// Per-part particle-effect slots (§8), stepped from [updateMs] because they
  /// need a delta time. Empty when the pack hosts no effects.
  final EffectSlots _effects;

  /// Per-part instance slots (§8) and the nested child players they drive,
  /// stepped from [updateMs] alongside the effects. Empty when the pack hosts no
  /// instances. Assigned right after construction ([load]) because building the
  /// children needs the finished parent.
  late final InstanceSlots<SpriteStudioInternalPlayer> _instances;

  /// Pure SoA→vertex baker (Widget/FFI-free); the shared compute both render
  /// backends draw from. Exposed to the backend as [geometry] ([RenderHost]).
  final GeometryBuilder _geometry = GeometryBuilder();

  /// The render backend that turns this player's `DrawBatch`es into pixels —
  /// Canvas (`Canvas.drawVertices`) by default, flutter_gpu when requested and
  /// available. Chosen in [load] from the requested [SpriteStudioBackend] via the
  /// capability probe. Owns the shader pools, batch paint and coverage resources
  /// that used to live here; disposed with the player.
  final RenderBackend _backend;

  /// [RenderHost]: the shared SoA→vertex baker.
  @override
  GeometryBuilder get geometry => _geometry;

  /// [RenderHost]: whether this player hosts any effect parts.
  @override
  bool get hasEffects => !_effects.isEmpty;

  /// When true (default), rendering samples the Brain's fractional (sub-frame)
  /// frame number, giving smooth playback beyond the source FPS on high-refresh
  /// displays. Set false to snap to integer frames.
  ///
  /// Propagates to instance children (§8): the SDK requires it, and a child left
  /// on the other setting visibly stutters at integer frames while its parent
  /// runs smooth.
  bool get subFrame => _subFrame;
  set subFrame(bool value) {
    _subFrame = value;
    for (final part in _instances.parts) {
      _instances.slotFor(part.partIndex)?.child.subFrame = value;
    }
  }

  bool _subFrame = true;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  // The SoA out-parameter scratch cells and the Context/Resource NativeFinalizers
  // moved into the native SsRuntime backend (ssruntime_dart) so this layer is
  // dart:ffi-free and compiles for the web. GC backstop is [SsRuntime.registerForGc].

  /// Loads `ssab` into a fresh Context, binds it, and recursively spawns any
  /// instance children (§8).
  ///
  /// Steps mirror docs/30_core/10_initialization: create resource → create
  /// context → bind → set coordinate system. The `.ssab` is NOT
  /// validated by the Brain; validate untrusted input before calling this.
  ///
  /// [instancePacks] maps a pack's `name_hash` to that pack's `.ssab` bytes and
  /// resolves `external_instances` references. Fetching those bytes is async
  /// (asset bundle / disk) while this factory is sync, so the host does the
  /// fetching — L3 `SpriteStudioPlayer.load` builds the map from
  /// [InstancePart.externalPackNames]. A same-pack sub-animation needs no entry;
  /// it resolves against [ssab] itself. Parts whose pack is missing get no child
  /// and are silently not drawn.
  factory SpriteStudioInternalPlayer.load(
    Uint8List ssab, {
    TextureRegistry? textures,
    Map<int, Uint8List>? instancePacks,
    SpriteStudioBackend backend = SpriteStudioBackend.auto,
  }) {
    // Copy mode: the Brain copies the bytes onto its own heap and retains no
    // pointer into `ssab` (the native backend does a zero-copy leaf hand-off).
    // Copy is also the only mode that works on the Web/WASM path, where the
    // Body's and Brain's memory spaces differ. Rejects an empty list.
    final resource = ssRuntime.createResourceCopy(ssab);
    if (resource == null) {
      throw StateError('ss_resource_create_copy returned null (bad .ssab?)');
    }

    final context = ssRuntime.createContext();
    if (context == null) {
      ssRuntime.destroyResource(resource);
      throw StateError('ss_runtime_create returned null');
    }
    if (!ssRuntime.bindResource(context, resource)) {
      ssRuntime.destroyContext(context);
      ssRuntime.destroyResource(resource);
      throw StateError('ss_runtime_bind_resource failed');
    }

    // Direct render mode (the default): the Brain fills the SoA buffers this
    // Body reads and skips redundant FrameData vertices/cells/deforms
    // (render_loop §2). The Godot flagship relies on the same default.
    ssRuntime.setRenderMode(context, 0);
    // Coordinate system = 1 (Y-Down) like the flagship: the Brain applies the
    // flip once, so the Body must NOT flip again. Origin/unit are left at the
    // runtime defaults (Center / Pixel) — the flagship sets neither.
    ssRuntime.setCoordinateSystem(context, 1); // 1 = Y-Down

    final registry = textures ?? TextureRegistry();
    // Resolve the requested backend through the capability probe: gpu only when
    // flutter_gpu is actually usable, else Canvas (which never throws). Every
    // player in an instance tree gets the same choice.
    final renderBackend =
        resolveBackend(backend) == SpriteStudioBackend.gpu
            ? createFlutterGpuBackend()
            : CanvasBackend();
    final player = SpriteStudioInternalPlayer._(
      context,
      resource,
      registry,
      // Mask roles (§1-2) live in the static `.ssab` PartData, not in FrameData
      // and not in any SoA buffer — read them once here rather than per frame.
      MaskPartFlags.readAll(ssab),
      // Same for the effect bindings; the slots themselves are created lazily.
      EffectSlots(resource, EffectPart.readAll(ssab)),
      renderBackend,
    );

    // Instance children (§8). Unlike effect slots these cannot be lazy: each is
    // a whole nested player, and `ss_instance_slot_step` needs its Context from
    // the very first tick. `_instances` is late-final rather than a constructor
    // argument because a child's `childFor` closure below wants the finished
    // parent in scope.
    final ownPackHash = InstancePart.packHashOf(ssab);
    // Nesting is expanded eagerly and without a depth cap, like every sibling
    // player: a cap buys nothing against real content (it would only ever fire
    // on nesting the SS7 editor cannot practically author) while silently
    // dropping the innermost child if it ever did. A cyclic `.ssab` recurses
    // until the stack gives out — `.ssab` is trusted input, which the Brain
    // does not validate either.
    player._instances = InstanceSlots<SpriteStudioInternalPlayer>.build(
      InstancePart.readAll(ssab),
      (part) {
        final bytes = InstancePart.resolvePack(
          part,
          ownBytes: ssab,
          ownPackHash: ownPackHash,
          packs: instancePacks,
        );
        if (bytes == null) return null; // unresolved external pack
        final child = SpriteStudioInternalPlayer.load(
          bytes,
          // Children share the parent's registry: cellmap hashes are global, so
          // a shared atlas resolves once and a child-only cellmap simply adds to
          // it. The host loads each pack's textures into this same registry.
          textures: registry,
          instancePacks: instancePacks,
          backend: backend, // inherit the parent's backend choice
        );
        if (!child.setupAnimation(part.animeName)) {
          // The pack resolved but the animation name did not — authored garbage.
          child.dispose();
          return null;
        }
        // The SDK requires this to propagate, and recursively: a child left on
        // the other setting stutters at integer frames while its parent is
        // smooth.
        child.subFrame = player.subFrame;
        // Stopped until an EventInstance starts it (the flagship does the same
        // at setup). A child left playing would advance its own clock from frame
        // 0 and be out of position the moment its key finally fires.
        child.stop();
        return child;
      },
    );
    return player;
  }

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('SpriteStudioInternalPlayer used after dispose()');
    }
  }

  // --- Setup / transport ---------------------------------------------------

  /// Selects the animation to play by name and rewinds to frame 0.
  bool setupAnimation(String name) {
    _ensureAlive();
    final ok = ssRuntime.setupAnimation(_context, name);
    // A different animation has different effect/instance keys — drop each
    // slot's "last started key" memory so the new animation fires its own.
    if (ok) _resetSlots();
    return ok;
  }

  /// Canonical name→id hash (never re-implement FNV-1a on the Dart side).
  int hashString(String name) => ssRuntime.hashString(name);

  void play() {
    _ensureAlive();
    ssRuntime.play(_context);
    // An explicit head-out: without this the slot debounces the first key as
    // "the one I already started" and a replayed animation never re-fires.
    _resetSlots();
  }

  /// Re-arms every slot-based kind on an explicit head-out (`play` / a new
  /// `setupAnimation`), recursing into instance children — the flagship's
  /// `_reset_slots_playback_state`.
  void _resetSlots() {
    _effects.reset();
    _instances.reset();
  }

  void pause() {
    _ensureAlive();
    ssRuntime.pause(_context);
  }

  void stop() {
    _ensureAlive();
    ssRuntime.stop(_context);
  }

  bool get isPlaying => ssRuntime.isPlaying(_context);

  /// Whether playback is paused. Note the Brain keeps [isPlaying] `true` while
  /// paused (pause is a *hold*, not a stop), and `ss_runtime_pause` *toggles*
  /// this — so callers must gate on it rather than blind-calling `pause()`.
  bool get isPausing => ssRuntime.isPausing(_context);

  /// Every configured loop has played. Sticky until the next play/setup, so
  /// callers wanting a one-shot notification must take the rising edge.
  bool get isFinished => ssRuntime.isFinished(_context);

  bool get isLooped => ssRuntime.isLooped(_context);
  double get frameNo => ssRuntime.frameNo(_context);
  int get startFrame => ssRuntime.startFrame(_context);
  int get endFrame => ssRuntime.endFrame(_context);
  int get fps => ssRuntime.fps(_context);

  set loop(int count) => ssRuntime.setLoop(_context, count);
  set speed(double rate) => ssRuntime.setSpeed(_context, rate);
  set frameRate(int fps) => ssRuntime.setFrameRate(_context, fps);
  void seek(double frame) => ssRuntime.seek(_context, frame);

  // --- Per-frame update ----------------------------------------------------

  /// Advances internal time. Returns the new (sub-frame) frame number.
  ///
  /// The Brain's `ss_runtime_update` takes a delta whose unit the SDK docs
  /// define (milliseconds per docs/30_core/20_playback_control). We pass the
  /// [delta] in milliseconds; use [updateMs] to control the raw value.
  double update(Duration delta) => updateMs(delta.inMicroseconds / 1000.0);

  double updateMs(double deltaMs) {
    _ensureAlive();
    final frame = ssRuntime.update(_context, deltaMs);
    // `is_looped` is per-update (cleared at the top of each update), so it is
    // the loop *edge* the slots want, not "looping is enabled".
    _stepSlots(frame, deltaMs, isLooped);
    return frame;
  }

  /// Drives the slot-based kinds (§8) one tick at [frame].
  ///
  /// Shared by [updateMs] (a root player, which has just advanced its own clock)
  /// and [instanceStepSlots] (an instance child, whose clock the parent's slot
  /// advanced instead) — both need their effects and nested instances ticked,
  /// and neither should duplicate the rules for doing it.
  void _stepSlots(double frame, double deltaMs, bool looped) {
    if (!_effects.isEmpty) {
      // Effects simulate themselves rather than riding the SoA, so they are
      // stepped here, where the delta is known; `paint` then draws the plans.
      //
      // Note this diverges from the flagship, which steps effects inside its
      // draw pass and therefore needs an `is_independent` probe to stop its
      // redraw dedup from also skipping simulation ticks. Flutter's Ticker
      // drives update→paint 1:1, so stepping here keeps the clock honest with
      // no such workaround. The visible difference is a *hidden* independent
      // effect: the flagship freezes its clock (no batch → no step), we keep it
      // running. Synced effects are unaffected — their frame is a pure function
      // of the parent's.
      _effects.step(
        _context,
        // Sample the same frame `paint` will draw, or the effect and the rest
        // of the animation disagree by up to a frame with sub-frame off.
        parentFrame: subFrame ? frame : frame.floorToDouble(),
        deltaSeconds: deltaMs / 1000.0,
        // The animation's authored fps (converts the delta to frames for
        // independent slots), NOT the display's.
        fps: fps > 0 ? fps.toDouble() : 60.0,
        parentLooped: looped,
      );
    }
    if (!_instances.isEmpty) {
      // Instances are stepped here for the same reason as effects — the delta
      // only exists on this side of the frame. An independent child keeps
      // running even while this player is paused, because `ss_runtime_update`
      // not advancing our frame does not stop us handing the slot a delta.
      _instances.step(
        _context,
        // NOT rounded: the Brain diffs this against the slot's own notion of the
        // parent clock to spot EventInstance edges, and `paint`'s rounding is a
        // display concern that must not leak into playback state.
        parentFrame: frame,
        deltaMs: deltaMs,
        parentLooped: looped,
      );
    }
  }

  /// Parses the FlatBuffers `FrameData` for [frameNo]. The returned view aliases
  /// the Brain's internal buffer and is only valid until the next update — read
  /// it within the current frame.
  fbs.FrameData? getFrameData(double frameNo) {
    _ensureAlive();
    final bytes = ssRuntime.getFrameData(_context, frameNo);
    if (bytes == null) return null;
    // Zero-copy typed view over the Brain buffer; FrameData reads it in place.
    return fbs.FrameData(bytes);
  }

  // --- SoA buffers (zero-copy typed views, valid until next update) -------

  /// Per-part 4×4 world matrices (parts × 16 floats).
  Float32List worldMatrices() => ssRuntime.worldMatrices(_context);

  /// Per-part local vertices (parts × 10 floats: lt,rt,lb,rb,center).
  Float32List localVertices() => ssRuntime.localVertices(_context);

  /// Per-part local UVs (parts × 10 floats: lt,rt,lb,rb,center in texture pixels).
  Float32List localUvs() => ssRuntime.localUvs(_context);

  /// Per-part cell meta (parts × 6: pivot_x,pivot_y,w,h,rect_left,rect_top).
  Float32List cellMeta() => ssRuntime.cellMeta(_context);

  // --- Mesh SoA (§8) -------------------------------------------------------
  //
  // Unlike the Normal path's `local_vertices`, mesh vertices arrive **already
  // world-transformed** — do NOT apply the world matrix again. All four data
  // buffers are concatenated across parts and sliced by a CSR prefix sum
  // (length = parts + 1): part `p` owns `[offsets[p], offsets[p + 1])`, and a
  // non-mesh part has an empty range. Empty under Indirect render mode (we set
  // Direct at load).

  /// Mesh per-vertex X coordinates, **world space**, all parts concatenated.
  Float32List meshVerticesX() => ssRuntime.meshVerticesX(_context);

  /// Mesh per-vertex Y coordinates (SoA companion to [meshVerticesX]).
  Float32List meshVerticesY() => ssRuntime.meshVerticesY(_context);

  /// Mesh per-vertex UVs in **texture-pixel** space, interleaved `[u,v,…]` and
  /// sliced by [meshVertexOffsets] (so vertex `v` is at `2v`, `2v+1`). Static.
  Float32List meshUvs() => ssRuntime.meshUvs(_context);

  /// Mesh triangle indices, **part-local and 0-based**, sliced by
  /// [meshIndexOffsets]. Static.
  Int32List meshIndices() => ssRuntime.meshIndices(_context);

  /// CSR prefix sum into [meshVerticesX] / [meshVerticesY] / [meshUvs].
  Uint32List meshVertexOffsets() => ssRuntime.meshVertexOffsets(_context);

  /// CSR prefix sum into [meshIndices].
  Uint32List meshIndexOffsets() => ssRuntime.meshIndexOffsets(_context);

  // --- Shape SoA (§11) -----------------------------------------------------

  /// Shape polygon vertices in **local** space, interleaved `[x,y,…]` at a fixed
  /// stride of 24 floats per part ([ShapeBuffers.stride]) — not CSR like the
  /// mesh. Apply the world matrix; pivot and the Y-Down flip are already in.
  Float32List shapeVertices() => ssRuntime.shapeVertices(_context);

  /// Normalised `[fx,fy,…]` box coordinates paired with [shapeVertices], same
  /// stride — the weights for per-vertex PartColor.
  Float32List shapeVertexBoxCoords() =>
      ssRuntime.shapeVertexBoxCoords(_context);

  /// Live vertex count per part for [shapeVertices]. The only valid slice: a
  /// Shape batch's `vertex_count` / `index_count` are 0.
  Int32List shapeVertexCounts() => ssRuntime.shapeVertexCounts(_context);

  // --- Effects (§8) --------------------------------------------------------

  /// The effect-hosting parts in this pack (empty when it has none).
  List<EffectPart> get effectParts => _effects.parts;

  /// The particle plan for effect part [partIndex] as of the last [update], or
  /// null when that slot drew nothing (dead, unstarted, or past its lifetime).
  ///
  /// Like the SoA views this aliases the Brain's memory: it is only valid until
  /// that slot is stepped again, i.e. until the next [update].
  @override
  efbs.EffectDrawPlan? effectPlanFor(int partIndex) =>
      _effects.planFor(partIndex);

  // --- Instances (§8) ------------------------------------------------------

  /// The instance-hosting parts in this pack (empty when it has none).
  List<InstancePart> get instanceParts => _instances.parts;

  /// The live slot for instance part [partIndex] — the child player and the
  /// frame the Brain last stepped it to — or null when the part has no child
  /// (its pack did not resolve).
  ///
  /// The child is owned by this player and dies with it; do not dispose it.
  InstanceSlot<SpriteStudioInternalPlayer>? instanceSlotFor(int partIndex) =>
      _instances.slotFor(partIndex);

  // --- Events (polling) ----------------------------------------------------

  /// Indices, into the ssab `events()` table, that were passed on the last
  /// update. The caller resolves user data / signals / audio from the ssab.
  List<int> passedEventIndices() {
    _ensureAlive();
    final count = ssRuntime.passedEventCount(_context);
    if (count <= 0) return const [];
    return List<int>.generate(
        count, (i) => ssRuntime.passedEventIndex(_context, i));
  }

  // --- Rendering -----------------------------------------------------------

  /// Draws the current frame into [canvas] (design §7; ports the Godot flagship
  /// `_drawAnimation`). Gathers the FlatBuffers `FrameData` + SoA views into one
  /// [DrawFrame], hands frame placement to the [RenderBackend] (which centers the
  /// animation's world origin in [dst]), then dispatches each `DrawBatch` on its
  /// `kind` to the backend.
  ///
  /// The batch loop, mask pre-pass planning and instance recursion stay here
  /// (backend-agnostic control flow); only the pixel operations go to the
  /// backend. Shape / Nines / Text: Nines / Text are pre-cut seams and skipped
  /// for now, as is BoxFit / scale placement into [dst].
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _ensureAlive();
    _backend.beginFrame(canvas, dst: dst, sourceSize: sourceSize);
    // The whole tree draws through THIS player's backend — including instance
    // children (§8), which share it so their geometry lands in the same target
    // (GPU) / on the same canvas (Canvas) under a pushed transform.
    _paintTree(canvas, _backend);
    _backend.finish();
  }

  /// Draws this player's batches into the *already positioned* [canvas] — the
  /// recursive half of [paint].
  ///
  /// Split out for Instance (§8): a child is drawn by calling this under the
  /// instance part's world transform, so it must not re-apply [paint]'s origin
  /// placement. [frameOverride] is the child's Brain-owned clock, and
  /// [alphaScale] the instance chain's opacity.
  void _paintTree(
    ui.Canvas canvas,
    RenderBackend backend, {
    double? frameOverride,
    double alphaScale = 1.0,
    MaskDraw? inheritedMask,
  }) {
    // Last frame's coverage has been rasterised by now; release it.
    backend.releaseCoverage();
    // Sub-frame ON (default): sample the fractional frame for smooth playback;
    // OFF: snap to the integer frame. This is the ONLY place a frame gets
    // rounded — the playback state that feeds `ss_instance_slot_step` stays raw.
    final sampled = frameOverride ?? frameNo;
    final frameData = getFrameData(subFrame ? sampled : sampled.floorToDouble());
    final batches = frameData?.drawBatches;
    if (frameData == null || batches == null) return;

    // Decide which optional SoA blocks this frame needs in ONE pass over the
    // batch plan (was two separate `any` scans). Mesh SoA is fetched only when a
    // Mesh batch is present; shape SoA when a Shape OR Mask batch is — a
    // *pure-mask* shape's colour batch is emitted with `kind == Mask`, not
    // `Shape`, so keying only off Shape would starve the coverage pass of its
    // geometry. The common mesh/shape-free animation fetches neither.
    var hasMesh = false;
    var hasShapeGeom = false;
    for (final b in batches) {
      switch (b.kind) {
        case fbs.DrawBatchKind.Mesh:
          hasMesh = true;
        case fbs.DrawBatchKind.Shape:
        case fbs.DrawBatchKind.Mask:
          hasShapeGeom = true;
        default:
          break;
      }
    }

    // One zero-copy SoA gather per frame (mirrors the flagship's single-block
    // fetch); the views are valid only until the next update.
    final frame = DrawFrame.build(
      frameData: frameData,
      world: worldMatrices(), // parts × 16
      local: localVertices(), // parts × 10
      uv: localUvs(), // parts × 10 (texture-pixel space)
      mesh: hasMesh
          ? MeshBuffers(
              x: meshVerticesX(),
              y: meshVerticesY(),
              uv: meshUvs(),
              indices: meshIndices(),
              vertexOffsets: meshVertexOffsets(),
              indexOffsets: meshIndexOffsets(),
            )
          : null,
      shape: hasShapeGeom
          ? ShapeBuffers(
              vertices: shapeVertices(),
              boxCoords: shapeVertexBoxCoords(),
              counts: shapeVertexCounts(),
            )
          : null,
      alphaScale: alphaScale,
    );
    if (frame == null) return;

    // Rewind the backend's per-frame shader pools (reused across frames).
    backend.rewindShaderPools();

    // Masking (§9) is a pre-pass: collect this frame's writers, rasterise their
    // coverage bitmap, then let the batch loop test each target against it.
    // Unlike the flagship's viewport (1-frame latency, size classes, shrink
    // hysteresis) `toImageSync` gives us the bitmap within this same frame, so
    // none of that machinery is needed.
    final maskCtx = _buildMaskContext(backend, frame, batches);

    // A mask inherited from a parent instance (§3-2-2) reaches only the child's
    // peel-maskable kinds — Normal and Shape. Mesh/Effect are not peeled (no quad
    // affine / can't threshold a deformed-mesh UV), and nested Instances are
    // deliberately single-level, so those child kinds escape the parent clip —
    // the same kinds an own-mask can't gate either.
    for (final batch in batches) {
      switch (batch.kind) {
        case fbs.DrawBatchKind.Normal:
          backend.emitNormal(canvas, batch, frame, this, maskCtx, inheritedMask);
        case fbs.DrawBatchKind.Mesh:
          backend.emitMesh(canvas, batch, frame, this);
        case fbs.DrawBatchKind.Effect:
          backend.emitEffect(canvas, batch, frame, this);
        case fbs.DrawBatchKind.Instance:
          _emitInstanceBatch(canvas, backend, batch, frame, maskCtx);
        case fbs.DrawBatchKind.Shape:
          backend.emitShape(canvas, batch, frame, this, maskCtx, inheritedMask);
        case fbs.DrawBatchKind.Mask: // §9: coverage only, never colour
        case fbs.DrawBatchKind.Nines: // TODO(phase 2): §11 9-slice
        case fbs.DrawBatchKind.Text: // no SDK render path
          break; // kinds not yet ported are skipped
      }
    }
  }

  /// Emits one Instance batch (§8): draws each child animation in-place.
  ///
  /// The child is a whole nested player whose clock the Brain advanced during
  /// [updateMs]; all that is left here is placement. Its parts are in *child*
  /// space, so the instance part's world matrix goes on the canvas and the child
  /// paints beneath it — where the flagship instead re-parents a retained
  /// CanvasItem and lets Godot's scene graph do the multiply.
  ///
  /// The whole child occupies exactly the instance part's z-slot: it can never
  /// interleave with this player's other parts. Painting it recursively at this
  /// point in the batch loop reproduces that ordering for free.
  void _emitInstanceBatch(ui.Canvas canvas, RenderBackend backend,
      fbs.DrawBatch batch, DrawFrame frame, MaskContext? maskCtx) {
    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= frame.drawOrder.length) break;
      final part = frame.drawOrder[rank];
      final state = _instances.slotFor(part);
      // Invisible is the fail-safe: no slot (unresolved pack) or a
      // Brain-reported dead child both draw nothing.
      if (state == null || !state.visible) continue;

      final world = GeometryBuilder.world2dOf(part, frame);
      if (world == null) continue;

      // The instance part's own alpha modulates the entire child, and compounds
      // down a nested chain. `alphaOf` already folds in this frame's own scale.
      final alpha = frame.alphaOf(part);
      if (alpha <= 0.0) continue;

      // §3-2-2: this player's mask reaches an instance child that is itself a
      // mask target, gating the WHOLE sub-animation with the instance part's own
      // rank + polarity (not the child's individual parts). The coverage + meta
      // come from this player; only the UV affine is re-composed with the slot
      // matrix so the child's local fragments sample the parent's coverage.
      // Single-level (the child does not forward it to its own instances).
      final ownBits = maskCtx?.bitsForTarget(rank, flagsFor(part));
      final inherited =
          ownBits == null ? null : maskCtx!.drawFor(ownBits).composeSlot(world);

      // The child draws through THIS player's [backend] (shared across the
      // recursion) under the composed transform — Canvas: save+transform; GPU:
      // the world matrix folds into the projection. So the child's geometry lands
      // in the same target/canvas at the instance part's place.
      backend.pushTransform(canvas, world);
      state.child._paintTree(
        canvas,
        backend,
        frameOverride: state.childFrame,
        alphaScale: alpha,
        inheritedMask: inherited,
      );
      backend.popTransform(canvas);
    }
  }

  /// Builds this frame's mask plan and rasterises its coverage bitmap, or null
  /// when nothing masks this frame (the overwhelmingly common case — the whole
  /// mask path then costs one [MaskPlan.build] walk of `draw_order`).
  MaskContext? _buildMaskContext(
      RenderBackend backend, DrawFrame frame, List<fbs.DrawBatch> batches) {
    if (_maskFlags.isEmpty) return null;
    final plan = MaskPlan.build(frame, _maskFlags);
    if (plan == null) return null;

    // Writers need their own texture; take it from the batch that owns each
    // rank, which is exactly what the colour path resolves against.
    final textureByRank = <int, int>{};
    for (final batch in batches) {
      for (var k = 0; k < batch.count; k++) {
        textureByRank[batch.startRank + k] = batch.textureHash;
      }
    }

    // The backend rasterises the coverage (Canvas: an offscreen bitmap; GPU: a
    // render-target texture) and owns its lifetime. Null when the mask program is
    // still compiling or no writer contributed — draw unmasked.
    return backend.renderCoverage(frame, this, plan, textureByRank);
  }

  // --- InstanceChild (§8): this player driven as another's instance child ---

  @override
  SsContext get instanceContext => _context;

  @override
  double get instanceFrameNo => frameNo;

  @override
  void instancePlay() {
    if (_disposed) return;
    // Required, not a courtesy: `ss_instance_slot_step` configures this child
    // but leaves it stopped, and an independent child's per-tick
    // `Context::update` no-ops until something starts it. `play()` also snaps to
    // the start frame the step just configured and re-arms our nested slots.
    play();
  }

  @override
  void instanceResetSlots() {
    if (_disposed) return;
    _resetSlots();
  }

  @override
  void instanceStop() {
    if (_disposed) return;
    stop();
  }

  @override
  void instanceStepSlots(double childFrame, double deltaMs, bool childLooped) {
    if (_disposed) return;
    // No `ss_runtime_update` — our animation clock belongs to the parent's slot,
    // which has already moved us to `childFrame`. Only the slot-based kinds
    // still owe a tick.
    _stepSlots(childFrame, deltaMs, childLooped);
  }

  @override
  void instanceDispose() => dispose();

  // --- Teardown ------------------------------------------------------------

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // The backend owns the coverage bitmap + shader pools (and any GPU
    // resources); release them.
    _backend.dispose();
    // The slots borrow `_resource`; they must go first. Instance children own
    // their own Context/Resource and are torn down recursively from here.
    _effects.dispose();
    _instances.dispose();
    ssRuntime.unregisterFromGc(this);
    ssRuntime.destroyContext(_context);
    ssRuntime.destroyResource(_resource);
  }
}
