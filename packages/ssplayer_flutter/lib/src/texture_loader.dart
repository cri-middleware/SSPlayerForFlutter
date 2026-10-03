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
/// texture-supply modes (like SSPlayerForWeb):
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
///
/// It then loads `external_textures()` the same way, keyed by their own
/// `name_hash`: the second hash space `texture_hash` spans (a TextureChange binds
/// the texture *file* name, `fnv1a("common.png")`, not the cellmap name). That
/// pass is silent best-effort — the converter fills the list with a superset of
/// names, so a missing one is not a load error (see [load]).
class SsTextureLoader {
  /// Decodes and registers every cellmap texture. Cellmaps that are neither
  /// embedded nor resolvable as an asset are collected in the returned report.
  ///
  /// A cellmap already in [registry] is skipped, so several packs sharing one
  /// registry (a root and its instance children routinely name the same
  /// atlas) decode it once. That only holds if the calls are *sequenced* — see
  /// the caller in `player.dart`; two concurrent calls would both find the
  /// registry empty.
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
      // Already brought in by a pack loaded before this one (instance children
      // share their parent's registry, and a shared atlas is the normal case).
      // Skipping is both the cheaper path and the safe one — decoding again would
      // hand `register` a second image for the same hash, disposing the first
      // while the pack that registered it is still live.
      //
      // Deliberately keyed on "is it registered", not on "has someone claimed
      // it": a claim taken before the decode has to be released when the decode
      // fails, and by then a sibling that skipped on the claim is already gone —
      // so a cellmap this pack cannot resolve but the next one could (embedded
      // here, referenced there) would be lost entirely. A missing atlas is
      // silent for a mask writer, which is dropped rather than drawn wrong.
      if (registry.contains(cm.nameHash)) return;
      // Wrap is a cellmap property. The filter is not: it is the registry's
      // (bilinear unless the app registers the atlas itself), and the
      // SpriteStudio setting in `filterMode` is deliberately not read — the
      // Porting Guide leaves filtering to the engine.
      final tileMode = _tileModeFor(cm);
      // 1. Embedded bytes take priority.
      final asset = embedded[cm.imagePathHash];
      final data = asset?.data;
      if (data != null && data.isNotEmpty) {
        registry.register(cm.nameHash, await decodeImage(_asBytes(data)),
            tileMode: tileMode);
        return;
      }
      // 2. Reference: resolve the sibling image from the asset bundle.
      final path = cm.imagePath;
      if (path != null && path.isNotEmpty && baseAssetDir != null) {
        final assetPath = _joinAsset(baseAssetDir, path);
        try {
          final bytes = (await bnd.load(assetPath)).buffer.asUint8List();
          registry.register(cm.nameHash, await decodeImage(bytes),
              tileMode: tileMode);
          return;
        } catch (_) {
          unresolved.add(assetPath);
          return;
        }
      }
      unresolved.add(path ?? 'cellmap#${cm.nameHash}');
    }));

    // Also load `external_textures()` — the SECOND hash space `texture_hash`
    // spans: a TextureChange (`TCHG`) binds the
    // texture FILE name's hash (`fnv1a("common.png")`), a different key from the
    // cellmap name's (`fnv1a("common")`). Both must be in the one map or a TCHG
    // frame — and any runtime replacement of that file — resolves to nothing.
    //
    // Best-effort and SILENT (not added to [unresolved]): the converter fills
    // this list with every name a TCHG can select, INCLUDING each cellmap's own
    // image, so most entries are duplicates or optional. A genuinely missing one
    // is simply not replaceable, which is not a load failure — unlike a cellmap,
    // whose absence leaves a part untextured.
    await Future.wait((anime.externalTextures ?? const <ssab.ExternalTexture>[])
        .map((ext) async {
      if (registry.contains(ext.nameHash)) return;
      // Embedded bytes are keyed by name hash, same as a cellmap's image.
      final data = embedded[ext.nameHash]?.data;
      if (data != null && data.isNotEmpty) {
        registry.register(ext.nameHash, await decodeImage(_asBytes(data)));
        return;
      }
      // Reference: the external texture's own name is the sibling file name.
      final name = ext.name;
      if (name != null && name.isNotEmpty && baseAssetDir != null) {
        try {
          final assetPath = _joinAsset(baseAssetDir, name);
          final bytes = (await bnd.load(assetPath)).buffer.asUint8List();
          registry.register(ext.nameHash, await decodeImage(bytes));
        } catch (_) {
          // Silent: a superset entry, not a shippable requirement.
        }
      }
    }));

    return TextureLoadReport(unresolved);
  }

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
