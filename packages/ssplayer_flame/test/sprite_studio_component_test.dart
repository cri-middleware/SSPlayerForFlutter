// Headless render test for the Flame adapter: proves a SpriteStudioComponent
// loads a real .ssab, advances on the (host) clock, and rasterizes a textured,
// non-blank frame — i.e. the update→advance and render→paint bridges work end
// to end. Drives the component's own Flame lifecycle directly (onLoad / update /
// render), which needs no GameWidget / mounted FlameGame.
//
//   flutter test   (in packages/ssplayer_flame/)
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter/services.dart' show AssetBundle, CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flame/ssplayer_flame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SpriteStudioComponent loads, advances, and paints a textured frame',
      () async {
    final ssabPath = _firstExisting([
      'examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
      '../../examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
      return;
    }
    final assetDir = ssabPath.substring(0, ssabPath.lastIndexOf('/'));
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());

    // Ringo uses reference textures (sibling Ringo.png). A disk-backed bundle
    // serves them from the filesystem, so this exercises the real texture path.
    final component = SpriteStudioComponent(
      ssab: bytes,
      baseAssetDir: assetDir,
      bundle: _DiskBundle(),
      size: Vector2(512, 512),
    );
    addTearDown(() => component.player?.dispose());

    // Flame would call these from its game loop; drive them directly here.
    await component.onLoad();
    expect(component.player, isNotNull, reason: 'onLoad builds the player');
    expect(component.player!.getAnimations(), isNotEmpty);

    // External clock: `update(dt)` (seconds) is exactly what FlameGame forwards.
    for (var i = 0; i < 5; i++) {
      component.update(1 / 30);
    }
    expect(component.player!.frameNo, greaterThan(0),
        reason: 'update() should advance playback');

    const w = 512, h = 512;
    final recorder = ui.PictureRecorder();
    component.render(ui.Canvas(recorder));
    final image = await recorder.endRecording().toImage(w, h);
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
        reason: 'expected textured content, not a flat fill');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// An [AssetBundle] whose keys are filesystem paths — lets the component's
/// reference-texture loader read the sibling PNG straight from disk in a
/// headless test (mirrors the overall example's dropped-folder bundle).
class _DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}
