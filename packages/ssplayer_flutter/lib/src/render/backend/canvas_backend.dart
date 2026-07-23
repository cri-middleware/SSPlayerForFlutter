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
import 'render_backend.dart';
import 'render_host.dart';

/// Longest edge, in pixels, of the mask coverage bitmap (§3-2). The bitmap is
/// stretched over the writers' bounding box, so this is purely a quality knob;
/// the flagship caps at the same 1024 (≤ 4 MiB RGBA8).
const double _maxCoverageDim = 1024.0;

/// The dart:ui `Canvas.drawVertices` render backend — the default path, the only
/// Web path, and the visual-parity reference for the flutter_gpu backend.
///
/// This is a behaviour-preserving extraction of the L2 player's former drawing
/// methods: the per-kind emit paths, the peeled PartColor/mask shader draws, and
/// the offscreen mask-coverage pass. It reads per-player data (geometry baker,
/// textures, mask roles, effect plans) through the [RenderHost] passed to each
/// emit call, so one instance serves an entire instance-recursion tree.
class CanvasBackend implements RenderBackend {
  /// PartColor (§10) + mask-replay (§3-2) fragment program — the shader every
  /// *peeled* part goes through. Compiled once, shared across players.
  static final _LazyProgram _partColorProgram =
      _LazyProgram('packages/ssplayer_flutter/shaders/partcolor.frag');

  /// Mask coverage writer (§3-2-1). Only loaded once an animation actually has
  /// mask writers.
  static final _LazyProgram _maskWriteProgram =
      _LazyProgram('packages/ssplayer_flutter/shaders/mask_write.frag');

  /// One [ui.Paint] reused across every plain Normal/Mesh batch draw instead of
  /// allocating one per batch. `Canvas.drawVertices` snapshots the paint's state
  /// at the call, so a single mutable instance is safe as long as every mutated
  /// field is re-set each time — [_paintForBatch] is its ONLY writer and always
  /// sets both `blendMode` and `shader`. Peeled / shape / effect draws build
  /// their own paints (different field sets) and never touch this one.
  final ui.Paint _batchPaint = ui.Paint();

  /// Reused `FragmentShader` instances (one per peeled part in a frame).
  /// Each draw in a Picture reads its shader's uniforms at raster time, so parts
  /// in the SAME frame need DISTINCT shader objects; across frames the pool is
  /// re-set (the documented, allocation-free reuse pattern). The cursors are
  /// rewound each frame via [rewindShaderPools].
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
  void beginFrame(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    // Place the animation's world origin at the center of the destination box.
    final origin = dst?.center ??
        ui.Offset((sourceSize?.width ?? 0) / 2, (sourceSize?.height ?? 0) / 2);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    _frameCanvas = canvas;
  }

  @override
  void finish() {
    _frameCanvas?.restore();
    _frameCanvas = null;
  }

  @override
  void pushTransform(ui.Canvas canvas, Float64List world) {
    canvas.save();
    canvas.transform(world);
  }

  @override
  void popTransform(ui.Canvas canvas) => canvas.restore();

  @override
  void pushGroupTint(ui.Canvas canvas, List<double> matrix) =>
      // Bounds-less: the subtree's extent isn't known before it is drawn, so the
      // layer is sized by what lands in it (the same trade the flagship's
      // group-modulate makes).
      canvas.saveLayer(null, ui.Paint()..colorFilter = ui.ColorFilter.matrix(matrix));

  @override
  void popGroupTint(ui.Canvas canvas) => canvas.restore();

  @override
  void rewindShaderPools() {
    _partColorShaders.rewind();
    _maskWriteShaders.rewind();
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
    for (final writer in plan.writers) {
      // A Shape writer (§2-5「シェイプの特例」) has no cell, hence no texel alpha
      // to threshold: its polygon *is* the mask. That needs no shader at all —
      // the bit colour over the geometry, additively, is the whole operation.
      if (host.flagsFor(writer.partIndex).shapeGeometry) {
        final geometry =
            host.geometry.buildShapeParts(<int>[writer.partIndex], frame);
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
      if (host.flagsFor(writer.partIndex).meshGeometry) {
        final geometry =
            host.geometry.buildMeshGeometry(<int>[writer.partIndex], frame);
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

      final quad = host.geometry.buildPartColorQuad(writer.partIndex, frame);
      if (quad == null) continue;
      final hash = textureByRank[writer.drawRank];
      final image = hash == null ? null : host.textures.imageFor(hash);
      if (image == null) continue;

      final shader = _maskWriteShaders.next(program);
      _setMaskWriteUniforms(shader, writer, quad,
          texWidth: image.width.toDouble(),
          texHeight: image.height.toDouble());
      shader.setImageSampler(0, image);
      // Disjoint bits + additive blend == a lossless OR.
      canvas.drawPath(_quadPath(quad),
          ui.Paint()..blendMode = ui.BlendMode.plus..shader = shader);
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

  @override
  void emitNormal(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask) {
    final start = batch.startRank;
    final count = batch.count;
    if (count == 0) return;
    final drawOrder = frame.drawOrder;
    final paint = _paintForBatch(batch, host);
    final blend = blendModeFor(batch.blendType);
    // Fetch the frame's parts_color vector once (see [DrawFrame.partsColor]).
    final partsColor = frame.partsColor;

    final run = <int>[];
    void flushRun() {
      if (run.isEmpty) return;
      // 2nd arg modulates the vertex color (white × alpha) with the texture
      // shader; paint.blendMode is the framebuffer composite.
      final vertices = host.geometry.buildNormalParts(run, frame);
      if (vertices != null) {
        canvas.drawVertices(vertices, ui.BlendMode.modulate, paint);
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
        _drawPeeledPart(canvas, p, pc, frame, host, batch, blend, mask);
      }
    }
    flushRun();
  }

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask) {
    if (batch.count == 0 || frame.shape == null) return;
    final blend = blendModeFor(batch.blendType);

    final run = <int>[];
    void flushRun() {
      if (run.isEmpty) return;
      final v = host.geometry.buildShapeParts(run, frame);
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
      final flags = host.flagsFor(p);
      if (flags.pureMask) continue; // coverage only, never colour
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final mask = ownBits != null ? maskCtx!.drawFor(ownBits) : inheritedMask;
      if (mask == null) {
        run.add(p);
      } else {
        flushRun();
        _drawMaskedShape(canvas, p, frame, host, blend, mask);
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
      RenderHost host, ui.BlendMode blend, MaskDraw mask) {
    final program = _partColorProgram.get();
    final geometry = host.geometry.buildShapeParts(<int>[part], frame);
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
    // The Canvas backend always provides a ui.Image coverage (only the GPU
    // backend passes null, and it never runs this path).
    shader.setImageSampler(1, mask.coverage!);

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

  @override
  void emitMesh(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask) {
    final count = batch.count;
    if (count == 0) return;
    final drawOrder = frame.drawOrder;
    final partsColor = frame.partsColor;

    // Same run/peel shape as [emitNormal]: plain parts batch into one
    // `drawVertices`, tinted/masked ones are drawn individually in z-order.
    final run = <int>[];
    void flushRun() {
      if (run.isEmpty) return;
      final vertices = host.geometry.buildMeshParts(run, frame);
      if (vertices != null) {
        canvas.drawVertices(
            vertices, ui.BlendMode.modulate, _paintForBatch(batch, host));
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
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final mask = ownBits != null ? maskCtx!.drawFor(ownBits) : inheritedMask;
      if (pc == null && mask == null) {
        run.add(p);
      } else {
        flushRun();
        _drawPeeledMesh(canvas, p, pc, frame, host, batch, mask);
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
    MaskDraw? mask,
  ) {
    // With a tint the corner alpha already carries the hierarchical alpha
    // (§1-3); only the instance chain's scale is still owed. Without one the
    // part's own alpha applies as usual.
    final tinted = pc?.scaleAlpha(frame.alphaScale);
    final geometry = host.geometry.buildMeshGeometry(<int>[part], frame,
        alphaOverride: tinted?.lt.a);
    if (geometry == null) return;
    final matrix = tinted?.wholeTintMatrix();
    final blend = blendModeFor(batch.blendType);

    final program = mask == null ? null : _partColorProgram.get();
    if (mask == null || program == null) {
      // Unmasked (or the gate program is still compiling — draw ungated rather
      // than dropping the part): one plain draw, tint folded into the paint.
      canvas.drawVertices(
        geometry.toVertices(),
        ui.BlendMode.modulate,
        _paintForBatch(batch, host,
            colorFilter: matrix == null ? null : ui.ColorFilter.matrix(matrix)),
      );
      return;
    }

    // Inflated so neither the layer nor the gate rect can shave the geometry's
    // outermost pixel row (the bbox lands exactly on it).
    final bounds = geometry.bounds.inflate(1.0);
    canvas.saveLayer(bounds, ui.Paint()..blendMode = blend);
    canvas.drawVertices(
      geometry.toVertices(),
      ui.BlendMode.modulate,
      ui.Paint()
        ..shader = host.textures.shaderFor(batch.textureHash)
        ..colorFilter = matrix == null ? null : ui.ColorFilter.matrix(matrix),
    );
    // The gate: `partcolor.frag` over a 1×1 white texel at rate 0 is opaque
    // white where the mask passes and transparent where it does not (the same
    // no-op configuration `_drawMaskedShape` uses), so `dstIn` keeps exactly the
    // fragments that pass.
    final shader = _partColorShaders.next(program);
    _setPartColorUniforms(shader, PartColor.identity, _unitQuad,
        texWidth: 1.0,
        texHeight: 1.0,
        maskBits: mask.bits,
        maskUvBasis: mask.uvBasis,
        maskUvOffset: mask.uvOffset);
    shader.setImageSampler(0, _ensureWhitePixel());
    shader.setImageSampler(1, mask.coverage!);
    canvas.drawRect(
        bounds,
        ui.Paint()
          ..blendMode = ui.BlendMode.dstIn
          ..isAntiAlias = false
          ..shader = shader);
    canvas.restore();
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
        final group = <efbs.EffectDrawCommand>[first];
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
          ui.Paint()
            // An emitter's blend is the raw 0=Mix / 1=Add byte, NOT a BlendType.
            ..blendMode = effectBlendModeFor(blend)
            ..shader = host.textures.shaderFor(cellmap),
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
    ui.BlendMode blend,
    MaskDraw? mask,
  ) {
    final program = _partColorProgram.get();
    final image = host.textures.imageFor(batch.textureHash);
    final quad = host.geometry.buildPartColorQuad(part, frame);
    if (program == null || image == null || quad == null) {
      // Fallback: plain textured draw so the part stays visible.
      final v = host.geometry.buildNormalParts(<int>[part], frame);
      if (v != null) {
        canvas.drawVertices(v, ui.BlendMode.modulate, _paintForBatch(batch, host));
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
        1, mask == null ? _ensureDummyCoverage() : mask.coverage!);

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

  /// Configures the shared [_batchPaint] for a batch — framebuffer blend
  /// (`render/blend.dart`) plus the resolved texture's identity [ui.ImageShader]
  /// (design §7B/§7C) — and returns it. The result aliases [_batchPaint]; a
  /// caller must consume it (draw) before the next [_paintForBatch] call, which
  /// every call site does within one batch's scope.
  ///
  /// [colorFilter] is the whole-part PartColor tint of a peeled Mesh part
  /// ([_drawPeeledMesh]); it is written unconditionally — like every other field
  /// here — so a tinted part can never leak its filter into the next draw.
  ui.Paint _paintForBatch(fbs.DrawBatch batch, RenderHost host,
          {ui.ColorFilter? colorFilter}) =>
      _batchPaint
        ..blendMode = blendModeFor(batch.blendType)
        ..shader = host.textures.shaderFor(batch.textureHash)
        ..colorFilter = colorFilter;
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
