// Headless render test: proves the Phase-1 Normal-batch path actually rasterizes
// a textured, non-blank frame (geometry bake + UV + ImageShader + drawVertices).
//
//   SSRUNTIME_LIBRARY_PATH=$PWD/native/libs/macos/libssruntime.framework/libssruntime \
//     flutter test test/render_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab/ssab.g.dart' as ssab;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('paints a non-blank, textured frame', () async {
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

    // Native assets: hook/build.dart bundles libssruntime; @Native resolves it.
    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);

    // Register the reference (sibling PNG) textures straight from disk, keyed
    // by cellmap name_hash (== DrawBatch.texture_hash).
    final anime = ssab.SsAnimeBinary(bytes);
    for (final cm in anime.cellmaps ?? const <ssab.CellMap>[]) {
      final p = cm.imagePath;
      if (p == null) continue;
      final f = File('$assetDir/$p');
      if (!f.existsSync()) continue;
      final img = await SsTextureLoader.decodeImage(
          Uint8List.fromList(f.readAsBytesSync()));
      player.textures.register(cm.nameHash, img);
    }

    expect(player.setupAnimation(anime.animations!.first.name!), isTrue);
    player.play();
    // Advance a few frames so parts are on-screen.
    for (var i = 0; i < 5; i++) {
      player.update(const Duration(milliseconds: 33));
    }

    const w = 512, h = 512;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    player.paint(canvas,
        dst: const ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
        sourceSize: const ui.Size(w * 1.0, h * 1.0));
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    final data = await image.toByteData(); // RGBA8888

    var nonTransparent = 0;
    final distinct = <int>{};
    for (var i = 0; i + 3 < data!.lengthInBytes; i += 4) {
      if (data.getUint8(i + 3) != 0) {
        nonTransparent++;
        distinct.add(data.getUint32(i));
      }
    }

    expect(nonTransparent, greaterThan(100),
        reason: 'expected visible drawn pixels');
    expect(distinct.length, greaterThan(2),
        reason: 'expected textured (non-uniform) content, not a flat fill');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
