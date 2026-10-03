import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show isCanvasKit, kIsWeb;

/// Texture store for the Player: a `cellmap` texture
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
/// (embedded + reference modes).
class TextureRegistry {
  TextureRegistry();

  final Map<int, ui.Image> _images = {};
  final Map<int, _Sampling> _sampling = {};
  final Map<int, ui.ImageShader> _shaders = {};

  /// Runtime texture replacements (ForGodot's
  /// `setCellMapOverrideTexture`). Keyed by the same `texture_hash` as [_images];
  /// when present, the override WINS over the loaded original in every lookup.
  ///
  /// The override images are the **caller's** — the registry borrows them and
  /// never disposes them (that would free a bitmap the app still owns and may
  /// re-use). Restoring is dropping the entry, which falls back to the original
  /// still held in [_images]: instant and infallible, where ForGodot reloads the
  /// image from its path (Flutter keeps the decoded original alive instead).
  final Map<int, ui.Image> _overrides = {};
  final Map<int, _Sampling> _overrideSampling = {};

  /// Shaders orphaned by a live override swap, disposed at the next frame's
  /// [flushRetired] rather than on the spot: a picture recorded before the swap
  /// may still reference the old shader until it rasterises. Only the
  /// registry-built [ui.ImageShader] wrapper is retired here — never the override
  /// image, which the caller owns.
  final List<ui.ImageShader> _retired = [];

  /// Registers (or replaces) the decoded image for a `cellmap` texture hash,
  /// together with its sampling: [filterQuality] is the app's choice
  /// (bilinear [ui.FilterQuality.low] by default; [ui.FilterQuality.none] for
  /// crisp pixel art), never the cellmap's `filterMode`, and [tileMode] maps the
  /// cellmap `wrapMode` (Clamp/Repeat/Mirror). Baked into the [ui.ImageShader]
  /// so `drawVertices` honours it — otherwise the shader inherits
  /// `Paint.filterQuality`, which defaults to [ui.FilterQuality.none] and makes
  /// every scaled/rotated sprite jaggy.
  ///
  /// Replacing an existing hash disposes what it replaces, so the caller must
  /// not re-register a texture that an already-recorded (but not yet rasterised)
  /// picture still draws with. Load-time registration is always safe; a live
  /// swap must go through a fresh registry, which is what [reload] does.
  void register(
    int textureHash,
    ui.Image image, {
    ui.FilterQuality filterQuality = ui.FilterQuality.low,
    ui.TileMode tileMode = ui.TileMode.clamp,
  }) {
    final previous = _images[textureHash];
    _images[textureHash] = image;
    _sampling[textureHash] = _Sampling(filterQuality, tileMode);
    // Invalidate the stale cached shader — and release it, along with the image
    // it sampled. Nothing else holds either, so dropping the reference alone
    // would leak the decoded bitmap until (if ever) the GC got to it.
    _shaders.remove(textureHash)?.dispose();
    if (previous != null && !identical(previous, image)) previous.dispose();
  }

  /// The effective image for [textureHash] — the runtime [setOverride] if one is
  /// set, otherwise the loaded original. Null when neither exists.
  ui.Image? imageFor(int textureHash) =>
      _overrides[textureHash] ?? _images[textureHash];

  /// Whether a texture is already registered for [textureHash]. Lets a loader
  /// skip re-decoding an atlas a sibling pack has already brought in (a root
  /// and its instance children routinely share one cellmap).
  bool contains(int textureHash) => _images.containsKey(textureHash);

  /// The identity-matrix [ui.ImageShader] for a texture hash (cached), or null
  /// when no image is registered. `drawVertices` samples it in image-pixel
  /// space, so the Brain's texture-pixel UVs are passed straight through.
  /// Tile mode + filter quality are the ones given to [register].
  ui.ImageShader? shaderFor(int textureHash) {
    final cached = _shaders[textureHash];
    if (cached != null) return cached;
    final image = imageFor(textureHash);
    if (image == null) return null;
    final s = _overrideSampling[textureHash] ??
        _sampling[textureHash] ??
        const _Sampling.defaults();
    return _shaders[textureHash] = ui.ImageShader(
      // CanvasKit's `ImageShader.dispose` disposes the image it was built from;
      // native and Skwasm shaders only borrow it. Handing CanvasKit a clone keeps
      // that to the shader's own handle — otherwise retiring a shader frees the
      // loaded original (the registry's own `dispose` then disposes it a second
      // time and asserts) or the caller's override image.
      kIsWeb && isCanvasKit ? image.clone() : image,
      s.tileMode,
      s.tileMode,
      _identity4x4,
      filterQuality: s.filterQuality,
    );
  }

  // --- Runtime texture replacement -----------------------------------------

  /// Sets a runtime replacement for [textureHash]: every subsequent lookup
  /// ([imageFor] / [shaderFor]) returns [image] in place of the loaded original.
  /// [image] is **not** owned by the registry — keep it alive while it is set and
  /// dispose it yourself once it is cleared or replaced.
  ///
  /// Sampling defaults to the original's ([filterQuality] / [tileMode]
  /// override it), on the same-size/same-layout-atlas assumption.
  void setOverride(
    int textureHash,
    ui.Image image, {
    ui.FilterQuality? filterQuality,
    ui.TileMode? tileMode,
  }) {
    _overrides[textureHash] = image;
    if (filterQuality != null || tileMode != null) {
      final base = _sampling[textureHash] ?? const _Sampling.defaults();
      _overrideSampling[textureHash] = _Sampling(
        filterQuality ?? base.filterQuality,
        tileMode ?? base.tileMode,
      );
    } else {
      _overrideSampling.remove(textureHash);
    }
    _retireShader(textureHash);
  }

  /// Clears the runtime replacement for [textureHash] (revert to the loaded
  /// original). Returns whether one was actually set. The override image is the
  /// caller's and is never disposed here.
  bool clearOverride(int textureHash) {
    final had = _overrides.remove(textureHash) != null;
    _overrideSampling.remove(textureHash);
    if (had) _retireShader(textureHash);
    return had;
  }

  /// Whether a runtime replacement is currently set for [textureHash].
  bool hasOverride(int textureHash) => _overrides.containsKey(textureHash);

  /// The runtime replacement set for [textureHash] (the override VALUE only,
  /// never the loaded original), or null when none is set — mirrors ForGodot's
  /// `get_cellmap_texture`.
  ui.Image? overrideImageFor(int textureHash) => _overrides[textureHash];

  /// Moves the cached shader for [hash] to the retired list (see [_retired]) so
  /// the next [shaderFor] rebuilds it against the new effective image.
  void _retireShader(int hash) {
    final s = _shaders.remove(hash);
    if (s != null) _retired.add(s);
  }

  /// Disposes shaders retired by [setOverride] / [clearOverride]. Called once per
  /// top-level frame (before the backend begins the frame), the point at which
  /// the previous frame's recorded picture is guaranteed to have rasterised — so
  /// a live swap can never dispose a shader a pending picture still reads.
  void flushRetired() {
    if (_retired.isEmpty) return;
    for (final shader in _retired) {
      shader.dispose();
    }
    _retired.clear();
  }

  /// Drops every entry **without** releasing it — for a registry whose images
  /// are owned elsewhere. Prefer [dispose] unless the caller is handing the
  /// textures on to something else.
  void clear() {
    _images.clear();
    _sampling.clear();
    _shaders.clear();
    // Overrides are borrowed (caller-owned) — drop the references, never dispose.
    _overrides.clear();
    _overrideSampling.clear();
    // Retired shaders are our own wrappers; disposing them here is always safe.
    flushRetired();
  }

  /// Releases every decoded image and cached shader, then empties the maps.
  ///
  /// A [ui.Image] holds GPU/native bitmap memory that Dart's GC does not account
  /// for, so a registry that is merely dropped leaks a full texture set — over a
  /// dev live-reload session (one registry per reload) that grows without bound.
  /// The owning player calls this from its own `dispose`; a registry supplied by
  /// the caller is the caller's to release, and instance children share their
  /// parent's and must never release it.
  ///
  /// Idempotent — safe to call twice, and safe on an already-cleared registry.
  void dispose() {
    for (final shader in _shaders.values) {
      shader.dispose();
    }
    for (final image in _images.values) {
      image.dispose();
    }
    clear();
  }

  static final Float64List _identity4x4 = Float64List.fromList(
    <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
  );
}

/// A texture's sampling, baked into its cached [ui.ImageShader].
class _Sampling {
  const _Sampling(this.filterQuality, this.tileMode);
  const _Sampling.defaults()
      : filterQuality = ui.FilterQuality.low,
        tileMode = ui.TileMode.clamp;

  final ui.FilterQuality filterQuality;
  final ui.TileMode tileMode;
}
