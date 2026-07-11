import 'dart:typed_data';
import 'dart:ui' as ui;

import 'ssab/framedata.g.dart' as fbs;

/// Resolves textures for the Player (design §7 / §11 / §16C).
///
/// Supplies a decoded [ui.Image] per `cellmap` texture hash and turns a
/// [fbs.DrawBatch] into the [ui.Paint] used for its `drawVertices` call
/// (framebuffer blend + texture shader).
///
/// SKELETON: image decoding and the pluggable [TextureProvider] variants
/// (embedded / asset / network, §16C) are Phase-1+ work. For now it holds a
/// hash→image map the caller populates, and maps the batch's blend type to a
/// [ui.BlendMode].
class TextureRegistry {
  TextureRegistry();

  final Map<int, ui.Image> _images = {};

  /// Registers (or replaces) the decoded image for a `cellmap` texture hash.
  /// The hash must come from `ss_runtime_hash_string` to stay consistent with
  /// the Brain — never re-implement FNV-1a on the Dart side.
  void register(int textureHash, ui.Image image) {
    _images[textureHash] = image;
  }

  ui.Image? imageFor(int textureHash) => _images[textureHash];

  void clear() => _images.clear();

  /// Builds the [ui.Paint] for a batch: framebuffer blend from [fbs.BlendType]
  /// plus (TODO) an [ui.ImageShader] for the resolved texture.
  ui.Paint paintForBatch(fbs.DrawBatch batch) {
    final paint = ui.Paint()..blendMode = blendModeFor(batch.blendType);
    final image = _images[batch.textureHash];
    if (image != null) {
      // TODO(phase1): use ui.ImageShader with the per-part UVs; drawVertices
      // then samples the texture via textureCoordinates. Placeholder keeps the
      // structure explicit.
      paint.shader = ui.ImageShader(
        image,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        _identity4x4,
      );
    }
    return paint;
  }

  /// Framebuffer blend mapping — the `paint.blendMode` for a batch's
  /// `drawVertices`. Follows the Godot flagship (`_apply_blend_material`),
  /// which supports only Mix/Add/Sub/Mul and falls back to Mix for the other
  /// SS7 modes. Straight (non-premultiplied) alpha, matching the flagship.
  ///
  ///   Mix → srcOver,  Add → plus,  Mul → multiply,  Sub → (no exact stock
  ///   mode; approximated), everything else → srcOver.
  static ui.BlendMode blendModeFor(fbs.BlendType type) {
    switch (type) {
      case fbs.BlendType.Add:
        return ui.BlendMode.plus;
      case fbs.BlendType.Mul:
        return ui.BlendMode.multiply;
      case fbs.BlendType.Sub:
        // No stock subtract BlendMode; darken is the closest approximation.
        // Pixel-exact Sub needs a custom pass (Phase-1+).
        return ui.BlendMode.darken;
      case fbs.BlendType.Mix:
      default:
        return ui.BlendMode.srcOver;
    }
  }

  static final Float64List _identity4x4 = Float64List.fromList(
    <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
  );
}
