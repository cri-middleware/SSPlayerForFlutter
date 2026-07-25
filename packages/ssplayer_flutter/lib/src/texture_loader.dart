import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'ssab/ssab.g.dart' as ssab;
import 'texture_registry.dart';

/// Result of a texture-load pass: cellmap image paths that could not be
/// resolved (neither embedded nor found as an asset). Empty on full success.
class TextureLoadReport {
  const TextureLoadReport(this.unresolved);
  final List<String> unresolved;
  bool get isComplete => unresolved.isEmpty;
}

/// Loads a `.ssab`'s cellmap textures into a [TextureRegistry], supporting BOTH
/// texture-supply modes (design §16C; like SSPlayerForWeb):
///
///  * **embedded** — the image bytes live in `SsAnimeBinary.embeddedAssets`
///    keyed by `cellmap.imagePathHash`. Self-contained, no missing-file risk.
///  * **reference** — the cellmap names a sibling image file
///    (`cellmap.imagePath`) resolved from the Flutter asset bundle under
///    [baseAssetDir]. Enables atlas sharing / runtime swap (skins, DL).
///
/// Routing is per-cellmap: embedded wins when present, otherwise the reference
/// path is tried. Each decoded [ui.Image] is registered under
/// `cellmap.nameHash`, which equals `DrawBatch.texture_hash` — so no Dart-side
/// re-hashing (which would risk diverging from the Brain's FNV-1a).
class SsTextureLoader {
  /// Decodes and registers every cellmap texture. Cellmaps that are neither
  /// embedded nor resolvable as an asset are collected in the returned report.
  /// [claimed] deduplicates across *concurrent* sibling calls that share one
  /// registry (a root pack and its instance children, §8, routinely name the
  /// same atlas). Every call claims its hashes synchronously before the first
  /// await, so a hash decodes exactly once no matter how the loads interleave;
  /// pass the same set to each. Omit it for a standalone load.
  static Future<TextureLoadReport> load(
    TextureRegistry registry,
    Uint8List ssabBytes, {
    AssetBundle? bundle,
    String? baseAssetDir,
    Set<int>? claimed,
  }) async {
    final anime = ssab.SsAnimeBinary(ssabBytes);
    final cellmaps = anime.cellmaps ?? const <ssab.CellMap>[];
    final embedded = <int, ssab.EmbeddedAsset>{
      for (final a in anime.embeddedAssets ?? const <ssab.EmbeddedAsset>[])
        a.nameHash: a,
    };
    final bnd = bundle ?? rootBundle;
    final unresolved = <String>[];

    await Future.wait(cellmaps.map((cm) async {
      // Already brought in by a sibling pack (§8 instance children share their
      // parent's registry, and a shared atlas is the normal case). Skipping is
      // both the cheaper path and the safe one — decoding again would hand
      // `register` a second image for the same hash, disposing the first while
      // the pack that registered it is still live. The claim is synchronous, so
      // it also holds against a sibling load that has not registered yet.
      if (registry.contains(cm.nameHash)) return;
      if (claimed != null && !claimed.add(cm.nameHash)) return;
      // Sampling is a cellmap property (design §7): honour its declared filter +
      // wrap so drawVertices doesn't fall back to nearest-neighbour (jaggy).
      final filterQuality = _filterQualityFor(cm);
      final tileMode = _tileModeFor(cm);
      // 1. Embedded bytes take priority.
      final asset = embedded[cm.imagePathHash];
      final data = asset?.data;
      if (data != null && data.isNotEmpty) {
        registry.register(cm.nameHash, await decodeImage(_asBytes(data)),
            filterQuality: filterQuality, tileMode: tileMode);
        return;
      }
      // 2. Reference: resolve the sibling image from the asset bundle.
      final path = cm.imagePath;
      if (path != null && path.isNotEmpty && baseAssetDir != null) {
        final assetPath = _joinAsset(baseAssetDir, path);
        try {
          final bytes = (await bnd.load(assetPath)).buffer.asUint8List();
          registry.register(cm.nameHash, await decodeImage(bytes),
              filterQuality: filterQuality, tileMode: tileMode);
          return;
        } catch (_) {
          unresolved.add(assetPath);
          return;
        }
      }
      unresolved.add(path ?? 'cellmap#${cm.nameHash}');
    }));

    return TextureLoadReport(unresolved);
  }

  /// Cellmap `filterMode` → Flutter sampling: Nearest keeps crisp pixel-art,
  /// Linear (the SpriteStudio default) is bilinear. These are plain single-value
  /// enums, so `fromValue` is safe here (unlike the OR-combined `bit_flags`).
  static ui.FilterQuality _filterQualityFor(ssab.CellMap cm) =>
      cm.filterMode == ssab.TexFilterMode.Nearest
          ? ui.FilterQuality.none
          : ui.FilterQuality.low;

  /// Cellmap `wrapMode` → [ui.TileMode] (default Clamp).
  static ui.TileMode _tileModeFor(ssab.CellMap cm) => switch (cm.wrapMode) {
        ssab.TexWrapMode.Repeat => ui.TileMode.repeated,
        ssab.TexWrapMode.Mirror => ui.TileMode.mirror,
        ssab.TexWrapMode.Clamp => ui.TileMode.clamp,
      };

  /// Loads ONLY the embedded cellmap textures (no asset bundle access).
  static Future<TextureLoadReport> loadEmbedded(
          TextureRegistry registry, Uint8List ssabBytes) =>
      load(registry, ssabBytes);

  /// Decodes an encoded image (PNG/etc.) to a [ui.Image] via dart:ui.
  ///
  /// The codec is disposed once the frame is out: it retains the encoded bytes
  /// and any decode scratch, none of which is needed for a single-frame atlas.
  /// The returned [ui.Image] outlives it and is the caller's to release.
  static Future<ui.Image> decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  static Uint8List _asBytes(List<int> data) =>
      data is Uint8List ? data : Uint8List.fromList(data);

  static String _joinAsset(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path.substring(1) : path;
    // A derived base is empty for a root-level `.ssab`; joining must not prepend
    // a leading '/', which would miss the asset key.
    return b.isEmpty ? p : '$b/$p';
  }
}
