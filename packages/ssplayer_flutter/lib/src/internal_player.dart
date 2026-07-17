import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/ssruntime_dart.dart';
import 'render/blend.dart';
import 'render/effect.dart';
import 'render/geometry_builder.dart';
import 'render/instance.dart';
import 'render/mask.dart';
import 'render/part_color.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;
import 'texture_registry.dart';

/// Longest edge, in pixels, of the mask coverage bitmap (§3-2). The bitmap is
/// stretched over the writers' bounding box, so this is purely a quality knob;
/// the flagship caps at the same 1024 (≤ 4 MiB RGBA8).
const double _maxCoverageDim = 1024.0;

/// Layer 2 — the Widget-agnostic drawing engine (ports the SDK's
/// `SSInternalPlayer`).
///
/// Owns the FFI [Resource]/[Context] lifecycle, advances time, pulls the
/// per-frame `FrameData` + SoA buffers from the Brain, and (will) bake them
/// into `ui.Vertices` for `Canvas.drawVertices`. It is `dispose`-able and
/// reusable from higher layers (Player) or headless tests.
class SpriteStudioInternalPlayer implements ffi.Finalizable, InstanceChild {
  SpriteStudioInternalPlayer._(
    this._context,
    this._resource,
    this.textures,
    this._maskFlags,
    this._effects,
  ) {
    // Backstop finalizers: if the caller forgets dispose(), the Brain-side
    // Context/Resource are still reclaimed on GC. The Arc refcount inside the
    // runtime makes destroy order irrelevant. The Brain owns its own copy of
    // the `.ssab` bytes (copy mode), so there is no Body-side buffer to keep
    // alive or leak on the GC-only path.
    _contextFinalizer.attach(this, _context.cast(), detach: this);
    _resourceFinalizer.attach(this, _resource.cast(), detach: this);
  }

  ffi.Pointer<ffi.Void> _context;
  ffi.Pointer<ffi.Void> _resource;

  /// texture_hash → decoded image / shader. Populated by the caller.
  final TextureRegistry textures;

  /// Static per-part mask flags (§1-2), read once from the `.ssab` `PartData` at
  /// load — they never change per frame. Empty when the pack has no parts, which
  /// disables the whole mask path.
  final List<MaskPartFlags> _maskFlags;

  MaskPartFlags _flagsFor(int partIndex) => partIndex < _maskFlags.length
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

  /// Pure SoA→`ui.Vertices` baker (Widget/FFI-free); the per-kind builders grow
  /// here as Phase-2 kinds are ported.
  final GeometryBuilder _geometry = GeometryBuilder();

  /// PartColor (§10) + mask-replay (§3-2) fragment program — the shader every
  /// *peeled* part goes through. Compiled once, shared across players.
  static final _LazyProgram _partColorProgram =
      _LazyProgram('packages/ssplayer_flutter/shaders/partcolor.frag');

  /// Mask coverage writer (§3-2-1). Only loaded once an animation actually has
  /// mask writers.
  static final _LazyProgram _maskWriteProgram =
      _LazyProgram('packages/ssplayer_flutter/shaders/mask_write.frag');

  /// Reused `FragmentShader` instances (one per peeled part in a frame).
  /// Each draw in a Picture reads its shader's uniforms at raster time, so parts
  /// in the SAME frame need DISTINCT shader objects; across frames the pool is
  /// re-set (the documented, allocation-free reuse pattern). The cursors are
  /// rewound each [paint].
  final _ShaderPool _partColorShaders = _ShaderPool();

  /// Same, for the coverage pass's writers.
  final _ShaderPool _maskWriteShaders = _ShaderPool();

  /// A 1×1 transparent image bound to the peeled shader's coverage sampler when
  /// the part is not masked (a sampler must always be bound). Shared; never
  /// disposed.
  static ui.Image? _dummyCoverage;

  static ui.Image _ensureDummyCoverage() {
    final existing = _dummyCoverage;
    if (existing != null) return existing;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder); // record nothing → fully transparent
    final picture = recorder.endRecording();
    final image = picture.toImageSync(1, 1);
    picture.dispose();
    return _dummyCoverage = image;
  }

  /// A 1×1 opaque white image — the "shape pixel" a Shape (§11) is composited
  /// against when it goes through the shader as a mask target. Shared; never
  /// disposed.
  static ui.Image? _whitePixel;

  static ui.Image _ensureWhitePixel() {
    final existing = _whitePixel;
    if (existing != null) return existing;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawPaint(ui.Paint()..color = const ui.Color(0xFFFFFFFF));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(1, 1);
    picture.dispose();
    return _whitePixel = image;
  }

  /// This frame's coverage bitmap. Retained past [paint] because the recorded
  /// picture rasterises later; disposed at the start of the next [paint].
  ui.Image? _coverage;

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

  // Reused scratch cells for the SoA out-parameters (avoid per-frame alloc).
  final ffi.Pointer<ffi.Pointer<ffi.Float>> _outFloatPtr =
      calloc<ffi.Pointer<ffi.Float>>();
  final ffi.Pointer<ffi.Pointer<ffi.Uint8>> _outBytePtr =
      calloc<ffi.Pointer<ffi.Uint8>>();
  final ffi.Pointer<ffi.Pointer<ffi.Uint32>> _outU32Ptr =
      calloc<ffi.Pointer<ffi.Uint32>>();
  final ffi.Pointer<ffi.Pointer<ffi.Int32>> _outI32Ptr =
      calloc<ffi.Pointer<ffi.Int32>>();
  final ffi.Pointer<ffi.Size> _outLen = calloc<ffi.Size>();

  // Native-assets: the finalizer function pointers come from the @Native
  // bindings (no DynamicLibrary). Constant, so shared statically.
  static final ffi.NativeFinalizer _contextFinalizer = ffi.NativeFinalizer(
      ffi.Native.addressOf<ffi.NativeFinalizerFunction>(ss_runtime_destroy));
  static final ffi.NativeFinalizer _resourceFinalizer = ffi.NativeFinalizer(
      ffi.Native.addressOf<ffi.NativeFinalizerFunction>(ss_resource_destroy));

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
  }) {
    // `TypedData.address` gives a pointer straight into `ssab`'s Dart-heap
    // backing store; it is only valid as the argument of a *leaf* @Native call
    // (`ss_resource_create_copy` is marked leaf in ffigen.yaml). It requires a
    // non-empty list.
    if (ssab.isEmpty) {
      throw ArgumentError.value(ssab, 'ssab', 'must not be empty');
    }

    // Zero-copy hand-off: the Brain copies the bytes onto its own heap inside
    // this call and never retains the pointer, so we pass `ssab` directly — no
    // Body-side malloc/memcpy. A leaf call reaches no safepoint, so the GC can
    // not move the list mid-call and the pointer stays valid for the whole
    // call. (Copy is also the only mode that works on the Web/WASM path, where
    // the Body's and Brain's memory spaces differ.) ffigen types the C
    // `const unsigned char *` as Pointer<UnsignedChar>, hence the .cast().
    final resource = ss_resource_create_copy(ssab.address.cast(), ssab.length);
    if (resource == ffi.nullptr) {
      throw StateError('ss_resource_create_copy returned null (bad .ssab?)');
    }

    final context = ss_runtime_create();
    if (context == ffi.nullptr) {
      ss_resource_destroy(resource);
      throw StateError('ss_runtime_create returned null');
    }
    if (!ss_runtime_bind_resource(context, resource)) {
      ss_runtime_destroy(context);
      ss_resource_destroy(resource);
      throw StateError('ss_runtime_bind_resource failed');
    }

    // Direct render mode (the default): the Brain fills the SoA buffers this
    // Body reads and skips redundant FrameData vertices/cells/deforms
    // (render_loop §2). The Godot flagship relies on the same default.
    ss_runtime_set_render_mode(context, 0);
    // Coordinate system = 1 (Y-Down) like the flagship: the Brain applies the
    // flip once, so the Body must NOT flip again. Origin/unit are left at the
    // runtime defaults (Center / Pixel) — the flagship sets neither.
    ss_context_set_coordinate_system(context, 1); // 1 = Y-Down

    final registry = textures ?? TextureRegistry();
    final player = SpriteStudioInternalPlayer._(
      context,
      resource,
      registry,
      // Mask roles (§1-2) live in the static `.ssab` PartData, not in FrameData
      // and not in any SoA buffer — read them once here rather than per frame.
      MaskPartFlags.readAll(ssab),
      // Same for the effect bindings; the slots themselves are created lazily.
      EffectSlots(resource, EffectPart.readAll(ssab)),
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
    final cName = name.toNativeUtf8();
    try {
      final ok = ss_runtime_setup_animation(_context, cName.cast());
      // A different animation has different effect/instance keys — drop each
      // slot's "last started key" memory so the new animation fires its own.
      if (ok) _resetSlots();
      return ok;
    } finally {
      malloc.free(cName);
    }
  }

  /// Canonical name→id hash (never re-implement FNV-1a on the Dart side).
  int hashString(String name) {
    final cName = name.toNativeUtf8();
    try {
      return ss_runtime_hash_string(cName.cast());
    } finally {
      malloc.free(cName);
    }
  }

  void play() {
    _ensureAlive();
    ss_runtime_play(_context);
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
    ss_runtime_pause(_context);
  }

  void stop() {
    _ensureAlive();
    ss_runtime_stop(_context);
  }

  bool get isPlaying => ss_runtime_is_playing(_context);

  /// Whether playback is paused. Note the Brain keeps [isPlaying] `true` while
  /// paused (pause is a *hold*, not a stop), and `ss_runtime_pause` *toggles*
  /// this — so callers must gate on it rather than blind-calling `pause()`.
  bool get isPausing => ss_runtime_is_pausing(_context);

  /// Every configured loop has played. Sticky until the next play/setup, so
  /// callers wanting a one-shot notification must take the rising edge.
  bool get isFinished => ss_runtime_is_finished(_context);

  bool get isLooped => ss_runtime_is_looped(_context);
  double get frameNo => ss_runtime_get_frame_no(_context);
  int get startFrame => ss_runtime_get_start_frame(_context);
  int get endFrame => ss_runtime_get_end_frame(_context);
  int get fps => ss_runtime_get_fps(_context);

  set loop(int count) => ss_runtime_set_loop(_context, count);
  set speed(double rate) => ss_runtime_set_animation_speed(_context, rate);
  set frameRate(int fps) => ss_runtime_set_frame_rate(_context, fps);
  void seek(double frame) => ss_runtime_set_frame_no(_context, frame);

  // --- Per-frame update ----------------------------------------------------

  /// Advances internal time. Returns the new (sub-frame) frame number.
  ///
  /// The Brain's `ss_runtime_update` takes a delta whose unit the SDK docs
  /// define (milliseconds per docs/30_core/20_playback_control). We pass the
  /// [delta] in milliseconds; use [updateMs] to control the raw value.
  double update(Duration delta) => updateMs(delta.inMicroseconds / 1000.0);

  double updateMs(double deltaMs) {
    _ensureAlive();
    final frame = ss_runtime_update(_context, deltaMs);
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
    _outBytePtr.value = ffi.nullptr;
    _outLen.value = 0;
    // ffigen out-params are Pointer<Pointer<UnsignedChar>> / Pointer<UintPtr>;
    // cast our ergonomic Uint8/Size scratch cells at the boundary.
    ss_runtime_get_frame_data(
        _context, frameNo, _outBytePtr.cast(), _outLen.cast());
    final data = _outBytePtr.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return null;
    // Zero-copy typed view over the Brain buffer; FrameData reads it in place.
    return fbs.FrameData(data.asTypedList(len));
  }

  // --- SoA buffers (zero-copy typed views, valid until next update) -------

  Float32List _soaFloats(
      void Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Pointer<ffi.Float>>, ffi.Pointer<ffi.UintPtr>)
          getter) {
    _outFloatPtr.value = ffi.nullptr;
    _outLen.value = 0;
    getter(_context, _outFloatPtr, _outLen.cast());
    final data = _outFloatPtr.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return Float32List(0);
    return data.asTypedList(len);
  }

  /// Per-part 4×4 world matrices (parts × 16 floats).
  Float32List worldMatrices() => _soaFloats(ss_runtime_get_world_matrices);

  /// Per-part local vertices (parts × 10 floats: lt,rt,lb,rb,center).
  Float32List localVertices() => _soaFloats(ss_runtime_get_local_vertices);

  /// Per-part local UVs (parts × 10 floats: lt,rt,lb,rb,center in texture pixels).
  Float32List localUvs() => _soaFloats(ss_runtime_get_local_uvs);

  /// Per-part cell meta (parts × 6: pivot_x,pivot_y,w,h,rect_left,rect_top).
  Float32List cellMeta() => _soaFloats(ss_runtime_get_cell_meta);

  // --- Mesh SoA (§8) -------------------------------------------------------
  //
  // Unlike the Normal path's `local_vertices`, mesh vertices arrive **already
  // world-transformed** — do NOT apply the world matrix again. All four data
  // buffers are concatenated across parts and sliced by a CSR prefix sum
  // (length = parts + 1): part `p` owns `[offsets[p], offsets[p + 1])`, and a
  // non-mesh part has an empty range. Empty under Indirect render mode (we set
  // Direct at load).

  Uint32List _soaU32(
      void Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Pointer<ffi.Uint32>>, ffi.Pointer<ffi.UintPtr>)
          getter) {
    _outU32Ptr.value = ffi.nullptr;
    _outLen.value = 0;
    getter(_context, _outU32Ptr, _outLen.cast());
    final data = _outU32Ptr.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return Uint32List(0);
    return data.asTypedList(len);
  }

  Int32List _soaI32(
      void Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Pointer<ffi.Int32>>, ffi.Pointer<ffi.UintPtr>)
          getter) {
    _outI32Ptr.value = ffi.nullptr;
    _outLen.value = 0;
    getter(_context, _outI32Ptr, _outLen.cast());
    final data = _outI32Ptr.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return Int32List(0);
    return data.asTypedList(len);
  }

  /// Mesh per-vertex X coordinates, **world space**, all parts concatenated.
  Float32List meshVerticesX() => _soaFloats(ss_runtime_get_mesh_vertices_x);

  /// Mesh per-vertex Y coordinates (SoA companion to [meshVerticesX]).
  Float32List meshVerticesY() => _soaFloats(ss_runtime_get_mesh_vertices_y);

  /// Mesh per-vertex UVs in **texture-pixel** space, interleaved `[u,v,…]` and
  /// sliced by [meshVertexOffsets] (so vertex `v` is at `2v`, `2v+1`). Static.
  Float32List meshUvs() => _soaFloats(ss_runtime_get_mesh_uvs);

  /// Mesh triangle indices, **part-local and 0-based**, sliced by
  /// [meshIndexOffsets]. Static.
  Int32List meshIndices() => _soaI32(ss_runtime_get_mesh_indices);

  /// CSR prefix sum into [meshVerticesX] / [meshVerticesY] / [meshUvs].
  Uint32List meshVertexOffsets() =>
      _soaU32(ss_runtime_get_mesh_vertex_offsets);

  /// CSR prefix sum into [meshIndices].
  Uint32List meshIndexOffsets() => _soaU32(ss_runtime_get_mesh_index_offsets);

  // --- Shape SoA (§11) -----------------------------------------------------

  /// Shape polygon vertices in **local** space, interleaved `[x,y,…]` at a fixed
  /// stride of 24 floats per part ([ShapeBuffers.stride]) — not CSR like the
  /// mesh. Apply the world matrix; pivot and the Y-Down flip are already in.
  Float32List shapeVertices() => _soaFloats(ss_runtime_get_shape_vertices);

  /// Normalised `[fx,fy,…]` box coordinates paired with [shapeVertices], same
  /// stride — the weights for per-vertex PartColor.
  Float32List shapeVertexBoxCoords() =>
      _soaFloats(ss_runtime_get_shape_vertex_box_coords);

  /// Live vertex count per part for [shapeVertices]. The only valid slice: a
  /// Shape batch's `vertex_count` / `index_count` are 0.
  Int32List shapeVertexCounts() => _soaI32(ss_runtime_get_shape_vertex_counts);

  // --- Effects (§8) --------------------------------------------------------

  /// The effect-hosting parts in this pack (empty when it has none).
  List<EffectPart> get effectParts => _effects.parts;

  /// The particle plan for effect part [partIndex] as of the last [update], or
  /// null when that slot drew nothing (dead, unstarted, or past its lifetime).
  ///
  /// Like the SoA views this aliases the Brain's memory: it is only valid until
  /// that slot is stepped again, i.e. until the next [update].
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
    final count = ss_runtime_get_passed_event_count(_context);
    if (count <= 0) return const [];
    return List<int>.generate(
        count, (i) => ss_runtime_get_passed_event_index(_context, i));
  }

  // --- Rendering -----------------------------------------------------------

  /// Draws the current frame into [canvas] (design §7; ports the Godot flagship
  /// `_drawAnimation`). Gathers the FlatBuffers `FrameData` + SoA views into one
  /// [DrawFrame], centers the animation's world origin in [dst], then dispatches
  /// each `DrawBatch` on its `kind`.
  ///
  /// The **Normal** batch path (see [_emitNormalBatch]) covers plain textured
  /// parts, PartColor (§10) and masking (§9); Mesh, Effect and Instance (§8) have
  /// their own. Shape / Nines / Text are pre-cut seams and skipped for now, as is
  /// BoxFit / scale placement into [dst].
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _ensureAlive();
    // Place the animation's world origin at the center of the destination box.
    final origin = dst?.center ??
        ui.Offset((sourceSize?.width ?? 0) / 2, (sourceSize?.height ?? 0) / 2);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    _paintTree(canvas);
    canvas.restore();
  }

  /// Draws this player's batches into the *already positioned* [canvas] — the
  /// recursive half of [paint].
  ///
  /// Split out for Instance (§8): a child is drawn by calling this under the
  /// instance part's world transform, so it must not re-apply [paint]'s origin
  /// placement. [frameOverride] is the child's Brain-owned clock, and
  /// [alphaScale] the instance chain's opacity.
  void _paintTree(
    ui.Canvas canvas, {
    double? frameOverride,
    double alphaScale = 1.0,
    _MaskDraw? inheritedMask,
  }) {
    // Last frame's coverage has been rasterised by now; release it.
    _coverage?.dispose();
    _coverage = null;
    // Sub-frame ON (default): sample the fractional frame for smooth playback;
    // OFF: snap to the integer frame. This is the ONLY place a frame gets
    // rounded — the playback state that feeds `ss_instance_slot_step` stays raw.
    final sampled = frameOverride ?? frameNo;
    final frameData = getFrameData(subFrame ? sampled : sampled.floorToDouble());
    final batches = frameData?.drawBatches;
    if (frameData == null || batches == null) return;

    // One zero-copy SoA gather per frame (mirrors the flagship's single-block
    // fetch); the views are valid only until the next update. The mesh SoA is
    // fetched only when a Mesh batch is actually present, so the common
    // mesh-free animation pays nothing.
    final frame = DrawFrame.build(
      frameData: frameData,
      world: worldMatrices(), // parts × 16
      local: localVertices(), // parts × 10
      uv: localUvs(), // parts × 10 (texture-pixel space)
      mesh: batches.any((b) => b.kind == fbs.DrawBatchKind.Mesh)
          ? MeshBuffers(
              x: meshVerticesX(),
              y: meshVerticesY(),
              uv: meshUvs(),
              indices: meshIndices(),
              vertexOffsets: meshVertexOffsets(),
              indexOffsets: meshIndexOffsets(),
            )
          : null,
      // The shape SoA is fetched when a Shape batch is present OR a mask writer
      // might be a shape: a *pure-mask* shape's colour batch is emitted with
      // `kind == Mask`, not `Shape`, so keying only off Shape batches would
      // starve the coverage pass of the very geometry it needs.
      shape: batches.any((b) =>
              b.kind == fbs.DrawBatchKind.Shape ||
              b.kind == fbs.DrawBatchKind.Mask)
          ? ShapeBuffers(
              vertices: shapeVertices(),
              boxCoords: shapeVertexBoxCoords(),
              counts: shapeVertexCounts(),
            )
          : null,
      alphaScale: alphaScale,
    );
    if (frame == null) return;

    // Rewind the per-frame shader pools (reused across frames).
    _partColorShaders.rewind();
    _maskWriteShaders.rewind();

    // Masking (§9) is a pre-pass: collect this frame's writers, rasterise their
    // coverage bitmap, then let the batch loop test each target against it.
    // Unlike the flagship's viewport (1-frame latency, size classes, shrink
    // hysteresis) `toImageSync` gives us the bitmap within this same frame, so
    // none of that machinery is needed.
    final maskCtx = _buildMaskContext(frame, batches);

    // A mask inherited from a parent instance (§3-2-2) reaches only the child's
    // peel-maskable kinds — Normal and Shape. Mesh/Effect are not peeled (no quad
    // affine / can't threshold a deformed-mesh UV), and nested Instances are
    // deliberately single-level, so those child kinds escape the parent clip —
    // the same kinds an own-mask can't gate either.
    for (final batch in batches) {
      switch (batch.kind) {
        case fbs.DrawBatchKind.Normal:
          _emitNormalBatch(canvas, batch, frame, maskCtx, inheritedMask);
        case fbs.DrawBatchKind.Mesh:
          _emitMeshBatch(canvas, batch, frame);
        case fbs.DrawBatchKind.Effect:
          _emitEffectBatch(canvas, batch, frame);
        case fbs.DrawBatchKind.Instance:
          _emitInstanceBatch(canvas, batch, frame, maskCtx);
        case fbs.DrawBatchKind.Shape:
          _emitShapeBatch(canvas, batch, frame, maskCtx, inheritedMask);
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
  void _emitInstanceBatch(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      _MaskContext? maskCtx) {
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
      final ownBits = maskCtx?.bitsForTarget(rank, _flagsFor(part));
      final inherited =
          ownBits == null ? null : maskCtx!.drawFor(ownBits).composeSlot(world);

      canvas.save();
      canvas.transform(world);
      state.child._paintTree(
        canvas,
        frameOverride: state.childFrame,
        alphaScale: alpha,
        inheritedMask: inherited,
      );
      canvas.restore();
    }
  }

  /// Builds this frame's mask plan and rasterises its coverage bitmap, or null
  /// when nothing masks this frame (the overwhelmingly common case — the whole
  /// mask path then costs one [MaskPlan.build] walk of `draw_order`).
  _MaskContext? _buildMaskContext(DrawFrame frame, List<fbs.DrawBatch> batches) {
    if (_maskFlags.isEmpty) return null;
    final plan = MaskPlan.build(frame, _maskFlags);
    if (plan == null) return null;
    final program = _maskWriteProgram.get();
    if (program == null) return null; // still compiling — draw unmasked this frame

    // Writers need their own texture; take it from the batch that owns each
    // rank, which is exactly what the colour path resolves against.
    final textureByRank = <int, int>{};
    for (final batch in batches) {
      for (var k = 0; k < batch.count; k++) {
        textureByRank[batch.startRank + k] = batch.textureHash;
      }
    }

    final coverage = _renderCoverage(plan, frame, program, textureByRank);
    if (coverage == null) return null;
    _coverage = coverage;
    return _MaskContext(plan, coverage);
  }

  /// Rasterises the writers' bits into an offscreen RGBA8 bitmap (§3-2, step 3).
  ///
  /// The bitmap is stretched over exactly [MaskPlan.bounds], so the local→UV map
  /// is resolution-independent and the pixel size is purely a quality knob
  /// (capped at [_maxCoverageDim] on the long edge — the flagship's cap too).
  /// The canvas transform keeps the canvas-local space *player-local*, so the
  /// writer quads and their shader affines are the same values the colour pass
  /// uses.
  ui.Image? _renderCoverage(
    MaskPlan plan,
    DrawFrame frame,
    ui.FragmentProgram program,
    Map<int, int> textureByRank,
  ) {
    final bounds = plan.bounds;
    var scale = 1.0;
    final longEdge = math.max(bounds.width, bounds.height);
    if (longEdge > _maxCoverageDim) scale = _maxCoverageDim / longEdge;
    final pw = (bounds.width * scale).ceil().clamp(1, _maxCoverageDim.toInt());
    final ph = (bounds.height * scale).ceil().clamp(1, _maxCoverageDim.toInt());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(pw / bounds.width, ph / bounds.height);
    canvas.translate(-bounds.left, -bounds.top);

    var wrote = false;
    for (final writer in plan.writers) {
      // A Shape writer (§2-5「シェイプの特例」) has no cell, hence no texel alpha
      // to threshold: its polygon *is* the mask. That needs no shader at all —
      // the bit colour over the geometry, additively, is the whole operation.
      if (_flagsFor(writer.partIndex).shapeGeometry) {
        final geometry = _geometry.buildShapeParts(<int>[writer.partIndex], frame);
        if (geometry == null) continue;
        canvas.drawPath(
          _trianglesPath(geometry),
          ui.Paint()
            ..blendMode = ui.BlendMode.plus
            ..color = _bitColor(writer.bit)
            // A coverage bit is a number, not a picture: a half-covered edge
            // pixel would decode as a *different* writer's bits, so the fill
            // must stay binary. (It also keeps the shared edges between the
            // fan's triangles from double-adding under `plus`.)
            ..isAntiAlias = false,
        );
        wrote = true;
        continue;
      }

      // A Mesh writer (§8): its deformed triangles are the mask. Same treatment
      // as a shape — geometry-as-mask, no texel cutout (a Flutter shader can't
      // sample the per-vertex mesh UV) — so it rasterises with a plain bit fill.
      if (_flagsFor(writer.partIndex).meshGeometry) {
        final geometry = _geometry.buildMeshGeometry(<int>[writer.partIndex], frame);
        if (geometry == null) continue;
        canvas.drawPath(
          _trianglesPath(geometry),
          ui.Paint()
            ..blendMode = ui.BlendMode.plus
            ..color = _bitColor(writer.bit)
            ..isAntiAlias = false,
        );
        wrote = true;
        continue;
      }

      final quad = _geometry.buildPartColorQuad(writer.partIndex, frame);
      if (quad == null) continue;
      final hash = textureByRank[writer.drawRank];
      final image = hash == null ? null : textures.imageFor(hash);
      if (image == null) continue;

      final shader = _maskWriteShaders.next(program);
      _setMaskWriteUniforms(shader, writer, quad,
          texWidth: image.width.toDouble(),
          texHeight: image.height.toDouble());
      shader.setImageSampler(0, image);
      // Disjoint bits + additive blend == a lossless OR.
      canvas.drawPath(
          _quadPath(quad), ui.Paint()..blendMode = ui.BlendMode.plus..shader = shader);
      wrote = true;
    }
    if (!wrote) {
      recorder.endRecording().dispose();
      return null;
    }

    final picture = recorder.endRecording();
    final image = picture.toImageSync(pw, ph);
    picture.dispose();
    return image;
  }

  /// Emits one Normal batch, preserving draw order.
  ///
  /// Walks `draw_order[start_rank .. +count)` and splits it into runs of plain
  /// parts — baked together via [GeometryBuilder] and drawn with the texture
  /// shader + framebuffer blend (the Phase-1 fast path) — with every part that
  /// needs the fragment shader (PartColor §10 and/or a mask test §9) peeled onto
  /// its own [_drawPeeledPart] draw in between, so overlap order is unchanged.
  /// An animation with neither (e.g. Basic) collapses to a single run == the
  /// whole batch.
  ///
  /// Pure-mask parts (§1-2) are dropped here: they feed only the coverage
  /// bitmap and must never draw their own colour, or the mask would read as a
  /// solid fill instead of a hole.
  void _emitNormalBatch(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      _MaskContext? maskCtx, _MaskDraw? inheritedMask) {
    final start = batch.startRank;
    final count = batch.count;
    if (count == 0) return;
    final drawOrder = frame.drawOrder;
    final paint = _paintForBatch(batch);
    final blend = blendModeFor(batch.blendType);

    final run = <int>[];
    void flushRun() {
      if (run.isEmpty) return;
      // 2nd arg modulates the vertex color (white × alpha) with the texture
      // shader; paint.blendMode is the framebuffer composite.
      final vertices = _geometry.buildNormalParts(run, frame);
      if (vertices != null) {
        canvas.drawVertices(vertices, ui.BlendMode.modulate, paint);
      }
      run.clear();
    }

    for (var k = 0; k < count; k++) {
      final rank = start + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      final flags = _flagsFor(p);
      // Coverage-only. It draws nothing, so it cannot split the run either.
      if (flags.pureMask) continue;
      final part = frame.partOf(p);
      final pc = part == null ? null : PartColor.read(frame.frameData, part);
      // This player's own mask wins per-part; a mask inherited from the parent
      // instance (§3-2-2) applies to every other part of the child subtree. A
      // part that is a target of BOTH keeps only its own test — the shader tests
      // one coverage per fragment, so the inherited clip is dropped for it
      // (a rare nested-mask case that would need a second peel pass to combine).
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final mask = ownBits != null ? maskCtx!.drawFor(ownBits) : inheritedMask;
      if (pc == null && mask == null) {
        run.add(p);
      } else {
        flushRun();
        _drawPeeledPart(canvas, p, pc, frame, batch, blend, mask);
      }
    }
    flushRun();
  }

  /// Emits one Shape batch (§11), preserving draw order.
  ///
  /// A Shape carries its colour entirely in its vertices ([GeometryBuilder.
  /// buildShapeParts]), so the common case is one `drawVertices` for the whole
  /// batch against a **white** paint: `modulate` against white is the identity,
  /// which stands in for the "shape pixel" the sibling players get for free from
  /// an unbound sampler returning white. Flutter has no such default — an
  /// `ImageShader`-less paint would otherwise modulate against opaque black.
  ///
  /// Mask targets (§9) are peeled onto their own draw, exactly like the Normal
  /// path, because the coverage test is per-fragment.
  ///
  /// Pure-mask shapes never reach here: the Brain emits their colour batch as
  /// `kind == Mask`, and they are dropped anyway ([_flagsFor] / `pureMask`).
  void _emitShapeBatch(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      _MaskContext? maskCtx, _MaskDraw? inheritedMask) {
    if (batch.count == 0 || frame.shape == null) return;
    final blend = blendModeFor(batch.blendType);

    final run = <int>[];
    void flushRun() {
      if (run.isEmpty) return;
      final v = _geometry.buildShapeParts(run, frame);
      if (v != null) {
        canvas.drawVertices(v.toVertices(), ui.BlendMode.modulate,
            ui.Paint()..blendMode = blend..color = const ui.Color(0xFFFFFFFF));
      }
      run.clear();
    }

    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= frame.drawOrder.length) break;
      final p = frame.drawOrder[rank];
      final flags = _flagsFor(p);
      if (flags.pureMask) continue; // coverage only, never colour
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final mask = ownBits != null ? maskCtx!.drawFor(ownBits) : inheritedMask;
      if (mask == null) {
        run.add(p);
      } else {
        flushRun();
        _drawMaskedShape(canvas, p, frame, blend, mask);
      }
    }
    flushRun();
  }

  /// Draws one mask-target Shape: its vertex colours gated by the coverage test.
  ///
  /// The trick is that `drawVertices`' blend combines the vertex colours with
  /// the paint's shader, so the shader only has to answer "does this fragment
  /// pass the mask?" — white for yes, zero for no — and `modulate` keeps the
  /// shape's own per-vertex gradient. That matters because a `FragmentProgram`
  /// cannot receive varyings, so the gradient could never come *from* the shader.
  ///
  /// The gate is `partcolor.frag` configured to a no-op (rate 0 over a white
  /// texel) rather than a second program: the mask replay is intricate enough
  /// (§2-1..§2-4 scope, polarity, invert/increment) that a copy of it would be a
  /// standing invitation to drift.
  void _drawMaskedShape(ui.Canvas canvas, int part, DrawFrame frame,
      ui.BlendMode blend, _MaskDraw mask) {
    final program = _partColorProgram.get();
    final geometry = _geometry.buildShapeParts(<int>[part], frame);
    if (geometry == null) return;
    if (program == null) {
      // Still compiling — draw unmasked rather than dropping the shape.
      canvas.drawVertices(geometry.toVertices(), ui.BlendMode.modulate,
          ui.Paint()..blendMode = blend..color = const ui.Color(0xFFFFFFFF));
      return;
    }

    final shader = _partColorShaders.next(program);
    // A 1×1 opaque white texel + rate 0 collapses the whole PartColor formula to
    // "pass the pixel through", i.e. opaque white — so the only thing the shader
    // still decides is the mask test.
    _setPartColorUniforms(shader, PartColor.identity, _unitQuad,
        texWidth: 1.0,
        texHeight: 1.0,
        maskBits: mask.bits,
        maskUvBasis: mask.uvBasis,
        maskUvOffset: mask.uvOffset);
    shader.setImageSampler(0, _ensureWhitePixel());
    shader.setImageSampler(1, mask.coverage);

    canvas.drawVertices(geometry.toVertices(), ui.BlendMode.modulate,
        ui.Paint()..blendMode = blend..shader = shader);
  }

  /// A degenerate quad for the mask gate: with `rate == 0` the shader never uses
  /// `(s,t)` or the UVs, so the affine only has to be present, not meaningful.
  static final PartColorQuad _unitQuad = PartColorQuad(
    corners: Float32List.fromList(<double>[0, 0, 1, 0, 0, 1, 1, 1]),
    originX: 0,
    originY: 0,
    inv: Float32List.fromList(<double>[0, 0, 0, 0]),
    uvA: Float32List(4),
    uvB: Float32List(4),
  );

  /// Emits one Mesh batch (§8), preserving draw order.
  ///
  /// Much cheaper than the Normal path: the Brain supplies mesh geometry ready
  /// to draw (world-space vertices, texture-pixel UVs, part-local indices), so
  /// the whole batch bakes into one indexed `drawVertices` with no matrix work.
  ///
  /// PartColor (§10) and the mask test (§9) are NOT applied to mesh parts yet:
  /// both run through `partcolor.frag`, which rebuilds a fragment's UV from a
  /// *quad* affine, and a deformed mesh is not an affine image of its quad —
  /// nor can a Flutter shader take the per-vertex UVs instead (no varyings).
  /// Such a part still draws — plain, un-tinted and unmasked — rather than
  /// vanishing. Two consequences to fix when that lands: a mesh's PartColor is
  /// **whole-only** (`lt` applies to every vertex, not a 4-corner gradient), and
  /// a PartColored mesh takes its alpha from `pc.lt.a` *instead of*
  /// `PartState.alpha` — multiplying the two double-applies the hierarchy alpha.
  void _emitMeshBatch(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame) {
    final count = batch.count;
    if (count == 0) return;
    final drawOrder = frame.drawOrder;

    final parts = <int>[];
    for (var k = 0; k < count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      if (_flagsFor(p).pureMask) continue; // coverage-only: never draws colour
      parts.add(p);
    }

    final vertices = _geometry.buildMeshParts(parts, frame);
    if (vertices == null) return;
    canvas.drawVertices(vertices, ui.BlendMode.modulate, _paintForBatch(batch));
  }

  /// Emits one Effect batch (§8) — the particle plans stepped by [updateMs].
  ///
  /// The odd one out: an Effect batch carries no geometry of its own. Its
  /// `texture_hash` / `vertex_count` / `index_count` are meaningless — the real
  /// texture is per `EffectDrawCommand.cellmap_hash` and the geometry lives in
  /// the slot's `EffectDrawPlan`. So this resolves each rank to its slot, then
  /// draws one `drawVertices` per command.
  ///
  /// One draw per command (the plan already concatenates every emitter into
  /// shared buffers, so a command's indices need no rebasing). The SDK suggests
  /// merging adjacent commands that share cellmap + blend into a single draw;
  /// that is an optimisation on top of this, and it would require the rebase.
  void _emitEffectBatch(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame) {
    if (_effects.isEmpty) return;
    final drawOrder = frame.drawOrder;

    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final part = drawOrder[rank];
      final plan = _effects.planFor(part);
      final commands = plan?.commands;
      if (plan == null || commands == null) continue; // invisible / dead slot

      for (final command in commands) {
        // The runtime still emits a command for an emitter whose cell failed to
        // resolve, with quad_count 0 — skip before touching the texture.
        if (command.quadCount == 0) continue;
        final image = textures.imageFor(command.cellmapHash);
        if (image == null) continue;

        final geometry = _geometry.buildEffectCommand(
          plan,
          command,
          part,
          frame,
          texWidth: image.width.toDouble(),
          texHeight: image.height.toDouble(),
        );
        if (geometry == null) continue;

        canvas.drawVertices(
          geometry.toVertices(),
          ui.BlendMode.modulate,
          ui.Paint()
            // An emitter's blend is the raw 0=Mix / 1=Add byte, NOT a BlendType.
            ..blendMode = effectBlendModeFor(command.blend)
            ..shader = textures.shaderFor(command.cellmapHash),
        );
      }
    }
  }

  /// Draws one peeled Normal part via `shaders/partcolor.frag` — the path for a
  /// part carrying PartColor (§10), a mask test (§9), or both.
  ///
  /// The shader can take no per-vertex varyings, so the part is drawn on its own
  /// quad and the per-corner colour/rate/UV gradient is reconstructed inside the
  /// shader from a CPU-supplied affine ([GeometryBuilder.buildPartColorQuad]).
  /// A null [pc] passes [PartColor.identity], which the shader's formula
  /// collapses to a plain texel passthrough (so a masked part keeps its exact
  /// unmasked colours). Falls back to the plain textured draw when the program
  /// isn't compiled yet or the texture/quad is unavailable — un-tinted and
  /// unmasked, but visible.
  void _drawPeeledPart(
    ui.Canvas canvas,
    int part,
    PartColor? pc,
    DrawFrame frame,
    fbs.DrawBatch batch,
    ui.BlendMode blend,
    _MaskDraw? mask,
  ) {
    final program = _partColorProgram.get();
    final image = textures.imageFor(batch.textureHash);
    final quad = _geometry.buildPartColorQuad(part, frame);
    if (program == null || image == null || quad == null) {
      // Fallback: plain textured draw so the part stays visible.
      final v = _geometry.buildNormalParts(<int>[part], frame);
      if (v != null) {
        canvas.drawVertices(v, ui.BlendMode.modulate, _paintForBatch(batch));
      }
      return;
    }

    // Two different alpha contracts meet here (§1-3):
    //  * WITH PartColor the Brain has already pre-folded the part's hierarchical
    //    alpha into the corner alphas, so re-multiplying it would double-apply.
    //    Only the instance chain's scale — which lives in the *parent's*
    //    FrameData and so cannot be pre-folded — is still owed.
    //  * WITHOUT PartColor there is no corner alpha to inherit, so the part's
    //    own alpha must be supplied (§1-2-4's 「頂点色 = 白（α は階層 α）」);
    //    `alphaOf` already includes the instance scale.
    // The shared α=1 `PartColor.identity` is deliberately not used: it renders a
    // masked part fully opaque.
    final effective = pc == null
        ? PartColor.passthrough(frame.alphaOf(part))
        : pc.scaleAlpha(frame.alphaScale);

    final shader = _partColorShaders.next(program);
    _setPartColorUniforms(shader, effective, quad,
        texWidth: image.width.toDouble(),
        texHeight: image.height.toDouble(),
        maskBits: mask?.bits,
        maskUvBasis: mask?.uvBasis,
        maskUvOffset: mask?.uvOffset);
    // The part's own texture wants bilinear like the batched ImageShader path —
    // the peeled shader's sampler defaults to nearest (jaggy) otherwise. The
    // coverage sampler (1) must stay nearest: its texels are bit fields, so any
    // interpolation would corrupt the mask stencil decode.
    shader.setImageSampler(0, image, filterQuality: ui.FilterQuality.low);
    shader.setImageSampler(
        1, mask == null ? _ensureDummyCoverage() : mask.coverage);

    canvas.drawPath(
        _quadPath(quad), ui.Paint()..blendMode = blend..shader = shader);
  }

  /// The union of a baked block's triangles, as one non-zero-wound path.
  ///
  /// Built from the very triangles the colour pass draws rather than from a
  /// re-derived outline, so the coverage a shape writes can never disagree with
  /// the shape it draws.
  static ui.Path _trianglesPath(MeshGeometry g) {
    final path = ui.Path();
    final p = g.positions;
    final idx = g.indices;
    for (var t = 0; t + 2 < idx.length; t += 3) {
      final a = idx[t] * 2, b = idx[t + 1] * 2, c = idx[t + 2] * 2;
      path.moveTo(p[a], p[a + 1]);
      path.lineTo(p[b], p[b + 1]);
      path.lineTo(p[c], p[c + 1]);
      path.close();
    }
    return path;
  }

  /// One writer's bit as a solid colour, in the same channel encoding the
  /// coverage shader uses (8 bits × R/G/B) — alpha 1 because `BlendMode.plus` is
  /// premultiplied and would otherwise scale the bit away.
  static ui.Color _bitColor(int bit) {
    final value = 1 << (bit % 8);
    return switch (bit ~/ 8) {
      0 => ui.Color.fromARGB(255, value, 0, 0),
      1 => ui.Color.fromARGB(255, 0, value, 0),
      _ => ui.Color.fromARGB(255, 0, 0, value),
    };
  }

  /// The world quad's fill path, wound `lt → rt → rb → lb`.
  static ui.Path _quadPath(PartColorQuad quad) {
    final c = quad.corners;
    return ui.Path()
      ..moveTo(c[0], c[1]) // lt
      ..lineTo(c[2], c[3]) // rt
      ..lineTo(c[6], c[7]) // rb
      ..lineTo(c[4], c[5]) // lb
      ..close();
  }

  /// Writes the [pc]/[quad]/[maskBits] values into the fragment shader's float
  /// uniforms in the exact declaration order of `shaders/partcolor.frag` (the
  /// samplers are set separately by the caller and do not consume float
  /// indices).
  static void _setPartColorUniforms(
    ui.FragmentShader shader,
    PartColor pc,
    PartColorQuad quad, {
    required double texWidth,
    required double texHeight,
    MaskBits? maskBits,
    Float32List? maskUvBasis,
    Float32List? maskUvOffset,
  }) {
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    void corner(PartColorCorner c) {
      f(c.r);
      f(c.g);
      f(c.b);
      f(c.a);
    }

    f(quad.originX); // uOrigin
    f(quad.originY);
    f(quad.inv[0]); // uInv
    f(quad.inv[1]);
    f(quad.inv[2]);
    f(quad.inv[3]);
    f(texWidth); // uTexSize
    f(texHeight);
    f(pc.coef[0]); // uCoef
    f(pc.coef[1]);
    f(pc.coef[2]);
    f(pc.coef[3]);
    f(pc.lt.rate); // uRate (lt,rt,lb,rb)
    f(pc.rt.rate);
    f(pc.lb.rate);
    f(pc.rb.rate);
    corner(pc.lt); // uColLT..uColRB
    corner(pc.rt);
    corner(pc.lb);
    corner(pc.rb);
    f(quad.uvA[0]); // uUvA (lt.uv, rt.uv)
    f(quad.uvA[1]);
    f(quad.uvA[2]);
    f(quad.uvA[3]);
    f(quad.uvB[0]); // uUvB (lb.uv, rb.uv)
    f(quad.uvB[1]);
    f(quad.uvB[2]);
    f(quad.uvB[3]);

    // uMaskBits — the two 24-bit scope-resolved writer sets (§2-1/§2-3), the
    // target's polarity (§2-4) and the enable flag.
    f(maskBits?.increment.toDouble() ?? 0.0);
    f(maskBits?.invert.toDouble() ?? 0.0);
    f((maskBits?.visibleInside ?? false) ? 1.0 : 0.0);
    f(maskBits == null ? 0.0 : 1.0);
    // uMaskUv / uMaskOff — local → coverage UV (§3-2-2). For an own mask this is
    // `plan.uvBasis/uvOffset` (player-local → UV); for a mask inherited by an
    // instance child it is that affine pre-composed with the slot matrix
    // (child-local → UV), so the same shader serves both.
    f(maskUvBasis?[0] ?? 0.0);
    f(maskUvBasis?[1] ?? 0.0);
    f(maskUvBasis?[2] ?? 0.0);
    f(maskUvBasis?[3] ?? 0.0);
    f(maskUvOffset?[0] ?? 0.0);
    f(maskUvOffset?[1] ?? 0.0);
  }

  /// Writes the coverage-writer uniforms in the declaration order of
  /// `shaders/mask_write.frag`.
  static void _setMaskWriteUniforms(
    ui.FragmentShader shader,
    MaskWriter writer,
    PartColorQuad quad, {
    required double texWidth,
    required double texHeight,
  }) {
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);

    f(quad.originX); // uOrigin
    f(quad.originY);
    f(quad.inv[0]); // uInv
    f(quad.inv[1]);
    f(quad.inv[2]);
    f(quad.inv[3]);
    f(texWidth); // uTexSize
    f(texHeight);
    f(quad.uvA[0]); // uUvA
    f(quad.uvA[1]);
    f(quad.uvA[2]);
    f(quad.uvA[3]);
    f(quad.uvB[0]); // uUvB
    f(quad.uvB[1]);
    f(quad.uvB[2]);
    f(quad.uvB[3]);

    // uBit — this writer's bit pre-encoded into the channel that owns it
    // (8 bits × R/G/B = 24 writers), plus the §2-5 cutout threshold in alpha.
    final channel = writer.bit ~/ 8;
    final value = (1 << (writer.bit % 8)) / 255.0;
    f(channel == 0 ? value : 0.0);
    f(channel == 1 ? value : 0.0);
    f(channel == 2 ? value : 0.0);
    f(writer.threshold);
  }

  /// Builds the [ui.Paint] for a batch: framebuffer blend (`render/blend.dart`)
  /// plus the resolved texture's identity [ui.ImageShader] (design §7B/§7C).
  ui.Paint _paintForBatch(fbs.DrawBatch batch) => ui.Paint()
    ..blendMode = blendModeFor(batch.blendType)
    ..shader = textures.shaderFor(batch.textureHash);

  // --- InstanceChild (§8): this player driven as another's instance child ---

  @override
  ffi.Pointer<ffi.Void> get instanceContext => _context;

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
    _coverage?.dispose();
    _coverage = null;
    // The slots borrow `_resource`; they must go first. Instance children own
    // their own Context/Resource and are torn down recursively from here.
    _effects.dispose();
    _instances.dispose();
    _contextFinalizer.detach(this);
    _resourceFinalizer.detach(this);

    if (_context != ffi.nullptr) {
      ss_runtime_destroy(_context);
      _context = ffi.nullptr;
    }
    if (_resource != ffi.nullptr) {
      ss_resource_destroy(_resource);
      _resource = ffi.nullptr;
    }
    calloc.free(_outFloatPtr);
    calloc.free(_outBytePtr);
    calloc.free(_outU32Ptr);
    calloc.free(_outI32Ptr);
    calloc.free(_outLen);

    _partColorShaders.dispose();
    _maskWriteShaders.dispose();
  }
}

/// The frame's masking state, handed to the batch loop.
class _MaskContext {
  _MaskContext(this.plan, this.coverage);

  final MaskPlan plan;
  final ui.Image coverage;

  /// The mask test for the target at [rank], or null when it is unmasked.
  MaskBits? bitsForTarget(int rank, MaskPartFlags flags) =>
      plan.bitsFor(rank, flags);

  /// A ready-to-draw bundle for a target of THIS player's own mask.
  _MaskDraw drawFor(MaskBits bits) =>
      _MaskDraw(bits, coverage, plan.uvBasis, plan.uvOffset);
}

/// Everything a peeled draw needs to run the mask replay: the resolved writer
/// sets + polarity ([bits]), the coverage bitmap, and the local→coverage-UV
/// affine. Unifies an *own* mask (from the player's own [MaskPlan]) and a mask
/// **inherited** by an instance child (§3-2-2), whose affine is the parent's
/// pre-composed with the slot matrix. The child gates its whole subtree with one
/// of these, using the instance part's rank/polarity.
class _MaskDraw {
  const _MaskDraw(this.bits, this.coverage, this.uvBasis, this.uvOffset);

  final MaskBits bits;
  final ui.Image coverage;
  final Float32List uvBasis;
  final Float32List uvOffset;

  /// Composes this player-local→UV mask with an instance slot matrix
  /// (`world2dOf`, child-local → parent-local, column-major), yielding the
  /// child-local → UV affine the child's fragments need (§3-2-2's
  /// `M_child = M_parent · slot_xf`). [bits] is carried over unchanged — the
  /// whole child is judged by the instance part's single resolved test.
  _MaskDraw composeSlot(Float64List slot) {
    final b = uvBasis;
    final s0 = slot[0], s1 = slot[1], s4 = slot[4], s5 = slot[5];
    final tx = slot[12], ty = slot[13];
    return _MaskDraw(
      bits,
      coverage,
      Float32List.fromList(<double>[
        b[0] * s0 + b[1] * s1, // m00
        b[0] * s4 + b[1] * s5, // m01
        b[2] * s0 + b[3] * s1, // m10
        b[2] * s4 + b[3] * s5, // m11
      ]),
      Float32List.fromList(<double>[
        b[0] * tx + b[1] * ty + uvOffset[0],
        b[2] * tx + b[3] * ty + uvOffset[1],
      ]),
    );
  }
}

/// A `FragmentProgram` loaded lazily from an asset and cached process-wide.
///
/// Loading is async but `paint` is synchronous, so [get] kicks the load off the
/// first time the program is actually needed and returns null until it resolves
/// (callers fall back for a frame or two). A load failure — e.g. no asset bundle
/// under headless `flutter test` — latches, so we stop retrying every frame.
class _LazyProgram {
  _LazyProgram(this._asset);

  final String _asset;
  ui.FragmentProgram? _program;
  bool _loading = false;
  bool _failed = false;

  ui.FragmentProgram? get() {
    final loaded = _program;
    if (loaded != null) return loaded;
    if (_failed || _loading) return null;
    _loading = true;
    ui.FragmentProgram.fromAsset(_asset).then((p) {
      _program = p;
      _loading = false;
    }, onError: (Object _) {
      _failed = true;
      _loading = false;
    });
    return null;
  }
}

/// A rewindable pool of `FragmentShader` instances for one program.
///
/// Every draw in a Picture reads its shader's uniforms at raster time, so draws
/// in the SAME frame need DISTINCT shader objects; across frames the pool is
/// re-set, which is Flutter's documented allocation-free reuse pattern.
class _ShaderPool {
  final List<ui.FragmentShader> _shaders = <ui.FragmentShader>[];
  int _cursor = 0;

  void rewind() => _cursor = 0;

  ui.FragmentShader next(ui.FragmentProgram program) {
    if (_cursor < _shaders.length) return _shaders[_cursor++];
    final shader = program.fragmentShader();
    _shaders.add(shader);
    _cursor++;
    return shader;
  }

  void dispose() {
    for (final shader in _shaders) {
      shader.dispose();
    }
    _shaders.clear();
    _cursor = 0;
  }
}
