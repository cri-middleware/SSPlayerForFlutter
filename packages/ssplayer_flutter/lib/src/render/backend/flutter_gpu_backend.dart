import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/framedata.dart' as fbs;

import '../geometry_builder.dart';
import '../mask.dart';
import '../mask_context.dart';
import '../part_color.dart';
import '../part_shader.dart';
import 'render_backend.dart';
import 'render_host.dart';

RenderBackend createFlutterGpuBackend() => FlutterGpuBackend();

/// The flutter_gpu (Impeller) render backend.
///
/// It renders each frame into an offscreen render-target [gpu.Texture] — sized
/// at display resolution ([_resolutionScale]) so HiDPI edges stay crisp — and
/// composites it back onto the Flutter canvas via `drawImageRect` into the
/// logical `dst` in [finish] (flutter_gpu has no on-screen target).
/// **Implemented: Normal, Mesh, Shape, Effect** (Effect with
/// its Add/Mix blend), all reusing one textured pipeline — Shape samples a 1×1
/// white texel so its per-vertex colour (incl. PartColor) passes through.
///
/// Per-batch blend is **exact for every SS mode** (see [blendEquationFor]):
/// SpriteStudio realises each one as a fixed-function GPU blend state, which is
/// precisely what a `RenderPass` takes — so where the Canvas path has to rebuild
/// Sub / Invert out of three stock passes, this backend just sets the state.
///
/// Peeled parts (§9 mask replay / §10 PartColor tint) draw on the dedicated
/// PartColor pipeline, which carries every per-part value as a **per-vertex
/// attribute** — the Godot/Web sibling design (§19). A per-vertex attribute
/// avoids the dynamically-indexed uniform array Impeller/Metal miscompiles, so
/// no UBO is bound. Instance group tint uses the ColorMatrix pipeline (`TintInfo`
/// *struct* UBO, which is fine — only uniform *arrays* are the problem).
///
/// Every GPU entry is guarded: any failure (pipeline not loaded, context error)
/// leaves the frame blank rather than throwing, so a bad GPU state never crashes
/// the app — it degrades to nothing drawn, and the Canvas backend is the escape
/// hatch selected by the capability probe.
class FlutterGpuBackend implements RenderBackend {
  /// The asset key the shader bundle is bundled under. `hook/build.dart`
  /// (`buildShaderBundleJson`, legacy mode) writes it to
  /// `build/shaderbundles/ssplayer.shaderbundle`, which pubspec.yaml lists under
  /// `flutter: assets:`, giving this `packages/<pkg>/<path>` key.
  static const String _kShaderBundle =
      'packages/ssplayer_flutter/build/shaderbundles/ssplayer.shaderbundle';

  /// Sign of the NDC Y axis relative to player-local Y-Down. Isolated so the
  /// macOS gate can flip it in one place if the composited image is upside-down
  /// (Impeller render-target NDC orientation is the one thing that must be
  /// confirmed on-device). `-1` assumes a Metal-style +Y-up NDC.
  static const double _kNdcYSign = -1.0;

  // --- Framebuffer blend equations (§7B) -----------------------------------
  //
  // SpriteStudio realises EVERY blend as a fixed-function GPU blend state, so
  // this backend can reproduce the reference **exactly** rather than
  // approximating with a stock enum the way the Canvas path must. The ground
  // truth is ssplayer-webgl's `applyBlend` (itself verified against
  // SS6PlayerForUnity), which for every mode issues
  //
  //   blendFuncSeparate(sRGB, dRGB, ONE, ONE_MINUS_SRC_ALPHA)
  //   blendEquationSeparate(rgbEq, FUNC_ADD)
  //
  // i.e. **only the RGB channels vary**; the alpha channel is premultiplied
  // source-over (`αr = αs + αb·(1-αs)`) for all of them. Honouring that is not
  // cosmetic: a reverse-subtract or a `×dstAlpha` on the *alpha* channel makes a
  // Sub / Mul part **erase** the pixels underneath instead of darkening them,
  // punching a transparent hole through the offscreen this backend composites
  // from. Every equation below therefore shares [_kSrcAlpha] / [_kDstAlpha].
  static const gpu.BlendFactor _kSrcAlpha = gpu.BlendFactor.one;
  static const gpu.BlendFactor _kDstAlpha = gpu.BlendFactor.oneMinusSourceAlpha;

  /// One SS row: `out.rgb = Cs·[src] ⊕ Cb·[dst]`, alpha always source-over.
  static gpu.ColorBlendEquation _ssBlend(
    gpu.BlendFactor src,
    gpu.BlendFactor dst, {
    gpu.BlendOperation op = gpu.BlendOperation.add,
  }) =>
      gpu.ColorBlendEquation(
        colorBlendOperation: op,
        sourceColorBlendFactor: src,
        destinationColorBlendFactor: dst,
        alphaBlendOperation: gpu.BlendOperation.add,
        sourceAlphaBlendFactor: _kSrcAlpha,
        destinationAlphaBlendFactor: _kDstAlpha,
      );

  /// Premultiplied source-over (SS Mix; Div2 / Overlay2 clamp to it upstream):
  /// `Cs + Cb·(1-αs)`. Exactly the [gpu.ColorBlendEquation] default.
  static final gpu.ColorBlendEquation _srcOver = gpu.ColorBlendEquation();

  /// SS Add: `Cs + Cb`.
  static final gpu.ColorBlendEquation _add =
      _ssBlend(gpu.BlendFactor.one, gpu.BlendFactor.one);

  /// SS Sub: `Cb - Cs` (reverse-subtract). One state here; the Canvas path needs
  /// a three-pass reconstruction to reach the same pixels (`blendPassesFor`), so
  /// the two agree over an opaque destination and diverge in alpha over
  /// transparency, where that reconstruction can only force alpha to 1.
  static final gpu.ColorBlendEquation _sub = _ssBlend(
      gpu.BlendFactor.one, gpu.BlendFactor.one,
      op: gpu.BlendOperation.reverseSubtract);

  /// SS Screen: `Cs·(1-Cb) + Cb` — algebraically `Cs + Cb - Cs·Cb`, which is
  /// exactly Skia's premultiplied `screen`, so it matches Canvas bit-for-bit
  /// (measured in `test/blend_pixel_test.dart`).
  static final gpu.ColorBlendEquation _screen = _ssBlend(
      gpu.BlendFactor.oneMinusDestinationColor, gpu.BlendFactor.one);

  /// SS Mul / Mulalpha / Mul2: `Cs·Cb + Cb·(1-αs)`.
  ///
  /// Skia's premultiplied `multiply` adds one more term (`Cs·(1-αb)`), so the two
  /// backends agree wherever the destination is **opaque** — the case SS itself
  /// assumes — and diverge over transparency, where this (reference) form drops
  /// the part and Canvas keeps it. Not fixable in fixed function; documented.
  static final gpu.ColorBlendEquation _multiply = _ssBlend(
      gpu.BlendFactor.destinationColor, gpu.BlendFactor.oneMinusSourceAlpha);

  /// SS Exclusion: `Cs·(1-Cb) + Cb·(1-Cs)` — algebraically `Cs + Cb - 2·Cs·Cb`,
  /// i.e. Skia's `exclusion`, so this too matches Canvas exactly.
  static final gpu.ColorBlendEquation _exclusion = _ssBlend(
      gpu.BlendFactor.oneMinusDestinationColor,
      gpu.BlendFactor.oneMinusSourceColor);

  /// SS Invert: `Cs·(1-Cb)` with the destination **replaced** (dst factor zero) —
  /// so the part blacks out its own quad wherever its cell is transparent, which
  /// is the mode's real behaviour, not a bug. Skia has no dst-replace, hence the
  /// Canvas path's three-pass reconstruction; same caveat as [_sub].
  static final gpu.ColorBlendEquation _invert = _ssBlend(
      gpu.BlendFactor.oneMinusDestinationColor, gpu.BlendFactor.zero);

  /// Straight additive on **all four** channels — `src + dst`, alpha included.
  ///
  /// Deliberately not [_add]: two callers want alpha to *accumulate* rather than
  /// composite. An **effect** emitter's additive blend, which the reference
  /// writes as `blendFuncSeparate(ONE, ONE, ONE, ONE)` (effect blend is a raw
  /// byte, a different enum space from [fbs.BlendType] — see `blend.dart`), and
  /// the mask coverage pass, where the disjoint per-writer bits OR losslessly.
  static final gpu.ColorBlendEquation _additive = gpu.ColorBlendEquation(
    colorBlendOperation: gpu.BlendOperation.add,
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    alphaBlendOperation: gpu.BlendOperation.add,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  /// The framebuffer blend equation for a batch's [fbs.BlendType].
  ///
  /// Every mode SpriteStudio defines is expressible here, so — unlike the Canvas
  /// mapping — there is **no approximation and no fallback**: Mix → source-over,
  /// Add → additive, Sub → reverse-subtract, Screen / Exclusion / Invert /
  /// Mul → their `Dst*Color` factor rows, Div2 / Overlay2 → Mix (which is what
  /// the reference does too — they have no GL mapping upstream either).
  ///
  /// The one residual caveat is **Mul over a transparent destination** (see
  /// [_multiply]) and, structurally, that this backend blends inside its own
  /// offscreen, so the modes that read the destination see the animation's own
  /// pixels rather than whatever the app painted behind the widget.
  @visibleForTesting
  static gpu.ColorBlendEquation blendEquationFor(fbs.BlendType type) {
    switch (type) {
      case fbs.BlendType.Add:
        return _add;
      case fbs.BlendType.Sub:
        return _sub;
      case fbs.BlendType.Screen:
      case fbs.BlendType.Screen2:
        return _screen;
      case fbs.BlendType.Mul:
      case fbs.BlendType.Mulalpha:
      case fbs.BlendType.Mul2:
        return _multiply;
      case fbs.BlendType.Exclusion:
        return _exclusion;
      case fbs.BlendType.Invert:
        return _invert;
      case fbs.BlendType.Mix:
      case fbs.BlendType.Div2: // no GL mapping upstream → Mix
      case fbs.BlendType.Overlay2: // no GL mapping upstream → Mix
        return _srcOver;
    }
  }

  /// The two pipelines, built once and shared across all players/backends. The
  /// sprite pipeline draws plain Normal/Mesh/Shape/Effect; the PartColor pipeline
  /// draws peeled PartColor/mask parts (§9/§10). Each latches a load failure so a
  /// missing bundle is not retried every frame.
  static gpu.RenderPipeline? _spritePipeline;
  static bool _spritePipelineFailed = false;
  static gpu.RenderPipeline? _partColorPipeline;
  static bool _partColorPipelineFailed = false;

  static gpu.RenderPipeline? _buildPipeline(String vert, String frag) {
    try {
      final lib = gpu.ShaderLibrary.fromAsset(_kShaderBundle);
      final v = lib?[vert];
      final f = lib?[frag];
      if (v == null || f == null) return null;
      return gpu.gpuContext.createRenderPipeline(v, f);
    } catch (_) {
      return null;
    }
  }

  static gpu.RenderPipeline? _ensureSpritePipeline() {
    if (_spritePipeline != null) return _spritePipeline;
    if (_spritePipelineFailed) return null;
    final p = _buildPipeline('SpriteVertex', 'SpriteFragment');
    if (p == null) {
      _spritePipelineFailed = true;
      return null;
    }
    return _spritePipeline = p;
  }

  static gpu.RenderPipeline? _ensurePartColorPipeline() {
    if (_partColorPipeline != null) return _partColorPipeline;
    if (_partColorPipelineFailed) return null;
    final p = _buildPipeline('PartColorVertex', 'PartColorFragment');
    if (p == null) {
      _partColorPipelineFailed = true;
      return null;
    }
    return _partColorPipeline = p;
  }

  static gpu.RenderPipeline? _maskWritePipeline;
  static bool _maskWritePipelineFailed = false;
  static gpu.RenderPipeline? _ensureMaskWritePipeline() {
    if (_maskWritePipeline != null) return _maskWritePipeline;
    if (_maskWritePipelineFailed) return null;
    final p = _buildPipeline('MaskWriteVertex', 'MaskWriteFragment');
    if (p == null) {
      _maskWritePipelineFailed = true;
      return null;
    }
    return _maskWritePipeline = p;
  }

  static gpu.RenderPipeline? _colorMatrixPipeline;
  static bool _colorMatrixPipelineFailed = false;
  static gpu.RenderPipeline? _ensureColorMatrixPipeline() {
    if (_colorMatrixPipeline != null) return _colorMatrixPipeline;
    if (_colorMatrixPipelineFailed) return null;
    final p = _buildPipeline('ColorMatrixVertex', 'ColorMatrixFragment');
    if (p == null) {
      _colorMatrixPipelineFailed = true;
      return null;
    }
    return _colorMatrixPipeline = p;
  }

  /// The built-in integration shaders (`SHDR`) — ONE pipeline for all 13,
  /// branching on the effect id in its uniform block.
  ///
  /// The Canvas backend takes the opposite trade (13 programs) because a
  /// runtime effect it cannot compile fails silently; here a bad shader breaks
  /// the bundle build loudly, and a shader part is drawn on its own quad
  /// regardless (its parameters are per-part uniforms), so 13 pipelines would
  /// buy nothing but bundle entries.
  static gpu.RenderPipeline? _ssShaderPipeline;
  static bool _ssShaderPipelineFailed = false;
  static gpu.RenderPipeline? _ensureSsShaderPipeline() {
    if (_ssShaderPipeline != null) return _ssShaderPipeline;
    if (_ssShaderPipelineFailed) return null;
    final p = _buildPipeline('SsShaderVertex', 'SsShaderFragment');
    if (p == null) {
      _ssShaderPipelineFailed = true;
      return null;
    }
    return _ssShaderPipeline = p;
  }

  static gpu.RenderPipeline? _shapeMaskPipeline;
  static bool _shapeMaskPipelineFailed = false;
  static gpu.RenderPipeline? _ensureShapeMaskPipeline() {
    if (_shapeMaskPipeline != null) return _shapeMaskPipeline;
    if (_shapeMaskPipelineFailed) return null;
    final p = _buildPipeline('ShapeMaskVertex', 'ShapeMaskFragment');
    if (p == null) {
      _shapeMaskPipelineFailed = true;
      return null;
    }
    return _shapeMaskPipeline = p;
  }

  /// Longest edge, in pixels, of the mask coverage texture (§3-2) — a quality
  /// knob; the Canvas backend and the flagship cap at the same 1024.
  static const double _kMaxCoverageDim = 1024.0;

  /// This frame's mask coverage textures (§9) — one per player that masks —
  /// rendered by [renderCoverage]. Each is handed to its [MaskContext] as an
  /// opaque `coverageHandle`, so an inherited mask (§3-2-2) samples the parent's
  /// coverage and an own mask the child's, with no shared mutable state. This list
  /// only keeps them alive until [finish] submits the frame.
  final List<gpu.Texture> _frameCoverages = <gpu.Texture>[];

  /// hash → uploaded sampled texture. A hash absent here that is in [_uploading]
  /// is mid-flight (async `toByteData`); a part using it is skipped until ready.
  final Map<int, gpu.Texture> _gpuTextures = <int, gpu.Texture>{};
  final Set<int> _uploading = <int>{};

  /// A shared opaque-white texel for the **fallback** Shape path (sprite + white,
  /// `texel * colour` collapsing to the per-vertex colour) used only when the
  /// ShapeMask pipeline — the primary, texture-free Shape path (see
  /// [_drawShapeBatch]) — is unavailable. Created via the deferred [_uploadWhite]
  /// (ready one frame later); see it for why a same-frame create can't be sampled.
  gpu.Texture? _whiteTexture;
  bool _whiteUploading = false;

  /// A shared 1×1 transparent texture bound to the PartColor shader's coverage
  /// sampler when a part is not masked (a sampler must always be bound).
  gpu.Texture? _dummyCoverage;

  /// Reused uniform bump allocator (aligned per platform). Reset each frame.
  gpu.HostBuffer? _hostBuffer;

  // Per-frame state (valid between beginFrame and finish; _active gates use).
  bool _active = false;
  ui.Canvas? _canvas;
  // The logical-pixel rect the device-resolution offscreen composites into.
  ui.Rect? _compositeRect;
  gpu.Texture? _target;
  gpu.CommandBuffer? _cmd;
  gpu.RenderPass? _pass;

  /// Device pixels per logical pixel for the offscreen target, so it is
  /// rasterised at display resolution instead of being a logical-pixel bitmap
  /// the engine upscales (and aliases) by the device-pixel ratio after paint.
  /// Read from the implicit view; 1.0 when there is none (a headless test).
  /// Clamped so a pathological ratio can't blow up the target allocation.
  static double _resolutionScale() {
    final view = ui.PlatformDispatcher.instance.implicitView;
    final dpr = view?.devicePixelRatio ?? 1.0;
    if (!dpr.isFinite || dpr <= 0) return 1.0;
    return dpr.clamp(1.0, 4.0);
  }

  /// The current player-local→NDC matrix's emplaced view — the top of the
  /// transform stack — re-bound to whichever pipeline's `FrameInfo` slot each draw
  /// uses. Instance recursion pushes composed matrices onto the stacks (§8).
  gpu.BufferView? _mvpView;
  final List<Float32List> _matStack = <Float32List>[];
  final List<gpu.BufferView> _viewStack = <gpu.BufferView>[];

  @override
  void beginFrame(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _active = false;
    _frameCoverages.clear();
    _tintStack.clear();
    _canvas = canvas;
    final logical = dst?.size ?? sourceSize ?? ui.Size.zero;
    if (logical.width <= 0 || logical.height <= 0) return;
    _compositeRect = dst ?? (ui.Offset.zero & logical);
    // Allocate the offscreen at display resolution; the projection below stays in
    // logical space (NDC covers the whole texture regardless of its pixel count),
    // and [finish] scales the device-resolution image back into the logical rect.
    final scale = _resolutionScale();
    final w = (logical.width * scale).round();
    final h = (logical.height * scale).round();
    if (w <= 0 || h <= 0) return;

    // The sprite pipeline is the base path; if it fails to load there is no GPU
    // rendering (the PartColor pipeline is checked lazily where it is used).
    if (_ensureSpritePipeline() == null) return;

    try {
      // Fresh render target every frame: the composited ui.Image aliases it until
      // the layer rasterises after paint returns, so it must not be reused before
      // then (pooling with double-buffering is a later optimisation).
      _target = gpu.gpuContext
          .createTexture(gpu.StorageMode.devicePrivate, w, h);
      _cmd = gpu.gpuContext.createCommandBuffer();
      // Transparent clear (ColorAttachment defaults: LoadAction.clear, zero).
      _pass = _cmd!.createRenderPass(
        gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: _target!)),
      );
      _pass!.setColorBlendEnable(true);

      _hostBuffer ??= gpu.gpuContext.createHostBuffer();
      _hostBuffer!.reset();
      // Player-local (Y-Down, origin centre) → NDC — the base of the transform
      // stack. Built from the LOGICAL box (not the device pixel count): NDC maps
      // to the full render target either way. Each draw re-binds the top to its
      // pipeline's FrameInfo slot.
      final mvp = _orthoMvp(logical.width, logical.height);
      final baseView = _hostBuffer!.emplace(ByteData.sublistView(mvp));
      _matStack
        ..clear()
        ..add(mvp);
      _viewStack
        ..clear()
        ..add(baseView);
      _mvpView = baseView;
      _active = true;
    } catch (_) {
      _active = false;
    }
  }

  @override
  void finish() {
    if (_active) {
      try {
        _cmd!.submit();
        final img = _target!.asImage();
        // Scale the device-resolution offscreen back into the logical dst; the
        // engine's later DPR upscale then lands it ~1:1 on the framebuffer, so
        // edges stay crisp instead of being nearest-upscaled by that transform.
        final dst = _compositeRect ??
            (ui.Offset.zero &
                ui.Size(img.width.toDouble(), img.height.toDouble()));
        _canvas!.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          dst,
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
      } catch (_) {
        // Swallow — a blank frame beats a crash.
      }
    }
    _active = false;
    _canvas = null;
    _compositeRect = null;
    _target = null;
    _cmd = null;
    _pass = null;
    _frameCoverages.clear(); // submitted; the composited image holds the main target
  }

  @override
  void emitNormal(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask) {
    if (!_active) return;
    final count = batch.count;
    if (count == 0) return;

    // One texture per batch; its size normalises the UVs.
    final image = host.textures.imageFor(batch.textureHash);
    if (image == null) return;
    final tex = _gpuTextureFor(batch.textureHash, image);
    if (tex == null) return; // still uploading — skip this frame

    final texW = image.width.toDouble();
    final texH = image.height.toDouble();
    final blend = blendEquationFor(batch.blendType);
    final drawOrder = frame.drawOrder;
    final partsColor = frame.partsColor;
    final shaders = frame.shaders;

    // Same run/peel structure as the Canvas path, but the peeled parts also
    // BATCH: a run of consecutive PartColor/mask parts draws in ONE PartColor
    // pipeline call (the fan-out collapse), preserving z-order against the plain
    // sprite runs (whichever kind switches flushes the other first).
    final run = <int>[];
    final pcParts = <int>[];
    final pcColors = <PartColor>[];
    final pcMasks = <MaskDraw?>[];
    // The coverage the current PartColor run samples. A masked part joins the run
    // only if it shares this handle — an own mask (this player's coverage) and an
    // inherited mask (§3-2-2, the parent's coverage) therefore split into separate
    // draws, each binding the right texture. Unmasked parts join any run.
    gpu.Texture? pcCoverage;

    void flushRun() {
      if (run.isEmpty) return;
      final geo = host.geometry
          .buildNormalInterleaved(run, frame, texWidth: texW, texHeight: texH);
      if (geo != null) _drawInterleaved(geo, tex, blend);
      run.clear();
    }

    void flushPc() {
      if (pcParts.isEmpty) return;
      _drawPartColorRun(pcParts, pcColors, pcMasks, pcCoverage, frame, host, tex,
          texW, texH, blend);
      pcParts.clear();
      pcColors.clear();
      pcMasks.clear();
      pcCoverage = null;
    }

    for (var k = 0; k < count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      final flags = host.flagsFor(p);
      if (flags.pureMask) continue; // coverage-only, never colour
      final part = frame.partOf(p);
      final pc = part == null ? null : PartColor.read(partsColor, part);
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final mask = ownBits != null ? maskCtx!.drawFor(ownBits) : inheritedMask;
      // Integration shader (`SHDR`): its parameters are per-part uniforms,
      // so it cannot join either run — flush both to keep z-order and draw it on
      // its own. NOT combined with a mask test (v1, both siblings agree): a
      // masked shader part keeps the plain masked path and drops its effect.
      final sh =
          (part == null || mask != null) ? null : PartShader.read(shaders, part);
      if (sh != null) {
        flushRun();
        flushPc();
        _drawSsShaderPart(
            p,
            sh,
            pc == null
                ? PartColor.passthrough(frame.alphaOf(p))
                : pc.scaleAlpha(frame.alphaScale),
            frame,
            host,
            tex,
            texW,
            texH,
            blend);
        continue;
      }
      if (pc == null && mask == null) {
        flushPc();
        run.add(p);
      } else {
        flushRun();
        final h = mask?.coverageHandle;
        final ht = h is gpu.Texture ? h : null;
        if ((ht != null && pcCoverage != null && !identical(ht, pcCoverage)) ||
            pcParts.length >= _kMaxPartColorRun) {
          flushPc();
        }
        if (ht != null) pcCoverage = ht;
        pcParts.add(p);
        pcColors.add(pc == null
            ? PartColor.passthrough(frame.alphaOf(p))
            : pc.scaleAlpha(frame.alphaScale));
        pcMasks.add(mask);
      }
    }
    flushRun();
    flushPc();
  }

  /// Max peeled parts per PartColor batch. Peeled parts carry their data
  /// per-vertex (no uniform array), so the only bound on a run is the 16-bit
  /// index buffer: at 4 vertices per part a run stays well under the 0xFFFF
  /// vertex limit. A longer run splits into multiple draws.
  static const int _kMaxPartColorRun = 4096;

  /// Draws a RUN of peeled parts (PartColor §10 and/or mask §9) in ONE PartColor
  /// pipeline call — the fan-out collapse. Each part's quad becomes 4 self-
  /// describing vertices (corner colour / rate / coef / mask replay all as
  /// per-vertex attributes; no UBO), so the whole run packs into one vertex
  /// buffer. A part with a degenerate quad is dropped. Falls back to plain sprite
  /// draws when the pipeline is unavailable, so parts stay visible.
  void _drawPartColorRun(
      List<int> parts,
      List<PartColor> pcs,
      List<MaskDraw?> masks,
      gpu.Texture? coverage,
      DrawFrame frame,
      RenderHost host,
      gpu.Texture tex,
      double texW,
      double texH,
      gpu.ColorBlendEquation blend) {
    final pass = _pass!;
    final pipeline = _ensurePartColorPipeline();
    final dummyCov = _ensureDummyCoverage();
    if (pipeline == null || dummyCov == null) {
      final geo = host.geometry
          .buildNormalInterleaved(parts, frame, texWidth: texW, texHeight: texH);
      if (geo != null) _drawInterleaved(geo, tex, blend);
      return;
    }

    final maskSets = <Float32List?>[
      for (final m in masks) _maskSet(m, coverage),
    ];
    final geo = host.geometry.buildPartColorInterleaved(
        parts, pcs, maskSets, frame,
        texWidth: texW, texHeight: texH);
    if (geo == null) return;

    try {
      final cov = coverage ?? dummyCov;
      pass.bindPipeline(pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.setColorBlendEquation(blend);

      final vb = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
          geo.vertexCount);
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16,
          geo.indexCount);
      pass.bindTexture(
        pipeline.fragmentShader.getUniformSlot('u_texture'),
        tex,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
        ),
      );
      // Coverage MUST stay nearest — its texels are bit fields.
      pass.bindTexture(
          pipeline.fragmentShader.getUniformSlot('u_coverage'), cov);
      pass.draw();
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  /// Draws ONE Normal part carrying an integration shader (`SHDR`) through
  /// the shared `SsShaderVertex/Fragment` pipeline.
  ///
  /// Per-part rather than batched: the effect id, its `param0..3` and the cell
  /// UV rect are a uniform block, so two parts can only share a draw if all
  /// three agree — not worth detecting for a part kind this rare.
  ///
  /// [pc] is the *effective* PartColor the caller resolved (the part's own
  /// scaled by the instance chain, or [PartColor.passthrough] when it has none):
  /// every effect but `ss-blur` folds it as its output tail, and even `ss-blur`
  /// multiplies by it, so it is never optional. Falls back to the ordinary
  /// PartColor path — effect dropped, colours intact — when the pipeline is
  /// unavailable, mirroring what the Canvas backend does.
  void _drawSsShaderPart(
      int part,
      PartShader sh,
      PartColor pc,
      DrawFrame frame,
      RenderHost host,
      gpu.Texture tex,
      double texW,
      double texH,
      gpu.ColorBlendEquation blend) {
    final pipeline = _ensureSsShaderPipeline();
    final quad =
        pipeline == null ? null : host.geometry.buildPartColorQuad(part, frame);
    if (pipeline == null || quad == null) {
      _drawPartColorRun(<int>[part], <PartColor>[pc], const <MaskDraw?>[null],
          null, frame, host, tex, texW, texH, blend);
      return;
    }

    final geo = host.geometry
        .buildSsShaderInterleaved(quad, pc, texWidth: texW, texHeight: texH);
    if (geo == null) return;

    // `ShaderInfo` — three vec4s, so every field lands on a 16-byte boundary
    // (the alignment Impeller needs). `TEXTURE_PIXEL_SIZE` is 1/atlas size, NOT
    // 1/offscreen size: the effects step in texture space, and the offscreen is
    // DPR-scaled underneath them.
    final cell = quad.cellRect(texW, texH);
    final info = Float32List(12)
      ..[0] = sh.params[0] // params
      ..[1] = sh.params[1]
      ..[2] = sh.params[2]
      ..[3] = sh.params[3]
      ..[4] = cell[0] // cell_rect
      ..[5] = cell[1]
      ..[6] = cell[2]
      ..[7] = cell[3]
      // misc: (effect id, 1/texW, 1/texH, -). The id is SsShaderId's index —
      // shaders/gpu/ssshader.frag's SS_* constants mirror that order.
      ..[8] = sh.id.index.toDouble()
      ..[9] = texW > 0 ? 1.0 / texW : 0.0
      ..[10] = texH > 0 ? 1.0 / texH : 0.0;

    try {
      final pass = _pass!;
      pass.bindPipeline(pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.bindUniform(pipeline.fragmentShader.getUniformSlot('ShaderInfo'),
          _hostBuffer!.emplace(ByteData.sublistView(info)));
      pass.setColorBlendEquation(blend);

      final vb = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
          geo.vertexCount);
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16,
          geo.indexCount);
      pass.bindTexture(
        pipeline.fragmentShader.getUniformSlot('u_texture'),
        tex,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
        ),
      );
      pass.draw();
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  static final Uint16List _quadIndices =
      Uint16List.fromList(const <int>[0, 1, 2, 1, 3, 2]);

  /// Flattens a peeled part's mask replay into the 10 floats the PartColor vertex
  /// carries — `(increment, invert, visibleInside, enabled, m00, m01, m10, m11,
  /// ox, oy)`, matching `GeometryBuilder._writePcVertex` — or null when the part
  /// is unmasked this frame (no [mask], or no [coverage] texture bound for the
  /// run), so the bake writes `enabled = 0` and the shader passes it through.
  static Float32List? _maskSet(MaskDraw? mask, gpu.Texture? coverage) {
    if (mask == null || coverage == null) return null;
    return Float32List.fromList(<double>[
      mask.bits.increment.toDouble(),
      mask.bits.invert.toDouble(),
      mask.bits.visibleInside ? 1.0 : 0.0,
      1.0, // enabled
      mask.uvBasis[0],
      mask.uvBasis[1],
      mask.uvBasis[2],
      mask.uvBasis[3],
      mask.uvOffset[0],
      mask.uvOffset[1],
    ]);
  }

  void _drawInterleaved(
      InterleavedGeometry geo, gpu.Texture tex, gpu.ColorBlendEquation blend) {
    final pass = _pass!;
    final pipeline = _spritePipeline!;
    try {
      // Pipeline + FrameInfo + blend are set per draw (two pipelines share the
      // pass, and blend state persists — an additive effect draw must not leak
      // into the next batch).
      pass.bindPipeline(pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.setColorBlendEquation(blend);
      final vb = gpu.gpuContext.createDeviceBufferWithCopy(
          ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext.createDeviceBufferWithCopy(
          ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
          geo.vertexCount);
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16,
          geo.indexCount);
      pass.bindTexture(
        pipeline.fragmentShader.getUniformSlot('u_texture'),
        tex,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
        ),
      );
      pass.draw();
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  /// Returns the uploaded GPU texture for [hash], or null while it uploads.
  ///
  /// Upload is async (`Image.toByteData`), so the first frame(s) after a texture
  /// is first needed skip the parts using it; a playing animation re-paints and
  /// picks it up once ready.
  gpu.Texture? _gpuTextureFor(int hash, ui.Image image) {
    final ready = _gpuTextures[hash];
    if (ready != null) return ready;
    if (!_uploading.contains(hash)) {
      _uploading.add(hash);
      _upload(hash, image);
    }
    return null;
  }

  Future<void> _upload(int hash, ui.Image image) async {
    try {
      // rawRgba is premultiplied — matches the sprite.frag / bake convention.
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return;
      // Default coordinate system (renderToTexture, top-left) matches toByteData's
      // top-to-bottom rows and the Brain's top-left UVs, so no vertical flip.
      final tex = gpu.gpuContext.createTexture(
          gpu.StorageMode.hostVisible, image.width, image.height);
      tex.overwrite(bytes); // throws on failure (caught below)
      _gpuTextures[hash] = tex;
    } catch (_) {
      // Leave it absent; the part keeps skipping (or the Canvas backend is used).
    } finally {
      _uploading.remove(hash);
    }
  }

  /// The shared white texel, or null until [_uploadWhite] finishes (one frame
  /// after first use — the Shape run is skipped until then, imperceptible on a
  /// playing animation).
  gpu.Texture? _ensureWhiteTexture() {
    if (_whiteTexture != null) return _whiteTexture;
    if (!_whiteUploading) {
      _whiteUploading = true;
      _uploadWhite();
    }
    return null;
  }

  /// Uploads the white texel through the *exact* atlas path — a decoded
  /// [ui.Image] → `toByteData(rawRgba)` → `createTexture(w, h)` → `overwrite` —
  /// not a hand-built byte list.
  ///
  /// A `hostVisible` texture `overwrite`n from a literal `ByteData` sampled as
  /// zero on Metal, so the Shape path (which multiplies this texel by the baked
  /// vertex colour) drew nothing; the atlas, which samples fine, differs only in
  /// coming from a decoded image, so the Shape texel does too. The decode also
  /// defers the write past the frame's command buffer (the atlas relies on the
  /// same), and 8×8 sidesteps any 1×1 upload edge case.
  Future<void> _uploadWhite() async {
    try {
      const w = 8, h = 8;
      final img = await _decodeSolidRgba(w, h, 0xFF, 0xFF, 0xFF, 0xFF);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      final tex =
          gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, w, h);
      tex.overwrite(bytes!);
      _whiteTexture = tex;
    } catch (_) {
      _whiteUploading = false; // retry on the next frame
    }
  }

  /// Decodes a solid `w×h` RGBA image through the engine image pipeline — the
  /// same source of truth the atlas uploads from.
  Future<ui.Image> _decodeSolidRgba(int w, int h, int r, int g, int b, int a) {
    final px = Uint8List(w * h * 4);
    for (var i = 0; i < px.length; i += 4) {
      px[i] = r;
      px[i + 1] = g;
      px[i + 2] = b;
      px[i + 3] = a;
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  gpu.Texture? _ensureDummyCoverage() {
    final existing = _dummyCoverage;
    if (existing != null) return existing;
    try {
      final tex =
          gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, 1, 1);
      tex.overwrite(
          ByteData.sublistView(Uint8List.fromList(const [0, 0, 0, 0])));
      return _dummyCoverage = tex;
    } catch (_) {
      return null;
    }
  }

  /// Column-major orthographic projection: player-local (origin centre, Y-Down)
  /// → clip space. Diagonal, so major-ness is irrelevant. The Y term carries the
  /// single [_kNdcYSign] flip (the Brain already flipped once; do not add a
  /// second — this only maps Y-Down into NDC).
  static Float32List _orthoMvp(double w, double h) {
    final m = Float32List(16);
    m[0] = 2.0 / w; // x: [-w/2, w/2] → [-1, 1]
    m[5] = _kNdcYSign * 2.0 / h; // y
    m[10] = 1.0; // z passthrough
    m[15] = 1.0;
    return m;
  }

  @override
  void emitMesh(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask) {
    if (!_active) return;
    final count = batch.count;
    if (count == 0) return;
    final image = host.textures.imageFor(batch.textureHash);
    if (image == null) return;
    final tex = _gpuTextureFor(batch.textureHash, image);
    if (tex == null) return; // still uploading

    final texW = image.width.toDouble();
    final texH = image.height.toDouble();
    final blend = blendEquationFor(batch.blendType);
    final drawOrder = frame.drawOrder;
    final partsColor = frame.partsColor;

    // Same run/peel split as [emitNormal] — and the peeled mesh parts likewise
    // BATCH into one PartColor-pipeline call, sharing a coverage texture.
    final parts = <int>[];
    final pcParts = <int>[];
    final pcColors = <PartColor>[];
    final pcMasks = <MaskDraw?>[];
    gpu.Texture? pcCoverage;

    void flushRun() {
      if (parts.isEmpty) return;
      final geo = host.geometry
          .buildMeshInterleaved(parts, frame, texWidth: texW, texHeight: texH);
      if (geo != null) _drawInterleaved(geo, tex, blend);
      parts.clear();
    }

    void flushPc() {
      if (pcParts.isEmpty) return;
      _drawMeshPartColorRun(pcParts, pcColors, pcMasks, pcCoverage, frame, host,
          tex, texW, texH, blend);
      pcParts.clear();
      pcColors.clear();
      pcMasks.clear();
      pcCoverage = null;
    }

    for (var k = 0; k < count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      final flags = host.flagsFor(p);
      if (flags.pureMask) continue;
      final state = frame.partOf(p);
      final pc = state == null ? null : PartColor.read(partsColor, state);
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final mask = ownBits != null ? maskCtx!.drawFor(ownBits) : inheritedMask;
      if (pc == null && mask == null) {
        flushPc();
        parts.add(p);
      } else {
        flushRun();
        final h = mask?.coverageHandle;
        final ht = h is gpu.Texture ? h : null;
        if ((ht != null && pcCoverage != null && !identical(ht, pcCoverage)) ||
            pcParts.length >= _kMaxPartColorRun) {
          flushPc();
        }
        if (ht != null) pcCoverage = ht;
        pcParts.add(p);
        pcColors.add(pc == null
            ? PartColor.passthrough(frame.alphaOf(p))
            : pc.scaleAlpha(frame.alphaScale));
        pcMasks.add(mask);
      }
    }
    flushRun();
    flushPc();
  }

  /// Draws a RUN of peeled mesh parts (PartColor §10 and/or mask §9) in ONE
  /// PartColor-pipeline call.
  ///
  /// No mesh-specific shader is needed: the bake carries the `lt` corner's colour
  /// + rate on every vertex — the §10 *whole-only* Mesh rule — and the mask
  /// replay samples the coverage through the player-local `v_local` varying,
  /// which a mesh vertex is in. So this is [_drawPartColorRun] with a different
  /// geometry source. Falls back to the plain textured draw when the pipeline is
  /// unavailable.
  void _drawMeshPartColorRun(
      List<int> parts,
      List<PartColor> pcs,
      List<MaskDraw?> masks,
      gpu.Texture? coverage,
      DrawFrame frame,
      RenderHost host,
      gpu.Texture tex,
      double texW,
      double texH,
      gpu.ColorBlendEquation blend) {
    final pass = _pass!;
    final pipeline = _ensurePartColorPipeline();
    final dummyCov = _ensureDummyCoverage();
    if (pipeline == null || dummyCov == null) {
      final plain = host.geometry
          .buildMeshInterleaved(parts, frame, texWidth: texW, texHeight: texH);
      if (plain != null) _drawInterleaved(plain, tex, blend);
      return;
    }

    final maskSets = <Float32List?>[
      for (final m in masks) _maskSet(m, coverage),
    ];
    final geo = host.geometry.buildMeshPartColorInterleaved(
        parts, pcs, maskSets, frame,
        texWidth: texW, texHeight: texH);
    if (geo == null) return;

    try {
      final cov = coverage ?? dummyCov;
      pass.bindPipeline(pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.setColorBlendEquation(blend);

      final vb = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
          geo.vertexCount);
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16,
          geo.indexCount);
      pass.bindTexture(
        pipeline.fragmentShader.getUniformSlot('u_texture'),
        tex,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
        ),
      );
      // Coverage MUST stay nearest — its texels are bit fields.
      pass.bindTexture(
          pipeline.fragmentShader.getUniformSlot('u_coverage'), cov);
      pass.draw();
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask) {
    if (!_active) return;
    if (batch.count == 0) return;
    final blend = blendEquationFor(batch.blendType);
    final drawOrder = frame.drawOrder;

    // Every Shape draws through the ShapeMask pipeline, which outputs the baked
    // per-vertex colour directly (`frag_color = v_color`, no texture — matching
    // the Godot/WebGL siblings). Unmasked shapes batch into one draw with the mask
    // disabled; a mask-target shape flushes the batch and draws alone, its colour
    // gated by the coverage, preserving z-order. PartColor is already baked into
    // the vertex colour.
    final run = <int>[];
    void flushRun() {
      if (run.isEmpty) return;
      _drawShapeBatch(run, null, frame, host, blend);
      run.clear();
    }

    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      final flags = host.flagsFor(p);
      if (flags.pureMask) continue; // coverage-only, never colour
      final ownBits = maskCtx?.bitsForTarget(rank, flags);
      final mask = ownBits != null ? maskCtx!.drawFor(ownBits) : inheritedMask;
      // Gate only when a GPU coverage texture exists (own or inherited); else draw
      // unmasked (mask disabled).
      if (mask == null || mask.coverageHandle is! gpu.Texture) {
        run.add(p);
      } else {
        flushRun();
        _drawShapeBatch(<int>[p], mask, frame, host, blend);
      }
    }
    flushRun();
  }

  /// Draws a batch of Shapes through the ShapeMask pipeline, whose fragment shader
  /// outputs the baked per-vertex colour (`frag_color = v_color`, premultiplied).
  ///
  /// When [mask] is non-null the colour is gated by the mask coverage (§9) and
  /// [parts] is a single mask-target shape; when null the mask is disabled
  /// (`mask_bits.w = 0`, the shader passes the colour straight through) and [parts]
  /// is a run of plain shapes batched into one draw. Either way there is **no
  /// texture sample for the colour** — matching the Godot/WebGL siblings — which is
  /// why this replaced the sprite + white-texel path: a `hostVisible` white texel
  /// sampled as zero on Metal, so `texel * colour` collapsed to nothing and plain
  /// Shapes were invisible. Falls back to sprite + white only if the mask pipeline
  /// is unavailable.
  void _drawShapeBatch(List<int> parts, MaskDraw? mask, DrawFrame frame,
      RenderHost host, gpu.ColorBlendEquation blend) {
    final pass = _pass!;
    final pipeline = _ensureShapeMaskPipeline();
    // A sampler must always be bound; when unmasked the shader never reads it.
    final coverage = mask?.coverageHandle is gpu.Texture
        ? mask!.coverageHandle as gpu.Texture
        : _ensureDummyCoverage();
    final geo = host.geometry.buildShapeColorInterleaved(parts, frame);
    if (geo == null) return;
    if (pipeline == null || coverage == null) {
      // Fallback: sprite + white texel (only if the mask pipeline is unavailable).
      final plain = host.geometry.buildShapeInterleaved(parts, frame);
      final white = _ensureWhiteTexture();
      if (plain != null && white != null) _drawInterleaved(plain, white, blend);
      return;
    }

    try {
      // MaskInfo UBO: mask_bits, mask_uv, mask_off (3 vec4). All-zero => disabled.
      final ubo = Float32List(12);
      if (mask != null) {
        ubo[0] = mask.bits.increment.toDouble();
        ubo[1] = mask.bits.invert.toDouble();
        ubo[2] = mask.bits.visibleInside ? 1.0 : 0.0;
        ubo[3] = 1.0; // enabled
        ubo[4] = mask.uvBasis[0];
        ubo[5] = mask.uvBasis[1];
        ubo[6] = mask.uvBasis[2];
        ubo[7] = mask.uvBasis[3];
        ubo[8] = mask.uvOffset[0];
        ubo[9] = mask.uvOffset[1];
      }

      pass.bindPipeline(pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.bindUniform(pipeline.fragmentShader.getUniformSlot('MaskInfo'),
          _hostBuffer!.emplace(ByteData.sublistView(ubo)));
      pass.setColorBlendEquation(blend);

      final vb = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
          geo.vertexCount);
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16,
          geo.indexCount);
      pass.bindTexture(
          pipeline.fragmentShader.getUniformSlot('u_coverage'), coverage);
      pass.draw();
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  @override
  void emitEffect(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host) {
    if (!_active) return;
    if (!host.hasEffects) return;
    final drawOrder = frame.drawOrder;

    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final part = drawOrder[rank];
      final plan = host.effectPlanFor(part);
      final commands = plan?.commands;
      if (plan == null || commands == null) continue;

      // Same grouping as the Canvas path: merge consecutive same-(cellmap,blend)
      // commands under the 16-bit vertex cap, one draw per group.
      var i = 0;
      while (i < commands.length) {
        final first = commands[i];
        if (first.quadCount == 0) {
          i++;
          continue;
        }
        final image = host.textures.imageFor(first.cellmapHash);
        if (image == null) {
          i++;
          continue;
        }
        final tex = _gpuTextureFor(first.cellmapHash, image);
        if (tex == null) {
          i++;
          continue; // cellmap still uploading
        }
        final cellmap = first.cellmapHash;
        final blend = first.blend;

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

        final geo = host.geometry.buildEffectGroupInterleaved(
          plan,
          group,
          part,
          frame,
          texWidth: image.width.toDouble(),
          texHeight: image.height.toDouble(),
        );
        if (geo == null) continue;
        // Effect blend byte: 1 = Add → additive, else Mix → source-over. The
        // reference writes the additive case as `(ONE, ONE, ONE, ONE)` — alpha
        // included — so it takes [_additive], not the batch-level [_add].
        _drawInterleaved(geo, tex, blend == 1 ? _additive : _srcOver);
      }
    }
  }

  @override
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
      Map<int, int> textureByRank) {
    if (!_active) return null;
    final pipeline = _ensureMaskWritePipeline();
    final dummyTex = _ensureDummyCoverage(); // "no cell" bind for shape/mesh writers
    if (pipeline == null || dummyTex == null || _hostBuffer == null) return null;

    final bounds = plan.bounds;
    if (bounds.width <= 0 || bounds.height <= 0) return null;
    final longEdge =
        bounds.width > bounds.height ? bounds.width : bounds.height;
    final scale = longEdge > _kMaxCoverageDim ? _kMaxCoverageDim / longEdge : 1.0;
    final pw = (bounds.width * scale).ceil().clamp(1, _kMaxCoverageDim.toInt());
    final ph = (bounds.height * scale).ceil().clamp(1, _kMaxCoverageDim.toInt());

    try {
      // A dedicated command buffer / render pass: the coverage texture is written
      // here and sampled by the main pass, so it is submitted before the main
      // command buffer records its sampling draws.
      final target =
          gpu.gpuContext.createTexture(gpu.StorageMode.devicePrivate, pw, ph);
      final cmd = gpu.gpuContext.createCommandBuffer();
      final pass = cmd.createRenderPass(
        gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: target)),
      );
      pass.setColorBlendEnable(true); // disjoint bits OR losslessly: `_additive`

      // Player-local -> coverage NDC, built from the SAME uvBasis/uvOffset the
      // main-pass shader samples with, so the two are guaranteed to agree.
      final covMvpView =
          _hostBuffer!.emplace(ByteData.sublistView(_coverageMvp(plan)));
      final mvpSlot = pipeline.vertexShader.getUniformSlot('MaskFrame');
      final bitSlot = pipeline.fragmentShader.getUniformSlot('MaskBit');
      final texSlot = pipeline.fragmentShader.getUniformSlot('u_texture');

      var wrote = false;
      for (final writer in plan.writers) {
        final flags = host.flagsFor(writer.partIndex);
        Float32List verts;
        Uint16List indices;
        var threshold = -1.0; // shape/mesh writers: geometry is the mask, no cutout
        gpu.Texture writerTex = dummyTex;

        if (flags.shapeGeometry) {
          final g = host.geometry.buildShapeParts(<int>[writer.partIndex], frame);
          if (g == null) continue;
          verts = _posUvFromPositions(g.positions);
          indices = g.indices;
        } else if (flags.meshGeometry) {
          final g =
              host.geometry.buildMeshGeometry(<int>[writer.partIndex], frame);
          if (g == null) continue;
          verts = _posUvFromPositions(g.positions);
          indices = g.indices;
        } else {
          final quad = host.geometry.buildPartColorQuad(writer.partIndex, frame);
          if (quad == null) continue;
          final hash = textureByRank[writer.drawRank];
          final image = hash == null ? null : host.textures.imageFor(hash);
          if (image == null) continue;
          final tex = _gpuTextureFor(hash!, image);
          if (tex == null) continue; // cell still uploading
          writerTex = tex;
          threshold = writer.threshold;
          final invW = image.width > 0 ? 1.0 / image.width : 0.0;
          final invH = image.height > 0 ? 1.0 / image.height : 0.0;
          final c = quad.corners, ua = quad.uvA, ub = quad.uvB;
          verts = Float32List.fromList(<double>[
            c[0], c[1], ua[0] * invW, ua[1] * invH,
            c[2], c[3], ua[2] * invW, ua[3] * invH,
            c[4], c[5], ub[0] * invW, ub[1] * invH,
            c[6], c[7], ub[2] * invW, ub[3] * invH,
          ]);
          indices = _quadIndices;
        }

        final vb = gpu.gpuContext
            .createDeviceBufferWithCopy(ByteData.sublistView(verts));
        final ib = gpu.gpuContext
            .createDeviceBufferWithCopy(ByteData.sublistView(indices));
        pass.bindPipeline(pipeline);
        pass.bindUniform(mvpSlot, covMvpView);
        pass.bindUniform(bitSlot,
            _hostBuffer!.emplace(ByteData.sublistView(_bitColor(writer.bit, threshold))));
        pass.setColorBlendEquation(_additive); // bit accumulator: alpha adds too
        pass.bindVertexBuffer(
            gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
            verts.length ~/ 4);
        pass.bindIndexBuffer(
            gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
            gpu.IndexType.int16,
            indices.length);
        pass.bindTexture(texSlot, writerTex); // nearest (cutout threshold on raw texel)
        pass.draw();
        wrote = true;
      }
      if (!wrote) return null;
      cmd.submit();
      // The coverage texture travels with the MaskContext (as the opaque
      // coverageHandle); _frameCoverages just keeps it alive until finish submits.
      _frameCoverages.add(target);
      return MaskContext(plan, null, coverageHandle: target);
    } catch (_) {
      return null;
    }
  }

  /// Column-major player-local→coverage-NDC matrix, derived from the plan's
  /// local→coverage-UV affine so the coverage pass writes exactly what the main
  /// pass samples. `ndc = uv*2 - 1`, with the Y axis carrying [_kNdcYSign].
  static Float32List _coverageMvp(MaskPlan plan) {
    final b = plan.uvBasis; // [m00, m01, m10, m11]
    final o = plan.uvOffset; // [x, y]
    final m = Float32List(16);
    m[0] = 2.0 * b[0];
    m[4] = 2.0 * b[1];
    m[12] = 2.0 * o[0] - 1.0;
    m[1] = _kNdcYSign * 2.0 * b[2];
    m[5] = _kNdcYSign * 2.0 * b[3];
    m[13] = _kNdcYSign * (2.0 * o[1] - 1.0);
    m[10] = 1.0;
    m[15] = 1.0;
    return m;
  }

  /// Interleaves world-space `[x,y,…]` positions into the mask-writer vertex
  /// format `[x, y, 0, 0]` (UV unused — shape/mesh writers have no texel cutout).
  static Float32List _posUvFromPositions(Float32List pos) {
    final n = pos.length ~/ 2;
    final out = Float32List(n * 4);
    for (var i = 0; i < n; i++) {
      out[i * 4] = pos[i * 2];
      out[i * 4 + 1] = pos[i * 2 + 1];
    }
    return out;
  }

  /// One writer's bit as the `MaskBit` uniform: rgb = the bit in its owning R/G/B
  /// channel (8 bits × 3 = 24 writers), a = the §2-5 cutout threshold.
  static Float32List _bitColor(int bit, double threshold) {
    final channel = bit ~/ 8;
    final v = (1 << (bit % 8)) / 255.0;
    return Float32List.fromList(<double>[
      channel == 0 ? v : 0.0,
      channel == 1 ? v : 0.0,
      channel == 2 ? v : 0.0,
      threshold,
    ]);
  }

  @override
  void pushTransform(ui.Canvas canvas, Float64List world) {
    if (!_active || _hostBuffer == null || _matStack.isEmpty) return;
    // Compose the child→parent world transform into the current projection:
    // gl_Position = (baseMvp · … · world) · localPos.
    final composed = _mul4x4(_matStack.last, world);
    final view = _hostBuffer!.emplace(ByteData.sublistView(composed));
    _matStack.add(composed);
    _viewStack.add(view);
    _mvpView = view;
  }

  @override
  void popTransform(ui.Canvas canvas) {
    if (_matStack.length > 1) {
      _matStack.removeLast();
      _viewStack.removeLast();
      _mvpView = _viewStack.last;
    }
  }

  /// The suspended pass/target/command-buffer of each enclosing [pushGroupTint],
  /// innermost last — the GPU's answer to the Canvas backend's `saveLayer`
  /// stack. A frame with no instance tint never touches this.
  final List<_GroupTintLayer> _tintStack = <_GroupTintLayer>[];

  @override
  void pushGroupTint(ui.Canvas canvas, List<double> matrix) {
    if (!_active) return;
    final target = _target;
    if (target == null) return;
    // A failed layer must still push, so the matching pop stays balanced; it
    // just carries no target and pops back to the same pass (untinted).
    _GroupTintLayer layer;
    try {
      if (_ensureColorMatrixPipeline() == null) throw StateError('no pipeline');
      // Same size as the pass being suspended, so the composite is a plain
      // full-target quad — the subtree keeps drawing with the very same
      // projection and transform stack.
      final sub = gpu.gpuContext.createTexture(
          gpu.StorageMode.devicePrivate, target.width, target.height);
      final cmd = gpu.gpuContext.createCommandBuffer();
      final pass = cmd.createRenderPass(
        gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: sub)),
      );
      pass.setColorBlendEnable(true);
      layer = _GroupTintLayer(_pass!, _target!, _cmd!, sub, cmd, matrix);
      _pass = pass;
      _target = sub;
      _cmd = cmd;
    } catch (_) {
      layer = _GroupTintLayer(_pass!, _target!, _cmd!, null, null, matrix);
    }
    _tintStack.add(layer);
  }

  @override
  void popGroupTint(ui.Canvas canvas) {
    if (_tintStack.isEmpty) return;
    final layer = _tintStack.removeLast();
    _pass = layer.pass;
    _target = layer.target;
    _cmd = layer.cmd;
    final sub = layer.subTarget;
    final subCmd = layer.subCmd;
    if (sub == null || subCmd == null) return; // the push failed — nothing to composite

    try {
      // The subtree's pass must be submitted before the pass that samples it.
      subCmd.submit();
      _frameCoverages.add(sub); // keep it alive until the frame is submitted
      final pipeline = _ensureColorMatrixPipeline()!;
      _pass!.bindPipeline(pipeline);
      _pass!.bindUniform(pipeline.fragmentShader.getUniformSlot('TintInfo'),
          _hostBuffer!.emplace(ByteData.sublistView(_tintRows(layer.matrix))));
      // The tinted subtree composites over the parent exactly as the Canvas
      // backend's restore() does: premultiplied source-over.
      _pass!.setColorBlendEquation(_srcOver);

      final vb = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(_fullTargetQuad));
      final ib = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(_quadIndices));
      _pass!.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
          4);
      _pass!.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16,
          _quadIndices.length);
      _pass!.bindTexture(
          pipeline.fragmentShader.getUniformSlot('u_texture'), sub);
      _pass!.draw();
    } catch (_) {
      // The subtree is lost for this frame; the rest of it still draws.
    }
  }

  /// The composite quad, in NDC with its 0..1 UVs — `[pos.xy, uv.xy]` per corner
  /// wound lt, rt, lb, rb to match [_quadIndices]. The V axis carries
  /// [_kNdcYSign] so the sampled subtree lands the same way up as it was drawn.
  static final Float32List _fullTargetQuad = Float32List.fromList(<double>[
    -1.0, _kNdcYSign, 0.0, 0.0, //
    1.0, _kNdcYSign, 1.0, 0.0, //
    -1.0, -_kNdcYSign, 0.0, 1.0, //
    1.0, -_kNdcYSign, 1.0, 1.0, //
  ]);

  /// The 4×5 `ColorFilter.matrix` [matrix] as the `TintInfo` UBO's three rgb
  /// rows `(m₀, m₁, m₂, offset)`, with the offset back in 0..1 (the Flutter
  /// matrix states it in 0..255). The alpha row is dropped — a whole-part tint
  /// never touches alpha (§10).
  static Float32List _tintRows(List<double> matrix) {
    final rows = Float32List(12);
    for (var r = 0; r < 3; r++) {
      rows[r * 4] = matrix[r * 5];
      rows[r * 4 + 1] = matrix[r * 5 + 1];
      rows[r * 4 + 2] = matrix[r * 5 + 2];
      rows[r * 4 + 3] = matrix[r * 5 + 4] / 255.0;
    }
    return rows;
  }

  /// Column-major 4×4 multiply `a · b` (a = current MVP, b = world 2D affine).
  static Float32List _mul4x4(Float32List a, Float64List b) {
    final r = Float32List(16);
    for (var c = 0; c < 4; c++) {
      for (var row = 0; row < 4; row++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[k * 4 + row] * b[c * 4 + k];
        }
        r[c * 4 + row] = sum;
      }
    }
    return r;
  }

  @override
  void rewindShaderPools() {
    // No shader pools — each frame builds fresh device buffers.
  }

  @override
  void releaseCoverage() {
    // No-op: coverage travels with each MaskContext/MaskDraw (its coverageHandle),
    // not a shared field. Lifetime is managed by _frameCoverages
    // (beginFrame/finish), which spans the whole tree including instance children.
  }

  @override
  void dispose() {
    // gpu.Texture / DeviceBuffer are GC-managed (no explicit destroy in the
    // flutter_gpu API); drop references so they can be collected.
    _gpuTextures.clear();
    _uploading.clear();
    _whiteTexture = null;
    _whiteUploading = false;
    _dummyCoverage = null;
    _frameCoverages.clear();
    _mvpView = null;
    _matStack.clear();
    _viewStack.clear();
    _hostBuffer = null;
    _target = null;
    _cmd = null;
    _pass = null;
    _canvas = null;
    _tintStack.clear();
  }
}

/// One suspended render pass while an instance subtree draws into its own target
/// for a group tint ([FlutterGpuBackend.pushGroupTint]).
///
/// [subTarget] / [subCmd] are null when the layer could not be allocated — the
/// entry then exists purely so the matching pop stays balanced and the subtree
/// draws untinted into the parent's pass rather than vanishing.
class _GroupTintLayer {
  _GroupTintLayer(this.pass, this.target, this.cmd, this.subTarget, this.subCmd,
      this.matrix);

  final gpu.RenderPass pass;
  final gpu.Texture target;
  final gpu.CommandBuffer cmd;
  final gpu.Texture? subTarget;
  final gpu.CommandBuffer? subCmd;
  final List<double> matrix;
}
