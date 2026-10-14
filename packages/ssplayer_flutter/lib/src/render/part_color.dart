import 'package:ssruntime_dart/framedata.dart' as fbs;
import 'blend.dart' show partColorCoef;

/// One corner's PartColor sample: a straight-alpha colour in
/// 0..1 plus the blend `rate` (composite strength).
///
/// The alpha channel already has the part's hierarchical opacity **pre-folded in
/// by the Brain** — do NOT re-multiply `PartState.alpha` on the PartColor path
/// (the sibling ports agree). It is the `texel.a × color.a` factor.
class PartColorCorner {
  const PartColorCorner(this.r, this.g, this.b, this.a, this.rate);

  /// This corner with its alpha replaced by [alpha] (RGB and `rate` untouched).
  PartColorCorner withAlpha(double alpha) =>
      PartColorCorner(r, g, b, alpha.clamp(0.0, 1.0), rate);

  final double r;
  final double g;
  final double b;
  final double a;
  final double rate;
}

/// A part's resolved PartColor: the shader-side blend
/// [coef]ficient row plus the four corner colours (`lt,rt,lb,rb`).
///
/// Read from `FrameData.parts_color[part.part_color]`; a part with no PartColor
/// (`part_color < 0`) yields `null` and keeps the plain textured path. The
/// coefficient row (from [partColorCoef]) already clamps invalid `blend_type`s
/// to Mix, so this type carries only the four PartColor-valid modes.
///
/// **Normal** parts use all four corners individually (a gradient across the
/// part's fan of four triangles, whose centre takes the corners' average);
/// **Shape** bypasses the formula (rate forced to 1, baked
/// straight into the vertex colour); **Mesh** is *whole-only* — the `lt` corner
/// applies to every vertex, which is what [wholeTintMatrix] evaluates. An
/// Instance part's PartColor does not tint its child subtree; only its `lt`
/// alpha crosses ([instanceAlpha]).
class PartColor {
  const PartColor({
    required this.coef,
    required this.lt,
    required this.rt,
    required this.lb,
    required this.rb,
  });

  /// The no-op PartColor: white corners at `rate` 0, which the shader's formula
  /// collapses to a plain texel passthrough (default white, rate 0 = passthrough).
  ///
  /// Fully opaque — prefer [passthrough], which carries the part's alpha, unless
  /// you specifically want α = 1.
  static const PartColor identity = PartColor(
    coef: <double>[-1.0, 1.0, 0.0, 0.0], // Mix
    lt: _white,
    rt: _white,
    lb: _white,
    rb: _white,
  );

  /// The no-op PartColor at [alpha] — the default for a part with no
  /// PartColor: vertex colour = white (alpha = hierarchical alpha), rate = 0.
  ///
  /// Used when a part must go through the fragment shader for a reason other
  /// than PartColor — a mask test, or an instance child's alpha — so
  /// that peeling it off the batched path does not change its colours. [alpha]
  /// must be supplied because the shader's `a = texel.a * col.a` has no
  /// `PartState.alpha` term of its own: on the *PartColor* path the Brain has
  /// pre-folded the hierarchical alpha into `rgba.a` (never re-multiply
  /// it), but on this path there is no such value to inherit, so passing the
  /// shared α=1 [identity] here silently renders the part fully opaque.
  static PartColor passthrough(double alpha) => PartColor(
        coef: const <double>[-1.0, 1.0, 0.0, 0.0], // Mix
        lt: _white.withAlpha(alpha),
        rt: _white.withAlpha(alpha),
        lb: _white.withAlpha(alpha),
        rb: _white.withAlpha(alpha),
      );

  /// This PartColor with every corner's alpha scaled by [scale].
  ///
  /// The one legitimate reason to touch a Brain-supplied corner alpha: an
  /// instance child is modulated by its instance part's alpha, which the
  /// Brain cannot know about because it lives in the *parent's* FrameData. RGB
  /// and `rate` are untouched, matching ForGodot's alpha-only
  /// `Color(1, 1, 1, part_alpha)` modulate.
  PartColor scaleAlpha(double scale) => scale == 1.0
      ? this
      : PartColor(
          coef: coef,
          lt: lt.withAlpha(lt.a * scale),
          rt: rt.withAlpha(rt.a * scale),
          lb: lb.withAlpha(lb.a * scale),
          rb: rb.withAlpha(rb.a * scale),
        );

  /// The alpha an Instance part hands down to its child sub-animation.
  ///
  /// Without a PartColor that is the part's own composed alpha ([partAlpha],
  /// which `DrawFrame.alphaOf` already folded the chain's [chainScale] into).
  /// **With** one it is the tint's `lt` alpha instead — the Brain pre-folds the
  /// part's hierarchical alpha into the corner alphas, so using both
  /// would apply it twice — times the chain scale, which lives in the *parent's*
  /// FrameData and so cannot have been pre-folded.
  static double instanceAlpha(PartColor? pc,
          {required double partAlpha, required double chainScale}) =>
      pc == null ? partAlpha : (pc.lt.a * chainScale).clamp(0.0, 1.0);

  /// The formula as a row-major 4×5 `ColorFilter.matrix`, evaluated from
  /// the **`lt`** corner — the *Whole-only* rule a Mesh part follows
  /// (Mesh = same value on every vertex).
  ///
  /// Where a Normal part needs a fragment shader (four corners, so the tint
  /// varies per fragment), a whole-part tint is one affine on rgb — exactly what
  /// a colour matrix is. Reading the shader's
  /// `rgb = pixel·vx + mix(1, pixel, vz)·color·vy` with `vx = 1 + coef₀·rate`,
  /// `vy = coef₁·rate`, `vz = coef₂` (0 for Mix/Add/Sub, 1 for Mul) as
  /// `rgb = scaleᶜ·pixelᶜ + offsetᶜ`:
  ///
  ///   * `vz == 0` (Mix / Add / Sub): `scale = vx`, `offset = colourᶜ·vy`
  ///   * `vz == 1` (Mul): `scale = vx + colourᶜ·vy`, `offset = 0`
  ///
  /// The alpha row is the identity: on this path α travels with the geometry
  /// (the vertex colour for a Mesh, [scaleAlpha] down the chain for an Instance)
  /// exactly as `a = texel.a · col.a` does in the shader — folding it in here
  /// too would double-apply it.
  ///
  /// Returns null when the tint is a no-op (`rate == 0`, i.e. the default
  /// passthrough) so the caller can stay on the plain, un-filtered path.
  ///
  /// One nuance vs `shaders/partcolor.frag`: the shader clamps the straight rgb
  /// to `[0,1]` *before* premultiplying, while a colour filter's clamp happens
  /// as the (premultiplied) result is stored. The two agree except for an
  /// **Add/Sub** tint that overflows on a *partially transparent* texel; that
  /// combination is the one place the Mesh path is not bit-identical to a Normal
  /// part's shader.
  List<double>? wholeTintMatrix() {
    final rate = lt.rate;
    if (rate == 0.0) return null; // default: white × rate 0 == passthrough
    final vx = 1.0 + coef[0] * rate;
    final vy = coef[1] * rate;
    final mul = coef[2]; // 1 for Mul (the colour scales the pixel), else 0
    double scale(double c) => vx + mul * c * vy;
    // ColorFilter.matrix' translation column is in unnormalised 0..255 space.
    double offset(double c) => (1.0 - mul) * c * vy * 255.0;
    return <double>[
      scale(lt.r), 0, 0, 0, offset(lt.r), //
      0, scale(lt.g), 0, 0, offset(lt.g), //
      0, 0, scale(lt.b), 0, offset(lt.b), //
      0, 0, 0, 1, 0, //
    ];
  }

  static const PartColorCorner _white = PartColorCorner(1.0, 1.0, 1.0, 1.0, 0.0);

  /// `(fSrc, fDst, fDstSrc/mulFlag, 0)` — see [partColorCoef].
  final List<double> coef;
  final PartColorCorner lt;
  final PartColorCorner rt;
  final PartColorCorner lb;
  final PartColorCorner rb;

  /// Resolves the PartColor for [part] against [partsColor] (the frame's
  /// `FrameData.parts_color` vector), or null when it has none.
  ///
  /// The caller passes the **already-fetched** vector rather than a `FrameData`
  /// so it can be fetched ONCE per frame: `frameData.partsColor` builds a fresh
  /// lazy list wrapper — and a full-length backing cache on first index — every
  /// call, so re-fetching it here per part churned `O(pcParts × total)` throwaway
  /// arrays each frame. `DrawFrame.partsColor` caches it; hand that in.
  ///
  /// Guarded by `part.part_color >= 0` (the sibling ports' `hasPc` test) rather
  /// than `update_flag` — reading the raw `update_flag` bitfield is the only safe
  /// way to test it (the generated `bit_flags` enum throws on OR-combined
  /// values), and the index alone is an equivalent, simpler signal.
  static PartColor? read(
      List<fbs.PartAttributePartColor>? partsColor, fbs.PartState part) {
    final idx = part.partColor;
    if (idx < 0) return null;
    if (partsColor == null || idx >= partsColor.length) return null;
    final pc = partsColor[idx];
    return PartColor(
      coef: partColorCoef(pc.blendType),
      lt: _corner(pc.lt),
      rt: _corner(pc.rt),
      lb: _corner(pc.lb),
      rb: _corner(pc.rb),
    );
  }

  // `U8Color` is stored A,R,G,B (alpha first); normalise each channel to 0..1.
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
