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
  static Future<TextureLoadReport> load(
    TextureRegistry registry,
    Uint8List ssabBytes, {
    AssetBundle? bundle,
    String? baseAssetDir,
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
      // 1. Embedded bytes take priority.
      final asset = embedded[cm.imagePathHash];
      final data = asset?.data;
      if (data != null && data.isNotEmpty) {
        registry.register(cm.nameHash, await decodeImage(_asBytes(data)));
        return;
      }
      // 2. Reference: resolve the sibling image from the asset bundle.
      final path = cm.imagePath;
      if (path != null && path.isNotEmpty && baseAssetDir != null) {
        final assetPath = _joinAsset(baseAssetDir, path);
        try {
          final bytes = (await bnd.load(assetPath)).buffer.asUint8List();
          registry.register(cm.nameHash, await decodeImage(bytes));
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

  /// Loads ONLY the embedded cellmap textures (no asset bundle access).
  static Future<TextureLoadReport> loadEmbedded(
          TextureRegistry registry, Uint8List ssabBytes) =>
      load(registry, ssabBytes);

  /// Decodes an encoded image (PNG/etc.) to a [ui.Image] via dart:ui.
  static Future<ui.Image> decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  static Uint8List _asBytes(List<int> data) =>
      data is Uint8List ? data : Uint8List.fromList(data);

  static String _joinAsset(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path.substring(1) : path;
    return '$b/$p';
  }
}
