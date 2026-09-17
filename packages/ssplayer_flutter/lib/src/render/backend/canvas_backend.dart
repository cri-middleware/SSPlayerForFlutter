import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/framedata.dart' as fbs;

import '../blend.dart';
import '../geometry_builder.dart';
import '../mask.dart';
import '../mask_context.dart';
import '../part_color.dart';
import '../part_shader.dart';
import '../root_transform.dart';
import '../../texture_registry.dart';
import 'render_backend.dart';
import 'render_host.dart';

/// Longest edge, in pixels, of the mask coverage bitmap (§3-2). The bitmap is
/// stretched over the writers' bounding box, so this is purely a quality knob;
/// the flagship caps at the same 1024 (≤ 4 MiB RGBA8).
const double _maxCoverageDim = 1024.0;

/// The dart:ui `Canvas.drawVertices` render backend — the default path, the only
/// Web path, and the visual-parity reference for the flutter_gpu backend.
///
/// Implements the per-kind emit paths, the peeled PartColor/mask shader draws, and
/// the offscreen mask-coverage pass over dart:ui `Canvas`. It reads per-player data (geometry baker,
/// textures, mask roles, effect plans) through the [RenderHost] passed to each
/// emit call, so one instance serves an entire instance-recursion tree.
class CanvasBackend implements RenderBackend {
  /// No-op: nothing here is prepared asynchronously, so there is never a frame
  /// to re-request. (Fragment programs do load lazily, but a part whose program
  /// is not ready falls back to a visible draw rather than being skipped.)
  @override
  set onResourcesReady(ui.VoidCallback? callback) {}

  /// No-op: every draw reads its shader/image straight from the (override-aware)
  /// [RenderHost.textures] registry, so a runtime texture replacement shows up on
  /// the next paint with nothing to evict here — unlike the GPU backend's cache.
  @override
  void invalidateTexture(int textureHash) {}

  /// PartColor (§10) + mask-replay (§3-2) fragment program — the shader every
  /// *peeled* part goes through. Compiled once, shared across players.
  static final _LazyProgram _partColorProgram =
      _LazyProgram('packages/ssplayer_flutter/shaders/partcolor.frag');

  /// Mask coverage writer (§3-2-1). Only loaded once an animation actually has
  /// mask writers.
  static final _LazyProgram _maskWriteProgram =
      _LazyProgram('packages/ssplayer_flutter/shaders/mask_write.frag');

  /// The built-in integration shaders (`SHDR`), one fragment program per effect,
  /// each compiled the first time a part actually uses it.
  ///
  /// Deliberately 13 programs rather than one mega-shader switching on an id: a
  /// runtime effect that impellerc rejects fails **silently** and falls back, so
  /// one shader per effect keeps a bad one from blanking the other twelve. They
  /// share `shaders/ss_shader_common.glsl` (hence one uniform layout and one
  /// writer, [_setSsShaderUniforms]), so the duplication is only in the file
  /// list. Shared across players; a load failure latches per effect.
  static final Map<SsShaderId, _LazyProgram> _ssPrograms =
      <SsShaderId, _LazyProgram>{
    for (final id in SsShaderId.values)
      id: _LazyProgram('packages/ssplayer_flutter/shaders/${id.asset}.frag'),
  };

  /// One [ui.Paint] reused across every plain Normal/Mesh batch draw instead of
  /// allocating one per batch. `Canvas.drawVertices` snapshots the paint's state
  /// at the call, so a single mutable instance is safe as long as every mutated
  /// field is re-set each time — [_paintForBatch] is its ONLY writer and always
  /// sets both `blendMode` and `shader`. Peeled / shape / effect draws build
  /// their own paints (different field sets) and never touch this one.
  final ui.Paint _batchPaint = ui.Paint();
  final ui.Paint _peeledPaint = ui.Paint();
  final ui.Paint _shapePaint = ui.Paint();
  final ui.Paint _effectPaint = ui.Paint();
  final ui.Paint _maskWritePaint = ui.Paint();

  // --- Per-frame scratch -----------------------------------------------------
  //
  // Reused across draws: a Canvas op copies its `Paint` and `Path` into the
  // display list at record time, so mutating either afterwards cannot disturb an
  // already-recorded draw (`test/scratch_reuse_test.dart` pins that down).
  //
  // ONE backend serves a whole instance tree (children draw through their
  // parent's — see `SpriteStudioInternalPlayer._paintTree`), so all of this is
  // shared across the recursion. That is sound only because instance recursion
  // happens BETWEEN batches — `_emitInstanceBatch` is its own `DrawBatchKind` —
  // so no `emit*` is ever re-entered while its run is live. [_noEmitInFlight]
  // asserts it, and the run lists are split per emit kind so the kinds are not
  // coupled at all.
  //
  // A reused `Paint` must have EVERY field it varies written on every use: a
  // field left unset silently inherits the previous draw's value.
  final List<int> _normalRunScratch = <int>[];
  final List<int> _shapeRunScratch = <int>[];
  final List<int> _meshRunScratch = <int>[];
  final List<efbs.EffectDrawCommand> _effectGroupScratch =
      <efbs.EffectDrawCommand>[];
  final ui.Path _quadPathScratch = ui.Path();
  final ui.Path _trianglesPathScratch = ui.Path();

  /// Debug-only re-entrancy guard, asserted at the top of every `emit*`.
  ///
  /// Every `emit*` flushes its run before returning, so an empty run list is
  /// exactly "no other `emit*` is part-way through". A future change that made
  /// one nest inside another (drawing an instance child from inside a batch
  /// rather than as its own batch) would trip here instead of silently
  /// interleaving two parts' geometry into one draw.
  bool get _noEmitInFlight {
    assert(
        _normalRunScratch.isEmpty &&
            _shapeRunScratch.isEmpty &&
            _meshRunScratch.isEmpty,
        'emit* re-entered — the per-frame scratch is not re-entrant');
    return true;
  }

  /// Reused `FragmentShader` instances (one per peeled part in a frame).
  /// Each draw in a Picture reads its shader's uniforms at raster time, so parts
  /// in the SAME frame need DISTINCT shader objects; across frames the pool is
  /// re-set (the documented, allocation-free reuse pattern). The cursors are
  /// rewound each frame via [rewindShaderPools].
  final _ShaderPool _partColorShaders = _ShaderPool();

  /// Same, for the coverage pass's writers.
  final _ShaderPool _maskWriteShaders = _ShaderPool();

  /// Same again, per integration-shader effect — a pool holds instances of ONE
  /// program, so the 13 effects cannot share one. Grown on demand: an animation
  /// with no shader parts allocates none.
  final Map<SsShaderId, _ShaderPool> _ssShaders = <SsShaderId, _ShaderPool>{};

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

  /// This frame's coverage bitmaps — **one per masked player in the tree**, since
  /// an instance child (§8) can mask independently of its parent and both sets of
  /// draws are recorded into the same picture.
  ///
  /// Retained past the frame because the recorded picture rasterises later, so
  /// they are disposed at the start of the *next* frame ([releaseCoverage],
  /// which the L2 player calls once per top-level `paint` — never per player).
  final List<ui.Image> _coverages = <ui.Image>[];

  /// The canvas the current top-level frame was begun on, so [finish] can undo
  /// [beginFrame]'s save.
  ui.Canvas? _frameCanvas;

  @override
  void beginFrame(ui.Canvas canvas,
      {ui.Rect? dst,
      ui.Size? sourceSize,
      SsRootTransform root = SsRootTransform.identity}) {
    // Place the animation's world origin at the center of the destination box.
    final origin = dst?.center ??
        ui.Offset((sourceSize?.width ?? 0) / 2, (sourceSize?.height ?? 0) / 2);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    // The player's flip / offset, on top of the centring and below everything
    // else: `drawn = offset + scale · local`, so the translate precedes the
    // scale. Everything under it — including the coverage pass and the
    // runtime-effect shaders, which read player-local coordinates — is unaware
    // this happened, which is the point of putting it here.
    if (!root.isIdentity) {
      canvas.translate(root.offset.dx, root.offset.dy);
      canvas.scale(root.scaleX, root.scaleY);
    }
    _frameCanvas = canvas;
  }

  @override
  void finish() {
    _frameCanvas?.restore();
    _frameCanvas = null;
    // Drop the frame's effect commands rather than pinning them until the next
    // frame overwrites the scratch. Nothing reads them stale (every user clears
    // first); this just stops the scratch from being a hidden retainer.
    _effectGroupScratch.clear();
  }

  @override
  void pushTransform(ui.Canvas canvas, Float64List world) {
    canvas.save();
    canvas.transform(world);
  }

  @override
  void popTransform(ui.Canvas canvas) => canvas.restore();

  /// The last whole-part tint, memoised — used by the peeled Mesh path
  /// (§1-2-3), which builds a 4×5 matrix per tinted part.
  ///
  /// A `ColorFilter` is immutable, so a tinted part would otherwise build a fresh
  /// one every frame. Such a tint is usually *static* (it only changes when the
  /// part's PartColor is animated), so comparing the 20 doubles is far cheaper
  /// than the object it saves — and a miss simply rebuilds.
  ///
  /// One entry, not a map: alternating tints thrash it, but a miss costs exactly
  /// what the un-memoised code paid every time, so this is never the worse trade.
  ///
  /// The key is a fixed 4×5 scratch overwritten in place, so a miss allocates
  /// only the `ColorFilter` itself — never worse than not memoising.
  final List<double> _lastTintMatrix = List<double>.filled(20, double.nan);
  ui.ColorFilter? _lastTintFilter;

  ui.ColorFilter _tintFilter(List<double> matrix) {
    if (matrix.length != _lastTintMatrix.length) {
      return ui.ColorFilter.matrix(matrix); // not the 4×5 shape — do not memoise
    }
    final cached = _lastTintFilter;
    if (cached != null) {
      var same = true;
      for (var i = 0; i < matrix.length; i++) {
        if (_lastTintMatrix[i] != matrix[i]) {
          same = false;
          break;
        }
      }
      if (same) return cached;
    }
    // `matrix` is the caller's list and may be recycled, so the key is a copy.
    // `ColorFilter.matrix` copies too, so the filter is safe to keep.
    _lastTintMatrix.setAll(0, matrix);
    return _lastTintFilter = ui.ColorFilter.matrix(matrix);
  }

  @override
  void rewindShaderPools() {
    _partColorShaders.rewind();
    _maskWriteShaders.rewind();
    for (final pool in _ssShaders.values) {
      pool.rewind();
    }
  }

  @override
  void releaseCoverage() {
    for (final coverage in _coverages) {
      coverage.dispose();
    }
    _coverages.clear();
  }

  @override
  void dispose() {
    releaseCoverage();
    _partColorShaders.dispose();
    _maskWriteShaders.dispose();
    for (final pool in _ssShaders.values) {
      pool.dispose();
    }
    _ssShaders.clear();
  }

  @override
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
      Map<int, int> textureByRank) {
    final program = _maskWriteProgram.get();
    if (program == null) return null; // still compiling — draw unmasked this frame
    final coverage = _renderCoverage(plan, frame, host, program, textureByRank);
    if (coverage == null) return null;
    // Kept alive until the next frame releases it; the MaskContext is what the
    // draws actually sample through (a child's own coverage travels with its own
    // context, so this list is purely ownership).
    _coverages.add(coverage);
    return MaskContext(plan, coverage);
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
    RenderHost host,
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
    // Own writers (§2-2), baked from this player's geometry — the canvas is
    // already this player's local space.
    for (final writer in plan.writers) {
      if (writer.partIndex < 0) continue; // carry-over sentinel — baked below
      if (_bakeCoverageWriter(
        canvas,
        program,
        geometry: host.geometry,
        textures: host.textures,
        frame: frame,
        flags: host.flagsFor(writer.partIndex),
        partIndex: writer.partIndex,
        bit: writer.bit,
        threshold: writer.threshold,
        textureHash: textureByRank[writer.drawRank],
      )) {
        wrote = true;
      }
    }
    // Carry-over (§2-6): an instance child's clipping writers, baked from the
    // CHILD's geometry under the instance slot matrix so they land in this
    // player's coverage. The slot maps child-local → owner-local; the canvas is
    // owner-local, so the transform places them exactly where the child draws.
    for (final bw in plan.bubbled) {
      canvas.save();
      canvas.transform(bw.slot);
      final ok = _bakeCoverageWriter(
        canvas,
        program,
        geometry: bw.geometry,
        textures: bw.textures,
        frame: bw.frame,
        flags: bw.flags,
        partIndex: bw.childPartIndex,
        bit: bw.bit,
        threshold: bw.threshold,
        textureHash: bw.textureHash,
      );
      canvas.restore();
      if (ok) wrote = true;
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

  /// Bakes one coverage writer into [canvas] under its [bit]: the bit colour over
  /// a shape/mesh polygon (§2-5 shape special case — geometry *is* the mask), or
  /// the cutout shader over a textured quad. [geometry]/[textures]/[frame] are the
  /// writer's SOURCE — this player's for an own writer, an instance child's for a
  /// carried-up one (§2-6) — so this path is source-agnostic. The caller places a
  /// carried-up writer with a `canvas.transform`; the geometry itself is built in
  /// source-local space. Returns whether anything was drawn.
  ///
  /// Every draw is a **binary** fill (`isAntiAlias = false`): a coverage bit is a
  /// number, not a picture, so a half-covered edge pixel would decode as a
  /// *different* writer's bits (and shared triangle edges would double-add under
  /// `plus`). Disjoint bits + additive blend is a lossless OR.
  bool _bakeCoverageWriter(
    ui.Canvas canvas,
    ui.FragmentProgram program, {
    required GeometryBuilder geometry,
    required TextureRegistry textures,
    required DrawFrame frame,
    required MaskPartFlags flags,
    required int partIndex,
    required int bit,
    required double threshold,
    required int? textureHash,
  }) {
    if (flags.shapeGeometry) {
      final geo =
          geometry.buildShapeParts(geometry.singlePart(partIndex), frame);
      if (geo == null) return false;
      canvas.drawPath(
        _trianglesPath(geo),
        _maskWritePaint
          ..blendMode = ui.BlendMode.plus
          ..color = _bitColor(bit)
          ..shader = null
          ..colorFilter = null
          ..isAntiAlias = false,
      );
      return true;
    }
    if (flags.meshGeometry) {
      final geo =
          geometry.buildMeshGeometry(geometry.singlePart(partIndex), frame);
      if (geo == null) return false;
      canvas.drawPath(
        _trianglesPath(geo),
        _maskWritePaint
          ..blendMode = ui.BlendMode.plus
          ..color = _bitColor(bit)
          ..shader = null
          ..colorFilter = null
          ..isAntiAlias = false,
      );
      return true;
    }
    final quad = geometry.buildPartColorQuad(partIndex, frame);
    if (quad == null) return false;
    final image = textureHash == null ? null : textures.imageFor(textureHash);
    if (image == null) return false;
    final shader = _maskWriteShaders.next(program);
    _setMaskWriteUniforms(shader, bit, threshold, quad,
        texWidth: image.width.toDouble(), texHeight: image.height.toDouble());
    shader.setImageSampler(0, image);
    canvas.drawPath(
        _quadPath(quad),
        _maskWritePaint
          ..blendMode = ui.BlendMode.plus
          // Opaque white, NOT the bit colour a previous writer left here: with a
          // shader bound the paint's RGB is unused but its ALPHA still modulates
          // the shader's output, and the bit must land undimmed.
          ..color = const ui.Color(0xFFFFFFFF)
          ..colorFilter = null
          ..isAntiAlias = false
          ..shader = shader);
    return true;
  }

  @override
  void emitNormal(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, InheritedMask? inheritedMask) {
    assert(_noEmitInFlight);
    final start = batch.startRank;
    final count = batch.count;
    if (count == 0) return;
    final drawOrder = frame.drawOrder;
    final passes = blendPassesFor(batch.blendType);
    // Fetch the frame's parts_color / shaders vectors once (see
    // [DrawFrame.partsColor]).
    final partsColor = frame.partsColor;
    final shaders = frame.shaders;

    final run = _normalRunScratch..clear();
    void flushRun() {
      if (run.isEmpty) return;
      // 2nd arg modulates the vertex color (white × alpha) with the texture
      // shader; paint.blendMode is the framebuffer composite.
      final vertices = host.geometry.buildNormalParts(run, frame);
      if (vertices != null) {
        for (final pass in passes) {
          canvas.drawVertices(vertices, ui.BlendMode.modulate,
              _paintForBatch(batch, host, pass));
        }
      }
      run.clear();
    }

    for (var k = 0; k < count; k++) {
      final rank = start + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      final flags = host.flagsFor(p);
      // Coverage-only. It draws nothing, so it cannot split the run either.
      if (flags.pureMask) continue;
      final part = frame.partOf(p);
      final pc = part == null ? null : PartColor.read(partsColor, part);
      // This player's own mask wins per-part when a writer actually reaches the
      // part; when its own writers miss it, the mask inherited from the parent
      // instance (§3-2-2) clips it instead of the part vanishing (see
      // [resolvePartMask]). The shader tests one coverage per fragment, so a part
      // reached by BOTH keeps only its own test (a nested-mask case that would
      // need a second sampler to fully combine).
      final mask = resolvePartMask(maskCtx, inheritedMask, rank, flags);
      // Integration shader (`SHDR`). NOT combined with a mask test: the
      // peeled shader binds no coverage sampler, so a masked shader part keeps
      // the plain masked path and drops its effect — the v1 limitation both
      // sibling ports share.
      final sh =
          (part == null || mask != null) ? null : PartShader.read(shaders, part);
      if (pc == null && mask == null && sh == null) {
        run.add(p);
        // A multi-pass blend (Sub / Invert) must cover each pixel exactly once
        // per pass, so its parts cannot share a run — two overlapping ones would
        // invert their overlap twice and cancel it (see [blendPassesFor]).
        if (passes.length > 1) flushRun();
      } else {
        flushRun();
        if (sh != null) {
          _drawShaderPart(canvas, p, sh, pc, frame, host, batch, passes);
        } else {
          _drawPeeledPart(canvas, p, pc, frame, host, batch, passes, mask);
        }
      }
    }
    flushRun();
  }

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, InheritedMask? inheritedMask) {
    assert(_noEmitInFlight);
    if (batch.count == 0 || frame.shape == null) return;
    final passes = blendPassesFor(batch.blendType);

    final run = _shapeRunScratch..clear();
    void flushRun() {
      if (run.isEmpty) return;
      final v = host.geometry.buildShapeParts(run, frame);
      if (v != null) {
        final vertices = v.toVertices();
        for (final pass in passes) {
          canvas.drawVertices(
              vertices,
              ui.BlendMode.modulate,
              _shapePaint
                ..blendMode = pass.mode
                ..colorFilter = pass.filter
                ..shader = null
                ..color = const ui.Color(0xFFFFFFFF));
        }
      }
      run.clear();
    }

    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= frame.drawOrder.length) break;
      final p = frame.drawOrder[rank];
      final flags = host.flagsFor(p);
      if (flags.pureMask) continue; // coverage only, never colour
      final mask = resolvePartMask(maskCtx, inheritedMask, rank, flags);
      if (mask == null) {
        run.add(p);
        if (passes.length > 1) flushRun(); // see [emitNormal]
      } else {
        flushRun();
        _drawMaskedShape(canvas, p, frame, host, passes, mask);
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
      RenderHost host, List<BlendPass> passes, MaskDraw mask) {
    final program = _partColorProgram.get();
    final geometry =
        host.geometry.buildShapeParts(host.geometry.singlePart(part), frame);
    if (geometry == null) return;
    if (program == null) {
      // Still compiling — draw unmasked rather than dropping the shape.
      final vertices = geometry.toVertices();
      for (final pass in passes) {
        canvas.drawVertices(
            vertices,
            ui.BlendMode.modulate,
            _shapePaint
              ..blendMode = pass.mode
              ..colorFilter = pass.filter
              ..shader = null
              ..color = const ui.Color(0xFFFFFFFF));
      }
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
    // The Canvas backend always provides a ui.Image coverage (only the GPU
    // backend passes null, and it never runs this path).
    shader.setImageSampler(1, mask.coverage!);

    // One shader instance across all passes: the pool's "distinct object per
    // draw" rule exists because uniforms are read at raster time, and every pass
    // here reads the *same* uniforms.
    final vertices = geometry.toVertices();
    for (final pass in passes) {
      canvas.drawVertices(
          vertices,
          ui.BlendMode.modulate,
          _shapePaint
            ..blendMode = pass.mode
            ..colorFilter = pass.filter
            // Opaque white: with a shader bound the RGB is unused, but the alpha
            // modulates it — and the unmasked branch above leaves a colour here.
            ..color = const ui.Color(0xFFFFFFFF)
            ..shader = shader);
    }
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

  @override
  void emitMesh(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, InheritedMask? inheritedMask) {
    assert(_noEmitInFlight);
    final count = batch.count;
    if (count == 0) return;
    final drawOrder = frame.drawOrder;
    final partsColor = frame.partsColor;
    final passes = blendPassesFor(batch.blendType);

    // Same run/peel shape as [emitNormal]: plain parts batch into one
    // `drawVertices`, tinted/masked ones are drawn individually in z-order.
    final run = _meshRunScratch..clear();
    void flushRun() {
      if (run.isEmpty) return;
      final vertices = host.geometry.buildMeshParts(run, frame);
      if (vertices != null) {
        for (final pass in passes) {
          canvas.drawVertices(vertices, ui.BlendMode.modulate,
              _paintForBatch(batch, host, pass));
        }
      }
      run.clear();
    }

    for (var k = 0; k < count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      final flags = host.flagsFor(p);
      if (flags.pureMask) continue; // coverage-only: never draws colour
      final state = frame.partOf(p);
      final pc = state == null ? null : PartColor.read(partsColor, state);
      final mask = resolvePartMask(maskCtx, inheritedMask, rank, flags);
      if (pc == null && mask == null) {
        run.add(p);
        if (passes.length > 1) flushRun(); // see [emitNormal]
      } else {
        flushRun();
        _drawPeeledMesh(canvas, p, pc, frame, host, batch, passes, mask);
      }
    }
    flushRun();
  }

  /// Draws one peeled Mesh part (§8): PartColor (§10) and/or a mask test (§9).
  ///
  /// Where a Normal part needs `partcolor.frag` — four corners, so the tint is
  /// per-fragment — a Mesh tint is **whole-only** and therefore one affine on
  /// rgb, which is exactly a [ui.ColorFilter.matrix] on the draw's own paint. No
  /// shader, no peeled quad, and the deformed triangles keep going through the
  /// ordinary textured `drawVertices` path, which is why this works at all: a
  /// Flutter fragment shader gets no per-vertex varyings, so it could never
  /// sample the atlas at a *deformed mesh* UV.
  ///
  /// A mask test can't be folded into a colour filter (it is per-fragment), so a
  /// masked part additionally goes through a layer and is gated by drawing the
  /// coverage test over it with [ui.BlendMode.dstIn] — the shader answers "does
  /// this fragment pass?" in alpha, and `dstIn` multiplies that into what was
  /// drawn. The batch blend then composites the layer as one.
  void _drawPeeledMesh(
    ui.Canvas canvas,
    int part,
    PartColor? pc,
    DrawFrame frame,
    RenderHost host,
    fbs.DrawBatch batch,
    List<BlendPass> passes,
    MaskDraw? mask,
  ) {
    // With a tint the corner alpha already carries the hierarchical alpha
    // (§1-3); only the instance chain's scale is still owed. Without one the
    // part's own alpha applies as usual.
    final tinted = pc?.scaleAlpha(frame.alphaScale);
    final geometry = host.geometry.buildMeshGeometry(
        host.geometry.singlePart(part), frame,
        alphaOverride: tinted?.lt.a);
    if (geometry == null) return;
    final matrix = tinted?.wholeTintMatrix();
    // Built once for the whole part: a `ColorFilter` is immutable, so building
    // it inside the pass loop allocated one per pass for the same tint. Through
    // the memo, so a run of parts sharing a tint also shares its filter.
    final tint = matrix == null ? null : _tintFilter(matrix);
    final vertices = geometry.toVertices();

    final program = mask == null ? null : _partColorProgram.get();
    if (mask == null || program == null) {
      // Unmasked (or the gate program is still compiling — draw ungated rather
      // than dropping the part): one plain draw, tint folded into the paint.
      for (final pass in passes) {
        canvas.drawVertices(
          vertices,
          ui.BlendMode.modulate,
          _paintForBatch(batch, host, pass, colorFilter: tint),
        );
      }
      return;
    }

    // Inflated so neither the layer nor the gate rect can shave the geometry's
    // outermost pixel row (the bbox lands exactly on it).
    final bounds = geometry.bounds.inflate(1.0);
    // The gate: `partcolor.frag` over a 1×1 white texel at rate 0 is opaque
    // white where the mask passes and transparent where it does not (the same
    // no-op configuration `_drawMaskedShape` uses), so `dstIn` keeps exactly the
    // fragments that pass. Built once and reused across the passes below — they
    // all read the same uniforms, which is what the pool's one-object-per-draw
    // rule actually guards against.
    final shader = _partColorShaders.next(program);
    _setPartColorUniforms(shader, PartColor.identity, _unitQuad,
        texWidth: 1.0,
        texHeight: 1.0,
        maskBits: mask.bits,
        maskUvBasis: mask.uvBasis,
        maskUvOffset: mask.uvOffset);
    shader.setImageSampler(0, _ensureWhitePixel());
    shader.setImageSampler(1, mask.coverage!);

    // A masked part composites as one layer, so a multi-pass blend records the
    // layer once per pass — with the pass's filter on the *layer's* paint, which
    // is where it belongs: the layer result is the part's final colour.
    // `_peeledPaint` is shared with [_drawPeeledPart] / [_drawShaderPart], which
    // set `isAntiAlias` from [_antiAliasFor] — so all three draws below state it
    // rather than inheriting whatever the previous part (or the previous pass's
    // gate rect) happened to leave.
    for (final pass in passes) {
      canvas.saveLayer(
          bounds,
          _peeledPaint
            ..blendMode = pass.mode
            ..colorFilter = pass.filter
            ..isAntiAlias = true
            ..shader = null);
      canvas.drawVertices(
        vertices,
        ui.BlendMode.modulate,
        _peeledPaint
          ..blendMode = ui.BlendMode.srcOver
          ..isAntiAlias = true
          ..shader = host.textures.shaderFor(batch.textureHash)
          ..colorFilter = tint,
      );
      canvas.drawRect(
          bounds,
          _peeledPaint
            ..blendMode = ui.BlendMode.dstIn
            ..isAntiAlias = false
            ..colorFilter = null
            ..shader = shader);
      canvas.restore();
    }
  }

  @override
  void emitEffect(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host) {
    if (!host.hasEffects) return;
    final drawOrder = frame.drawOrder;

    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final part = drawOrder[rank];
      final plan = host.effectPlanFor(part);
      final commands = plan?.commands;
      if (plan == null || commands == null) continue; // invisible / dead slot

      var i = 0;
      while (i < commands.length) {
        final first = commands[i];
        // The runtime still emits a command for an emitter whose cell failed to
        // resolve, with quad_count 0 — skip before touching the texture.
        if (first.quadCount == 0) {
          i++;
          continue;
        }
        final image = host.textures.imageFor(first.cellmapHash);
        if (image == null) {
          i++;
          continue;
        }
        final cellmap = first.cellmapHash;
        final blend = first.blend;

        // Gather the maximal run of drawable same-(cellmap,blend) commands,
        // keeping the group's vertex count inside the 16-bit index limit.
        final group = _effectGroupScratch
          ..clear()
          ..add(first);
        var groupVerts = first.quadCount * 4;
        var j = i + 1;
        while (j < commands.length) {
          final c = commands[j];
          if (c.quadCount == 0 ||
              c.cellmapHash != cellmap ||
              c.blend != blend ||
              groupVerts + c.quadCount * 4 > 0xFFFF) {
            break;
          }
          group.add(c);
          groupVerts += c.quadCount * 4;
          j++;
        }
        i = j;

        final geometry = host.geometry.buildEffectGroup(
          plan,
          group,
          part,
          frame,
          texWidth: image.width.toDouble(),
          texHeight: image.height.toDouble(),
        );
        if (geometry == null) continue;

        canvas.drawVertices(
          geometry.toVertices(),
          ui.BlendMode.modulate,
          _effectPaint
            // An emitter's blend is the raw 0=Mix / 1=Add byte, NOT a BlendType.
            ..blendMode = effectBlendModeFor(blend)
            ..shader = host.textures.shaderFor(cellmap)
            ..colorFilter = null
            ..color = const ui.Color(0xFFFFFFFF),
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
    RenderHost host,
    fbs.DrawBatch batch,
    List<BlendPass> passes,
    MaskDraw? mask,
  ) {
    final program = _partColorProgram.get();
    final image = host.textures.imageFor(batch.textureHash);
    final quad = host.geometry.buildPartColorQuad(part, frame);
    if (program == null || image == null || quad == null) {
      // Fallback: plain textured draw so the part stays visible.
      final v = host.geometry
          .buildNormalParts(host.geometry.singlePart(part), frame);
      if (v != null) {
        for (final pass in passes) {
          canvas.drawVertices(
              v, ui.BlendMode.modulate, _paintForBatch(batch, host, pass));
        }
      }
      return;
    }

    // Two different alpha contracts meet here (§1-3):
    //  * WITH PartColor the Brain has already pre-folded the part's hierarchical
    //    alpha into the corner alphas, so re-multiplying it would double-apply.
    //    Only the instance chain's scale — which lives in the *parent's*
    //    FrameData and so cannot be pre-folded — is still owed.
    //  * WITHOUT PartColor there is no corner alpha to inherit, so the part's
    //    own alpha must be supplied (§1-2-4's "vertex colour = white, alpha = hierarchical alpha");
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
        1, mask == null ? _ensureDummyCoverage() : mask.coverage!);

    // One path + one shader across the passes (identical uniforms every time, so
    // the pool's distinct-instance rule is satisfied), which also guarantees the
    // inversion passes of a Sub / Invert plan cover exactly the same pixels.
    final path = _quadPath(quad);
    final antiAlias = _antiAliasFor(passes);
    for (final pass in passes) {
      canvas.drawPath(
          path,
          _peeledPaint
            ..blendMode = pass.mode
            ..colorFilter = pass.filter
            ..isAntiAlias = antiAlias
            ..shader = shader);
    }
  }

  /// Whether a blend plan's passes may be anti-aliased.
  ///
  /// Rasterizer coverage is applied *after* the paint's colour filter, so on a
  /// partly-covered edge pixel a multi-pass plan's two inversions no longer
  /// cancel: `difference` against white returns `c + b - 2bc` rather than
  /// `1 - b`, and the round trip lands on ~0.5 regardless of the source — a dark
  /// fringe around every anti-aliased Sub / Invert part. Single-pass modes are
  /// unaffected and keep their smooth edges, which is the overwhelmingly common
  /// case; only the reconstructed plans pay the hard edge. One bool per part.
  static bool _antiAliasFor(List<BlendPass> passes) => passes.length == 1;

  /// Draws one Normal part carrying an integration shader (`SHDR`) through
  /// that effect's `shaders/ss_*.frag` program.
  ///
  /// Structurally [_drawPeeledPart] with a different fragment program: the part
  /// is drawn on its own quad and the shader rebuilds the UV / colour / rate
  /// gradient from the CPU-supplied affine (see `ss_shader_common.glsl`), so the
  /// effect bodies get the `vUV` / `vColor` varyings their WebGL originals
  /// assume. Every effect but `ss-blur` then folds the PartColor formula as its
  /// output tail, which is why [pc] travels along: a part can carry both, and
  /// one without a PartColor still needs the passthrough corner so its
  /// hierarchical alpha survives (§1-3, same contract as [_drawPeeledPart]).
  ///
  /// Falls back to the ordinary peeled path — effect dropped, colours intact —
  /// when the program is still compiling (or failed to) or the texture/quad is
  /// unavailable, so the part stays visible either way.
  void _drawShaderPart(
    ui.Canvas canvas,
    int part,
    PartShader sh,
    PartColor? pc,
    DrawFrame frame,
    RenderHost host,
    fbs.DrawBatch batch,
    List<BlendPass> passes,
  ) {
    final program = _ssPrograms[sh.id]!.get();
    final image = host.textures.imageFor(batch.textureHash);
    final quad = host.geometry.buildPartColorQuad(part, frame);
    if (program == null || image == null || quad == null) {
      _drawPeeledPart(canvas, part, pc, frame, host, batch, passes, null);
      return;
    }

    final effective = pc == null
        ? PartColor.passthrough(frame.alphaOf(part))
        : pc.scaleAlpha(frame.alphaScale);
    final texWidth = image.width.toDouble();
    final texHeight = image.height.toDouble();

    final shader =
        _ssShaders.putIfAbsent(sh.id, _ShaderPool.new).next(program);
    final cell = host.geometry.cellRectScratch(quad, texWidth, texHeight);
    _setSsShaderUniforms(shader, effective, quad, sh,
        texWidth: texWidth, texHeight: texHeight, cellRect: cell);
    // Bilinear, like the batched ImageShader path — the peeled sampler defaults
    // to nearest, which the multi-tap effects (blur / outline / move) would
    // turn into visible stair-stepping.
    shader.setImageSampler(0, image, filterQuality: ui.FilterQuality.low);

    final path = _quadPath(quad); // same geometry every pass — see [_drawPeeledPart]
    final antiAlias = _antiAliasFor(passes); // see [_antiAliasFor]
    for (final pass in passes) {
      canvas.drawPath(
          path,
          _peeledPaint
            ..blendMode = pass.mode
            ..colorFilter = pass.filter
            ..isAntiAlias = antiAlias
            ..shader = shader);
    }
  }

  /// The union of a baked block's triangles, as one non-zero-wound path.
  ///
  /// Built from the very triangles the colour pass draws rather than from a
  /// re-derived outline, so the coverage a shape writes can never disagree with
  /// the shape it draws.
  ui.Path _trianglesPath(MeshGeometry g) {
    final path = _trianglesPathScratch..reset();
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
  ui.Path _quadPath(PartColorQuad quad) {
    final c = quad.corners;
    return _quadPathScratch
      ..reset()
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
    f(maskBits != null && maskBits.visibleInside ? 1.0 : 0.0);
    f(maskBits != null ? 1.0 : 0.0);
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

  /// Writes the integration-shader uniforms in the declaration order of
  /// `shaders/ss_shader_common.glsl` — the block all 13 `ss_*.frag` programs
  /// share, which is what lets ONE writer serve every effect.
  ///
  /// The first eleven entries are `partcolor.frag`'s reconstruction + PartColor
  /// block verbatim (see [_setPartColorUniforms]); the two after them are the
  /// effect's own parameters and, for `ss-circle` / `ss-spot`, the cell's UV
  /// rect. An effect that reads neither still has them in its layout — impellerc
  /// keeps a declared-but-unused uniform in its slot — so the indices below hold
  /// for all 13.
  ///
  /// [cellRect] is passed in rather than derived here because the caller already
  /// has it (and owns the scratch it lives in — see
  /// [GeometryBuilder.cellRectScratch]).
  static void _setSsShaderUniforms(
    ui.FragmentShader shader,
    PartColor pc,
    PartColorQuad quad,
    PartShader sh, {
    required double texWidth,
    required double texHeight,
    required Float32List cellRect,
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
    f(sh.param0); // uParams (param0..param3)
    f(sh.param1);
    f(sh.param2);
    f(sh.param3);
    f(cellRect[0]); // uCellRect
    f(cellRect[1]);
    f(cellRect[2]);
    f(cellRect[3]);
  }

  /// Writes the coverage-writer uniforms in the declaration order of
  /// `shaders/mask_write.frag`.
  static void _setMaskWriteUniforms(
    ui.FragmentShader shader,
    int bit,
    double threshold,
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
    final channel = bit ~/ 8;
    final value = (1 << (bit % 8)) / 255.0;
    f(channel == 0 ? value : 0.0);
    f(channel == 1 ? value : 0.0);
    f(channel == 2 ? value : 0.0);
    f(threshold);
  }

  /// Configures the shared [_batchPaint] for one [pass] of a batch — the pass's
  /// framebuffer blend (`render/blend.dart`) plus the resolved texture's identity
  /// [ui.ImageShader] (design §7B/§7C) — and returns it. The result aliases
  /// [_batchPaint]; a caller must consume it (draw) before the next
  /// [_paintForBatch] call, which every call site does within one pass's scope.
  ///
  /// [colorFilter] is the whole-part PartColor tint of a peeled Mesh part
  /// ([_drawPeeledMesh]). A pass that wants coverage or a flat fill overrides it
  /// ([BlendPass.filter]); either way it is written unconditionally — like every
  /// other field here — so a tinted part can never leak its filter into the next
  /// draw.
  ui.Paint _paintForBatch(fbs.DrawBatch batch, RenderHost host, BlendPass pass,
          {ui.ColorFilter? colorFilter}) =>
      _batchPaint
        ..blendMode = pass.mode
        ..shader = host.textures.shaderFor(batch.textureHash)
        ..colorFilter = pass.filter ?? colorFilter;
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
