import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import 'package:ssruntime_dart/ssruntime_dart.dart';
import 'render/blend.dart';
import 'render/geometry_builder.dart';
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
class SpriteStudioInternalPlayer implements ffi.Finalizable {
  SpriteStudioInternalPlayer._(
    this._context,
    this._resource,
    this.textures,
    this._maskFlags,
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

  /// This frame's coverage bitmap. Retained past [paint] because the recorded
  /// picture rasterises later; disposed at the start of the next [paint].
  ui.Image? _coverage;

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

  // Native-assets: the finalizer function pointers come from the @Native
  // bindings (no DynamicLibrary). Constant, so shared statically.
  static final ffi.NativeFinalizer _contextFinalizer = ffi.NativeFinalizer(
      ffi.Native.addressOf<ffi.NativeFinalizerFunction>(ss_runtime_destroy));
  static final ffi.NativeFinalizer _resourceFinalizer = ffi.NativeFinalizer(
      ffi.Native.addressOf<ffi.NativeFinalizerFunction>(ss_resource_destroy));

  /// Loads `ssab` into a fresh Context and binds it.
  ///
  /// Steps mirror docs/30_core/10_initialization: create resource → create
  /// context → bind → set coordinate system. The `.ssab` is NOT
  /// validated by the Brain; validate untrusted input before calling this.
  factory SpriteStudioInternalPlayer.load(
    Uint8List ssab, {
    TextureRegistry? textures,
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

    return SpriteStudioInternalPlayer._(
      context,
      resource,
      textures ?? TextureRegistry(),
      // Mask roles (§1-2) live in the static `.ssab` PartData, not in FrameData
      // and not in any SoA buffer — read them once here rather than per frame.
      MaskPartFlags.readAll(ssab),
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
      return ss_runtime_setup_animation(_context, cName.cast());
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
  bool get isEndFrameReached => ss_runtime_is_end_frame_reached(_context);
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
    return ss_runtime_update(_context, deltaMs);
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
  /// parts, PartColor (§10) and masking (§9); the other kinds are pre-cut seams
  /// for Phase 2 (§8–§11) and skipped for now. BoxFit / scale placement into
  /// [dst] is also Phase 2.
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _ensureAlive();
    // Last frame's coverage has been rasterised by now; release it.
    _coverage?.dispose();
    _coverage = null;
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

    // Rewind the per-frame shader pools (reused across frames).
    _partColorShaders.rewind();
    _maskWriteShaders.rewind();

    // Masking (§9) is a pre-pass: collect this frame's writers, rasterise their
    // coverage bitmap, then let the batch loop test each target against it.
    // Unlike the flagship's viewport (1-frame latency, size classes, shrink
    // hysteresis) `toImageSync` gives us the bitmap within this same frame, so
    // none of that machinery is needed.
    final maskCtx = _buildMaskContext(frame, batches);

    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    for (final batch in batches) {
      switch (batch.kind) {
        case fbs.DrawBatchKind.Normal:
          _emitNormalBatch(canvas, batch, frame, maskCtx);
        case fbs.DrawBatchKind.Mask: // §9: coverage only, never colour
        case fbs.DrawBatchKind.Shape: // TODO(phase 2): §11 shape SoA
        case fbs.DrawBatchKind.Mesh: // TODO(phase 2): §8 mesh SoA
        case fbs.DrawBatchKind.Instance: // TODO(phase 2): §8 instance slot
        case fbs.DrawBatchKind.Effect: // TODO(phase 2): §8 effect slot
        case fbs.DrawBatchKind.Nines: // TODO(phase 2): §11 9-slice
        case fbs.DrawBatchKind.Text: // no SDK render path
          break; // kinds not yet ported are skipped
      }
    }
    canvas.restore();
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
      _MaskContext? maskCtx) {
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
      final part = frame.partByIndex[p];
      final pc = part == null ? null : PartColor.read(frame.frameData, part);
      final maskBits = maskCtx?.bitsForTarget(rank, flags);
      if (pc == null && maskBits == null) {
        run.add(p);
      } else {
        flushRun();
        _drawPeeledPart(canvas, p, pc, frame, batch, blend, maskBits, maskCtx);
      }
    }
    flushRun();
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
    MaskBits? maskBits,
    _MaskContext? maskCtx,
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

    final shader = _partColorShaders.next(program);
    _setPartColorUniforms(shader, pc ?? PartColor.identity, quad,
        texWidth: image.width.toDouble(),
        texHeight: image.height.toDouble(),
        maskBits: maskBits,
        plan: maskCtx?.plan);
    shader.setImageSampler(0, image);
    shader.setImageSampler(
        1, maskBits == null ? _ensureDummyCoverage() : maskCtx!.coverage);

    canvas.drawPath(
        _quadPath(quad), ui.Paint()..blendMode = blend..shader = shader);
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
    MaskPlan? plan,
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
    // uMaskUv / uMaskOff — player-local → coverage UV (§3-2-2).
    final basis = plan?.uvBasis;
    final offset = plan?.uvOffset;
    f(basis?[0] ?? 0.0);
    f(basis?[1] ?? 0.0);
    f(basis?[2] ?? 0.0);
    f(basis?[3] ?? 0.0);
    f(offset?[0] ?? 0.0);
    f(offset?[1] ?? 0.0);
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

  // --- Teardown ------------------------------------------------------------

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _coverage?.dispose();
    _coverage = null;
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
