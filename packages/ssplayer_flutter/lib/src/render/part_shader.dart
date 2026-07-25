import 'dart:typed_data';

import 'package:ssruntime_dart/framedata.dart' as fbs;

/// One of SpriteStudio's built-in **integration shaders** (`ss-*`), the effects a
/// part carries through its `SHDR` attribute.
///
/// [hash] is the value the Brain emits as `PartAttributeShader.id_hash` — the
/// FNV-1a-32 of the shader id string, which the converter bakes in and the
/// runtime then drops the name for. The constants are **pre-baked**, exactly as
/// the texture key is (`cellmap.name_hash`): the Body never re-implements FNV-1a,
/// and these ids are stable SDK built-ins so the id ↔ hash pairing cannot drift.
/// The same table appears verbatim in the sibling ports (Web `SSShaderLib.ts`,
/// Godot `EMBEDDED_SHADERS`).
///
/// [asset] names the Canvas backend's fragment program
/// (`shaders/<asset>.frag`); the flutter_gpu backend instead selects the effect
/// inside one shared pipeline by this enum's **[index]**, which
/// `shaders/gpu/ssshader.frag`'s `SS_*` constants mirror — keep the two in the
/// same order.
enum SsShaderId {
  /// `param0` = tone strength; negative = plain greyscale.
  sepia(0x36629dfc, 'ss_sepia'),

  /// `param0/1/2` = hue rotate / saturation offset / brightness offset.
  hsb(0x8a5c3037, 'ss_hsb'),

  /// `param0/1/2` = threshold (sign = polarity) / posterise stages / mono↔rgb.
  step(0x1b721788, 'ss_step'),

  /// `param0` = block size (mosaic).
  pix(0xc488a527, 'ss_pix'),

  /// `param0/1/2` = mix amount / chroma / phase seed.
  noise(0x80d6d514, 'ss_noise'),

  /// `param0` = brightness key (sign = polarity). Cuts fragments out.
  bmask(0x64e07450, 'ss_bmask'),

  /// `param0` = alpha edge threshold. Cuts fragments out.
  outline(0x8f8307d4, 'ss_outline'),

  /// `param0` = radius. The one effect that does **not** fold the PartColor
  /// formula — it has its own output tail (`Pixel × colour`).
  blur(0xb59c8d1b, 'ss_blur'),

  /// `param0/1/2` = frequency / amplitude / phase.
  wave(0xe1df9a2b, 'ss_wave'),

  /// `param0/1/2` = distance (sign = direction) / angle / decay. Up to 128 taps.
  move(0xe1c1ee07, 'ss_move'),

  /// `param0/1/2` = displacement / affected fraction / phase seed.
  scatter(0x45e35578, 'ss_scatter'),

  /// `param0/1` = phase / direction. Polar-unwraps the cell; needs the cell rect
  /// and cuts fragments outside the disc.
  circle(0x9b90e282, 'ss_circle'),

  /// `param0/1/2` = radius / falloff / white↔texture. Needs the cell rect.
  spot(0x7140896a, 'ss_spot');

  const SsShaderId(this.hash, this.asset);

  /// `PartAttributeShader.id_hash` — see the enum docs.
  final int hash;

  /// Basename (no extension) of this effect's Canvas fragment program under
  /// `shaders/`.
  final String asset;

  static final Map<int, SsShaderId> _byHash = <int, SsShaderId>{
    for (final id in SsShaderId.values) id.hash: id,
  };

  /// The built-in for [hash], or null when the pack references a shader this
  /// player does not implement (a custom material, or SpriteStudio's `Default`
  /// passthrough). The caller then keeps the plain textured/PartColor path — the
  /// same fallback the sibling ports take.
  static SsShaderId? fromHash(int hash) => _byHash[hash];
}

/// A part's resolved shader attribute (`SHDR`): which built-in [id] to run and
/// the parameters to run it with.
///
/// Read from `FrameData.shaders[part.shader]`; a part with no shader
/// (`shader < 0`) — or one naming a shader this player does not implement —
/// yields null and keeps the plain textured/PartColor path.
///
/// The attribute is orthogonal to PartColor: a part can carry both, and every
/// effect except [SsShaderId.blur] folds the PartColor formula as its output
/// tail (see `shaders/ss_shader_common.glsl`'s `ssBlend`).
class PartShader {
  const PartShader({required this.id, required this.params});

  final SsShaderId id;

  /// `param0..param3`, in that order.
  ///
  /// The FlatBuffers struct carries eight, but **no built-in reads past
  /// `param2`** (`param3` is included only because it rounds the uniform out to
  /// one `vec4`). Surfacing `param4..7` would mean four dead floats in every
  /// shader draw's uniform block, so they are deliberately not read; add them
  /// here and to both backends' parameter blocks if a shader ever needs them.
  final Float32List params;

  /// Resolves the shader attribute for [part] against [shaders] (the frame's
  /// `FrameData.shaders` vector), or null when it has none.
  ///
  /// The caller passes the **already-fetched** vector rather than a `FrameData`
  /// so it is fetched once per frame — `DrawFrame.shaders` caches it, hand that
  /// in (same reasoning as [PartColor.read], see `part_color.dart`).
  ///
  /// Guarded by `part.shader >= 0` rather than the `AttributeShader` bit of
  /// `update_flag`: reading the raw bitfield is the only safe way to test that
  /// (the generated `bit_flags` enum throws on OR-combined values), and the
  /// index alone is an equivalent, simpler signal — exactly how the Body already
  /// tests PartColor.
  static PartShader? read(
      List<fbs.PartAttributeShader>? shaders, fbs.PartState part) {
    final idx = part.shader;
    if (idx < 0) return null;
    if (shaders == null || idx >= shaders.length) return null;
    final attr = shaders[idx];
    final id = SsShaderId.fromHash(attr.idHash);
    if (id == null) return null; // not a built-in — plain path
    return PartShader(
      id: id,
      params: Float32List(4)
        ..[0] = attr.param0
        ..[1] = attr.param1
        ..[2] = attr.param2
        ..[3] = attr.param3,
    );
  }
}
