import 'dart:ui' as ui;

import 'package:ssruntime_dart/framedata.dart' as fbs;

/// Framebuffer blend mapping (design §7B): the `Paint.blendMode` used for a
/// batch's `drawVertices`.
///
/// Ports the Godot flagship `_apply_blend_material` and the sibling blend tables
/// (Web `SSBlendModes`, Unity `SpriteStudioBlendTable`), which honor only
/// Mix/Add/Mul/Sub and fall back to Mix for the other SS7 modes. Straight
/// (non-premultiplied) alpha, matching the flagship.
///
///   Mix → srcOver,  Add → plus,  Mul → multiply,  Sub → (no exact stock mode;
///   approximated), everything else → srcOver.
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
      return ui.BlendMode.multiply;
    case fbs.BlendType.Sub:
      // No stock subtract BlendMode; darken is the closest approximation.
      // Pixel-exact Sub needs a custom pass (Phase 2).
      return ui.BlendMode.darken;
    case fbs.BlendType.Mix:
    default:
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
