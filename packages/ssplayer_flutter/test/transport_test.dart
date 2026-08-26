// Play/pause/resume transport (L3). Pins the regression where a play/pause
// button froze after one press: the Brain keeps `isPlaying` true while paused
// and its `pause` merely *toggles* a hold, so a naive `isPlaying ? pause : play`
// re-paused every tap and never restarted the ticker.
//
// Also pins the four-verb contract itself: `resume` lifts a hold and does
// NOTHING else. It used to head out through `play` when nothing was playing,
// which is the one shape the SDK's porting guide asks Players not to take
// (`30_core/20_playback_control.md`) -- and this was the only Player in the
// family that took it.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Basic.ssab',
    '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
  ]);

  testWidgets('pause holds in place, resume continues, and both are idempotent',
      (tester) async {
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final player = SpriteStudioPlayer(vsync: tester);
    addTearDown(player.dispose);

    // The ticker forces the first tick's delta to 0 (anti-jump), so advancing
    // needs a few frames after every (re)start.
    Future<void> pumpFrames([int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await player.load(bytes, loadTextures: false);
    player.setAnimation(player.animationNames.first);
    player.loopCount = -1;
    player.play();

    await pumpFrames();
    final playing = player.frameNo;
    expect(playing, greaterThan(0), reason: 'advances while playing');
    expect(player.isPlaying, isTrue);
    expect(player.isPausing, isFalse);

    // Pause holds the playhead.
    player.pause();
    expect(player.isPlaying, isTrue, reason: 'paused is still "playing" (a hold)');
    expect(player.isPausing, isTrue);
    await pumpFrames();
    expect(player.frameNo, closeTo(playing, 1e-6), reason: 'frozen while paused');

    // The regression: a SECOND pause() must not silently un-pause.
    player.pause();
    expect(player.isPausing, isTrue);
    await pumpFrames();
    expect(player.frameNo, closeTo(playing, 1e-6));

    // Resume continues in place (no head-out rewind).
    player.resume();
    expect(player.isPausing, isFalse);
    await pumpFrames();
    expect(player.frameNo, greaterThan(playing), reason: 'resumes forward');

    // togglePlayPause flips advancing <-> paused each call.
    player.togglePlayPause();
    expect(player.isPausing, isTrue);
    player.togglePlayPause();
    expect(player.isPausing, isFalse);

    player.stop(); // quiesce the ticker before teardown
  });

  testWidgets('resume is a no-op when stopped; togglePlayPause heads out',
      (tester) async {
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing -- run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final player = SpriteStudioPlayer(vsync: tester);
    addTearDown(player.dispose);

    Future<void> pumpFrames([int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await player.load(bytes, loadTextures: false);
    player.setAnimation(player.animationNames.first);
    player.loopCount = -1;

    // Never played: resume must not start it. `play` is the only head-out.
    expect(player.isPlaying, isFalse);
    player.resume();
    expect(player.isPlaying, isFalse, reason: 'resume does not start a stopped animation');
    await pumpFrames();
    expect(player.frameNo, closeTo(0, 1e-6), reason: 'and nothing advanced');

    // Stopped mid-run: the playhead stays put, and resume still does nothing --
    // the bug this replaces sent it back to the head instead.
    player.play();
    await pumpFrames();
    final stoppedAt = player.frameNo;
    expect(stoppedAt, greaterThan(0));
    player.stop();
    expect(player.isPlaying, isFalse);

    player.resume();
    expect(player.isPlaying, isFalse);
    await pumpFrames();
    expect(player.frameNo, closeTo(stoppedAt, 1e-6),
        reason: 'resume neither restarts nor rewinds');

    // The head-out lives in the toggle instead, so a play/pause button still
    // starts a stopped player on the first tap.
    player.togglePlayPause();
    expect(player.isPlaying, isTrue);
    expect(player.isPausing, isFalse);
    await pumpFrames();
    expect(player.frameNo, greaterThan(0));

    player.stop(); // quiesce the ticker before teardown
  });

  testWidgets('onAnimationStarted fires on play, and not on resume',
      (tester) async {
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing -- run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final player = SpriteStudioPlayer(vsync: tester);
    addTearDown(player.dispose);

    var started = 0;
    player.onAnimationStarted = () => started++;

    await player.load(bytes, loadTextures: false);
    player.setAnimation(player.animationNames.first);
    player.loopCount = -1;
    expect(started, 0, reason: 'setAnimation is not a start; nothing plays yet');

    player.play();
    expect(started, 1);

    // A resume carries on rather than heading out. Firing here would make the
    // two indistinguishable to a listener, which is the whole point of having a
    // separate event for the head-out.
    player.pause();
    player.resume();
    expect(started, 1, reason: 'resume is not a start');

    // ...and a resume on a STOPPED player is a no-op, so still not a start.
    player.stop();
    player.resume();
    expect(started, 1);

    player.play();
    expect(started, 2, reason: 'every head-out is a start');

    player.stop(); // quiesce the ticker before teardown
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
