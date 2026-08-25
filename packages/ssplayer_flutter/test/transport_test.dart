// Play/pause/resume transport (L3). Pins the regression where a play/pause
// button froze after one press: the Brain keeps `isPlaying` true while paused
// and its `pause` merely *toggles* a hold, so a naive `isPlaying ? pause : play`
// re-paused every tap and never restarted the ticker.
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
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
