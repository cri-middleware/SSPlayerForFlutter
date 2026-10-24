// The UI widgets against a real runtime: the view plays what the button's
// states call for, holds still under reduced motion, labels itself for a screen
// reader only when asked, and the region keeps taps and hovers off everything
// but the parts it names.
//
// Ringo's animations stand in for the states through clips, since no example
// pack names its labels after them; Signal.ssab's `Start` / `End` labels cover
// the label sections.
//
//   flutter test test/ui_widgets_test.dart
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/ui.dart';

const _clips = {
  SsUiState.hover: SsUiClip(animation: 'walk'),
  SsUiState.pressed: SsUiClip(animation: 'attack1'),
  SsUiState.disabled: SsUiClip(animation: 'dead'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpriteStudioStateView', () {
    testWidgets('plays the section the states call for', (tester) async {
      final player = await _loaded(tester, 'Ringo/Ringo.ssab', 'wait1');
      if (player == null) return;
      final states = WidgetStatesController();
      addTearDown(states.dispose);
      await tester.pumpWidget(
        _app(
          SpriteStudioStateView(
            player: player,
            statesController: states,
            clips: _clips,
          ),
        ),
      );

      expect(player.currentAnimation, 'wait1');
      expect(player.isPlaying, isTrue);

      states.update(WidgetState.hovered, true);
      expect(player.currentAnimation, 'walk');
      expect(player.isPlaying, isTrue);
      expect(player.frameNo, player.startFrame, reason: 'from its first frame');
      expect(player.loopCount, -1);

      states.update(WidgetState.pressed, true);
      expect(player.currentAnimation, 'attack1');
      states.update(WidgetState.disabled, true);
      expect(player.currentAnimation, 'dead', reason: 'disabled wins');

      states.value = <WidgetState>{};
      expect(player.currentAnimation, 'wait1');
    });

    testWidgets('a clip of a label plays to the frame before the next', (
      tester,
    ) async {
      final player = await _loaded(tester, 'overall/Signal.ssab', 'anime_1');
      if (player == null) return;
      final states = WidgetStatesController();
      addTearDown(states.dispose);
      await tester.pumpWidget(
        _app(
          SpriteStudioStateView(
            player: player,
            statesController: states,
            clips: const {
              SsUiState.hover: SsUiClip(label: 'Start'),
              SsUiState.pressed: SsUiClip(label: 'End'),
            },
          ),
        ),
      );
      final last = player.endFrame;

      states.update(WidgetState.hovered, true);
      expect((player.startFrame, player.endFrame), (10, 19));
      states.update(WidgetState.pressed, true);
      expect((player.startFrame, player.endFrame), (20, last));
    });

    testWidgets('shows the state again after the pack is loaded again', (
      tester,
    ) async {
      final player = await _loaded(tester, 'Ringo/Ringo.ssab', 'wait1');
      if (player == null) return;
      final states = WidgetStatesController();
      addTearDown(states.dispose);
      await tester.pumpWidget(
        _app(
          SpriteStudioStateView(
            player: player,
            statesController: states,
            clips: _clips,
          ),
        ),
      );
      states.update(WidgetState.hovered, true);
      expect(player.currentAnimation, 'walk');

      final bytes = File('${_dir()}/Ringo/Ringo.ssab').readAsBytesSync();
      await tester.runAsync(
        () => player.load(bytes, animationName: 'wait1', loadTextures: false),
      );
      expect(player.currentAnimation, 'walk');
      expect(player.isPlaying, isTrue);
    });

    testWidgets('holds the first frame under reduced motion', (tester) async {
      final player = await _loaded(tester, 'Ringo/Ringo.ssab', 'wait1');
      if (player == null) return;
      final states = WidgetStatesController();
      addTearDown(states.dispose);
      Widget view({bool? reduced}) => MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: SpriteStudioStateView(
          player: player,
          statesController: states,
          clips: _clips,
          reducedMotion: reduced,
        ),
      );
      await tester.pumpWidget(_app(view()));
      expect(player.isPlaying, isFalse);
      expect(player.frameNo, player.startFrame);

      states.update(WidgetState.hovered, true);
      expect(player.currentAnimation, 'walk');
      expect(player.isPlaying, isFalse);
      expect(player.frameNo, player.startFrame);

      // Said outright, it outranks the MediaQuery.
      await tester.pumpWidget(_app(view(reduced: false)));
      expect(player.isPlaying, isTrue);
    });

    testWidgets('is decoration unless given a label', (tester) async {
      final player = await _loaded(tester, 'Ringo/Ringo.ssab', 'wait1');
      if (player == null) return;
      final semantics = tester.ensureSemantics();
      final states = WidgetStatesController();
      addTearDown(states.dispose);

      await tester.pumpWidget(
        _app(SpriteStudioStateView(player: player, statesController: states)),
      );
      expect(find.bySemanticsLabel('Ringo'), findsNothing);

      await tester.pumpWidget(
        _app(
          SpriteStudioStateView(
            player: player,
            statesController: states,
            semanticLabel: 'Ringo',
          ),
        ),
      );
      expect(find.bySemanticsLabel('Ringo'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Ringo')),
        matchesSemantics(label: 'Ringo', isImage: true),
      );
      semantics.dispose();
    });

    testWidgets('shows disabled for a button that has no handler', (
      tester,
    ) async {
      final player = await _loaded(tester, 'Ringo/Ringo.ssab', 'wait1');
      if (player == null) return;
      final states = WidgetStatesController();
      addTearDown(states.dispose);
      await tester.pumpWidget(
        _app(
          InkWell(
            statesController: states,
            child: SpriteStudioStateView(
              player: player,
              statesController: states,
              clips: _clips,
            ),
          ),
        ),
      );
      expect(player.currentAnimation, 'dead');
    });
  });

  group('SpriteStudioHitRegion', () {
    // A 400x300 view behind 16 px of padding inside the button, so the
    // region's box is not the view's.
    Future<({SpriteStudioPlayer player, WidgetStatesController states})?>
    button(WidgetTester tester, List<String>? parts, VoidCallback onTap) async {
      final player = await _loaded(tester, 'Ringo/Ringo.ssab', 'wait1');
      if (player == null) return null;
      final states = WidgetStatesController();
      addTearDown(states.dispose);
      await tester.pumpWidget(
        _app(
          Center(
            child: SpriteStudioHitRegion(
              player: player,
              parts: parts,
              child: InkWell(
                statesController: states,
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SpriteStudioStateView(
                    player: player,
                    statesController: states,
                    clips: _clips,
                    width: 400,
                    height: 300,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return (player: player, states: states);
    }

    Offset onScreen(WidgetTester tester, Offset viewPoint) {
      final view = tester.getRect(find.byType(SpriteStudioView));
      return view.center + viewPoint;
    }

    testWidgets('takes a tap on the parts it names only', (tester) async {
      var taps = 0;
      final b = await button(tester, const ['apple'], () => taps++);
      if (b == null) return;
      final apple = b.player.partQuad('apple')!.bounds.center;
      final body = b.player.partQuad('body')!.bounds.center;

      await tester.tapAt(onScreen(tester, body));
      await tester.pump(kDoubleTapTimeout);
      expect(taps, 0, reason: 'the body is drawn but not named');

      await tester.tapAt(onScreen(tester, apple));
      await tester.pump(kDoubleTapTimeout);
      expect(taps, 1);

      // Just inside two opposite corners: a point mapped into the view without
      // the padding lands 16 px off one of them.
      final quad = b.player.partQuad('apple')!;
      for (final corner in [quad.leftTop, quad.rightBottom]) {
        await tester.tapAt(onScreen(tester, Offset.lerp(corner, apple, 0.15)!));
        await tester.pump(kDoubleTapTimeout);
      }
      expect(taps, 3);

      // Inside the button's box, on nothing at all.
      final corner =
          tester.getTopLeft(find.byType(InkWell)) + const Offset(2, 2);
      await tester.tapAt(corner);
      await tester.pump(kDoubleTapTimeout);
      expect(taps, 3);
    });

    testWidgets('with no parts named, takes a tap on any part', (tester) async {
      var taps = 0;
      final b = await button(tester, null, () => taps++);
      if (b == null) return;
      final body = b.player.partQuad('body')!.bounds.center;

      await tester.tapAt(onScreen(tester, body));
      await tester.pump(kDoubleTapTimeout);
      expect(taps, 1);
      await tester.tapAt(
        tester.getTopLeft(find.byType(InkWell)) + const Offset(2, 2),
      );
      await tester.pump(kDoubleTapTimeout);
      expect(taps, 1);
    });

    testWidgets('keeps a hover off everything else', (tester) async {
      final b = await button(tester, const ['apple'], () {});
      if (b == null) return;
      final apple = b.player.partQuad('apple')!.bounds.center;
      final body = b.player.partQuad('body')!.bounds.center;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: onScreen(tester, body));
      await tester.pump();
      expect(b.states.value, isNot(contains(WidgetState.hovered)));
      expect(b.player.currentAnimation, 'wait1');

      await mouse.moveTo(onScreen(tester, apple));
      await tester.pump();
      expect(b.states.value, contains(WidgetState.hovered));
      expect(b.player.currentAnimation, 'walk');
    });
  });
}

Widget _app(Widget child) => MaterialApp(
  home: Material(child: Center(child: child)),
);

/// A player on [animation] of the pack at [path] under the example assets,
/// externally clocked and with no textures: the tests read state and poses.
Future<SpriteStudioPlayer?> _loaded(
  WidgetTester tester,
  String path,
  String animation,
) async {
  final dir = _dir();
  final f = File('$dir/$path');
  if (dir != null && f.existsSync()) {
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);
    await tester.runAsync(
      () => player.load(
        f.readAsBytesSync(),
        animationName: animation,
        loadTextures: false,
      ),
    );
    return player;
  }
  markTestSkipped('$path missing — run scripts/deploy-examples.sh');
  return null;
}

/// Where the example packs are deployed, or null when they are not.
String? _dir() {
  for (final dir in const [
    'examples/overall/assets/spritestudio',
    '../../examples/overall/assets/spritestudio',
  ]) {
    if (Directory(dir).existsSync()) return dir;
  }
  return null;
}
