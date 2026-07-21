import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/framedata.dart' as fbs;

import '../geometry_builder.dart';
import '../mask.dart';
import '../mask_context.dart';
import '../part_color.dart';
import 'render_backend.dart';
import 'render_host.dart';

RenderBackend createFlutterGpuBackend() => FlutterGpuBackend();

/// The flutter_gpu (Impeller) render backend.
///
/// It renders each frame into an offscreen render-target [gpu.Texture] and
/// composites it back onto the Flutter canvas via
/// `canvas.drawImage(target.asImage(), dst)` in [finish] (flutter_gpu has no
/// on-screen target). **Implemented: Normal, Mesh, Shape, Effect** (Effect with
/// its Add/Mix blend), all reusing one textured pipeline — Shape samples a 1×1
/// white texel so its per-vertex colour (incl. PartColor) passes through.
///
/// Per-batch blend is mapped for the fixed-function-expressible modes (Mix / Add
/// / Sub — see [_blendFor]); Mul / Screen / Exclusion / Invert need advanced
/// blend and fall back to source-over.
///
/// **Not yet on GPU (drawn correctly only by the Canvas reference):** the mask
/// coverage pass (Phase 4) — so a *mask-target* part draws unmasked; a peeled
/// *Normal* PartColor part (Phase 5) — draws un-tinted; and Instance children
/// (Phase 6). The Canvas backend remains the complete parity reference for those.
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

  /// Premultiplied source-over — the framebuffer composite for Mix (and, until
  /// Phase 3 maps the full table, every non-additive kind). This is exactly the
  /// [gpu.ColorBlendEquation] default.
  static final gpu.ColorBlendEquation _srcOver = gpu.ColorBlendEquation();

  /// Additive (SpriteStudio Add / effect blend byte 1): `src + dst`.
  static final gpu.ColorBlendEquation _add = gpu.ColorBlendEquation(
    colorBlendOperation: gpu.BlendOperation.add,
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    alphaBlendOperation: gpu.BlendOperation.add,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  /// Subtractive (SpriteStudio Sub): `dst - src`. This is the exact reverse-
  /// subtract the Canvas path can only approximate as `BlendMode.difference` —
  /// so a Sub batch renders *more* correctly here, and intentionally does NOT
  /// pixel-match the Canvas reference for that mode.
  static final gpu.ColorBlendEquation _sub = gpu.ColorBlendEquation(
    colorBlendOperation: gpu.BlendOperation.reverseSubtract,
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.one,
    alphaBlendOperation: gpu.BlendOperation.reverseSubtract,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.one,
  );

  /// Screen (premultiplied): `Cr = Cs + Cd·(1 - Cs)` — exactly Skia's separable
  /// screen, so it matches the Canvas reference bit-for-bit.
  static final gpu.ColorBlendEquation _screen = gpu.ColorBlendEquation(
    colorBlendOperation: gpu.BlendOperation.add,
    sourceColorBlendFactor: gpu.BlendFactor.one,
    destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceColor,
    alphaBlendOperation: gpu.BlendOperation.add,
    sourceAlphaBlendFactor: gpu.BlendFactor.one,
    destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
  );

  /// Multiply as `Cr = Cs·Cd` (src×dst). This equals Skia's separable multiply
  /// only where the destination is **opaque** (the common case); over
  /// transparency it drops the `Cs·(1-Ad) + Cd·(1-As)` terms, which needs a
  /// framebuffer-read shader to reproduce exactly.
  static final gpu.ColorBlendEquation _multiply = gpu.ColorBlendEquation(
    colorBlendOperation: gpu.BlendOperation.add,
    sourceColorBlendFactor: gpu.BlendFactor.destinationColor,
    destinationColorBlendFactor: gpu.BlendFactor.zero,
    alphaBlendOperation: gpu.BlendOperation.add,
    sourceAlphaBlendFactor: gpu.BlendFactor.destinationAlpha,
    destinationAlphaBlendFactor: gpu.BlendFactor.zero,
  );

  /// The framebuffer blend equation for a batch's [fbs.BlendType].
  ///
  /// Fixed-function reaches more SS modes than first assumed: Mix / Div2 /
  /// Overlay2 → source-over, Add → additive, Sub → reverse-subtract, **Screen →
  /// exact**, **Mul → src×dst (exact over opaque)**. Only **Exclusion / Invert**
  /// (and Multiply *over transparency*) truly need a framebuffer-read shader —
  /// those still fall back to source-over here.
  static gpu.ColorBlendEquation _blendFor(fbs.BlendType type) {
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
      case fbs.BlendType.Mix:
      case fbs.BlendType.Div2:
      case fbs.BlendType.Overlay2:
      case fbs.BlendType.Exclusion:
      case fbs.BlendType.Invert:
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

  /// A shared 1×1 opaque-white texture for the Shape path (which samples no
  /// atlas): `texel * colour` then collapses to the per-vertex colour.
  gpu.Texture? _whiteTexture;

  /// A shared 1×1 transparent texture bound to the PartColor shader's coverage
  /// sampler when a part is not masked (a sampler must always be bound).
  gpu.Texture? _dummyCoverage;

  /// Reused uniform bump allocator (aligned per platform). Reset each frame.
  gpu.HostBuffer? _hostBuffer;

  // Per-frame state (valid between beginFrame and finish; _active gates use).
  bool _active = false;
  ui.Canvas? _canvas;
  ui.Rect? _dst;
  gpu.Texture? _target;
  gpu.CommandBuffer? _cmd;
  gpu.RenderPass? _pass;

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
    _canvas = canvas;
    _dst = dst;
    final size = dst?.size ?? sourceSize ?? ui.Size.zero;
    final w = size.width.floor();
    final h = size.height.floor();
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
      // stack. Each draw re-binds the top to its pipeline's FrameInfo slot.
      final mvp = _orthoMvp(w.toDouble(), h.toDouble());
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
        _canvas!.drawImage(img, _dst?.topLeft ?? ui.Offset.zero, ui.Paint());
      } catch (_) {
        // Swallow — a blank frame beats a crash.
      }
    }
    _active = false;
    _canvas = null;
    _dst = null;
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
    final blend = _blendFor(batch.blendType);
    final drawOrder = frame.drawOrder;
    final partsColor = frame.partsColor;

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

  /// Max peeled parts per PartColor batch — bounded by the `PartColorInfo` array
  /// size (40 entries = 5760 bytes < impellerc's 6208-byte UBO limit). A longer
  /// run splits into multiple draws.
  static const int _kMaxPartColorRun = 40;

  /// Draws a RUN of peeled parts (PartColor §10 and/or mask §9) in ONE PartColor
  /// pipeline call — the fan-out collapse. Each part's quad becomes 4 vertices
  /// tagged with its slot index (`a_part`); its corner colours / rate / coef /
  /// mask sets go into the `PartColorInfo` uniform array at that slot. A part with
  /// a degenerate quad is dropped. Falls back to plain sprite draws when the
  /// pipeline is unavailable, so parts stay visible.
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

    final invW = texW > 0 ? 1.0 / texW : 0.0;
    final invH = texH > 0 ? 1.0 / texH : 0.0;
    final n = parts.length;
    final verts = Float32List(n * 4 * 7); // 4 corners × [pos.xy, uv.xy, st.xy, part]
    final indices = Uint16List(n * 6);
    final ubo = Float32List(360 * 4); // the full declared UBO, zero-padded
    var vp = 0, ip = 0, slot = 0, vbase = 0;

    for (var i = 0; i < n; i++) {
      final quad = host.geometry.buildPartColorQuad(parts[i], frame);
      if (quad == null) continue; // degenerate — drop
      final c = quad.corners, ua = quad.uvA, ub = quad.uvB;
      final pf = slot.toDouble();
      void v(double x, double y, double u, double vv, double s, double t) {
        verts[vp++] = x;
        verts[vp++] = y;
        verts[vp++] = u;
        verts[vp++] = vv;
        verts[vp++] = s;
        verts[vp++] = t;
        verts[vp++] = pf;
      }

      v(c[0], c[1], ua[0] * invW, ua[1] * invH, 0.0, 0.0); // lt
      v(c[2], c[3], ua[2] * invW, ua[3] * invH, 1.0, 0.0); // rt
      v(c[4], c[5], ub[0] * invW, ub[1] * invH, 0.0, 1.0); // lb
      v(c[6], c[7], ub[2] * invW, ub[3] * invH, 1.0, 1.0); // rb
      indices[ip++] = vbase;
      indices[ip++] = vbase + 1;
      indices[ip++] = vbase + 2;
      indices[ip++] = vbase + 1;
      indices[ip++] = vbase + 3;
      indices[ip++] = vbase + 2;
      vbase += 4;

      final masked = masks[i] != null && coverage != null;
      _writePartColorEntry(ubo, slot * 36, pcs[i], masked ? masks[i] : null);
      slot++;
    }
    if (slot == 0) return;

    try {
      final cov = coverage ?? dummyCov;
      pass.bindPipeline(pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.bindUniform(pipeline.fragmentShader.getUniformSlot('PartColorInfo'),
          _hostBuffer!.emplace(ByteData.sublistView(ubo)));
      pass.setColorBlendEquation(blend);

      final vb = gpu.gpuContext.createDeviceBufferWithCopy(ByteData.sublistView(
          Float32List.view(verts.buffer, verts.offsetInBytes, vp)));
      final ib = gpu.gpuContext.createDeviceBufferWithCopy(ByteData.sublistView(
          Uint16List.view(indices.buffer, indices.offsetInBytes, ip)));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes),
          slot * 4);
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16,
          ip);
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

  static final Uint16List _quadIndices =
      Uint16List.fromList(const <int>[0, 1, 2, 1, 3, 2]);

  /// Writes one part's 36 floats into the `PartColorInfo` array at [base]
  /// (9 vec4: 4 corner colours, rate, coef, mask_bits, mask_uv, mask_off), in the
  /// declaration order of shaders/gpu/partcolor.frag.
  static void _writePartColorEntry(
      Float32List u, int base, PartColor pc, MaskDraw? mask) {
    void corner(int o, PartColorCorner k) {
      u[o] = k.r;
      u[o + 1] = k.g;
      u[o + 2] = k.b;
      u[o + 3] = k.a;
    }

    corner(base, pc.lt);
    corner(base + 4, pc.rt);
    corner(base + 8, pc.lb);
    corner(base + 12, pc.rb);
    u[base + 16] = pc.lt.rate;
    u[base + 17] = pc.rt.rate;
    u[base + 18] = pc.lb.rate;
    u[base + 19] = pc.rb.rate;
    u[base + 20] = pc.coef[0];
    u[base + 21] = pc.coef[1];
    u[base + 22] = pc.coef[2];
    u[base + 23] = pc.coef[3];
    if (mask != null) {
      u[base + 24] = mask.bits.increment.toDouble();
      u[base + 25] = mask.bits.invert.toDouble();
      u[base + 26] = mask.bits.visibleInside ? 1.0 : 0.0;
      u[base + 27] = 1.0; // enabled
      u[base + 28] = mask.uvBasis[0];
      u[base + 29] = mask.uvBasis[1];
      u[base + 30] = mask.uvBasis[2];
      u[base + 31] = mask.uvBasis[3];
      u[base + 32] = mask.uvOffset[0];
      u[base + 33] = mask.uvOffset[1];
    }
    // base+34, base+35 (mask_off.zw) stay 0.
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

  gpu.Texture? _ensureWhiteTexture() {
    final existing = _whiteTexture;
    if (existing != null) return existing;
    try {
      final tex =
          gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, 1, 1);
      tex.overwrite(
          ByteData.sublistView(Uint8List.fromList(const [255, 255, 255, 255])));
      return _whiteTexture = tex;
    } catch (_) {
      return null;
    }
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
      RenderHost host) {
    if (!_active) return;
    final count = batch.count;
    if (count == 0) return;
    final image = host.textures.imageFor(batch.textureHash);
    if (image == null) return;
    final tex = _gpuTextureFor(batch.textureHash, image);
    if (tex == null) return; // still uploading

    final drawOrder = frame.drawOrder;
    final parts = <int>[];
    for (var k = 0; k < count; k++) {
      final rank = batch.startRank + k;
      if (rank >= drawOrder.length) break;
      final p = drawOrder[rank];
      if (host.flagsFor(p).pureMask) continue;
      parts.add(p);
    }
    final geo = host.geometry.buildMeshInterleaved(parts, frame,
        texWidth: image.width.toDouble(), texHeight: image.height.toDouble());
    if (geo == null) return;
    _drawInterleaved(geo, tex, _blendFor(batch.blendType));
  }

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask) {
    if (!_active) return;
    if (batch.count == 0) return;
    final white = _ensureWhiteTexture();
    if (white == null) return;
    final blend = _blendFor(batch.blendType);
    final drawOrder = frame.drawOrder;

    // Plain shapes batch (sprite pipeline + white texel so `texel * colour` is the
    // colour); a mask-target shape is peeled onto the ShapeMask pipeline (its
    // per-vertex gradient gated by the coverage), preserving z-order. PartColor is
    // already baked into the vertex colour — no shader needed for it.
    final run = <int>[];
    void flushRun() {
      if (run.isEmpty) return;
      final geo = host.geometry.buildShapeInterleaved(run, frame);
      if (geo != null) _drawInterleaved(geo, white, blend);
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
      // plain (unmasked).
      if (mask == null || mask.coverageHandle is! gpu.Texture) {
        run.add(p);
      } else {
        flushRun();
        _drawMaskedShape(p, mask, frame, host, blend);
      }
    }
    flushRun();
  }

  /// Draws one mask-target Shape (§9): its per-vertex gradient gated by the mask
  /// coverage via the ShapeMask pipeline. Falls back to a plain (unmasked) shape
  /// draw when the pipeline/coverage is unavailable.
  void _drawMaskedShape(int part, MaskDraw mask, DrawFrame frame,
      RenderHost host, gpu.ColorBlendEquation blend) {
    final pass = _pass!;
    final pipeline = _ensureShapeMaskPipeline();
    final coverage = mask.coverageHandle is gpu.Texture
        ? mask.coverageHandle as gpu.Texture
        : null;
    final geo = host.geometry.buildShapeColorInterleaved(<int>[part], frame);
    if (geo == null) return;
    if (pipeline == null || coverage == null) {
      // Fallback: plain (unmasked) shape via the sprite + white path.
      final plain = host.geometry.buildShapeInterleaved(<int>[part], frame);
      final white = _ensureWhiteTexture();
      if (plain != null && white != null) _drawInterleaved(plain, white, blend);
      return;
    }

    try {
      // MaskInfo UBO: mask_bits, mask_uv, mask_off (3 vec4).
      final ubo = Float32List(12);
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
        // Effect blend byte: 1 = Add → additive, else Mix → source-over.
        _drawInterleaved(geo, tex, blend == 1 ? _add : _srcOver);
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
      pass.setColorBlendEnable(true); // disjoint bits OR losslessly under `_add`

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
        pass.setColorBlendEquation(_add);
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
    // not a shared field, so a child's _paintTree must NOT drop the parent's
    // coverage here. Lifetime is managed by _frameCoverages (beginFrame/finish).
  }

  @override
  void dispose() {
    // gpu.Texture / DeviceBuffer are GC-managed (no explicit destroy in the
    // flutter_gpu API); drop references so they can be collected.
    _gpuTextures.clear();
    _uploading.clear();
    _whiteTexture = null;
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
  }
}
