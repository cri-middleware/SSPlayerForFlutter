import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import 'bindings/ssruntime_bindings.g.dart';
import 'bindings/ssruntime_library.dart';
import 'render/blend.dart';
import 'render/geometry_builder.dart';
import 'ssab/framedata.g.dart' as fbs;
import 'texture_registry.dart';

/// Coordinate-system orientation passed to `ss_context_set_coordinate_system`.
/// Flutter's canvas is Y-Down; the Brain applies the flip once, so the Body
/// must NOT flip again.
enum SsCoordinateSystem {
  yUp(0),
  yDown(1);

  const SsCoordinateSystem(this.value);
  final int value;
}

/// Origin placement passed to `ss_context_set_origin`.
enum SsOrigin {
  center(0),
  topLeft(1);

  const SsOrigin(this.value);
  final int value;
}

/// Coordinate unit passed to `ss_context_set_unit`.
enum SsUnit {
  pixel(0),
  normalized(1);

  const SsUnit(this.value);
  final int value;
}

/// How the `.ssab` bytes are handed to the Brain.
///
///  * [borrow] — the Body owns the bytes (zero-copy). We keep a native copy of
///    the bytes alive for the resource's whole lifetime. This is the native
///    (dart:ffi) default.
///  * [copy] — the Brain copies the bytes onto its own heap; ours can be freed
///    immediately. Required for the Web (WASM) path where memory spaces differ.
enum SsResourceMode { borrow, copy }

/// Layer 2 — the Widget-agnostic drawing engine (ports the SDK's
/// `SSInternalPlayer`).
///
/// Owns the FFI [Resource]/[Context] lifecycle, advances time, pulls the
/// per-frame `FrameData` + SoA buffers from the Brain, and (will) bake them
/// into `ui.Vertices` for `Canvas.drawVertices`. It is `dispose`-able and
/// reusable from higher layers (Player) or headless tests.
class SpriteStudioInternalPlayer implements ffi.Finalizable {
  SpriteStudioInternalPlayer._(
    this._runtime,
    this._context,
    this._resource,
    this._ssabBuffer,
    this.textures,
  ) {
    // Backstop finalizers: if the caller forgets dispose(), the Brain-side
    // Context/Resource are still reclaimed on GC. The Arc refcount inside the
    // runtime makes destroy order irrelevant. (The borrowed ssab buffer is not
    // freed by a finalizer to avoid a use-after-free race with the resource;
    // it is only freed by the explicit dispose() below — a minor leak on the
    // GC-only path, which the docs accept.)
    _contextFinalizer.attach(this, _context.cast(), detach: this);
    _resourceFinalizer.attach(this, _resource.cast(), detach: this);
  }

  final SsRuntime _runtime;
  SsRuntimeBindings get _b => _runtime.bindings;

  ffi.Pointer<ffi.Void> _context;
  ffi.Pointer<ffi.Void> _resource;
  ffi.Pointer<ffi.Uint8> _ssabBuffer; // native copy kept alive for borrow

  /// texture_hash → decoded image / shader. Populated by the caller.
  final TextureRegistry textures;

  /// Pure SoA→`ui.Vertices` baker (Widget/FFI-free); the per-kind builders grow
  /// here as Phase-2 kinds are ported.
  final GeometryBuilder _geometry = GeometryBuilder();

  /// When true (default), rendering samples the Brain's fractional (sub-frame)
  /// frame number, giving smooth playback beyond the source FPS on high-refresh
  /// displays. Set false to snap to integer frames.
  bool subFrame = true;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  // Reused scratch cells for the SoA out-parameters (avoid per-frame alloc).
  final ffi.Pointer<ffi.Pointer<ffi.Float>> _outFloatPtr =
      calloc<ffi.Pointer<ffi.Float>>();
  final ffi.Pointer<ffi.Pointer<ffi.Uint8>> _outBytePtr =
      calloc<ffi.Pointer<ffi.Uint8>>();
  final ffi.Pointer<ffi.Size> _outLen = calloc<ffi.Size>();

  late final ffi.NativeFinalizer _contextFinalizer = ffi.NativeFinalizer(
      _runtime.dynamicLibrary
          .lookup<ffi.NativeFinalizerFunction>('ss_runtime_destroy'));
  late final ffi.NativeFinalizer _resourceFinalizer = ffi.NativeFinalizer(
      _runtime.dynamicLibrary
          .lookup<ffi.NativeFinalizerFunction>('ss_resource_destroy'));

  /// Loads `ssab` into a fresh Context and binds it.
  ///
  /// Steps mirror docs/30_core/10_initialization: create resource → create
  /// context → bind → set coordinate system/origin/unit. The `.ssab` is NOT
  /// validated by the Brain; validate untrusted input before calling this.
  factory SpriteStudioInternalPlayer.load(
    Uint8List ssab, {
    SsRuntime? runtime,
    TextureRegistry? textures,
    SsResourceMode mode = SsResourceMode.borrow,
    SsCoordinateSystem coordinateSystem = SsCoordinateSystem.yDown,
    SsOrigin? origin,
    SsUnit? unit,
  }) {
    final rt = runtime ?? SsRuntime.open();
    final b = rt.bindings;

    // Copy the ssab bytes into native memory. For borrow the Brain references
    // this block directly, so it must outlive the resource.
    final buf = malloc<ffi.Uint8>(ssab.length);
    buf.asTypedList(ssab.length).setAll(0, ssab);

    // ffigen types the C `const unsigned char *` as Pointer<UnsignedChar>.
    final resource = mode == SsResourceMode.borrow
        ? b.ss_resource_create_borrow(buf.cast(), ssab.length)
        : b.ss_resource_create_copy(buf.cast(), ssab.length);
    if (resource == ffi.nullptr) {
      malloc.free(buf);
      throw StateError('ss_resource_create_* returned null (bad .ssab?)');
    }
    // For copy the Brain has its own duplicate; release ours right away.
    var keepBuf = buf;
    if (mode == SsResourceMode.copy) {
      malloc.free(buf);
      keepBuf = ffi.nullptr;
    }

    final context = b.ss_runtime_create();
    if (context == ffi.nullptr) {
      b.ss_resource_destroy(resource);
      if (keepBuf != ffi.nullptr) malloc.free(keepBuf);
      throw StateError('ss_runtime_create returned null');
    }
    if (!b.ss_runtime_bind_resource(context, resource)) {
      b.ss_runtime_destroy(context);
      b.ss_resource_destroy(resource);
      if (keepBuf != ffi.nullptr) malloc.free(keepBuf);
      throw StateError('ss_runtime_bind_resource failed');
    }

    // Direct render mode (the default): the Brain fills the SoA buffers this
    // Body reads and skips redundant FrameData vertices/cells/deforms
    // (render_loop §2). The Godot flagship relies on the same default.
    b.ss_runtime_set_render_mode(context, 0);
    // Y-Down like the flagship; origin/unit are left at the runtime defaults
    // (the flagship sets neither) unless the caller opts in.
    b.ss_context_set_coordinate_system(context, coordinateSystem.value);
    if (origin != null) b.ss_context_set_origin(context, origin.value);
    if (unit != null) b.ss_context_set_unit(context, unit.value);

    return SpriteStudioInternalPlayer._(
      rt,
      context,
      resource,
      keepBuf,
      textures ?? TextureRegistry(),
    );
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
      return _b.ss_runtime_setup_animation(_context, cName.cast());
    } finally {
      malloc.free(cName);
    }
  }

  /// Canonical name→id hash (never re-implement FNV-1a on the Dart side).
  int hashString(String name) {
    final cName = name.toNativeUtf8();
    try {
      return _b.ss_runtime_hash_string(cName.cast());
    } finally {
      malloc.free(cName);
    }
  }

  void play() {
    _ensureAlive();
    _b.ss_runtime_play(_context);
  }

  void pause() {
    _ensureAlive();
    _b.ss_runtime_pause(_context);
  }

  void stop() {
    _ensureAlive();
    _b.ss_runtime_stop(_context);
  }

  bool get isPlaying => _b.ss_runtime_is_playing(_context);
  bool get isEndFrameReached => _b.ss_runtime_is_end_frame_reached(_context);
  bool get isLooped => _b.ss_runtime_is_looped(_context);
  double get frameNo => _b.ss_runtime_get_frame_no(_context);
  int get startFrame => _b.ss_runtime_get_start_frame(_context);
  int get endFrame => _b.ss_runtime_get_end_frame(_context);
  int get fps => _b.ss_runtime_get_fps(_context);

  set loop(int count) => _b.ss_runtime_set_loop(_context, count);
  set speed(double rate) => _b.ss_runtime_set_animation_speed(_context, rate);
  set frameRate(int fps) => _b.ss_runtime_set_frame_rate(_context, fps);
  void seek(double frame) => _b.ss_runtime_set_frame_no(_context, frame);

  // --- Per-frame update ----------------------------------------------------

  /// Advances internal time. Returns the new (sub-frame) frame number.
  ///
  /// The Brain's `ss_runtime_update` takes a delta whose unit the SDK docs
  /// define (milliseconds per docs/30_core/20_playback_control). We pass the
  /// [delta] in milliseconds; use [updateMs] to control the raw value.
  double update(Duration delta) => updateMs(delta.inMicroseconds / 1000.0);

  double updateMs(double deltaMs) {
    _ensureAlive();
    return _b.ss_runtime_update(_context, deltaMs);
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
    _b.ss_runtime_get_frame_data(
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
  Float32List worldMatrices() => _soaFloats(_b.ss_runtime_get_world_matrices);

  /// Per-part local vertices (parts × 10 floats: lt,rt,lb,rb,center).
  Float32List localVertices() => _soaFloats(_b.ss_runtime_get_local_vertices);

  /// Per-part local UVs (parts × 10 floats: lt,rt,lb,rb,center in texture pixels).
  Float32List localUvs() => _soaFloats(_b.ss_runtime_get_local_uvs);

  /// Per-part cell meta (parts × 6: pivot_x,pivot_y,w,h,rect_left,rect_top).
  Float32List cellMeta() => _soaFloats(_b.ss_runtime_get_cell_meta);

  // --- Events (polling) ----------------------------------------------------

  /// Indices, into the ssab `events()` table, that were passed on the last
  /// update. The caller resolves user data / signals / audio from the ssab.
  List<int> passedEventIndices() {
    _ensureAlive();
    final count = _b.ss_runtime_get_passed_event_count(_context);
    if (count <= 0) return const [];
    return List<int>.generate(
        count, (i) => _b.ss_runtime_get_passed_event_index(_context, i));
  }

  // --- Rendering -----------------------------------------------------------

  /// Draws the current frame into [canvas] (design §7; ports the Godot flagship
  /// `_drawAnimation`). Gathers the FlatBuffers `FrameData` + SoA views into one
  /// [DrawFrame], centers the animation's world origin in [dst], then dispatches
  /// each `DrawBatch` on its `kind`.
  ///
  /// Phase 1 draws the **Normal** batch path (see [_emitNormalBatch]); the other
  /// kinds are pre-cut seams for Phase 2 (§8–§11) and skipped for now. BoxFit /
  /// scale placement into [dst] is also Phase 2.
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _ensureAlive();
    // Sub-frame ON (default): sample the fractional frame for smooth playback;
    // OFF: snap to the integer frame.
    final frameData = getFrameData(subFrame ? frameNo : frameNo.floorToDouble());
    final batches = frameData?.drawBatches;
    if (frameData == null || batches == null) return;

    // One zero-copy SoA gather per frame (mirrors the flagship's single-block
    // fetch); the views are valid only until the next update.
    final frame = DrawFrame.build(
      frameData: frameData,
      world: worldMatrices(), // parts × 16
      local: localVertices(), // parts × 10
      uv: localUvs(), // parts × 10 (texture-pixel space)
    );
    if (frame == null) return;

    // Place the animation's world origin at the center of the destination box.
    final origin = dst?.center ??
        ui.Offset((sourceSize?.width ?? 0) / 2, (sourceSize?.height ?? 0) / 2);

    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    for (final batch in batches) {
      switch (batch.kind) {
        case fbs.DrawBatchKind.Normal:
          _emitNormalBatch(canvas, batch, frame);
        case fbs.DrawBatchKind.Shape: // TODO(phase 2): §11 shape SoA
        case fbs.DrawBatchKind.Mesh: // TODO(phase 2): §8 mesh SoA
        case fbs.DrawBatchKind.Instance: // TODO(phase 2): §8 instance slot
        case fbs.DrawBatchKind.Effect: // TODO(phase 2): §8 effect slot
        case fbs.DrawBatchKind.Mask: // TODO(phase 2): §9 coverage bitmap
        case fbs.DrawBatchKind.Nines: // TODO(phase 2): §11 9-slice
        case fbs.DrawBatchKind.Text: // no SDK render path
          break; // kinds not yet ported are skipped
      }
    }
    canvas.restore();
  }

  /// Emits one Normal batch: bakes its geometry via [GeometryBuilder] and
  /// composites it with the batch's texture shader and framebuffer blend.
  void _emitNormalBatch(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame) {
    final vertices = _geometry.buildNormalBatch(batch, frame);
    if (vertices == null) return;
    // 2nd arg modulates the vertex color (white × alpha) with the texture
    // shader; paint.blendMode is the framebuffer composite (Mix/Add/Mul/Sub).
    canvas.drawVertices(vertices, ui.BlendMode.modulate, _paintForBatch(batch));
  }

  /// Builds the [ui.Paint] for a batch: framebuffer blend (`render/blend.dart`)
  /// plus the resolved texture's identity [ui.ImageShader] (design §7B/§7C).
  ui.Paint _paintForBatch(fbs.DrawBatch batch) => ui.Paint()
    ..blendMode = blendModeFor(batch.blendType)
    ..shader = textures.shaderFor(batch.textureHash);

  // --- Teardown ------------------------------------------------------------

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _contextFinalizer.detach(this);
    _resourceFinalizer.detach(this);

    if (_context != ffi.nullptr) {
      _b.ss_runtime_destroy(_context);
      _context = ffi.nullptr;
    }
    if (_resource != ffi.nullptr) {
      _b.ss_resource_destroy(_resource);
      _resource = ffi.nullptr;
    }
    if (_ssabBuffer != ffi.nullptr) {
      malloc.free(_ssabBuffer);
      _ssabBuffer = ffi.nullptr;
    }
    calloc.free(_outFloatPtr);
    calloc.free(_outBytePtr);
    calloc.free(_outLen);
  }
}
