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

  test('zero-size component falls back to a finite, origin-centred render box',
      () async {
    // Regression: a component given no `size` has a 0×0 box, so `render` used to
    // pass an empty `dst`. The Canvas backend tolerates that (it only reads
    // `dst.center`), but the flutter_gpu backend needs a real render target and
    // drew a blank frame. `render` now sizes a fallback box from the animation's
    // authored canvas, so the point-placed (size-less) component stays visible on
    // both backends. This drives the Canvas backend (headless) and checks the
    // fallback both paints and reports a positive canvas size.
    final ssabPath = _firstExisting([
      'examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
      '../../examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
      return;
    }

    // No `size:` — the default zero box is exactly the case that regressed.
    final component = SpriteStudioComponent.asset(
      ssabPath,
      bundle: _DiskBundle(),
    );
    addTearDown(() => component.player?.dispose());
    await component.onLoad();
    for (var i = 0; i < 5; i++) {
      component.update(1 / 30);
    }

    final size = component.player!.canvasSize;
    expect(size, isNotNull,
        reason: 'the fallback box is sized from the authored canvas');
    expect(size!.width, greaterThan(0));
    expect(size.height, greaterThan(0));

    // Origin is local (0,0); centre the recorded image on it so the art (drawn
    // around the origin) lands inside the captured pixels.
    const w = 512, h = 512;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..translate(w / 2, h / 2);
    component.render(canvas);
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(); // RGBA8888

    var nonTransparent = 0;
    for (var i = 0; i + 3 < data!.lengthInBytes; i += 4) {
      if (data.getUint8(i + 3) != 0) nonTransparent++;
    }
    expect(nonTransparent, greaterThan(100),
        reason: 'the size-less component must still paint visible pixels');
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
