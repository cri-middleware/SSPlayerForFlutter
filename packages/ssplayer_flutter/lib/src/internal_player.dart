import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/ssruntime_dart.dart';
import 'playback.dart';
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
import 'render/part_color.dart';
import 'render/part_override.dart';
import 'render/root_transform.dart';
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
    this._partNames,
    this._effects,
    this._backend,
    this._ownsTextures,
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

  /// Called when the backend finishes preparing a resource the last paint drew
  /// without (a GPU texture upload), so the frame should be painted again.
  ///
  /// L3 points this at its `notifyListeners`. Without it a player that is not
  /// continuously animating — paused, seeked, or drawn once — keeps whatever the
  /// first, texture-less paint produced, which for a single-atlas animation is a
  /// blank frame. Fires outside paint (the upload awaits), and only on the
  /// backend this player owns, so an instance child (which draws through its
  /// parent's) does not double-notify.
  ui.VoidCallback? onNeedsRepaint;

  /// Whether [dispose] should release [textures]. True only when [load] created
  /// the registry itself; a caller-supplied one stays the caller's (it may well
  /// outlive this player or be shared between several), and an instance child
  /// draws from its parent's and must never release it.
  final bool _ownsTextures;

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

  /// Pack-level part name → index table, read once from the `.ssab` `PartData`
  /// alongside [_maskFlags]. Backs the by-name part-override overloads; indices
  /// are stable within one `.ssab` (§65-4).
  final PartNameTable _partNames;

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

  /// drawRank → texture hash for [_buildMaskContext]. Rebuilt each frame and
  /// consumed inside `renderCoverage`, which never retains it.
  final Map<int, int> _textureByRankScratch = <int, int>{};

  /// The instance part's world matrix in [_emitInstanceBatch]. One per player,
  /// not per part: an instance child recurses with its OWN player (and so its
  /// own scratch), and the matrix is fully consumed — composed into the mask
  /// affine, then pushed onto the backend's transform stack, which copies it —
  /// before the next part refills it.
  final Float64List _world2dScratch = Float64List(16);

  /// The render backend that turns this player's `DrawBatch`es into pixels —
  /// Canvas (`Canvas.drawVertices`) by default, flutter_gpu when requested and
  /// available. Chosen in [load] from the requested [SpriteStudioBackend] via the
  /// capability probe. Owns the shader pools, batch paint and coverage resources;
  /// disposed with the player.
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
  bool get subFrameEnabled => _subFrame;
  set subFrameEnabled(bool value) {
    _subFrame = value;
    for (final part in _instances.parts) {
      _instances.slotFor(part.partIndex)?.child.subFrameEnabled = value;
    }
    // Effects sample `subFrameEnabled ? frame : floor(frame)`, so on a frozen frame the
    // toggle would otherwise not show until something advances the clock. The
    // flagship's `setSubFrameEnabled` re-resolves for the same reason.
    _stepSlots(frameNo, 0.0, false);
  }

  bool _subFrame = true;

  /// The player-level flip / offset (default [SsRootTransform.identity]) — see
  /// [SsRootTransform] for what it is and why it lives at this layer.
  ///
  /// Read by exactly two consumers, which is the whole point of storing it here:
  /// [paint] hands it to the backend's `beginFrame`, and [partWorldMatrix] folds
  /// it into the pose it reports. Split them and a follower comes off its part
  /// the moment the player is flipped.
  ///
  /// **Top-level players only.** An instance child draws through its parent's
  /// backend under the parent's transform, so the parent's flip already covers
  /// it; setting one here too would apply it twice.
  SsRootTransform rootTransform = SsRootTransform.identity;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  // The SoA out-parameter scratch cells and the Context/Resource NativeFinalizers
  // moved into the native SsRuntime backend (ssruntime_dart) so this layer is
  // dart:ffi-free and compiles for the web. GC backstop is [SsRuntime.registerForGc].

  /// Loads `ssab` into a fresh Context, binds it, and recursively spawns any
  /// instance children (§8).
  ///
  /// Steps: parse the static Dart-side tables → create resource → create
  /// context → bind → set coordinate system. The Brain does NOT validate the
  /// `.ssab` (unchecked parse, undefined behaviour on malformed input);
  /// [SsRuntime.createResourceCopy] rejects a non-`.ssab` header, but that is an
  /// identify check, not full validation. Do not load `.ssab` from untrusted
  /// sources.
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
    @visibleForTesting RenderBackend? renderBackendOverride,
  }) {
    // Parse the static Dart-side tables first. These are pure, bounds-checked
    // FlatBuffers reads that throw on a corrupt pack — doing them BEFORE any
    // native allocation means a malformed pack fails here and leaks no Brain-side
    // Context/Resource. Mask roles (§1-2) and part names (§65) live in the static
    // `.ssab` PartData, the effect bindings in the effect block — all read once
    // here rather than per frame; the effect/instance slots themselves are lazy.
    final maskFlags = MaskPartFlags.readAll(ssab);
    final partNames = PartNameTable.readAll(ssab);
    final effectParts = EffectPart.readAll(ssab);
    final instanceParts = InstancePart.readAll(ssab);
    final ownPackHash = InstancePart.packHashOf(ssab);

    // Copy mode: the Brain copies the bytes onto its own heap and retains no
    // pointer into `ssab` (the native backend does a zero-copy leaf hand-off).
    // Copy is also the only mode that works on the Web/WASM path, where the
    // Body's and Brain's memory spaces differ. Rejects a non-`.ssab` header.
    final resource = ssRuntime.createResourceCopy(ssab);
    if (resource == null) {
      throw StateError('ss_resource_create_copy returned null (bad .ssab?)');
    }

    final context = ssRuntime.createContext();
    if (context == null) {
      ssRuntime.destroyResource(resource);
      throw StateError('ss_runtime_create returned null');
    }

    final registry = textures ?? TextureRegistry();
    // Until the constructor attaches the GC finalizer, the Context+Resource are
    // owned by nothing, so any throw in between must destroy them by hand.
    late final SpriteStudioInternalPlayer player;
    try {
      if (!ssRuntime.bindResource(context, resource)) {
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

      // Resolve the requested backend through the capability probe: gpu only when
      // flutter_gpu is actually usable, else Canvas (which never throws). A whole
      // instance tree shares one backend (children draw through the parent's), so
      // the override is applied at the root only; children inherit it by drawing
      // through the same instance. Tests use it to observe the per-frame lifetime
      // contract without a real engine.
      final renderBackend = renderBackendOverride ??
          (resolveBackend(backend) == SpriteStudioBackend.gpu
              ? createFlutterGpuBackend()
              : CanvasBackend());
      player = SpriteStudioInternalPlayer._(
        context,
        resource,
        registry,
        maskFlags,
        partNames,
        EffectSlots(resource, effectParts),
        renderBackend,
        textures == null, // we built `registry`, so we release it
      );
      // Route the backend's "a resource I was preparing is ready" signal up to
      // whoever drives repaints (L3 sets [onNeedsRepaint] to notifyListeners).
      renderBackend.onResourcesReady = () => player.onNeedsRepaint?.call();
    } catch (_) {
      ssRuntime.destroyContext(context);
      ssRuntime.destroyResource(resource);
      rethrow;
    }

    // Instance children (§8). Unlike effect slots these cannot be lazy: each is
    // a whole nested player, and `ss_instance_slot_step` needs its Context from
    // the very first tick. `_instances` is assigned right after construction
    // because building the children needs the finished parent in scope.
    //
    // Nesting is expanded eagerly and without a depth cap, like every sibling
    // player: a cap buys nothing against real content (it would only ever fire
    // on nesting the SS7 editor cannot practically author) while silently
    // dropping the innermost child if it ever did. A pathological cyclic `.ssab`
    // recurses until it exhausts the stack; the per-child guard below then unwinds
    // it, skipping the offending child rather than crashing the load.
    player._instances = InstanceSlots<SpriteStudioInternalPlayer>.build(
      instanceParts,
      (part) {
        final bytes = InstancePart.resolvePack(
          part,
          ownBytes: ssab,
          ownPackHash: ownPackHash,
          packs: instancePacks,
        );
        if (bytes == null) return null; // unresolved external pack
        final SpriteStudioInternalPlayer child;
        try {
          child = SpriteStudioInternalPlayer.load(
            bytes,
            // Children share the parent's registry: cellmap hashes are global, so
            // a shared atlas resolves once and a child-only cellmap simply adds to
            // it. The host loads each pack's textures into this same registry.
            textures: registry,
            instancePacks: instancePacks,
            backend: backend, // inherit the parent's backend choice
          );
        } catch (_) {
          // A corrupt / unloadable child pack is skipped (not drawn) rather than
          // failing the whole parent load — same outcome as an unresolved pack.
          return null;
        }
        if (!child.setupAnimation(part.animeName)) {
          // The pack resolved but the animation name did not — authored garbage.
          child.dispose();
          return null;
        }
        // The SDK requires this to propagate, and recursively: a child left on
        // the other setting stutters at integer frames while its parent is
        // smooth.
        child.subFrameEnabled = player.subFrameEnabled;
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
    if (ok) {
      // A different animation has different effect/instance keys — drop each
      // slot's "last started key" memory so the new animation fires its own.
      _resetSlots();
      // Then resolve them *at* the frame we just rewound to. `setupAnimation`
      // poses the first frame without playing (the idle pose the SDK's player
      // guidelines call for), and without this the instance children are
      // missing from that pose until something advances the clock. The flagship
      // ends its `_fetchAnimation` with the same re-resolve.
      _stepSlots(frameNo, 0.0, false);
    }
    return ok;
  }

  /// Canonical name→id hash (never re-implement FNV-1a on the Dart side).
  int hashString(String name) => ssRuntime.hashString(name);

  void play([double? startFrame]) {
    _ensureAlive();
    if (startFrame == null) {
      ssRuntime.play(_context);
    } else {
      ssRuntime.playWithStartFrame(_context, startFrame);
    }
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

  void resume() {
    _ensureAlive();
    ssRuntime.resume(_context);
  }

  void stop() {
    _ensureAlive();
    ssRuntime.stop(_context);
  }

  bool get isPlaying => ssRuntime.isPlaying(_context);

  /// Whether playback is paused. Note the Brain keeps [isPlaying] `true` while
  /// paused (pause is a *hold*, not a stop). `false` before the first `play`
  /// and after `stop` — the Brain keeps "paused" implying "playing" — so this
  /// can be read on its own.
  bool get isPausing => ssRuntime.isPausing(_context);

  /// Every configured loop has played. Sticky until the next play/setup, so
  /// callers wanting a one-shot notification must take the rising edge.
  bool get isFinished => ssRuntime.isFinished(_context);

  bool get justLooped => ssRuntime.isLooped(_context);

  /// Which way the playhead is actually travelling — see
  /// [SpriteStudioPlayer.isPlayingForward].
  bool get isPlayingForward => ssRuntime.isPlayingForward(_context);
  double get frameNo => ssRuntime.frameNo(_context);
  int get startFrame => ssRuntime.startFrame(_context);
  int get endFrame => ssRuntime.endFrame(_context);
  int get fps => ssRuntime.fps(_context);

  set loopCount(int count) => ssRuntime.setLoop(_context, count);
  set speedScale(double rate) => ssRuntime.setSpeed(_context, rate);
  set frameRate(int fps) => ssRuntime.setFrameRate(_context, fps);
  /// Moves the playhead, then re-resolves the slot-based kinds (§8) *at the new
  /// frame*. Without that second half an instance child keeps whatever
  /// visibility and child frame the last [updateMs] left it on, so a scrubbed or
  /// frozen frame can drop the children entirely.
  ///
  /// The delta is zero — a seek is a jump, not elapsed time. That is exactly
  /// right for **synced** slots, which are a pure function of the parent frame
  /// (`ss_instance_slot_step` re-seeks the child with `set_frame_relative`, and
  /// an effect slot re-derives its relative frame from `parent_frame`), so they
  /// land where playing to [frame] would have left them. **Independent** slots
  /// ride their own real-time clock and a zero delta deliberately leaves them
  /// untouched: the SDK defines seeking them as undefined
  /// ([InstanceSlot.isIndependent]).
  void seek(double frame) {
    _ensureAlive();
    ssRuntime.seek(_context, frame);
    // Read the frame back rather than reusing the argument: the Brain confines a
    // seek to the animation section, and the slots must see where it landed.
    _stepSlots(frameNo, 0.0, false);
  }

  /// Restricts playback to `[startFrame, endFrame]` of the current animation.
  /// Reflected by [startFrame] / [endFrame], which report the *played* range.
  void setAnimationSection(int startFrame, int endFrame) =>
      ssRuntime.setAnimationSection(_context, startFrame, endFrame);

  void setPlaybackDirection(SsPlaybackDirection direction,
          SsPlaybackStyle style) =>
      ssRuntime.setPlaybackDirection(_context, direction.value, style.value);

  SsPlaybackDirection get playbackDirection =>
      SsPlaybackDirection.fromValue(ssRuntime.playbackDirection(_context));

  SsPlaybackStyle get playbackStyle =>
      SsPlaybackStyle.fromValue(ssRuntime.playbackStyle(_context));

  set frameSkipEnabled(bool skip) => ssRuntime.setSkipFrames(_context, skip);
  bool get frameSkipEnabled => ssRuntime.skipFrames(_context);

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
    _stepSlots(frame, deltaMs, justLooped);
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
        parentFrame: subFrameEnabled ? frame : frame.floorToDouble(),
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

  // --- Part overrides (§65 Override Layer) ---------------------------------
  //
  // An imperative "make this part this colour / cell / hidden now" that wins
  // over both the keyframes and the blend. The Brain applies them at a seam
  // AFTER the keyframe mix and BEFORE FrameData is composed, and it owns the
  // whole table and its lifecycle — so this player keeps no copy and must NOT
  // re-apply them per frame. `setupAnimation` clears everything but
  // `SsOverridePriority.permanent`; a new pack clears everything.
  //
  // Parts are addressed by index; the by-name overloads resolve once through
  // [partNames] (an unknown name is -1, and the call is a no-op returning
  // false). A `false` return means the call was REJECTED — a part whose type
  // the attribute does not apply to (a colour override on a Null part, say)
  // still returns true and is simply ignored at the seam, so never use the
  // return value to decide whether an override is visible.
  //
  // **[setupAnimation] must have run first.** The Brain's override table is a
  // dense per-part array that only `setup_animation` sizes (`bind_resource`
  // empties it), so before an animation is selected EVERY index is out of range
  // and every call here returns false. §65 does not spell this out — it only
  // says `find_part_index` needs setup — but it applies to the setters just as
  // much. [partNames] is read from the pack and so works either way, which is
  // exactly how a caller ends up with a valid index and a failing set.
  //
  // Unlike the Unity player there is no frame cache to invalidate here: [paint]
  // re-reads `getFrameData` every frame, so a set/clear shows up on the next
  // paint. What a paused player DOES need is a repaint — L3
  // `SpriteStudioPlayer` notifies its listeners for exactly that reason.

  /// Pack-level part names / name→index lookup (§65-4). Indices are stable
  /// within one `.ssab`; resolve once and reuse.
  PartNameTable get partNames => _partNames;

  /// Resolves [name] to its part index, or -1 when this pack has no such part.
  int findPartIndex(String name) => _partNames.indexOf(name);

  /// Force-hides [partIndex] ([hide] true) or reverts it to the animation.
  /// With [cascade] the force-hide propagates to the part's descendants.
  ///
  /// Visibility has no priority mode — it always wins, and `setupAnimation`
  /// always clears it. Note the cascade only propagates override-driven hiding:
  /// a keyframe `hide` stays per-part (§65-3-3), so do not add your own parent→
  /// child propagation on top.
  ///
  /// An instance part's own force-hide does NOT reach into its child animation
  /// (a separate context); skipping the child's drawing is the Body's job.
  bool setPartVisibilityOverrideByIndex(int partIndex, bool hide,
      {bool cascade = false}) {
    _ensureAlive();
    if (partIndex < 0) return false;
    // force: 0 = clear/revert, 1 = force-hide (2 = force-visible is reserved).
    return ssRuntime.setPartVisibilityOverride(
        _context, partIndex, hide ? 1 : 0,
        cascade: cascade);
  }

  /// Index form of [setPartVisibilityOverride].
  bool setPartVisibilityOverride(String partName, bool hide,
          {bool cascade = false}) =>
      setPartVisibilityOverrideByIndex(findPartIndex(partName), hide, cascade: cascade);

  /// Clears [partIndex]'s visibility override (revert to the animation).
  bool clearPartVisibilityOverrideByIndex(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return ssRuntime.clearPartVisibilityOverride(_context, partIndex);
  }

  /// Index form of [clearPartVisibilityOverride].
  bool clearPartVisibilityOverride(String partName) =>
      clearPartVisibilityOverrideByIndex(findPartIndex(partName));

  /// Overrides [partIndex]'s colour with one value flowed to all four corners.
  /// Normal parts only — other types return true and are ignored at the seam.
  ///
  /// [color] is read in the same 8-bit sRGB space as the authored PartColor and
  /// the Brain pre-multiplies the part's composed alpha itself, so do NOT
  /// gamma-convert it or fold `PartState.alpha` in. Overriding a part the
  /// animation gave no PartColor makes the Brain emit it as a 5-vertex fan
  /// instead of a quad; the bake path handles both, so nothing else changes.
  bool setPartColorOverrideByIndex(int partIndex, ui.Color color,
      {SsBlendOp blendOp = SsBlendOp.mix,
      SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation}) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return ssRuntime.setPartColorOverride(
        _context, partIndex, blendOp.value, packRgba(color), priority.value);
  }

  /// Index form of [setPartColorOverride].
  bool setPartColorOverride(String partName, ui.Color color,
          {SsBlendOp blendOp = SsBlendOp.mix,
          SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      setPartColorOverrideByIndex(findPartIndex(partName), color,
          blendOp: blendOp, priority: priority);

  /// Four-corner form of [setPartColorOverride] (a gradient). The corner order
  /// is the Brain's: left-top, right-top, left-bottom, right-bottom — swapping
  /// `leftBottom` and `rightTop` silently mirrors the gradient.
  bool setPartColorOverrideCornersByIndex(
    int partIndex,
    SsCornerColors corners, {
    SsBlendOp blendOp = SsBlendOp.mix,
    SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation,
  }) {
    _ensureAlive();
    if (partIndex < 0) return false;
    final packed = Uint32List(4)
      ..[0] = packRgba(corners.leftTop)
      ..[1] = packRgba(corners.rightTop)
      ..[2] = packRgba(corners.leftBottom)
      ..[3] = packRgba(corners.rightBottom);
    return ssRuntime.setPartColorOverrideCorners(
        _context, partIndex, blendOp.value, packed, priority.value);
  }

  /// Index form of [setPartColorOverrideCorners].
  bool setPartColorOverrideCorners(
    String partName,
    SsCornerColors corners, {
    SsBlendOp blendOp = SsBlendOp.mix,
    SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation,
  }) =>
      setPartColorOverrideCornersByIndex(findPartIndex(partName), corners,
          blendOp: blendOp, priority: priority);

  /// Clears [partIndex]'s colour override (revert to the animation).
  bool clearPartColorOverrideByIndex(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return ssRuntime.clearPartColorOverride(_context, partIndex);
  }

  /// Index form of [clearPartColorOverride].
  bool clearPartColorOverride(String partName) =>
      clearPartColorOverrideByIndex(findPartIndex(partName));

  /// Makes [partIndex] draw a different cell. [cellmapName] carries NO `.ssce`
  /// extension. Normal + Mask parts only.
  ///
  /// The cell is resolved once, here — an unresolvable cellmap/cell name fails
  /// immediately (false) rather than costing a hash lookup per frame. Passing
  /// two empty names reverts the part to the animation. If the new cell lives on
  /// another texture the batch split changes; [paint] just re-reads
  /// `draw_batches`, so only a caller that assumed a fixed batch count breaks.
  bool setPartCellOverrideByIndex(int partIndex, String cellmapName, String cellName,
      {SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation}) {
    _ensureAlive();
    if (partIndex < 0) return false;
    // (0, 0) is the Brain's "follow the animation" sentinel, and an empty name
    // hashes to 0 — so empty/empty reverts, exactly as documented.
    return ssRuntime.setPartCellOverride(
        _context,
        partIndex,
        _hashName(cellmapName),
        _hashName(cellName),
        priority.value);
  }

  /// Index form of [setPartCellOverride].
  bool setPartCellOverride(
          String partName, String cellmapName, String cellName,
          {SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      setPartCellOverrideByIndex(findPartIndex(partName), cellmapName, cellName,
          priority: priority);

  /// Clears [partIndex]'s cell override (revert to the animation).
  bool clearPartCellOverrideByIndex(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return ssRuntime.clearPartCellOverride(_context, partIndex);
  }

  /// Index form of [clearPartCellOverride].
  bool clearPartCellOverride(String partName) =>
      clearPartCellOverrideByIndex(findPartIndex(partName));

  /// Clears every per-part override on this player (all parts, all attributes).
  /// Does not recurse into instance children — each child owns its own context
  /// and therefore its own override table.
  bool clearAllPartOverrides() {
    _ensureAlive();
    return ssRuntime.clearAllPartOverrides(_context);
  }

  /// FNV-1a via the Brain's own hasher, so a cell override keys on exactly the
  /// hashes the pack was built with (never re-implement it in Dart). An empty
  /// name hashes to 0 — the revert sentinel.
  int _hashName(String name) => name.isEmpty ? 0 : ssRuntime.hashString(name);

  // --- Part following (read a part's live pose) ----------------------------
  //
  // The read mirror of the overrides above: those push a pose in, these pull the
  // composed pose out, so a Body-side follower — the [SpriteStudioPartAnchor]
  // widget, a Flame component — can stick to a part (ForUnity's part tracker /
  // ForGodot's part attachment, done the Flutter way). No C-API of its own: the
  // Brain already emits a world matrix per part every update; these just
  // re-sample the current frame and slice it. Address parts by index (resolve a
  // name once through [partIndexOf]); the results are borrows recomputed per
  // call, so read them within the frame.

  /// The current-frame world transform of [partIndex] as a [Matrix4] in
  /// player-local (animation) space, or null when the index is out of range or
  /// no frame is available.
  ///
  /// Only the 2D affine (`m0, m1, m4, m5, m12, m13`) is carried, with an identity
  /// Z row — the same contract as [GeometryBuilder.world2dOf] the Instance path
  /// places children through, so a follower lands exactly where the part draws.
  /// The Y-Down flip is already baked in by the Brain (never re-flip); position,
  /// rotation, scale and skew all ride in the matrix — hand it straight to a
  /// `Transform` widget.
  ///
  /// [rootTransform] is folded in, so this is the pose as **drawn**, flip and
  /// offset included. Note that the result can be a *reflection* — a matrix no
  /// rotation can express — and that this port carries that fact without loss
  /// precisely because it never decomposes: `Transform` takes the whole
  /// [Matrix4]. Callers that do decompose (reading a rotation out of it) inherit
  /// the siblings' caveats and should check `determinant()` first. The sign is
  /// the *product* of this flip and any mirroring authored on the part, so the
  /// two cancel in pairs — never infer it from the flip settings.
  ///
  /// Re-reads `getFrameData` for the current (sub-)frame first: the SoA world
  /// buffer reflects whichever frame was last parsed (call `get_frame_data`
  /// before any SoA getter), and this samples the same frame [paint] draws
  /// (fractional when [subFrameEnabled], else floored) so the pose matches on screen.
  Matrix4? partWorldMatrix(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return null;
    final sampled = subFrameEnabled ? frameNo : frameNo.floorToDouble();
    if (getFrameData(sampled) == null) return null;
    final w = worldMatrices();
    final m = partIndex * DrawFrame.worldStride;
    if (m + DrawFrame.worldStride > w.length) return null;
    // Identity seeds [10]/[15] = 1; overwrite only the six affine terms so a
    // stray Z scale or perspective row can never leak into `Transform`.
    final world = Matrix4.identity()
      ..[0] = w[m]
      ..[1] = w[m + 1]
      ..[4] = w[m + 4]
      ..[5] = w[m + 5]
      ..[12] = w[m + 12]
      ..[13] = w[m + 13];
    // The same root transform `beginFrame` gave the backend — read from the one
    // place that resolves it, so the pose can never drift from the geometry.
    return rootTransform.compose(world);
  }

  /// Whether [partIndex] is hidden on the current frame — the keyframe `hide`
  /// composed with any visibility override (§65), read from the same FrameData
  /// the draw path consumes. A part absent from this frame's `parts` reads as not
  /// hidden (its world matrix is still valid), matching the flagship followers.
  /// Out-of-range → false.
  bool partHidden(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    final sampled = subFrameEnabled ? frameNo : frameNo.floorToDouble();
    final parts = getFrameData(sampled)?.parts;
    if (parts == null) return false;
    for (final p in parts) {
      if (p.partIndex == partIndex) return p.$hide;
    }
    return false;
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
  /// backend. Nines / Text are pre-cut seams and not drawn; BoxFit / scale
  /// placement into [dst] is likewise not supported.
  ///
  /// **Call this at most once per frame per player.** The hooks below recycle
  /// resources that stay live until the recorded picture rasterises, and this is
  /// the only place they run — so painting one player into two adapters (two
  /// [SpriteStudioView]s, a view plus a Flame component) within a single frame
  /// makes the second call free and rebind what the first call's already-recorded
  /// draws still point at: a disposed coverage bitmap, or a pooled shader whose
  /// uniforms are overwritten before it rasterises. The visible result is the
  /// wrong mask or tint in the first view, or "Image has been disposed". Give
  /// each view its own player; they are cheap next to the textures, and a shared
  /// [TextureRegistry] passed to both `load`s keeps the atlases single-copy.
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _ensureAlive();
    // Per-FRAME, not per-player: both hooks recycle resources that stay live
    // until the recorded picture rasterises, so an instance child must never run
    // them — doing so frees/rebinds what the parent's already-recorded draws are
    // still pointing at (a disposed coverage bitmap, or a pooled shader whose
    // uniforms get overwritten before it is rasterised).
    _backend.releaseCoverage();
    _backend.rewindShaderPools();
    _backend.beginFrame(canvas,
        dst: dst, sourceSize: sourceSize, root: rootTransform);
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
    InheritedMask? inheritedMask,
  }) {
    // Sub-frame ON (default): sample the fractional frame for smooth playback;
    // OFF: snap to the integer frame. This is the ONLY place a frame gets
    // rounded — the playback state that feeds `ss_instance_slot_step` stays raw.
    final sampled = frameOverride ?? frameNo;
    final frameData = getFrameData(subFrameEnabled ? sampled : sampled.floorToDouble());
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
    final frame = _geometry.buildFrame(
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

    // Masking (§9) is a pre-pass: collect this frame's writers, rasterise their
    // coverage bitmap, then let the batch loop test each target against it.
    // Unlike the flagship's viewport (1-frame latency, size classes, shrink
    // hysteresis) `toImageSync` gives us the bitmap within this same frame, so
    // none of that machinery is needed.
    // The composition (§2-6) reaches the own mask too — a caller that opted out
    // settles "not masked" for this whole player, its own writers included.
    final maskCtx = _buildMaskContext(backend, frame, batches,
        inheritedMask?.comp ?? MaskComposition.identity);

    // A mask inherited from a parent instance (§3-2-2) reaches the child's
    // peel-maskable kinds — Normal, Shape and Mesh — resolved per part against
    // the composed settings. Effect is not peeled (its plan carries its own
    // colours), so it escapes the parent clip — the same kind an own-mask can't
    // gate either. A nested Instance forwards it another level down.
    for (final batch in batches) {
      switch (batch.kind) {
        case fbs.DrawBatchKind.Normal:
          backend.emitNormal(canvas, batch, frame, this, maskCtx, inheritedMask);
        case fbs.DrawBatchKind.Mesh:
          backend.emitMesh(canvas, batch, frame, this, maskCtx, inheritedMask);
        case fbs.DrawBatchKind.Effect:
          backend.emitEffect(canvas, batch, frame, this);
        case fbs.DrawBatchKind.Instance:
          _emitInstanceBatch(
              canvas, backend, batch, frame, maskCtx, inheritedMask);
        case fbs.DrawBatchKind.Shape:
          backend.emitShape(canvas, batch, frame, this, maskCtx, inheritedMask);
        case fbs.DrawBatchKind.Mask: // §9: coverage only, never colour
        case fbs.DrawBatchKind.Nines: // §11 9-slice: not yet supported
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
  void _emitInstanceBatch(
      ui.Canvas canvas,
      RenderBackend backend,
      fbs.DrawBatch batch,
      DrawFrame frame,
      MaskContext? maskCtx,
      InheritedMask? inheritedMask) {
    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= frame.drawOrder.length) break;
      final part = frame.drawOrder[rank];
      final state = _instances.slotFor(part);
      // Invisible is the fail-safe: no slot (unresolved pack) or a
      // Brain-reported dead child both draw nothing.
      if (state == null || !state.visible) continue;

      final world = GeometryBuilder.world2dOf(part, frame, _world2dScratch);
      if (world == null) continue;

      // The instance part's own PartColor (§10) tints the entire child. The SDK
      // spec's part-type table (§1-2) covers Normal / Mesh / Shape only, but the
      // runtime emits `part_color` for any part that carries the attribute, so
      // an instance part can have one — read whole-only, like a Mesh.
      final st = frame.partOf(part);
      final pc = st == null ? null : PartColor.read(frame.partsColor, st);

      // The instance part's own alpha modulates the entire child, and compounds
      // down a nested chain (see [PartColor.instanceAlpha] for the PartColor
      // case, where the corner alpha replaces `PartState.alpha`).
      final alpha = PartColor.instanceAlpha(pc,
          partAlpha: frame.alphaOf(part), chainScale: frame.alphaScale);
      if (alpha <= 0.0) continue;

      // §2-6 / §3-2-2: a mask reaching this instance part applies to the whole
      // sub-animation, but the calling part's settings do NOT replace the
      // callee's — they compose (`mask_influence` AND, `visible_inside_mask` OR)
      // and each child part resolves its own test from the pair. So what goes
      // down is the composed context, not a finished test.
      //
      // The coverage that reaches the child is this player's own if it has one
      // (a fragment can test only one), else the one this player itself
      // inherited, forwarded another level. Only the UV affine is re-composed
      // with the slot matrix, so the child's local fragments sample it correctly.
      // Scope (§2-1) is settled here, at the instance part's rank.
      final flags = flagsFor(part);
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final source = ownBits != null
          ? maskCtx!.drawFor(ownBits)
          : inheritedMask?.drawFor(flags);
      final inherited =
          (inheritedMask ?? const InheritedMask(comp: MaskComposition.identity))
              .forChild(flags, source?.composeSlot(world));

      // The child draws through THIS player's [backend] (shared across the
      // recursion) under the composed transform — Canvas: save+transform; GPU:
      // the world matrix folds into the projection. So the child's geometry lands
      // in the same target/canvas at the instance part's place.
      // The instance part's PartColor tints the child as a GROUP — one filter
      // over the finished subtree — where alpha instead folds per-part through
      // [alphaScale]. The two differ deliberately: a group *alpha* disagrees
      // with the flagship's per-part modulate wherever child parts overlap (§8),
      // while a group *colour* is the only reading available at all, since the
      // formula's offset term (Mix / Add / Sub) cannot be folded into a child's
      // vertex colours. `rate == 0` yields no matrix and no layer.
      final tint = pc?.wholeTintMatrix();
      backend.pushTransform(canvas, world);
      if (tint != null) backend.pushGroupTint(canvas, tint);
      state.child._paintTree(
        canvas,
        backend,
        frameOverride: state.childFrame,
        alphaScale: alpha,
        inheritedMask: inherited,
      );
      if (tint != null) backend.popGroupTint(canvas);
      backend.popTransform(canvas);
    }
  }

  /// Builds this frame's mask plan and rasterises its coverage bitmap, or null
  /// when nothing masks this frame (the overwhelmingly common case — the whole
  /// mask path then costs one [MaskPlan.build] walk of `draw_order`).
  MaskContext? _buildMaskContext(RenderBackend backend, DrawFrame frame,
      List<fbs.DrawBatch> batches, MaskComposition comp) {
    if (_maskFlags.isEmpty) return null;
    // NB no early-out on `!comp.influence`: the AND-chain settles the *targets*,
    // not the writers, and a clipping writer stays a target of its own mask
    // regardless (`mask_write` does not compose, §2-6). The coverage is still
    // needed for those.
    final plan = MaskPlan.build(frame, _maskFlags);
    if (plan == null) return null;

    // Writers need their own texture; take it from the batch that owns each
    // rank, which is exactly what the colour path resolves against.
    final textureByRank = _textureByRankScratch..clear();
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
    // Decoded atlases are native bitmap memory the GC cannot see, so a dropped
    // registry leaks a full texture set per load. Children share ours and have
    // already run their own dispose above with `_ownsTextures == false`.
    if (_ownsTextures) textures.dispose();
    ssRuntime.unregisterFromGc(this);
    ssRuntime.destroyContext(_context);
    ssRuntime.destroyResource(_resource);
  }
}
