// Runtime texture replacement (a Player-side override): ForGodot's
// `set_cellmap_texture`, ported. Four layers, from pure to end-to-end:
//
//   1. [TextureRegistry]   — override wins over the original; restore falls back
//                            to it; the override image is never disposed by us;
//                            a swap retires (and later frees) the stale shader.
//   2. [SsTextureLoader]   — BOTH hash spaces load: cellmap name AND the
//                            external-texture file name (what a TextureChange
//                            binds). Second-space entries load silently.
//   3. [SsAnimeInfo]       — name→hash resolves across both spaces; enumeration.
//   4. end-to-end (Canvas) — a real pack: override a cellmap → the frame's pixels
//                            change; restore → they come back. Skips without the
//                            deployed Basic.ssab.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab/ssab.g.dart' as ssabr;
// Re-exports the .ssab readers plus the flatc write-side ObjectBuilders that
// live outside lib/ (see scripts/strip_fbs_builders.dart).
import 'support/ssab_builders.g.dart' as ssab;

// Hashes are the pre-baked `name_hash`es; the test controls them directly, so
// they need only be distinct, non-zero, and consistent between the two tables.
const _commonNameHash = 0x11111111; // fnv1a("common")     — cellmap name space
const _commonImgHash = 0x22222222; //  fnv1a("common.png") — the image path hash
const _extNameHash = 0x33333333; //    fnv1a("costume.png")— external-tex space

/// A solid-colour PNG of [w]×[h] — real encoded bytes, so the loader's
/// `instantiateImageCodec` path is exercised, not just a hand-built image.
Future<Uint8List> _png(int w, int h, ui.Color color) async {
  final image = await _image(w, h, color);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// A decoded solid-colour image (a stand-in for a caller-supplied override).
Future<ui.Image> _image(int w, int h, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = color);
  return recorder.endRecording().toImage(w, h);
}

/// A pack with a cellmap `common` and an external texture `costume.png`, both
/// supplied as EMBEDDED bytes so the loader needs no asset bundle.
Future<Uint8List> _buildSsab() async {
  final cellPng = await _png(2, 2, const ui.Color(0xFF0000FF));
  final extPng = await _png(2, 2, const ui.Color(0xFF00FF00));
  return ssab.SsAnimeBinaryObjectBuilder(
    name: 'pack',
    cellmaps: [
      ssab.CellMapObjectBuilder(
        nameHash: _commonNameHash,
        name: 'common',
        imagePath: 'common.png',
        imagePathHash: _commonImgHash,
      ),
    ],
    externalTextures: [
      ssab.ExternalTextureObjectBuilder(
          nameHash: _extNameHash, name: 'costume.png'),
    ],
    embeddedAssets: [
      // Cellmap image: keyed by imagePathHash (same as the reader's lookup).
      ssab.EmbeddedAssetObjectBuilder(
          nameHash: _commonImgHash, name: 'common.png', data: cellPng),
      // External texture: keyed by its own name_hash.
      ssab.EmbeddedAssetObjectBuilder(
          nameHash: _extNameHash, name: 'costume.png', data: extPng),
    ],
  ).toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TextureRegistry override / restore', () {
    late TextureRegistry registry;
    late ui.Image original;
    late ui.Image replacement;

    setUp(() async {
      registry = TextureRegistry();
      original = await _image(4, 4, const ui.Color(0xFF112233));
      replacement = await _image(4, 4, const ui.Color(0xFFAABBCC));
      registry.register(_commonNameHash, original);
    });

    tearDown(() {
      // The registry owns `original`; `replacement` is ours to release.
      registry.dispose();
      if (!replacement.debugDisposed) replacement.dispose();
    });

    test('override wins; restore falls back to the loaded original', () {
      expect(registry.imageFor(_commonNameHash), same(original));
      expect(registry.hasOverride(_commonNameHash), isFalse);

      registry.setOverride(_commonNameHash, replacement);
      expect(registry.imageFor(_commonNameHash), same(replacement));
      expect(registry.overrideImageFor(_commonNameHash), same(replacement));
      expect(registry.hasOverride(_commonNameHash), isTrue);

      expect(registry.clearOverride(_commonNameHash), isTrue);
      expect(registry.imageFor(_commonNameHash), same(original));
      expect(registry.overrideImageFor(_commonNameHash), isNull);
      expect(registry.hasOverride(_commonNameHash), isFalse);
      // A second clear is a no-op (nothing was set).
      expect(registry.clearOverride(_commonNameHash), isFalse);
    });

    test('the override image is never disposed by the registry', () {
      registry.setOverride(_commonNameHash, replacement);
      registry.clearOverride(_commonNameHash);
      registry.setOverride(_commonNameHash, replacement); // reuse after a clear
      registry.dispose();
      // dispose() releases the original but must leave the borrowed override live.
      expect(replacement.debugDisposed, isFalse);
      expect(original.debugDisposed, isTrue);
    });

    test('a swap rebuilds the shader; retired shaders survive to flushRetired',
        () {
      final s0 = registry.shaderFor(_commonNameHash);
      expect(s0, isNotNull);

      registry.setOverride(_commonNameHash, replacement);
      final s1 = registry.shaderFor(_commonNameHash);
      expect(s1, isNotNull);
      expect(identical(s0, s1), isFalse, reason: 'override must rebuild');

      registry.clearOverride(_commonNameHash);
      final s2 = registry.shaderFor(_commonNameHash);
      expect(identical(s1, s2), isFalse, reason: 'restore must rebuild');

      // Frees the shaders retired by the two swaps; the live one keeps working.
      registry.flushRetired();
      expect(registry.shaderFor(_commonNameHash), isNotNull);
    });
  });

  group('SsTextureLoader loads both hash spaces', () {
    test('cellmap name AND external-texture file name are registered', () async {
      final bytes = await _buildSsab();
      final registry = TextureRegistry();
      addTearDown(registry.dispose);

      final report = await SsTextureLoader.loadEmbedded(registry, bytes);
      expect(report.isComplete, isTrue, reason: 'embedded: nothing unresolved');

      // Cellmap-name space and external-texture (TextureChange) space both land.
      expect(registry.contains(_commonNameHash), isTrue);
      expect(registry.contains(_extNameHash), isTrue);
      expect(registry.imageFor(_commonNameHash), isNotNull);
      expect(registry.imageFor(_extNameHash), isNotNull);
    });
  });

  group('SsAnimeInfo name resolution across the two spaces', () {
    late SsAnimeInfo info;
    setUp(() async => info = SsAnimeInfo(await _buildSsab()));

    test('enumeration lists cellmaps then external textures', () {
      expect(info.cellmapNames, ['common']);
      expect(info.externalTextureNames, ['costume.png']);
      expect(info.replaceableTextureNames, ['common', 'costume.png']);
    });

    test('textureHashForName resolves cellmap first, then external', () {
      expect(info.textureHashForName('common'), _commonNameHash);
      expect(info.textureHashForName('costume.png'), _extNameHash);
      expect(info.textureHashForName('nope'), isNull);
      expect(info.cellmapTextureHash('common'), _commonNameHash);
      expect(info.cellmapTextureHash('costume.png'), isNull);
    });
  });

  group('end-to-end (Canvas): a swap changes the frame, restore undoes it', () {
    test('override a cellmap texture and restore it', () async {
      final ssabPath = _firstExisting([
        'examples/overall/assets/spritestudio/overall/Basic.ssab',
        '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
      ]);
      if (ssabPath == null) {
        markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
        return;
      }
      final assetDir = ssabPath.substring(0, ssabPath.lastIndexOf('/'));
      final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());

      final player = SpriteStudioInternalPlayer.load(
        bytes,
        backend: SpriteStudioBackend.canvas, // no Impeller device in `flutter test`
      );
      addTearDown(player.dispose);

      final anime = ssabr.SsAnimeBinary(bytes);
      for (final cm in anime.cellmaps ?? const <ssabr.CellMap>[]) {
        final p = cm.imagePath;
        if (p == null) continue;
        final f = File('$assetDir/$p');
        if (!f.existsSync()) continue;
        player.textures.register(cm.nameHash,
            await SsTextureLoader.decodeImage(Uint8List.fromList(f.readAsBytesSync())));
      }

      final info = SsAnimeInfo(bytes);
      final cellmap = info.cellmapNames.first;
      final hash = info.textureHashForName(cellmap)!;

      expect(player.setupAnimation(anime.animations!.first.name!), isTrue);
      player.play();
      for (var i = 0; i < 5; i++) {
        player.update(const Duration(milliseconds: 33));
      }

      final base = await _snapshot(player);
      expect(base.isNotEmpty, isTrue, reason: 'expected a drawn frame');

      // Swap the whole cellmap for solid magenta — the same frame now samples it.
      final magenta = await _image(1024, 1024, const ui.Color(0xFFFF00FF));
      addTearDown(() {
        if (!magenta.debugDisposed) magenta.dispose();
      });
      expect(player.setCellmapTexture(hash, magenta), isTrue);
      final swapped = await _snapshot(player);
      expect(swapped, isNot(base), reason: 'the swap must change the pixels');

      // Restore: null reverts to the loaded original, pixel-for-pixel.
      expect(player.setCellmapTexture(hash, null), isTrue);
      final restored = await _snapshot(player);
      expect(restored, base, reason: 'restore must reproduce the original frame');
    });
  });
}

/// Paints [player] once and returns the RGBA bytes — a comparable frame snapshot.
Future<Uint8List> _snapshot(SpriteStudioInternalPlayer player) async {
  const w = 256, h = 256;
  final recorder = ui.PictureRecorder();
  player.paint(ui.Canvas(recorder),
      dst: const ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
      sourceSize: const ui.Size(w * 1.0, h * 1.0));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData();
  image.dispose();
  return data!.buffer.asUint8List();
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
