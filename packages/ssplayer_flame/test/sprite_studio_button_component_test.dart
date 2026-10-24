// The Flame button, mounted in a real game so that taps and hovers come
// through Flame's own dispatch and the button's containsLocalPoint. Ringo's
// animations stand in for the states through clips, since no example pack names
// its labels after them.
//
//   flutter test   (in packages/ssplayer_flame/)
import 'dart:io';
import 'dart:typed_data';

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show CachingAssetBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flame/ssplayer_flame.dart';

const _clips = {
  SsUiState.normal: SsUiClip(animation: 'wait1'),
  SsUiState.hover: SsUiClip(animation: 'walk'),
  SsUiState.pressed: SsUiClip(animation: 'attack1'),
  SsUiState.disabled: SsUiClip(animation: 'dead'),
  SsUiState.focused: SsUiClip(animation: 'jump_wait'),
};

// Past the tap recognizer's own timer, so none is left pending.
const _tapSettles = Duration(milliseconds: 100);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A button the size of the 800x1200 screen, so a point in the button is the
  // same point on the screen. Ringo stands on the origin, which the component
  // puts in the middle of its box, so the box must reach well above it.
  Future<SpriteStudioButtonComponent?> mounted(
    WidgetTester tester, {
    List<String>? hitParts,
    bool hitOnArtwork = false,
    void Function()? onPressed,
    void Function()? onReleased,
  }) async {
    final path = _ringo();
    if (path == null) {
      markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
      return null;
    }
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final button = SpriteStudioButtonComponent(
      ssab: File(path).readAsBytesSync(),
      bundle: _NoTextures(),
      clips: _clips,
      hitParts: hitParts,
      hitOnArtwork: hitOnArtwork,
      onPressed: onPressed,
      onReleased: onReleased,
      size: Vector2(800, 1200),
    );
    await tester.pumpWidget(GameWidget(game: FlameGame(children: [button])));
    for (var i = 0; i < 100 && !button.isLoaded; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    // The tap dispatcher mounts after the button, and the game widget takes
    // its recognizer up on a later frame still.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(button.player, isNotNull, reason: '${button.loadError}');
    return button;
  }

  Offset centreOf(SpriteStudioButtonComponent button, String part) =>
      button.player!.partQuad(part)!.bounds.center + const Offset(400, 600);

  testWidgets('shows normal, pressed while held, and fires both edges', (
    tester,
  ) async {
    var pressed = 0, released = 0;
    final button = await mounted(
      tester,
      onPressed: () => pressed++,
      onReleased: () => released++,
    );
    if (button == null) return;
    final player = button.player!;
    expect(player.currentAnimation, 'wait1');
    expect(player.isPlaying, isTrue);

    final gesture = await tester.startGesture(centreOf(button, 'body'));
    await tester.pump();
    expect(button.uiState, SsUiState.pressed);
    expect(player.currentAnimation, 'attack1');
    expect((pressed, released), (1, 0));

    await gesture.up();
    await tester.pump(_tapSettles);
    expect(player.currentAnimation, 'wait1');
    expect((pressed, released), (1, 1));
  });

  testWidgets('takes a tap on the parts it names only', (tester) async {
    var pressed = 0;
    final button = await mounted(
      tester,
      hitParts: const ['apple'],
      onPressed: () => pressed++,
    );
    if (button == null) return;

    await tester.tapAt(centreOf(button, 'body'));
    await tester.pump(_tapSettles);
    expect(pressed, 0, reason: 'the body is drawn but not named');

    await tester.tapAt(centreOf(button, 'apple'));
    await tester.pump(_tapSettles);
    expect(pressed, 1);
  });

  testWidgets('on artwork, takes a tap on any part but not the empty box', (
    tester,
  ) async {
    var pressed = 0;
    final button = await mounted(
      tester,
      hitOnArtwork: true,
      onPressed: () => pressed++,
    );
    if (button == null) return;

    await tester.tapAt(const Offset(2, 2));
    await tester.pump(_tapSettles);
    expect(pressed, 0);

    await tester.tapAt(centreOf(button, 'body'));
    await tester.pump(_tapSettles);
    expect(pressed, 1);
  });

  testWidgets('a hover on the named parts only shows hover', (tester) async {
    final button = await mounted(tester, hitParts: const ['apple']);
    if (button == null) return;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);

    await mouse.addPointer(location: centreOf(button, 'body'));
    await mouse.moveTo(centreOf(button, 'body') + const Offset(1, 1));
    await tester.pump();
    expect(button.uiState, SsUiState.normal);

    await mouse.moveTo(centreOf(button, 'apple'));
    await tester.pump();
    expect(button.uiState, SsUiState.hover);
    expect(button.player!.currentAnimation, 'walk');
  });

  testWidgets('disabled shows disabled and fires nothing', (tester) async {
    var pressed = 0;
    final button = await mounted(tester, onPressed: () => pressed++);
    if (button == null) return;

    button.isDisabled = true;
    expect(button.player!.currentAnimation, 'dead');
    await tester.tapAt(centreOf(button, 'body'));
    await tester.pump(_tapSettles);
    expect(pressed, 0);
    expect(button.uiState, SsUiState.disabled);

    button.isDisabled = false;
    expect(button.player!.currentAnimation, 'wait1');
  });

  testWidgets('the game marks focus', (tester) async {
    final button = await mounted(tester);
    if (button == null) return;

    button.isFocused = true;
    expect(button.uiState, SsUiState.focused);
    expect(button.player!.currentAnimation, 'jump_wait');
  });

  testWidgets('reduced motion holds the first frame', (tester) async {
    final button = await mounted(tester);
    if (button == null) return;
    final player = button.player!;

    button.reducedMotion = true;
    expect(player.isPlaying, isFalse);
    expect(player.frameNo, player.startFrame);

    button.isFocused = true;
    expect(player.currentAnimation, 'jump_wait');
    expect(player.isPlaying, isFalse);

    button.reducedMotion = false;
    expect(player.isPlaying, isTrue);
  });
}

String? _ringo() {
  for (final p in const [
    'examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
    '../../examples/flame/assets/spritestudio/Ringo/Ringo.ssab',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Has no textures, so none is decoded: a decode left running when one test
/// ends is one the next load of the same pack would wait on.
class _NoTextures extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      throw FlutterError('not in bundle: $key');
}
