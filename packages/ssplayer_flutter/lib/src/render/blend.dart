import 'dart:ui' as ui;

import 'package:ssruntime_dart/framedata.dart' as fbs;

/// Framebuffer blend mapping: the `Paint.blendMode` used for a
/// batch's `drawVertices` / peeled `drawPath`.
///
/// The ground truth is the **ssplayer-webgl** renderer (`SSWebGLRenderer.applyBlend`
/// / `SSBlendModes`), which realises every SS blend as a fixed-function GL blend
/// state `out = Cs·srcFactor + Cb·dstFactor` (RGB) with premultiplied source and a
/// premultiplied-coverage alpha channel `[ONE, 1-SRC_ALPHA]`:
///
///   | SS BlendType    | srcRGB          | dstRGB          | rgbEq           |
///   |-----------------|-----------------|-----------------|-----------------|
///   | Mix             | ONE             | 1-SRC_ALPHA     | ADD             |
///   | Mul / Mulalpha  | DST_COLOR       | 1-SRC_ALPHA     | ADD             |
///   | Add             | ONE             | ONE             | ADD             |
///   | Sub             | ONE             | ONE             | REVERSE_SUBTRACT|
///   | Screen          | 1-DST_COLOR     | ONE             | ADD             |
///   | Exclusion       | 1-DST_COLOR     | 1-SRC_COLOR     | ADD             |
///   | Invert          | 1-DST_COLOR     | ZERO            | ADD             |
///
/// Skia's stock separable [ui.BlendMode]s are defined on **premultiplied** colours,
/// so — reading the table against a premultiplied source `Cs` — most rows have an
/// *exact* stock equivalent. `test/blend_pixel_test.dart` measures every row against
/// the formula above rather than trusting this algebra:
///
///   * Mix       → `srcOver`   (`Cs + Cb·(1-αs)`)
///   * Add       → `plus`      (`Cs + Cb`, both clamp)
///   * Mul/α/2   → `multiply`  (`Cs·Cb + Cb·(1-αs)`, Skia's premult multiply)
///   * Screen/2  → `screen`    (`Cs + Cb - Cs·Cb`)
///   * Exclusion → `exclusion` (`Cs + Cb - 2·Cs·Cb`)
///
/// Screen and Exclusion are exact for **any** backdrop alpha — the `αs`/`αb` terms
/// of Skia's separable composite cancel identically for those two. `multiply` keeps
/// one extra term, `Cs·(1-αb)`, so Mul is exact wherever `Cb` is **opaque** (which
/// is what SS itself assumes: it renders onto an opaque target) and diverges over
/// transparency, where the reference drops the part to black and Skia keeps it.
/// Choosing `modulate` (`Cs·Cb`, the literal `DST_COLOR, ZERO` row) would fix that
/// corner at the cost of blacking out every semi-transparent texel of every Mul
/// part, so `multiply` stays.
///
/// Two rows have **no *single* stock equivalent** — Flutter's fixed blend enum
/// offers neither a reverse-subtract nor a "replace dst with `Cs·(1-Cb)`" — so
/// `Sub` / `Invert` map to `difference` (`|Cs - Cb|`), which is exact only in the
/// narrow regime each mode is authored for (measured: `Sub` while `Cs ≤ αs·Cb`,
/// `Invert` for an opaque white overlay). **The Canvas backend does not use that
/// approximation** — it reconstructs both exactly out of a few stock passes; see
/// [blendPassesFor]. [blendModeFor] keeps returning `difference` as the honest
/// one-pass answer for callers that cannot run a multi-pass plan.
///
/// Div2 / Overlay2 have no GL mapping in ssplayer-webgl either (its `default`
/// clamps them to Mix), so they follow suit → `srcOver`.
///
/// The 4-mode **PartColor** blend is a *shader-side* concern, unrelated to
/// this framebuffer mapping; its coefficient table ([partColorCoef]) lives
/// alongside this mapping (the `FragmentProgram` path — `render/part_color.dart`
/// + `shaders/partcolor.frag`).
ui.BlendMode blendModeFor(fbs.BlendType type) {
  switch (type) {
    case fbs.BlendType.Add:
      return ui.BlendMode.plus;
    case fbs.BlendType.Mul:
    case fbs.BlendType.Mulalpha:
    case fbs.BlendType.Mul2:
      return ui.BlendMode.multiply;
    case fbs.BlendType.Screen:
    case fbs.BlendType.Screen2:
      return ui.BlendMode.screen;
    case fbs.BlendType.Exclusion:
      return ui.BlendMode.exclusion;
    case fbs.BlendType.Sub:
    case fbs.BlendType.Invert:
      // No stock reverse-subtract / dst-replace; difference is the closest
      // one-pass approximation (exact for the darkening / opaque-overlay case
      // each targets). Prefer [blendPassesFor], which is exact.
      return ui.BlendMode.difference;
    case fbs.BlendType.Mix:
    case fbs.BlendType.Div2: // no GL mapping upstream → Mix
    case fbs.BlendType.Overlay2: // no GL mapping upstream → Mix
      return ui.BlendMode.srcOver;
  }
}

/// What one pass of a [blendPassesFor] plan actually draws.
enum BlendPassSource {
  /// The part itself — the ordinary draw, with its own texture / shader / tint.
  part,

  /// The part's **coverage only**: saturated opaque white wherever the part puts
  /// any alpha at all, and nothing where it puts none. Realised as a colour
  /// filter, so it works uniformly for a textured `drawVertices`, a peeled
  /// `FragmentShader` quad (whose alpha already carries the mask gate) and a
  /// tinted layer alike — the filter replaces whatever colour the draw would
  /// have produced and keeps only "did it cover this pixel".
  coverage,

  /// Opaque black over the whole geometry, whatever the part's own colours are.
  black,
}

/// One pass of a reconstructed framebuffer blend: a stock [ui.BlendMode] plus
/// what the draw should put through it.
class BlendPass {
  const BlendPass(this.mode, [this.source = BlendPassSource.part]);

  /// The framebuffer composite for this pass.
  final ui.BlendMode mode;

  /// What the pass draws.
  final BlendPassSource source;

  /// The colour filter this pass forces onto the draw, or null to keep the
  /// draw's own (a peeled Mesh part's whole-part tint, typically). A textured
  /// `drawVertices` takes it through [drawTexturedPass], never as its paint's
  /// `colorFilter`.
  ///
  /// A pass that only needs coverage may safely drop that tint: the tint is an
  /// rgb affine and cannot change *whether* a pixel is covered.
  ui.ColorFilter? get filter => switch (source) {
        BlendPassSource.part => null,
        BlendPassSource.coverage => _coverageFilter,
        BlendPassSource.black => _blackFilter,
      };
}

/// `rgb = white`, `α = saturate(255·α)` — see [BlendPassSource.coverage]. The
/// translation column of a [ui.ColorFilter.matrix] is in 0..255 space while the
/// coefficients are normalised, so `255·α` saturates for any non-zero alpha.
const ui.ColorFilter _coverageFilter = ui.ColorFilter.matrix(<double>[
  0, 0, 0, 0, 255, //
  0, 0, 0, 0, 255,
  0, 0, 0, 0, 255,
  0, 0, 0, 255, 0,
]);

/// `rgba = opaque black` — see [BlendPassSource.black].
const ui.ColorFilter _blackFilter = ui.ColorFilter.matrix(<double>[
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0,
  0, 0, 0, 0, 0,
  0, 0, 0, 0, 255,
]);

/// The stock-[ui.BlendMode] passes that realise [type] over **one part's**
/// geometry, in order. All but two modes are a single pass — [blendModeFor].
///
/// `Sub` and `Invert` have no stock equivalent, but both are exactly
/// reconstructible from a few passes over the same geometry, because a
/// `difference` against opaque white *is* a destination inversion (`|1-Cb| =
/// 1-Cb`) and inverting twice cancels:
///
///   * **Sub** = `max(0, Cb - Cs)`:
///     `difference` white → `1-Cb`; `plus` the part → `1-Cb+Cs`; `darken` white
///     → `min(1, 1-Cb+Cs)`; `difference` white again → `max(0, Cb-Cs)`. The
///     clamp is what reproduces SS's clamp-to-black, and it is a pass of its
///     own because `plus` does not clamp on every target: Impeller (measured on
///     macOS) keeps the sum above 1, and the last inversion then turns the
///     excess into brightness. Where the target clamps, `darken` changes
///     nothing. Wherever the part contributes nothing the two inversions cancel
///     to a no-op.
///   * **Invert** = `Cs·(1-Cb)` with the destination *replaced*:
///     `difference` white → `1-Cb`; `modulate` the part → `Cs·(1-Cb)`;
///     `dstOver` opaque black restores the alpha `modulate` multiplied down.
///     The dst-replace shows up for free — `modulate` zeroes the destination
///     where the part's texel is transparent, which is exactly what a ZERO dst
///     factor does. A fragment the part's mask hides must not reach it, which
///     is what [openModulateLayer] is for.
///
/// Both are pixel-exact over an **opaque** destination — the case SS itself
/// assumes, and already the caveat on Mul / Screen / Exclusion — but for the
/// pixels the part's edge crosses on Impeller, where the inversions no longer
/// cancel exactly (measured on macOS: a one-pixel fringe). Over transparency
/// the rgb still matches but the inversion passes force alpha to 1 across the
/// part's covered area (source-over is the only alpha composite a stock blend
/// mode has), so a part hanging off the animation's opaque content reads as an
/// opaque silhouette rather than a translucent one.
///
/// Two constraints the caller must honour:
///
///  1. **One part per plan.** The inversion passes must cover each pixel exactly
///     once, so a batch's parts cannot be run through it together — two
///     overlapping Sub parts would invert their overlap twice and cancel it.
///     Callers peel multi-pass parts out of their batched run.
///  2. **Same geometry every pass.** Build the geometry once and draw it once per
///     pass; a different tessellation between passes would leave the inversion
///     un-cancelled at the seams.
List<BlendPass> blendPassesFor(fbs.BlendType type) => _passPlans[type]!;

/// Plans are immutable and cheap to share, so they are built once rather than
/// allocated per batch on the paint hot path.
final Map<fbs.BlendType, List<BlendPass>> _passPlans =
    <fbs.BlendType, List<BlendPass>>{
  for (final type in fbs.BlendType.values) type: _planFor(type),
};

List<BlendPass> _planFor(fbs.BlendType type) {
  switch (type) {
    case fbs.BlendType.Sub:
      return const <BlendPass>[
        BlendPass(ui.BlendMode.difference, BlendPassSource.coverage),
        BlendPass(ui.BlendMode.plus),
        BlendPass(ui.BlendMode.darken, BlendPassSource.coverage),
        BlendPass(ui.BlendMode.difference, BlendPassSource.coverage),
      ];
    case fbs.BlendType.Invert:
      return const <BlendPass>[
        BlendPass(ui.BlendMode.difference, BlendPassSource.coverage),
        BlendPass(ui.BlendMode.modulate),
        BlendPass(ui.BlendMode.dstOver, BlendPassSource.black),
      ];
    default:
      return <BlendPass>[BlendPass(blendModeFor(type))];
  }
}

/// Draws one [pass] of a [blendPassesFor] plan as a textured `drawVertices`:
/// [vertices] sampling [texture] (the atlas's `ImageShader`), with [tint] — a
/// peeled Mesh part's whole-part PartColor — unless the pass brings a filter
/// of its own.
///
/// The filter never goes on the textured draw's `colorFilter`: Impeller drops
/// that from a `drawVertices` that samples an `ImageShader` (Skia applies it).
/// Nor on a layer's `colorFilter`: Impeller composites a second `difference`
/// layer against the backdrop the first one read, so Sub's second inversion would
/// undo the first. It goes on the draw's `imageFilter`, which both renderers
/// apply and which composites against the current backdrop. The black pass
/// needs no texel, so it draws the bare geometry, whose vertex colours the
/// filter does reach; an image filter would blacken its whole extent.
///
/// A filtered `modulate` pass (a tinted Invert) goes through
/// [openModulateLayer]: the filtered draw composites as a rectangle, and
/// `modulate` with the transparent around the geometry would zero the
/// destination there. So does a masked part's, whose [maskedOut] is opaque white
/// wherever the mask hides the part. [bounds], what [vertices] cover, sizes that
/// layer; null leaves it the size of the clip.
///
/// [paint] and [layerPaint] are the caller's reused paints. Every field the
/// draws read is set here.
void drawTexturedPass(
  ui.Canvas canvas,
  ui.Vertices vertices,
  BlendPass pass,
  ui.Shader? texture, {
  ui.ColorFilter? tint,
  ui.Shader? maskedOut,
  ui.Rect? bounds,
  required ui.Paint paint,
  required ui.Paint layerPaint,
}) {
  final filter = pass.filter ?? tint;
  // `modulate` multiplies the vertex colour (white × alpha) into the texel; the
  // paint's blend mode is the framebuffer composite. Opaque white, because with
  // a shader bound the paint's RGB is unused but its alpha still scales it.
  paint
    ..color = const ui.Color(0xFFFFFFFF)
    ..colorFilter = null
    ..imageFilter = null;
  if (pass.mode == ui.BlendMode.modulate &&
      (filter != null || maskedOut != null)) {
    openModulateLayer(canvas, bounds, paint: paint, layerPaint: layerPaint);
    canvas
      ..drawVertices(vertices, ui.BlendMode.modulate,
          paint..blendMode = ui.BlendMode.clear)
      ..drawVertices(
          vertices,
          ui.BlendMode.modulate,
          paint
            ..blendMode = ui.BlendMode.srcOver
            ..shader = texture
            ..imageFilter = filter);
    closeModulateLayer(canvas, maskedOut, paint: paint);
  } else if (filter == null) {
    canvas.drawVertices(
        vertices,
        ui.BlendMode.modulate,
        paint
          ..blendMode = pass.mode
          ..shader = texture);
  } else if (pass.source == BlendPassSource.black) {
    canvas.drawVertices(
        vertices,
        ui.BlendMode.modulate,
        paint
          ..blendMode = pass.mode
          ..shader = null
          ..colorFilter = filter);
  } else {
    canvas.drawVertices(
        vertices,
        ui.BlendMode.modulate,
        paint
          ..blendMode = pass.mode
          ..shader = texture
          ..imageFilter = filter);
  }
}

/// Opens the layer a `modulate` pass (Invert's) draws a part into when the
/// draw reaches pixels the part must leave alone. `modulate` multiplies the
/// destination by everything the layer holds, transparent pixels included,
/// so the layer starts as its identity, opaque white, over [bounds] (null:
/// the clip). The caller clears the part's geometry out of it, draws the part
/// there in source-over, and closes it with [closeModulateLayer].
///
/// Every field [paint] and [layerPaint] are read for is set here.
void openModulateLayer(ui.Canvas canvas, ui.Rect? bounds,
    {required ui.Paint paint, required ui.Paint layerPaint}) {
  canvas
    ..saveLayer(
        bounds,
        layerPaint
          ..blendMode = ui.BlendMode.modulate
          ..colorFilter = null
          ..imageFilter = null)
    ..drawPaint(paint
      ..blendMode = ui.BlendMode.srcOver
      ..color = const ui.Color(0xFFFFFFFF)
      ..shader = null
      ..colorFilter = null
      ..imageFilter = null);
}

/// Closes [openModulateLayer]'s layer. [maskedOut], opaque white wherever the
/// part's mask hides it and transparent elsewhere, puts the identity back
/// there: a hidden fragment must leave the destination alone, as it does
/// under every other mode, and `modulate` would otherwise zero it. Null for an
/// unmasked part.
void closeModulateLayer(ui.Canvas canvas, ui.Shader? maskedOut,
    {required ui.Paint paint}) {
  if (maskedOut != null) {
    canvas.drawPaint(paint
      ..blendMode = ui.BlendMode.srcOver
      ..color = const ui.Color(0xFFFFFFFF)
      ..shader = maskedOut
      ..colorFilter = null
      ..imageFilter = null);
  }
  canvas.restore();
}

/// Framebuffer blend mapping for an `EffectDrawCommand.blend`.
///
/// **Not** the [fbs.BlendType] enum — an emitter's blend is the SS6-style raw
/// byte `0 = Mix`, `1 = Add`, and anything else falls back to Mix (the runtime
/// says so, and ForGodot agrees). Passing it through [blendModeFor] would
/// read 1 as `BlendType.Mul` and silently turn every additive particle into a
/// multiply, so the two mappings stay separate on purpose.
///
/// The additive row is `(ONE, ONE, ONE, ONE)` upstream — alpha adds too, unlike
/// the batch-level Add, whose alpha stays on source-over — and `plus` is exactly
/// that on all four channels.
ui.BlendMode effectBlendModeFor(int blend) =>
    blend == 1 ? ui.BlendMode.plus : ui.BlendMode.srcOver;

/// Shader-side PartColor coefficient row for [type]: the
/// `_PartColorCoef` table `(fSrc, fDst, fDstSrc/mulFlag, 0)`. The `partcolor.frag`
/// shader combines it with the per-fragment `rate` into
/// `varg = (1 + fSrc·rate, fDst·rate, fDstSrc, pma)` and evaluates
/// `pixel·varg.x + mix(1, pixel, varg.z)·color·varg.y`.
///
/// Only **Mix / Mul / Add / Sub** are valid PartColor modes; every other
/// `BlendType` (those are framebuffer-composite modes) clamps to **Mix**.
/// Passing this row as a per-part uniform keeps the shader branch- and
/// index-free (no dynamic array lookup in GLSL).
List<double> partColorCoef(fbs.BlendType type) {
  switch (type) {
    case fbs.BlendType.Mul:
      return const [-1.0, 1.0, 1.0, 0.0];
    case fbs.BlendType.Add:
      return const [0.0, 1.0, 0.0, 0.0];
    case fbs.BlendType.Sub:
      return const [0.0, -1.0, 0.0, 0.0];
    case fbs.BlendType.Mix:
    default:
      return const [-1.0, 1.0, 0.0, 0.0];
  }
}
