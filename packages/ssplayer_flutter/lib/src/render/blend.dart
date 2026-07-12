import 'dart:ui' as ui;

import '../ssab/framedata.g.dart' as fbs;

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
/// this framebuffer mapping; its coefficient table (`_PartColorCoef`) will live
/// alongside this mapping once the `FragmentProgram` path lands (Phase 2).
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
