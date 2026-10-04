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
import '../root_transform.dart';
import 'render_backend.dart';
import 'render_host.dart';
import 'target_ring.dart';

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
/// Peeled parts (mask replay / PartColor tint) draw on the dedicated
/// PartColor pipeline, which carries every per-part value as a **per-vertex
/// attribute** — the Godot/Web sibling design. A per-vertex attribute
/// avoids the dynamically-indexed uniform array Impeller/Metal miscompiles, so
/// no UBO is bound.
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

  // --- Framebuffer blend equations -----------------------------------------
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
  /// draws peeled PartColor/mask parts. Each latches a load failure so a
  /// missing bundle is not retried every frame.
  static gpu.RenderPipeline? _spritePipeline;
  static bool _spritePipelineFailed = false;
  static gpu.RenderPipeline? _partColorPipeline;
  static bool _partColorPipelineFailed = false;

  /// The compiled shader bundle every pipeline below is built from, read once
  /// per isolate.
  ///
  /// `ShaderLibrary.fromAsset` returns a `Future` (Flutter 3.47+): some
  /// platforms can only read assets asynchronously, so the API is async
  /// everywhere. Pipelines are still built from inside the *synchronous*
  /// `paint`, hence the split — [_ensureLibrary] kicks the read off from
  /// [beginFrame] and parks the result here, and [_buildPipeline] only ever
  /// reads what has already landed.
  ///
  /// The gap is one blank frame, handled the same way the async texture upload
  /// handles its own: a build attempted before the bundle has landed is **not**
  /// a failure (see [_libraryReady] — it must not latch one), and the read's
  /// completion fires [onResourcesReady] so a paused, seeked or single-shot
  /// player repaints instead of staying blank forever.
  static gpu.ShaderLibrary? _library;
  static bool _libraryFailed = false;
  static Future<void>? _libraryRead;

  /// Backends that began a frame before the bundle landed, to be repainted once
  /// it does. Held only until the read completes; [dispose] deregisters.
  static final Set<FlutterGpuBackend> _libraryWaiters = <FlutterGpuBackend>{};

  /// Whether a pipeline can be built at all. False while the bundle is still
  /// being read, which is why a null [_buildPipeline] must not be latched as a
  /// failure until this is true.
  static bool get _libraryReady => _library != null;

  /// Starts the one-shot bundle read (idempotent) and registers this backend for
  /// the repaint that follows it. No-op once the bundle has landed or failed.
  void _ensureLibrary() {
    if (_libraryReady || _libraryFailed) return;
    _libraryWaiters.add(this);
    _libraryRead ??= _readLibrary();
  }

  static Future<void> _readLibrary() async {
    try {
      _library = await gpu.ShaderLibrary.fromAsset(_kShaderBundle);
    } catch (_) {
      _library = null;
    }
    _libraryFailed = _library == null;
    final waiters = _libraryWaiters.toList(growable: false);
    _libraryWaiters.clear();
    if (_libraryFailed) return;
    for (final w in waiters) {
      w._onResourcesReady?.call();
    }
  }

  static gpu.RenderPipeline? _buildPipeline(String vert, String frag) {
    final lib = _library;
    if (lib == null) return null;
    try {
      final v = lib[vert];
      final f = lib[frag];
      if (v == null || f == null) return null;
      return gpu.gpuContext.createRenderPipeline(v, f);
    } catch (_) {
      return null;
    }
  }

  static gpu.RenderPipeline? _ensureSpritePipeline() {
    if (_spritePipeline != null) return _spritePipeline;
    if (_spritePipelineFailed) return null;
    // Still reading the bundle: not a failure, do not latch one.
    if (!_libraryReady) return null;
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
    // Still reading the bundle: not a failure, do not latch one.
    if (!_libraryReady) return null;
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
    // Still reading the bundle: not a failure, do not latch one.
    if (!_libraryReady) return null;
    final p = _buildPipeline('MaskWriteVertex', 'MaskWriteFragment');
    if (p == null) {
      _maskWritePipelineFailed = true;
      return null;
    }
    return _maskWritePipeline = p;
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
    // Still reading the bundle: not a failure, do not latch one.
    if (!_libraryReady) return null;
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
    // Still reading the bundle: not a failure, do not latch one.
    if (!_libraryReady) return null;
    final p = _buildPipeline('ShapeMaskVertex', 'ShapeMaskFragment');
    if (p == null) {
      _shapeMaskPipelineFailed = true;
      return null;
    }
    return _shapeMaskPipeline = p;
  }

  /// Starts one draw on [pass] with [pipeline]. **Every** draw must go through
  /// here, and the [gpu.RenderPass.clearBindings] is not a tidy-up — it is what
  /// makes switching pipelines mid-pass correct.
  ///
  /// A `RenderPass` accumulates its uniform/texture bindings and keeps them
  /// across `draw()` calls: flutter_gpu keys each one by *(shader, uniform name)*
  /// (`RenderPass._bindTexture` / `_bindAsUniform`), so a binding stays live
  /// until something replaces that exact key. Five pipelines share this backend's
  /// single pass (sprite / PartColor / ss-shader / ShapeMask / colour-matrix) and
  /// their shaders are *different objects*, so re-binding by name inside the next
  /// draw does NOT replace the previous pipeline's entries — it adds to them. The
  /// leftovers are then applied alongside the current draw's, and on
  /// macOS/Metal that silently mis-renders: the sampler and vertex-buffer state
  /// the resolved binding set lands on is not the one the bound pipeline
  /// describes.
  ///
  /// Observed on the official SpriteStudio Mask sample (`Walk_Gate.ssab`): a
  /// plain sprite run drawn *after* a peeled PartColor run rendered as opaque
  /// black, or not at all — the gates and the platform vanished while the
  /// PartColor background beside them was pixel-exact. Neither the atlas upload
  /// nor the baked vertices were wrong (both were dumped and verified); only the
  /// draw order mattered, and clearing first fixes it exactly.
  ///
  /// The cost is one call per draw, and every call site here re-binds its whole
  /// state (pipeline, uniforms, vertex/index buffers, textures, blend) before
  /// `draw()`, so nothing legitimately relies on inheritance.
  static void _beginDraw(gpu.RenderPass pass, gpu.RenderPipeline pipeline) {
    pass.clearBindings();
    pass.bindPipeline(pipeline);
  }

  /// Longest edge, in pixels, of the mask coverage texture — a quality
  /// knob; the Canvas backend and ForGodot cap at the same 1024.
  static const double _kMaxCoverageDim = 1024.0;

  /// This frame's mask coverage textures, rendered by [renderCoverage] — one
  /// for the whole instance tree, which the top-level player owns. Each is
  /// handed to its [MaskContext] as an opaque `coverageHandle`, with no shared
  /// mutable state. This list only keeps them alive until [finish] submits the
  /// frame.
  final List<gpu.Texture> _frameCoverages = <gpu.Texture>[];

  /// hash → uploaded sampled texture. A hash absent here that is in [_uploading]
  /// is mid-flight (async `toByteData`); a part using it is skipped until ready.
  final Map<int, gpu.Texture> _gpuTextures = <int, gpu.Texture>{};
  final Set<int> _uploading = <int>{};

  /// Per-hash upload generation, bumped by [invalidateTexture] when a runtime
  /// texture replacement changes what a hash resolves to. An in-flight [_upload]
  /// captures the generation it started under and commits only if it still
  /// matches — so a replacement issued while the OLD image was uploading can
  /// never land the stale bitmap in [_gpuTextures].
  final Map<int, int> _texGeneration = <int, int>{};

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

  ui.VoidCallback? _onResourcesReady;

  @override
  set onResourcesReady(ui.VoidCallback? callback) =>
      _onResourcesReady = callback;

  // Per-frame state (valid between beginFrame and finish; _active gates use).
  bool _active = false;
  ui.Canvas? _canvas;
  // The logical-pixel rect the device-resolution offscreen composites into.
  ui.Rect? _compositeRect;
  gpu.Texture? _target;
  gpu.CommandBuffer? _cmd;
  gpu.RenderPass? _pass;

  /// Recycled offscreen render targets (see [TargetRing]).
  ///
  /// The backend used to allocate a fresh device-resolution target every frame
  /// — at DPR 3 a 640x480 box is a ~44 MB texture, 60 times a second — and
  /// `gpu.Texture` has no explicit destroy, so every one of them left its GPU
  /// allocation waiting on the GC. Recycling is safe content-wise because the
  /// colour attachment's default `LoadAction.clear` zeroes the target at the
  /// start of every pass, and safe timing-wise at depth 3 (see [TargetRing]).
  late final TargetRing<gpu.Texture> _targets = TargetRing<gpu.Texture>(
    3,
    (w, h) => gpu.gpuContext.createTexture(gpu.StorageMode.devicePrivate, w, h),
  );

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
  /// uses. Instance recursion pushes composed matrices onto the stacks.
  gpu.BufferView? _mvpView;
  final List<Float32List> _matStack = <Float32List>[];
  final List<gpu.BufferView> _viewStack = <gpu.BufferView>[];

  // --- Per-frame scratch -----------------------------------------------------
  //
  // ONE backend serves a whole instance tree (the children draw through their
  // parent's — see `SpriteStudioInternalPlayer._paintTree`), so every field below
  // is shared across the recursion. That is only sound because instance recursion
  // happens BETWEEN batches — `_emitInstanceBatch` is its own `DrawBatchKind` — so
  // no `emit*` is ever re-entered while its run is live. [_emitDepth] asserts it.
  //
  // The run lists are per emit kind rather than one shared list: three empty
  // lists cost nothing and the kinds stop being coupled at all.
  final List<int> _normalRunScratch = <int>[];
  final List<int> _shapeRunScratch = <int>[];
  final List<int> _meshRunScratch = <int>[];
  final List<int> _pcPartsScratch = <int>[];
  final List<PartColor> _pcColorsScratch = <PartColor>[];
  final List<MaskDraw?> _pcMasksScratch = <MaskDraw?>[];
  final List<Float32List?> _maskSetsScratch = <Float32List?>[];
  final List<efbs.EffectDrawCommand> _effectGroupScratch =
      <efbs.EffectDrawCommand>[];
  final Float32List _orthoMvpScratch = Float32List(16);
  final Float32List _shaderInfoScratch = Float32List(12);
  final Float32List _shapeMaskUboScratch =
      Float32List(MaskDraw.replayFloats);
  final Float32List _writerVertsScratch = Float32List(16);
  final Float32List _bitColorScratch = Float32List(4);
  final Float32List _coverageMvpScratch = Float32List(16);
  Float32List _posUvScratch = Float32List(0);

  /// Per-slot mask replay sets for [_drawPartColorRun]. Indexed by position in
  /// the run because ALL of a run's sets are live at once (the bake reads them
  /// part by part), so unlike the other scratch this needs one buffer per slot.
  final List<Float32List> _maskSetPool = <Float32List>[];

  /// Composed transforms for [pushTransform], indexed by stack depth — the whole
  /// stack is live at once, and each entry must survive until its `pop`.
  final List<Float32List> _matPool = <Float32List>[];

  /// Debug-only re-entrancy guard, asserted at the top of every `emit*`.
  ///
  /// Every `emit*` flushes its runs before returning, so an empty run list is
  /// exactly "no other `emit*` is part-way through". A future change that made
  /// one nest inside another (drawing an instance child from inside a batch
  /// rather than as its own batch) would trip here instead of silently
  /// interleaving two parts' geometry into one draw.
  bool get _noEmitInFlight {
    assert(
        _normalRunScratch.isEmpty &&
            _shapeRunScratch.isEmpty &&
            _meshRunScratch.isEmpty &&
            _pcPartsScratch.isEmpty,
        'emit* re-entered — the per-frame scratch is not re-entrant');
    return true;
  }

  @override
  void beginFrame(ui.Canvas canvas,
      {ui.Rect? dst,
      ui.Size? sourceSize,
      SsRootTransform root = SsRootTransform.identity}) {
    _active = false;
    _frameCoverages.clear();
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

    // Every pipeline is built from the shader bundle, and reading it is async;
    // this is the one place that starts it (nothing else runs until beginFrame
    // sets _active) and books the repaint for when it lands.
    _ensureLibrary();

    // The sprite pipeline is the base path; if it fails to load there is no GPU
    // rendering (the PartColor pipeline is checked lazily where it is used).
    if (_ensureSpritePipeline() == null) return;

    try {
      // Recycled, not freshly allocated — a size change (resize, DPR change, a
      // different `dst`) transparently starts a new ring.
      _target = _targets.acquire(w, h);
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
      final mvp = _orthoMvp(logical.width, logical.height, root, _orthoMvpScratch);
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
          _compositePaint,
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
    _releaseScratchRefs();
  }

  /// The offscreen→dst composite paint. One per backend: [finish] hands it to
  /// `drawImageRect`, which copies it into the display list.
  final ui.Paint _compositePaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium;

  /// Drops the object references the per-frame scratch still holds once the
  /// frame is submitted.
  ///
  /// None of these are ever *read* stale (each is cleared before its next use),
  /// so this is not a correctness fix — it stops the scratch from pinning a
  /// frame's `PartColor`s, `MaskDraw`s (and through them a coverage texture) and
  /// FlatBuffers command wrappers alive until the next frame overwrites them.
  /// The typed-data scratch is left alone: it holds no references.
  void _releaseScratchRefs() {
    _normalRunScratch.clear();
    _shapeRunScratch.clear();
    _meshRunScratch.clear();
    _pcPartsScratch.clear();
    _pcColorsScratch.clear();
    _pcMasksScratch.clear();
    _maskSetsScratch.clear();
    _effectGroupScratch.clear();
  }

  @override
  void emitNormal(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {
    if (!_active) return;
    assert(_noEmitInFlight);
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
    final run = _normalRunScratch..clear();
    final pcParts = _pcPartsScratch..clear();
    final pcColors = _pcColorsScratch..clear();
    final pcMasks = _pcMasksScratch..clear();
    // The coverage the current PartColor run samples. A masked part joins the run
    // only if it shares this handle, so a run never mixes two textures. The
    // tree shares one coverage per frame, so in practice every masked part
    // does; the check is what keeps that an optimisation rather than an
    // assumption. Unmasked parts join any run.
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
      final mask = masking.drawFor(rank, flags);
      // Draws only inside a mask, and none reaches it: nowhere at all.
      if (mask != null && mask.drawsNothing) continue;
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

  /// Draws a RUN of peeled parts (PartColor and/or mask) in ONE PartColor
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

    final maskSets = _maskSetsScratch..clear();
    for (var i = 0; i < masks.length; i++) {
      maskSets.add(_maskSet(masks[i], coverage, i));
    }
    final geo = host.geometry.buildPartColorInterleaved(
        parts, pcs, maskSets, frame,
        texWidth: texW, texHeight: texH);
    if (geo == null) return;

    try {
      final cov = coverage ?? dummyCov;
      _beginDraw(pass, pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.setColorBlendEquation(blend);

      final vb = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes));
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16);
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
      pass.drawIndexed(geo.indexCount);
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
      _drawPartColorRun(host.geometry.singlePart(part), <PartColor>[pc],
          const <MaskDraw?>[null], null, frame, host, tex, texW, texH, blend);
      return;
    }

    final geo = host.geometry
        .buildSsShaderInterleaved(quad, pc, texWidth: texW, texHeight: texH);
    if (geo == null) return;

    // `ShaderInfo` — three vec4s, so every field lands on a 16-byte boundary
    // (the alignment Impeller needs). `TEXTURE_PIXEL_SIZE` is 1/atlas size, NOT
    // 1/offscreen size: the effects step in texture space, and the offscreen is
    // DPR-scaled underneath them.
    final cell = host.geometry.cellRectScratch(quad, texW, texH);
    final info = _shaderInfoScratch
      ..[0] = sh.param0 // params
      ..[1] = sh.param1
      ..[2] = sh.param2
      ..[3] = sh.param3
      ..[4] = cell[0] // cell_rect
      ..[5] = cell[1]
      ..[6] = cell[2]
      ..[7] = cell[3]
      // misc: (effect id, 1/texW, 1/texH, -). The id is SsShaderId's index —
      // shaders/gpu/ssshader.frag's SS_* constants mirror that order.
      ..[8] = sh.id.index.toDouble()
      ..[9] = texW > 0 ? 1.0 / texW : 0.0
      ..[10] = texH > 0 ? 1.0 / texH : 0.0
      ..[11] = 0.0;

    try {
      final pass = _pass!;
      _beginDraw(pass, pipeline);
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
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes));
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16);
      pass.bindTexture(
        pipeline.fragmentShader.getUniformSlot('u_texture'),
        tex,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
        ),
      );
      pass.drawIndexed(geo.indexCount);
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  static final Uint16List _quadIndices =
      Uint16List.fromList(const <int>[0, 1, 2, 1, 3, 2]);

  /// Flattens a peeled part's mask replay into the [MaskDraw.replayFloats]
  /// floats the PartColor vertex carries ([MaskDraw.writeReplay], matching
  /// `GeometryBuilder._writePcVertex`) — or null when the part is unmasked this
  /// frame (no [mask], or no [coverage] texture bound for the run), so the bake
  /// writes `enabled = 0` and the shader passes it through.
  ///
  /// Written into [_maskSetPool]`[slot]` — every set in a run is live until the
  /// bake has read them all, so [slot] must be the part's index in the run.
  Float32List? _maskSet(MaskDraw? mask, gpu.Texture? coverage, int slot) {
    if (mask == null || coverage == null) return null;
    while (_maskSetPool.length <= slot) {
      _maskSetPool.add(Float32List(MaskDraw.replayFloats));
    }
    final set = _maskSetPool[slot];
    MaskDraw.writeReplay(mask, set);
    return set;
  }

  void _drawInterleaved(
      InterleavedGeometry geo, gpu.Texture tex, gpu.ColorBlendEquation blend) {
    final pass = _pass!;
    final pipeline = _spritePipeline!;
    try {
      // Pipeline + FrameInfo + blend are set per draw (several pipelines share
      // the pass — see [_beginDraw] for why the bindings must be cleared first —
      // and blend state persists, so an additive effect draw must not leak into
      // the next batch).
      _beginDraw(pass, pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.setColorBlendEquation(blend);
      final vb = gpu.gpuContext.createDeviceBufferWithCopy(
          ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext.createDeviceBufferWithCopy(
          ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes));
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16);
      pass.bindTexture(
        pipeline.fragmentShader.getUniformSlot('u_texture'),
        tex,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
        ),
      );
      pass.drawIndexed(geo.indexCount);
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  @override
  void invalidateTexture(int textureHash) {
    // Evict the cached upload so the next [_gpuTextureFor] re-uploads from the
    // registry's now-current image, and bump the generation so any in-flight
    // upload of the old image discards itself on completion. Dropping the map
    // entry is enough to release the old `gpu.Texture` — it is GC-managed (no
    // explicit destroy), like every texture this backend allocates.
    _gpuTextures.remove(textureHash);
    _uploading.remove(textureHash);
    _texGeneration[textureHash] = (_texGeneration[textureHash] ?? 0) + 1;
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
      _upload(hash, image, _texGeneration[hash] ?? 0);
    }
    return null;
  }

  Future<void> _upload(int hash, ui.Image image, int generation) async {
    var ready = false;
    try {
      // rawRgba is premultiplied — matches the sprite.frag / bake convention.
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return;
      // A runtime replacement issued while we awaited invalidated this upload;
      // drop the stale result rather than caching it under the current hash.
      if ((_texGeneration[hash] ?? 0) != generation) return;
      // Default coordinate system (renderToTexture, top-left) matches toByteData's
      // top-to-bottom rows and the Brain's top-left UVs, so no vertical flip.
      final tex = gpu.gpuContext.createTexture(
          gpu.StorageMode.hostVisible, image.width, image.height);
      tex.overwrite(bytes); // throws on failure (caught below)
      _gpuTextures[hash] = tex;
      ready = true;
    } catch (_) {
      // Leave it absent; the part keeps skipping (or the Canvas backend is used).
    } finally {
      _uploading.remove(hash);
      // Ask for another paint: the frame that triggered this upload drew without
      // the texture, and a paused / seeked / single-shot player has no next frame
      // of its own to correct it. See [onResourcesReady].
      if (ready) _onResourcesReady?.call();
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
      // Same as the atlas path: the frame that needed this drew without it, and
      // a static player has no next frame of its own. See [onResourcesReady].
      _onResourcesReady?.call();
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
  /// → clip space, with the player's [root] flip / offset folded in. The Y term
  /// carries the single [_kNdcYSign] flip (the Brain already flipped once; do not
  /// add a second — this only maps Y-Down into NDC); [root]'s own Y sign is a
  /// separate, user-driven mirror that multiplies onto it.
  ///
  /// `ortho · translate(offset) · scale(root)` written out: the projection is
  /// diagonal, so composing it costs two extra multiplies and puts the offset in
  /// the translation column. Note this is the *whole* per-vertex cost of the
  /// feature on this backend — the shaders and the geometry bake never learn of
  /// it.
  static Float32List _orthoMvp(
      double w, double h, SsRootTransform root, [Float32List? out]) {
    final m = out ?? Float32List(16);
    final sx = 2.0 / w; // x: [-w/2, w/2] → [-1, 1]
    final sy = _kNdcYSign * 2.0 / h; // y
    m[0] = sx * root.scaleX;
    m[1] = 0.0;
    m[2] = 0.0;
    m[3] = 0.0;
    m[4] = 0.0;
    m[5] = sy * root.scaleY;
    m[6] = 0.0;
    m[7] = 0.0;
    m[8] = 0.0;
    m[9] = 0.0;
    m[10] = 1.0; // z passthrough
    m[11] = 0.0;
    m[12] = sx * root.offset.dx;
    m[13] = sy * root.offset.dy;
    m[14] = 0.0;
    m[15] = 1.0;
    return m;
  }

  @override
  void emitMesh(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {
    if (!_active) return;
    assert(_noEmitInFlight);
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
    final parts = _meshRunScratch..clear();
    final pcParts = _pcPartsScratch..clear();
    final pcColors = _pcColorsScratch..clear();
    final pcMasks = _pcMasksScratch..clear();
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
      final mask = masking.drawFor(rank, flags);
      // Draws only inside a mask, and none reaches it: nowhere at all.
      if (mask != null && mask.drawsNothing) continue;
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

  /// Draws a RUN of peeled mesh parts (PartColor and/or mask) in ONE
  /// PartColor-pipeline call.
  ///
  /// No mesh-specific shader is needed: the bake carries the `lt` corner's colour
  /// + rate on every vertex — the *whole-only* Mesh rule — and the mask
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

    final maskSets = _maskSetsScratch..clear();
    for (var i = 0; i < masks.length; i++) {
      maskSets.add(_maskSet(masks[i], coverage, i));
    }
    final geo = host.geometry.buildMeshPartColorInterleaved(
        parts, pcs, maskSets, frame,
        texWidth: texW, texHeight: texH);
    if (geo == null) return;

    try {
      final cov = coverage ?? dummyCov;
      _beginDraw(pass, pipeline);
      pass.bindUniform(
          pipeline.vertexShader.getUniformSlot('FrameInfo'), _mvpView!);
      pass.setColorBlendEquation(blend);

      final vb = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.vertices));
      final ib = gpu.gpuContext
          .createDeviceBufferWithCopy(ByteData.sublistView(geo.indices));
      pass.bindVertexBuffer(
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes));
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16);
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
      pass.drawIndexed(geo.indexCount);
    } catch (_) {
      // Skip this draw; keep the rest of the frame.
    }
  }

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {
    if (!_active) return;
    assert(_noEmitInFlight);
    if (batch.count == 0) return;
    final blend = blendEquationFor(batch.blendType);
    final drawOrder = frame.drawOrder;

    // Every Shape draws through the ShapeMask pipeline, which outputs the baked
    // per-vertex colour directly (`frag_color = v_color`, no texture — matching
    // the Godot/WebGL siblings). Unmasked shapes batch into one draw with the mask
    // disabled; a mask-target shape flushes the batch and draws alone, its colour
    // gated by the coverage, preserving z-order. PartColor is already baked into
    // the vertex colour.
    final run = _shapeRunScratch..clear();
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
      final mask = masking.drawFor(rank, flags);
      // Draws only inside a mask, and none reaches it: nowhere at all.
      if (mask != null && mask.drawsNothing) continue;
      // Gate only when a GPU coverage texture exists; else draw
      // unmasked (mask disabled).
      if (mask == null || mask.coverageHandle is! gpu.Texture) {
        run.add(p);
      } else {
        flushRun();
        _drawShapeBatch(host.geometry.singlePart(p), mask, frame, host, blend);
      }
    }
    flushRun();
  }

  /// Draws a batch of Shapes through the ShapeMask pipeline, whose fragment shader
  /// outputs the baked per-vertex colour (`frag_color = v_color`, premultiplied).
  ///
  /// When [mask] is non-null the colour is gated by the mask coverage and
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
      // MaskInfo UBO: the five vec4s of [MaskDraw.writeReplay]. All-zero =>
      // disabled.
      final ubo = _shapeMaskUboScratch;
      MaskDraw.writeReplay(mask, ubo);

      _beginDraw(pass, pipeline);
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
          gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes));
      pass.bindIndexBuffer(
          gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
          gpu.IndexType.int16);
      pass.bindTexture(
          pipeline.fragmentShader.getUniformSlot('u_coverage'), coverage);
      pass.drawIndexed(geo.indexCount);
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
    // Past 24 writers the texture splits into tiles rather than growing: each
    // tile holds the whole box at a fraction of the resolution.
    final cols = plan.tilesX, rows = plan.tilesY;
    final tw = (pw / cols).ceil(), th = (ph / rows).ceil();

    try {
      // A dedicated command buffer / render pass: the coverage texture is written
      // here and sampled by the main pass, so it is submitted before the main
      // command buffer records its sampling draws.
      final target = gpu.gpuContext
          .createTexture(gpu.StorageMode.devicePrivate, tw * cols, th * rows);
      final cmd = gpu.gpuContext.createCommandBuffer();
      final pass = cmd.createRenderPass(
        gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: target)),
      );
      pass.setColorBlendEnable(true); // disjoint bits OR losslessly: `_additive`

      // Player-local -> coverage NDC per tile, built from the SAME
      // uvBasis/uvOffset the main-pass shader samples with, so the two are
      // guaranteed to agree. Emplaced once per tile in use.
      final tileMvps = <Float32List>[];
      final tileMvpViews = <gpu.BufferView>[];
      for (var t = 0; t < plan.tileCount; t++) {
        final m = Float32List.fromList(_coverageMvp(plan, t));
        tileMvps.add(m);
        tileMvpViews.add(_hostBuffer!.emplace(ByteData.sublistView(m)));
      }
      final mvpSlot = pipeline.vertexShader.getUniformSlot('MaskFrame');
      final bitSlot = pipeline.fragmentShader.getUniformSlot('MaskBit');
      final texSlot = pipeline.fragmentShader.getUniformSlot('u_texture');

      var wrote = false;
      for (final writer in plan.writers) {
        if (writer.partIndex < 0) continue; // a descendant's — baked below
        final flags = host.flagsFor(writer.partIndex);
        Float32List verts;
        Uint16List indices;
        var threshold = -1.0; // shape/mesh writers: geometry is the mask, no cutout
        gpu.Texture writerTex = dummyTex;

        if (flags.shapeGeometry) {
          final g = host.geometry
              .buildShapeParts(host.geometry.singlePart(writer.partIndex), frame);
          if (g == null) continue;
          verts = _posUvFromPositions(g.positions);
          indices = g.indices;
        } else if (flags.meshGeometry) {
          final g = host.geometry
              .buildMeshGeometry(host.geometry.singlePart(writer.partIndex), frame);
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
          final v = _writerVertsScratch;
          v[0] = c[0];
          v[1] = c[1];
          v[2] = ua[0] * invW;
          v[3] = ua[1] * invH;
          v[4] = c[2];
          v[5] = c[3];
          v[6] = ua[2] * invW;
          v[7] = ua[3] * invH;
          v[8] = c[4];
          v[9] = c[5];
          v[10] = ub[0] * invW;
          v[11] = ub[1] * invH;
          v[12] = c[6];
          v[13] = c[7];
          v[14] = ub[2] * invW;
          v[15] = ub[3] * invH;
          verts = v;
          indices = _quadIndices;
        }

        final vb = gpu.gpuContext
            .createDeviceBufferWithCopy(ByteData.sublistView(verts));
        final ib = gpu.gpuContext
            .createDeviceBufferWithCopy(ByteData.sublistView(indices));
        _beginDraw(pass, pipeline);
        pass.bindUniform(mvpSlot, tileMvpViews[writer.bit ~/ kMaskTileBits]);
        pass.bindUniform(bitSlot,
            _hostBuffer!.emplace(ByteData.sublistView(_bitColor(writer.bit, threshold))));
        pass.setColorBlendEquation(_additive); // bit accumulator: alpha adds too
        pass.bindVertexBuffer(
            gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes));
        pass.bindIndexBuffer(
            gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
            gpu.IndexType.int16);
        pass.bindTexture(texSlot, writerTex); // nearest (cutout threshold on raw texel)
        pass.drawIndexed(indices.length);
        wrote = true;
      }

      // Instance descendants' writers, at any depth, from THEIR geometry,
      // projected through coverageMvp ∘ slot so the descendant-local verts land
      // in this player's coverage (the owner-local MVP folds the slot in, where
      // the Canvas path applies it on the canvas transform stack).
      for (final bw in plan.bubbled) {
        final childMvpView = _hostBuffer!.emplace(ByteData.sublistView(
            _mul4Col(tileMvps[bw.bit ~/ kMaskTileBits], bw.slot)));
        Float32List verts;
        Uint16List indices;
        var threshold = -1.0;
        gpu.Texture writerTex = dummyTex;

        if (bw.flags.shapeGeometry) {
          final g = bw.geometry
              .buildShapeParts(bw.geometry.singlePart(bw.childPartIndex), bw.frame);
          if (g == null) continue;
          verts = _posUvFromPositions(g.positions);
          indices = g.indices;
        } else if (bw.flags.meshGeometry) {
          final g = bw.geometry
              .buildMeshGeometry(bw.geometry.singlePart(bw.childPartIndex), bw.frame);
          if (g == null) continue;
          verts = _posUvFromPositions(g.positions);
          indices = g.indices;
        } else {
          final quad = bw.geometry.buildPartColorQuad(bw.childPartIndex, bw.frame);
          if (quad == null) continue;
          final hash = bw.textureHash;
          final image = hash == null ? null : bw.textures.imageFor(hash);
          if (image == null) continue;
          final tex = _gpuTextureFor(hash!, image);
          if (tex == null) continue; // cell still uploading
          writerTex = tex;
          threshold = bw.threshold;
          final invW = image.width > 0 ? 1.0 / image.width : 0.0;
          final invH = image.height > 0 ? 1.0 / image.height : 0.0;
          final c = quad.corners, ua = quad.uvA, ub = quad.uvB;
          final v = _writerVertsScratch;
          v[0] = c[0];
          v[1] = c[1];
          v[2] = ua[0] * invW;
          v[3] = ua[1] * invH;
          v[4] = c[2];
          v[5] = c[3];
          v[6] = ua[2] * invW;
          v[7] = ua[3] * invH;
          v[8] = c[4];
          v[9] = c[5];
          v[10] = ub[0] * invW;
          v[11] = ub[1] * invH;
          v[12] = c[6];
          v[13] = c[7];
          v[14] = ub[2] * invW;
          v[15] = ub[3] * invH;
          verts = v;
          indices = _quadIndices;
        }

        final vb = gpu.gpuContext
            .createDeviceBufferWithCopy(ByteData.sublistView(verts));
        final ib = gpu.gpuContext
            .createDeviceBufferWithCopy(ByteData.sublistView(indices));
        _beginDraw(pass, pipeline);
        pass.bindUniform(mvpSlot, childMvpView);
        pass.bindUniform(bitSlot,
            _hostBuffer!.emplace(ByteData.sublistView(_bitColor(bw.bit, threshold))));
        pass.setColorBlendEquation(_additive);
        pass.bindVertexBuffer(
            gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: vb.sizeInBytes));
        pass.bindIndexBuffer(
            gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: ib.sizeInBytes),
            gpu.IndexType.int16);
        pass.bindTexture(texSlot, writerTex);
        pass.drawIndexed(indices.length);
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

  /// Column-major 4×4 product `a · b` — the owner-local→NDC coverage matrix
  /// composed with a descendant writer's descendant-local→owner-local slot, so
  /// its geometry projects straight into the owner's coverage. Fresh list
  /// (not a scratch): each bubbled writer emplaces its own before the next.
  static Float32List _mul4Col(Float32List a, Float64List b) {
    final out = Float32List(16);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[k * 4 + r] * b[c * 4 + k];
        }
        out[c * 4 + r] = s;
      }
    }
    return out;
  }

  /// Column-major player-local→coverage-NDC matrix for coverage [tile],
  /// derived from the plan's local→coverage-UV affine so the coverage pass
  /// writes exactly what the main pass samples: the box's UV lands on the
  /// tile's cell, `(uv + cell) / tiles`, then `ndc = uv*2 - 1`, with the Y axis
  /// carrying [_kNdcYSign].
  ///
  /// Written into [_coverageMvpScratch] — the caller copies it.
  Float32List _coverageMvp(MaskPlan plan, int tile) {
    final cols = plan.tilesX.toDouble(), rows = plan.tilesY.toDouble();
    final cx = (tile % plan.tilesX).toDouble();
    final cy = (tile ~/ plan.tilesX).toDouble();
    final pb = plan.uvBasis; // [m00, m01, m10, m11]
    final po = plan.uvOffset; // [x, y]
    final b = <double>[pb[0] / cols, pb[1] / cols, pb[2] / rows, pb[3] / rows];
    final o = <double>[(po[0] + cx) / cols, (po[1] + cy) / rows];
    // Every slot written, zeros included: a recycled buffer keeps nothing.
    final m = _coverageMvpScratch;
    m[0] = 2.0 * b[0];
    m[1] = _kNdcYSign * 2.0 * b[2];
    m[2] = 0.0;
    m[3] = 0.0;
    m[4] = 2.0 * b[1];
    m[5] = _kNdcYSign * 2.0 * b[3];
    m[6] = 0.0;
    m[7] = 0.0;
    m[8] = 0.0;
    m[9] = 0.0;
    m[10] = 1.0;
    m[11] = 0.0;
    m[12] = 2.0 * o[0] - 1.0;
    m[13] = _kNdcYSign * (2.0 * o[1] - 1.0);
    m[14] = 0.0;
    m[15] = 1.0;
    return m;
  }

  /// Interleaves world-space `[x,y,…]` positions into the mask-writer vertex
  /// format `[x, y, 0, 0]` (UV unused — shape/mesh writers have no texel cutout).
  ///
  /// Returns a view into [_posUvScratch]; the caller copies it into a device
  /// buffer before the next writer refills it.
  Float32List _posUvFromPositions(Float32List pos) {
    final n = pos.length ~/ 2;
    final need = n * 4;
    if (_posUvScratch.length < need) _posUvScratch = Float32List(need);
    final s = _posUvScratch;
    for (var i = 0; i < n; i++) {
      s[i * 4] = pos[i * 2];
      s[i * 4 + 1] = pos[i * 2 + 1];
      // Explicit: a recycled buffer would otherwise keep the previous writer's
      // UVs, where a fresh allocation came zeroed.
      s[i * 4 + 2] = 0.0;
      s[i * 4 + 3] = 0.0;
    }
    // Exact length — the caller derives its vertex count from it.
    return s.length == need
        ? s
        : Float32List.view(s.buffer, s.offsetInBytes, need);
  }

  /// One writer's bit as the `MaskBit` uniform: rgb = the bit in its owning R/G/B
  /// channel (8 bits × 3 = 24 writers per coverage tile), a = the cutout
  /// threshold.
  /// Written into [_bitColorScratch] — the caller emplaces it (which copies)
  /// before the next writer refills it.
  Float32List _bitColor(int bit, double threshold) {
    bit %= kMaskTileBits; // the tile is chosen by where it is drawn
    final channel = bit ~/ 8;
    final v = (1 << (bit % 8)) / 255.0;
    return _bitColorScratch
      ..[0] = channel == 0 ? v : 0.0
      ..[1] = channel == 1 ? v : 0.0
      ..[2] = channel == 2 ? v : 0.0
      ..[3] = threshold;
  }

  @override
  void pushTransform(ui.Canvas canvas, Float64List world) {
    if (!_active || _hostBuffer == null || _matStack.isEmpty) return;
    // Compose the child→parent world transform into the current projection:
    // gl_Position = (baseMvp · … · world) · localPos.
    // Depth-keyed buffer: the whole stack stays live until its pops, so this is
    // pooled per depth rather than a single scratch. It never aliases the
    // `_matStack.last` it reads — that is the enclosing depth's buffer (or
    // [_orthoMvpScratch] at the base, which is why slot 0 goes unused).
    final depth = _matStack.length;
    while (_matPool.length <= depth) {
      _matPool.add(Float32List(16));
    }
    final composed = _mul4x4(_matStack.last, world, _matPool[depth]);
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


  /// Column-major 4×4 multiply `a · b` (a = current MVP, b = world 2D affine),
  /// into [out] (which must not alias [a]).
  static Float32List _mul4x4(Float32List a, Float64List b, Float32List out) {
    final r = out;
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
    // A backend disposed while the shader bundle is still being read must not
    // be called back afterwards (the pending read is shared and outlives it).
    _libraryWaiters.remove(this);
    // gpu.Texture / DeviceBuffer are GC-managed (no explicit destroy in the
    // flutter_gpu API); drop references so they can be collected.
    _gpuTextures.clear();
    _uploading.clear();
    _texGeneration.clear();
    _whiteTexture = null;
    _whiteUploading = false;
    _dummyCoverage = null;
    _frameCoverages.clear();
    _mvpView = null;
    _matStack.clear();
    _viewStack.clear();
    _hostBuffer = null;
    _target = null;
    _targets.clear();
    _cmd = null;
    _pass = null;
    _canvas = null;
  }
}
