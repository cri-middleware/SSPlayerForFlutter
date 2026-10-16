// What a tick builds: a frame only when the pose can have moved, against the
// HOST-built Brain.
//
// Whether the track stack moves is the Brain's verdict (`is_stack_in_motion`)
// and is the SDK's to test. These pin how this player combines it with the
// clock: a paused, stopped or finished player builds nothing per tick, a track
// call or an override still gets its one frame, and whatever does move — an
// overlay, a source beside track 0's main one, a fade — keeps building.
//
// Ringo is the pack: `attack1` is short (20 frames at 60 fps), `wait1` and
// `walk` are 80. It has no effect or instance parts, which build every tick.
//
// Requires scripts/build-runtime.sh and scripts/deploy-examples.sh.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/player.dart' show tickKeptPose;
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ringoPath = _firstExisting([
    'examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
    '../../examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
  ]);

  /// An externally clocked player on Ringo, with [animation] selected — the
  /// shape a Flame component drives with its `update(dt)`.
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

  /// Plays `attack1` once and runs it out, so track 0 is finished.
  Future<SpriteStudioPlayer?> finished() async {
    final player = await ringo('attack1');
    if (player == null) return null;
    player
      ..loopCount = 1
      ..play();
    _advance(player, 600);
    expect(player.isFinished, isTrue);
    return player;
  }

  group('a tick that moves nothing builds nothing', () {
    test('while paused', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      _advance(player, 48);
      player.pause();

      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before);
    });

    test('between two frames, with sub-frame off', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player
        ..subFrameEnabled = false
        ..play();
      player.advance(const Duration(milliseconds: 1));

      final before = _evaluations(player);
      final frame = player.frameNo.floor();
      var ticks = 0;
      while (player.frameNo.floor() == frame) {
        player.advance(const Duration(milliseconds: 1));
        ticks++;
      }
      expect(ticks, greaterThan(5), reason: 'about 16 ticks to a frame');
      expect(_evaluations(player), before + 1,
          reason: 'only the tick that reached the next frame built one');
    });

    test('once stopped, and does not notify', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      _advance(player, 48);
      player.stop();

      var notified = 0;
      player.addListener(() => notified++);
      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before);
      expect(notified, 0);
    });

    test('once track 0 finishes with nothing else on the clock', () async {
      final player = await finished();
      if (player == null) return;

      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before);
    });

    test('after the only overlay is cleared', () async {
      final player = await finished();
      if (player == null) return;
      player.setTrackAnimation(1, 'walk');
      _advance(player, 48);
      expect(player.clearTrack(1), isTrue);

      _advance(player, 16);
      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before);
    });

    test('while the only overlay plays at speed 0', () async {
      final player = await finished();
      if (player == null) return;
      player
        ..setTrackAnimation(1, 'walk')
        ..setTrackSpeed(1, 0);

      _advance(player, 16);
      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before,
          reason: 'an overlay that does not advance does not move the pose');
    });

    test('while a crossfade is held by a pause', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      player.crossfade(0, 'walk', const Duration(milliseconds: 400));
      _advance(player, 48);
      player.pause();

      _advance(player, 16);
      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before);
      expect(player.trackFadeProgress(0), isNotNull);
    });
  });

  group('a call that changes the pose', () {
    test('builds one frame on a stopped player, then none', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      _advance(player, 48);
      player.stop();

      expect(player.setTrackAlpha(0, 0.5), isTrue);
      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before + 1);
    });

    test('builds one frame on a paused player, then none', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      _advance(player, 48);
      player.pause();
      _advance(player, 16);

      expect(player.setPartVisibilityOverride('apple', true), isTrue);
      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before + 1);
      expect(player.isPartHidden('apple'), isTrue);
    });

    test('that the Brain refuses builds nothing', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      _advance(player, 48);
      player.pause();
      _advance(player, 16);

      expect(player.setTrackAlpha(7, 0.5), isFalse);
      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), before);
    });
  });

  group('what moves keeps building', () {
    test('a source beside track 0\'s main one, after track 0 finishes',
        () async {
      final player = await finished();
      if (player == null) return;
      final walk = player.addTrackSource(0, 'walk', 0.5);
      expect(walk, isNotNull);

      _advance(player, 16);
      final frame = player.sourceFrame(walk!)!;
      final before = _evaluations(player);
      _advance(player, 160);
      expect(player.sourceFrame(walk), greaterThan(frame),
          reason: 'it plays on, though track 0 is done');
      expect(_evaluations(player), greaterThanOrEqualTo(before + 9),
          reason: 'one frame per tick while it moves');
    });

    test('an overlay with a weight-0 source keeps track 0 moving', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      player.setTrackAnimation(1, 'walk');
      player.setSourceWeight(player.trackMainSource(1)!, 0);

      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), greaterThanOrEqualTo(before + 9),
          reason: 'track 0 itself still plays');
    });

    test('a crossfade on a finished track 0, until it completes', () async {
      final player = await finished();
      if (player == null) return;
      player.crossfade(0, 'walk', const Duration(milliseconds: 160));

      final before = _evaluations(player);
      _advance(player, 160);
      expect(_evaluations(player), greaterThanOrEqualTo(before + 9));
    });
  });

  group('what a view hears', () {
    test('every tick, and which of them kept the pose', () async {
      final player = await ringo('wait1');
      if (player == null) return;
      player.play();
      _advance(player, 48);
      player.pause();

      final kept = <bool>[];
      player.addListener(() => kept.add(tickKeptPose(player)));
      _advance(player, 48);
      expect(kept, [true, true, true],
          reason: 'a paused tick notifies, and asks for no repaint');

      kept.clear();
      player.setPartColorOverride('apple', const Color(0xFFFF0000));
      expect(kept, [false], reason: 'a setter repaints');
      _advance(player, 16);
      expect(kept, [false, false], reason: 'the tick that builds it too');

      kept.clear();
      player.resume();
      kept.clear();
      _advance(player, 16);
      expect(kept, [false], reason: 'a playing tick moves the pose');
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

    testWidgets('stops once track 0 finishes under an overlay at speed 0',
        (tester) async {
      final player = await ticked(tester);
      if (player == null) return;
      player
        ..loopCount = 1
        ..setTrackAnimation(1, 'walk')
        ..setTrackSpeed(1, 0)
        ..play();

      await _pumpFrames(tester, 40);
      expect(player.isFinished, isTrue);
      final before = _evaluations(player);
      await _pumpFrames(tester, 10);
      expect(_evaluations(player), before);
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'the ticker stopped');
    });
  });
}

int _evaluations(SpriteStudioPlayer player) =>
    player.internal!.debugEvaluations;

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
