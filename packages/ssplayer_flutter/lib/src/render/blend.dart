import 'dart:ui' as ui;

import 'package:ssruntime_dart/framedata.dart' as fbs;

/// Framebuffer blend mapping (design §7B): the `Paint.blendMode` used for a
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
/// *exact* stock equivalent (verified component-wise; the alpha channel matches too
/// because these modes composite alpha as source-over, and SS renders onto an opaque
/// target where `Cb`'s alpha is 1):
///
///   * Mix       → `srcOver`   (`Cs + Cb·(1-αs)`)
///   * Add       → `plus`      (`Cs + Cb`, both clamp)
///   * Mul/α/2   → `multiply`  (`Cs·Cb + Cb·(1-αs)`, Skia's premult multiply)
///   * Screen/2  → `screen`    (`Cs + Cb - Cs·Cb`)
///   * Exclusion → `exclusion` (`Cs + Cb - 2·Cs·Cb`)
///
/// Two rows have **no stock equivalent** — Flutter's fixed blend enum offers
/// neither a reverse-subtract nor a "replace dst with `Cs·(1-Cb)`" — so they fall
/// back to `difference` (`|Cs - Cb|`), the closest honest approximation:
///
///   * Sub    (`max(0, Cb - Cs)`)  → `difference` is exact wherever `Cb ≥ Cs`
///     (the darkening regime Sub targets) and only diverges — giving `Cs - Cb`
///     instead of clamping to black — in the opposite regime. Strictly closer than
///     `darken` (`min(Cs, Cb)`), which is wrong across the whole range.
///   * Invert (`Cs·(1-Cb)`)        → `difference` is *exact* for the white/opaque
///     overlay these inversions are authored with (`|1 - Cb| = 1 - Cb`), diverging
///     only for a partial/coloured source. Pixel-exact Sub/Invert would need a
///     framebuffer read-back pass Flutter's immediate-mode canvas can't cheaply do.
///
/// Div2 / Overlay2 have no GL mapping in ssplayer-webgl either (its `default`
/// clamps them to Mix), so they follow suit → `srcOver`.
///
/// The 4-mode **PartColor** blend (§10) is a *shader-side* concern, unrelated to
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
      // approximation (exact for the darkening / opaque-overlay case each targets).
      return ui.BlendMode.difference;
    case fbs.BlendType.Mix:
    case fbs.BlendType.Div2: // no GL mapping upstream → Mix
    case fbs.BlendType.Overlay2: // no GL mapping upstream → Mix
      return ui.BlendMode.srcOver;
  }
}

/// Framebuffer blend mapping for an `EffectDrawCommand.blend` (§8).
///
/// **Not** the [fbs.BlendType] enum — an emitter's blend is the SS6-style raw
/// byte `0 = Mix`, `1 = Add`, and anything else falls back to Mix (the runtime
/// says so, and the flagship agrees). Passing it through [blendModeFor] would
/// read 1 as `BlendType.Mul` and silently turn every additive particle into a
/// multiply, so the two mappings stay separate on purpose.
ui.BlendMode effectBlendModeFor(int blend) =>
    blend == 1 ? ui.BlendMode.plus : ui.BlendMode.srcOver;

/// Shader-side PartColor coefficient row for [type] (parts_color §1-4): the
/// `_PartColorCoef` table `(fSrc, fDst, fDstSrc/mulFlag, 0)`. The `partcolor.frag`
/// shader combines it with the per-fragment `rate` into
/// `varg = (1 + fSrc·rate, fDst·rate, fDstSrc, pma)` and evaluates
/// `pixel·varg.x + mix(1, pixel, varg.z)·color·varg.y`.
///
/// Only **Mix / Mul / Add / Sub** are valid PartColor modes; every other
/// `BlendType` (those are framebuffer-composite modes) clamps to **Mix** (§1-1).
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
