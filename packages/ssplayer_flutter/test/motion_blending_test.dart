// Motion blending through the L3 player: the track stack, crossfades, sources
// and each track's playback settings, against the HOST-built Brain.
//
// What the Brain does with a mix is the SDK's to test. These pin what this
// player adds on top: which animation it reports and when, what it puts back
// after a switch of track 0, the events it decodes per source, and the clock it
// keeps running for the tracks once track 0 has finished.
//
// Ringo is the pack: `attack1` is short (20 frames at 60 fps), `wait1` and
// `walk` are 80, and `dead` alone has a wider canvas (1300).
//
// Requires scripts/build-runtime.sh and scripts/deploy-examples.sh.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ringoPath = _firstExisting([
    'examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
    '../../examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
  ]);
  final userDataPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/UserData.ssab',
    '../../examples/overall/assets/spritestudio/overall/UserData.ssab',
  ]);

  /// An externally clocked player on Ringo, with [animation] selected.
  Future<SpriteStudioPlayer?> ringo(String animation) async {
    if (ringoPath == null) {
      markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
      return null;
    }
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);
    await player.load(Uint8List.fromList(File(ringoPath).readAsBytesSync()),
        animationName: animation, loadTextures: false);
    return player;
  }

  group('a switch of track 0', () {
    test('a crossfade hands the current animation over at the call', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      _advance(player, 100);

      expect(player.crossfade(0, 'dead', const Duration(milliseconds: 400)),
          isTrue);
      // Not when the fade completes: from the call on.
      expect(player.currentAnimation, 'dead');
      expect(player.trackFadeProgress(0), isNotNull);
      // What is looked up by name follows it too: `dead` alone is 1300 wide.
      expect(player.canvasSize?.width, 1300);
    });

    test('setAnimation goes back to the animation a crossfade left', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      player.crossfade(0, 'walk', const Duration(milliseconds: 400));

      // The incoming one is selected, so naming it is no change: the fade
      // carries on.
      expect(player.setAnimation('walk'), isTrue);
      expect(player.trackFadeProgress(0), isNotNull);

      // The outgoing one is not. Recorded as still selected, this was a no-op
      // and the character could not go back.
      expect(player.setAnimation('wait1'), isTrue);
      expect(player.currentAnimation, 'wait1');
      expect(player.trackFadeProgress(0), isNull,
          reason: 'a switch folds the stack back to track 0 alone');
    });

    test('setTrackAnimation on track 0 switches; on track 1 it does not',
        () async {
      final player = await ringo('wait1');
      if (player == null) return;

      expect(player.setTrackAnimation(1, 'attack1'), isTrue);
      expect(player.currentAnimation, 'wait1');
      expect(player.trackCount, greaterThanOrEqualTo(2));
      expect(player.trackMainSource(1), isNotNull);

      expect(player.setTrackAnimation(0, 'walk'), isTrue);
      expect(player.currentAnimation, 'walk');
      expect(player.trackMainSource(1), isNotNull,
          reason: 'unlike setAnimation it keeps the stack');
    });

    test('the speed and the loop count carry across it', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player
        ..speedScale = 2
        ..loopCount = 1;

      player.crossfade(0, 'walk', const Duration(milliseconds: 200));
      expect(player.trackSpeed(0), 2);
      // The Brain lays every animation looping forever; the player puts the
      // host's count back.
      expect(player.trackLoopCount(0), 1);

      player.setTrackAnimation(0, 'attack1');
      expect(player.trackSpeed(0), 2);
      expect(player.trackLoopCount(0), 1);
    });

    test('track 0 settings written through the track calls survive '
        'setAnimation', () async {
      final player = await ringo('wait1');
      if (player == null) return;

      expect(player.setTrackLoopCount(0, 1), isTrue);
      expect(player.setTrackSpeed(0, 2), isTrue);
      expect(player.setTrackFrameSkipEnabled(0, false), isTrue);
      expect(player.setTrackFrameRate(0, 30), isTrue);

      // setAnimation re-applies what the player keeps; written past it, the
      // old values would come back here.
      player.setAnimation('walk');
      expect(player.loopCount, 1);
      expect(player.trackLoopCount(0), 1);
      expect(player.speedScale, 2);
      expect(player.trackSpeed(0), 2);
      expect(player.frameSkipEnabled, isFalse);
      expect(player.frameRate, 30);
    });
  });

  group('a track', () {
    test('keeps its playback settings; the loop count is the animation\'s',
        () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.setTrackAnimation(1, 'walk');

      expect(player.setTrackSpeed(1, 0.5), isTrue);
      expect(player.setTrackLoopCount(1, 2), isTrue);
      expect(player.setTrackFrameRate(1, 30), isTrue);
      expect(player.setTrackFrameSkipEnabled(1, false), isTrue);
      expect(
          player.setTrackPlaybackDirection(
              1, SsPlaybackDirection.backward, SsPlaybackStyle.pingPong),
          isTrue);
      expect(player.setTrackOutgoingEventThreshold(1, 0.5), isTrue);
      expect(player.setTrackAlpha(1, 0.25), isTrue);
      expect(player.setTrackBlend(1, SsTrackBlend.additive), isTrue);
      expect(player.setTrackSync(1, SsTrackSync.start), isTrue);

      expect(player.trackSpeed(1), 0.5);
      expect(player.trackLoopCount(1), 2);
      expect(player.trackFrameRate(1), 30);
      expect(player.trackFrameSkipEnabled(1), isFalse);
      expect(player.trackPlaybackDirection(1), SsPlaybackDirection.backward);
      expect(player.trackPlaybackStyle(1), SsPlaybackStyle.pingPong);
      expect(player.trackOutgoingEventThreshold(1), 0.5);
      expect(player.trackAlpha(1), 0.25);
      expect(player.trackBlend(1), SsTrackBlend.additive);
      expect(player.trackSync(1), SsTrackSync.start);

      // Another animation on the track: the track's settings stay, the
      // animation's loop count starts over.
      player.setTrackAnimation(1, 'wait1');
      expect(player.trackSpeed(1), 0.5);
      expect(player.trackFrameRate(1), 30);
      expect(player.trackLoopCount(1), -1);
    });

    test('reads null and refuses calls where there is nothing to address',
        () async {
      final unloaded = SpriteStudioPlayer();
      addTearDown(unloaded.dispose);
      expect(unloaded.trackCount, 0);
      expect(unloaded.crossfade(0, 'walk', Duration.zero), isFalse);
      expect(unloaded.setTrackSpeed(1, 2), isFalse);
      expect(unloaded.trackAlpha(0), isNull);
      expect(unloaded.addTrackSource(0, 'walk', 1), isNull);

      final player = await ringo('wait1');
      if (player == null) return;
      const none = 7;
      expect(player.trackAlpha(none), isNull);
      expect(player.trackSpeed(none), isNull);
      expect(player.trackFrameRate(none), isNull);
      expect(player.trackFrameSkipEnabled(none), isNull);
      expect(player.trackPlaybackDirection(none), isNull);
      expect(player.trackLoopCount(none), isNull);
      expect(player.trackOutgoingEventThreshold(none), isNull);
      expect(player.trackMainSource(none), isNull);
      expect(player.trackFadeProgress(0), isNull, reason: 'not fading');
      expect(player.isTrackFinished(none), isFalse);
      expect(player.trackJustLooped(none), isFalse);
      expect(player.sourceWeight(9999), isNull);
      expect(player.setSourceWeight(9999, 1), isFalse);
      expect(player.crossfade(0, 'no_such_animation', Duration.zero), isFalse);
      expect(player.currentAnimation, 'wait1',
          reason: 'a refused switch hands nothing over');
      // The track's settings need no animation; its loop count does.
      expect(player.setTrackSpeed(3, 2), isTrue);
      expect(player.setTrackLoopCount(3, 2), isFalse);
    });
  });

  group('a refused call', () {
    List<String> capturePrints() {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);
      return lines;
    }

    test('says what was asked for, once per call, target and name', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      final lines = capturePrints();

      // A bool nobody has to read is not a report: without the line, a
      // misspelt crossfade leaves the previous animation playing in silence.
      expect(player.crossfade(0, 'wakl', _fade), isFalse);
      expect(player.crossfade(0, 'wakl', _fade), isFalse);
      expect(lines, hasLength(1));
      expect(lines.single, contains('crossfade'));
      expect(lines.single, contains('"wakl"'));
      expect(lines.single, contains('track 0'));

      // Another wrong name, or another call, is another line.
      player.setTrackAnimation(1, 'runn');
      player.addTrackSource(1, 'runn', 1);
      expect(lines, hasLength(3));

      // A per-frame call that keeps being refused says so once.
      for (var i = 0; i < 5; i++) {
        player.setSourceWeight(9999, 0.5);
      }
      expect(lines, hasLength(4));
      expect(lines.last, contains('setSourceWeight on source 9999'));
    });

    test('says nothing before load', () async {
      final lines = capturePrints();
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      expect(player.crossfade(0, 'walk', _fade), isFalse);
      expect(player.setTrackSpeed(1, 2), isFalse);
      expect(lines, isEmpty);
    });
  });

  group('over time', () {
    test('a fade completes and releases the outgoing side', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      final outgoing = player.trackMainSource(0)!;

      player.crossfade(0, 'walk', const Duration(milliseconds: 200));
      expect(player.trackMainSource(0), isNot(outgoing));
      expect(player.sourceWeight(outgoing), isNotNull);

      _advance(player, 300);
      expect(player.trackFadeProgress(0), isNull);
      expect(player.sourceWeight(outgoing), isNull);
      expect(player.isPlaying, isTrue);
    });

    test('an overlay advances with the clock and holds under pause', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.setTrackAnimation(1, 'walk');
      player.play();

      final start = player.trackFrame(1)!;
      _advance(player, 160);
      final moved = player.trackFrame(1)!;
      expect(moved, greaterThan(start));

      player.pause();
      _advance(player, 160);
      expect(player.trackFrame(1), moved);
    });

    test('the incoming side plays at the speed track 0 had', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.speedScale = 2;
      player.play();
      player.crossfade(0, 'walk', const Duration(milliseconds: 100));

      _advance(player, 160);
      // 160 ms at 60 fps is about 10 frames; at twice the speed, about 20.
      expect(player.frameNo, greaterThan(15));
    });

    test('a loop count of 1 finishes the incoming animation once', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      var finished = 0;
      player
        ..loopCount = 1
        ..onAnimationFinished = (() => finished++)
        ..play();
      _advance(player, 50);

      player.crossfade(0, 'attack1', const Duration(milliseconds: 50));
      _advance(player, 1000);
      expect(player.isFinished, isTrue);
      expect(finished, 1);
    });

    test('the outgoing animation running out does not finish the character',
        () async {
      final player = await ringo('attack1');
      if (player == null) return;
      var finished = 0;
      player
        ..loopCount = 1
        ..onAnimationFinished = (() => finished++)
        ..play();
      _advance(player, 100);

      // attack1 has about 230 ms left; wait1 runs 1.3 s.
      player.crossfade(0, 'wait1', const Duration(seconds: 1));
      _advance(player, 500);
      expect(player.isFinished, isFalse);
      expect(finished, 0);
      expect(player.isPlaying, isTrue);
    });

    test('a crossfade called again mid-fade keeps the weights it had reached',
        () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      final first = player.trackMainSource(0)!;
      player.crossfade(0, 'walk', const Duration(milliseconds: 400));
      final second = player.trackMainSource(0)!;
      _advance(player, 200);
      final w1 = player.sourceWeight(first)!;
      final w2 = player.sourceWeight(second)!;

      player.crossfade(0, 'run', const Duration(milliseconds: 400));
      expect(player.sourceWeight(first), closeTo(w1, 1e-6));
      expect(player.sourceWeight(second), closeTo(w2, 1e-6));
    });

    test('an overlay loops, and finishes on its own count', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.setTrackAnimation(1, 'attack1');
      player.play();

      var looped = false;
      for (var i = 0; i < 40 && !looped; i++) {
        player.advance(const Duration(milliseconds: 16));
        looped = player.trackJustLooped(1);
      }
      expect(looped, isTrue, reason: 'an overlay loops forever as laid');

      player.setTrackAnimation(1, 'attack1');
      player.setTrackLoopCount(1, 1);
      _advance(player, 600);
      expect(player.isTrackFinished(1), isTrue);
      expect(player.trackFrame(1), 19, reason: 'it holds its last frame');
      expect(player.isFinished, isFalse,
          reason: 'only track 0 finishes the character');
    });
  });

  group('sources', () {
    test('a source joins a track and is mixed by weight', () async {
      final player = await ringo('wait1');
      if (player == null) return;

      final run = player.addTrackSource(0, 'run', 0.3);
      expect(run, isNotNull);
      expect(player.sourceWeight(run!), closeTo(0.3, 1e-6));
      expect(player.setSourceWeight(run, 0.7), isTrue);
      expect(player.sourceWeight(run), closeTo(0.7, 1e-6));
      expect(player.setSourceFrame(run, 10), isTrue);
      expect(player.sourceFrame(run), 10);
      expect(player.setSourceEventThreshold(run, 0.5), isTrue);
      expect(player.sourceEventThreshold(run), 0.5);
      expect(player.currentAnimation, 'wait1',
          reason: 'a source beside the main one hands nothing over');
    });
  });

  group('events', () {
    Future<SpriteStudioPlayer?> userData() async {
      if (userDataPath == null) {
        markTestSkipped('UserData.ssab missing — run deploy-examples.sh');
        return null;
      }
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(
          Uint8List.fromList(File(userDataPath).readAsBytesSync()),
          animationName: 'anime_1',
          loadTextures: false);
      return player;
    }

    test('each one carries the source that fired it', () async {
      final player = await userData();
      if (player == null) return;
      final seen = <SsUserData>[];
      player
        ..onUserData = seen.add
        ..play();
      _advance(player, 50);
      expect(seen, isNotEmpty);
      expect(seen.map((e) => e.source).toSet(), {player.trackMainSource(0)});
    });

    test('after a crossfade on track 0 only the incoming side fires',
        () async {
      final player = await userData();
      if (player == null) return;
      final seen = <SsUserData>[];
      player.play();
      _advance(player, 50);
      final outgoing = player.trackMainSource(0);

      player.onUserData = seen.add;
      player.crossfade(0, 'anime_1', const Duration(seconds: 2));
      final incoming = player.trackMainSource(0);
      _advance(player, 500);

      expect(seen, isNotEmpty);
      expect(seen.map((e) => e.source).toSet(), {incoming});
      expect(incoming, isNot(outgoing));
    });

    test('the outgoing side fires too while its threshold allows', () async {
      final player = await userData();
      if (player == null) return;
      final seen = <SsUserData>[];
      player.play();
      _advance(player, 50);
      final outgoing = player.trackMainSource(0);

      player
        ..onUserData = seen.add
        ..setTrackOutgoingEventThreshold(0, 0);
      player.crossfade(0, 'anime_1', const Duration(seconds: 2));
      final incoming = player.trackMainSource(0);
      _advance(player, 500);

      expect(seen.map((e) => e.source).toSet(), {outgoing, incoming});
    });
  });

  group('the ticker', () {
    Future<SpriteStudioPlayer?> ticked(WidgetTester tester) async {
      if (ringoPath == null) {
        markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
        return null;
      }
      final player = SpriteStudioPlayer(vsync: tester);
      addTearDown(player.dispose);
      await tester.runAsync(() => player.load(
          Uint8List.fromList(File(ringoPath).readAsBytesSync()),
          animationName: 'attack1',
          loadTextures: false));
      return player;
    }

    testWidgets('keeps an overlay moving after track 0 finishes',
        (tester) async {
      final player = await ticked(tester);
      if (player == null) return;
      player
        ..loopCount = 1
        ..setTrackAnimation(1, 'walk')
        ..play();

      await _pumpFrames(tester, 40);
      expect(player.isFinished, isTrue);
      final atFinish = player.trackFrame(1)!;
      await _pumpFrames(tester, 10);
      expect(player.trackFrame(1), greaterThan(atFinish));

      player.stop(); // quiesce the ticker before teardown
    });

    testWidgets('wakes when a track is laid on a finished player',
        (tester) async {
      final player = await ticked(tester);
      if (player == null) return;
      player
        ..loopCount = 1
        ..play();
      await _pumpFrames(tester, 40);
      expect(player.isFinished, isTrue);

      // Track 0 is done, the clock is not: an overlay laid now moves.
      player.setTrackAnimation(1, 'walk');
      await _pumpFrames(tester, 3);
      final laid = player.trackFrame(1)!;
      await _pumpFrames(tester, 10);
      expect(player.trackFrame(1), greaterThan(laid));

      player.stop();
    });
  });
}

const _fade = Duration(milliseconds: 200);

/// Advances an externally clocked [player] by [ms] in display-frame steps.
void _advance(SpriteStudioPlayer player, int ms) {
  for (var t = 0; t < ms; t += 16) {
    player.advance(const Duration(milliseconds: 16));
  }
}

Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
