import 'package:ssruntime_dart/framedata.dart' as fbs;
import 'blend.dart' show partColorCoef;

/// One corner's PartColor sample (parts_color §1-3): a straight-alpha colour in
/// 0..1 plus the blend `rate` (composite strength, §1-3).
///
/// The alpha channel already has the part's hierarchical opacity **pre-folded in
/// by the Brain** — do NOT re-multiply `PartState.alpha` on the PartColor path
/// (§1-3 / the sibling ports agree). It is the `texel.a × color.a` factor.
class PartColorCorner {
  const PartColorCorner(this.r, this.g, this.b, this.a, this.rate);

  final double r;
  final double g;
  final double b;
  final double a;
  final double rate;
}

/// A part's resolved PartColor (parts_color §1): the shader-side blend
/// [coef]ficient row plus the four corner colours (`lt,rt,lb,rb`).
///
/// Read from `FrameData.parts_color[part.part_color]`; a part with no PartColor
/// (`part_color < 0`) yields `null` and keeps the plain textured path. The
/// coefficient row (from [partColorCoef]) already clamps invalid `blend_type`s
/// to Mix, so this type carries only the four PartColor-valid modes.
///
/// **Normal** parts use all four corners individually (a bilinear gradient
/// across the quad). Mesh (whole-only) and Shape (rate forced to 1, formula
/// bypassed) parts live on their own `DrawBatch` kinds and are handled when
/// those kinds are ported — this reader serves the Normal path.
class PartColor {
  const PartColor({
    required this.coef,
    required this.lt,
    required this.rt,
    required this.lb,
    required this.rb,
  });

  /// `(fSrc, fDst, fDstSrc/mulFlag, 0)` — see [partColorCoef].
  final List<double> coef;
  final PartColorCorner lt;
  final PartColorCorner rt;
  final PartColorCorner lb;
  final PartColorCorner rb;

  /// Resolves the PartColor for [part], or null when it has none.
  ///
  /// Guarded by `part.part_color >= 0` (the sibling ports' `hasPc` test) rather
  /// than `update_flag` — reading the raw `update_flag` bitfield is the only safe
  /// way to test it (the generated `bit_flags` enum throws on OR-combined
  /// values), and the index alone is an equivalent, simpler signal.
  static PartColor? read(fbs.FrameData frameData, fbs.PartState part) {
    final idx = part.partColor;
    if (idx < 0) return null;
    final table = frameData.partsColor;
    if (table == null || idx >= table.length) return null;
    final pc = table[idx];
    return PartColor(
      coef: partColorCoef(pc.blendType),
      lt: _corner(pc.lt),
      rt: _corner(pc.rt),
      lb: _corner(pc.lb),
      rb: _corner(pc.rb),
    );
  }

  // `U8Rect` is stored A,R,G,B (alpha first); normalise each channel to 0..1.
  static PartColorCorner _corner(fbs.SsAttributePartColorKeyValueColor c) {
    final u = c.rgba;
    return PartColorCorner(
      u.r / 255.0,
      u.g / 255.0,
      u.b / 255.0,
      u.a / 255.0,
      c.rate,
    );
  }
}
