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

  test('part overrides reach the Brain through the component\'s player',
      () async {
    final ssabPath = _firstExisting([
      'examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
      '../../examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
      return;
    }

    // The adapter adds no override API of its own — it re-exports the core one
    // and hands out the L3 player. This asserts that path actually works from
    // Flame, including the enums coming through this package's barrel, and that
    // `onLoad`'s animation selection satisfies the override table's precondition.
    final component = SpriteStudioComponent.asset(
      ssabPath,
      bundle: _DiskBundle(),
      size: Vector2(512, 512),
    );
    addTearDown(() => component.player?.dispose());
    await component.onLoad();

    final player = component.player!;
    final apple = player.partIndexOf('apple');
    expect(apple, greaterThanOrEqualTo(0));
    expect(
        player.setPartColorOverride(apple, SsBlendOp.mul,
            const ui.Color(0xBF0033FF),
            priority: SsOverridePriority.permanent),
        isTrue);
    expect(player.setPartVisibilityOverrideByName('heta', true), isTrue);
    expect(player.clearAllPartOverrides(), isTrue);
  });

  test('SpriteStudioComponent.asset resolves textures with no baseAssetDir',
      () async {
    final ssabPath = _firstExisting([
      'examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
      '../../examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
      return;
    }

    // The asset key IS the ssab's filesystem path here, so loadAsset derives the
    // sibling-texture folder from it — no baseAssetDir passed. _DiskBundle then
    // serves `<dir>/Ringo.png` straight from disk.
    final component = SpriteStudioComponent.asset(
      ssabPath,
      bundle: _DiskBundle(),
      size: Vector2(512, 512),
    );
    addTearDown(() => component.player?.dispose());

    await component.onLoad();
    expect(component.player, isNotNull, reason: 'onLoad builds the player');
    expect(component.player!.lastTextureReport, isNotNull);
    expect(component.player!.lastTextureReport!.isComplete, isTrue,
        reason: 'derived base should resolve Ringo\'s reference textures');
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
