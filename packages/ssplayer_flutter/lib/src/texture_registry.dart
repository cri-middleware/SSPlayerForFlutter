import 'dart:typed_data';
import 'dart:ui' as ui;

/// Texture store for the Player (design §7 / §11 / §16C): a `cellmap` texture
/// hash → decoded [ui.Image] map, plus a cached identity [ui.ImageShader] per
/// image for `drawVertices`. Mirrors the sibling ports' hash-keyed texture map
/// (Godot `_textures`, Web `IResourceManager.getTexture`, Unity material map).
///
/// The hash must come from `ss_runtime_hash_string` / `cellmap.name_hash` (==
/// `DrawBatch.texture_hash`) — never re-implement FNV-1a on the Dart side.
///
/// Framebuffer blend selection and `Paint` construction are *render* concerns
/// that live on the render side (`render/blend.dart` + the internal player), not
/// here — this class only resolves textures. [SsTextureLoader] populates it
/// (embedded + reference modes, §16C).
class TextureRegistry {
  TextureRegistry();

  final Map<int, ui.Image> _images = {};
  final Map<int, _Sampling> _sampling = {};
  final Map<int, ui.ImageShader> _shaders = {};

  /// Registers (or replaces) the decoded image for a `cellmap` texture hash,
  /// together with the cellmap's declared sampling (design §7): [filterQuality]
  /// maps the cellmap `filterMode` (Nearest → [ui.FilterQuality.none], Linear →
  /// [ui.FilterQuality.low] bilinear) and [tileMode] its `wrapMode`
  /// (Clamp/Repeat/Mirror). Baked into the [ui.ImageShader] so `drawVertices`
  /// honours it — otherwise the shader inherits `Paint.filterQuality`, which
  /// defaults to [ui.FilterQuality.none] and makes every scaled/rotated sprite
  /// jaggy. Defaults match the SpriteStudio project defaults (bilinear + clamp).
  void register(
    int textureHash,
    ui.Image image, {
    ui.FilterQuality filterQuality = ui.FilterQuality.low,
    ui.TileMode tileMode = ui.TileMode.clamp,
  }) {
    _images[textureHash] = image;
    _sampling[textureHash] = _Sampling(filterQuality, tileMode);
    _shaders.remove(textureHash); // invalidate any stale cached shader
  }

  ui.Image? imageFor(int textureHash) => _images[textureHash];

  /// The identity-matrix [ui.ImageShader] for a texture hash (cached), or null
  /// when no image is registered. `drawVertices` samples it in image-pixel
  /// space, so the Brain's texture-pixel UVs are passed straight through (§7C).
  /// Tile mode + filter quality come from the cellmap via [register].
  ui.ImageShader? shaderFor(int textureHash) {
    final cached = _shaders[textureHash];
    if (cached != null) return cached;
    final image = _images[textureHash];
    if (image == null) return null;
    final s = _sampling[textureHash] ?? const _Sampling.defaults();
    return _shaders[textureHash] = ui.ImageShader(
      image,
      s.tileMode,
      s.tileMode,
      _identity4x4,
      filterQuality: s.filterQuality,
    );
  }

  void clear() {
    _images.clear();
    _sampling.clear();
    _shaders.clear();
  }

  static final Float64List _identity4x4 = Float64List.fromList(
    <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
  );
}

/// A cellmap's per-texture sampling, baked into its cached [ui.ImageShader].
class _Sampling {
  const _Sampling(this.filterQuality, this.tileMode);
  const _Sampling.defaults()
      : filterQuality = ui.FilterQuality.low,
        tileMode = ui.TileMode.clamp;

  final ui.FilterQuality filterQuality;
  final ui.TileMode tileMode;
}
