// The L3 read-outs that describe *where* the transport is, rather than driving
// it: the frame range (startFrame / endFrame / totalFrames), the advance rate
// (frameRate) and the two Brain state flags (isFinished / isLooped). These
// forward to Layer 2, which is why the interesting cases are the edges — before
// a load there is no Brain to ask, and `setAnimation` re-reads the pack.
//
// Externally clocked (no `vsync`) so the frame stepping is deterministic.
//
//   flutter test test/transport_frame_info_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Basic.ssab',
    '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
  ]);

  Future<SpriteStudioPlayer?> loadedPlayer() async {
    if (ssabPath == null) return null;
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);
    await player.load(bytes, loadTextures: false);
    player.setAnimation(player.getAnimations().first);
    return player;
  }

  test('the read-outs are inert before load rather than throwing', () {
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);

    // No Brain yet: every read-out falls back rather than blowing up, so a UI
    // built before the pack arrives can bind to them unguarded.
    expect(player.startFrame, 0);
    expect(player.endFrame, 0);
    expect(player.totalFrames, 0);
    expect(player.frameRate, 0);
    expect(player.isFinished, isFalse);
    expect(player.isLooped, isFalse);
  });

  test('the frame range and rate describe the loaded animation', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    expect(player.frameRate, greaterThan(0), reason: 'fps comes from the pack');
    expect(player.endFrame, greaterThanOrEqualTo(player.startFrame));
    // The length is inclusive of both ends, matching the flagship's
    // getTotalFrames(); an off-by-one here would shorten every scrubber.
    expect(player.totalFrames, player.endFrame - player.startFrame + 1);
    expect(player.totalFrames, greaterThan(1));
  });

  test('a frameRate override applies, and survives setAnimation', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    final authored = player.frameRate;
    player.frameRate = authored * 2;
    expect(player.frameRate, authored * 2, reason: 'the override takes');

    // The override is the host's, not the clip's, so the Brain keeps it across
    // a transition (SDK #370) — the same rule that keeps speed and frame skip.
    // Clear it by setting 0 (or any negative), which hands playback back to the
    // authored rate.
    player.setAnimation(player.getAnimations().first);
    expect(player.frameRate, authored * 2,
        reason: 'a host override outlives the transition');

    player.frameRate = 0;
    expect(player.frameRate, authored, reason: 'clearing restores the pack rate');
  });

  test('isFinished latches on completion; isLooped marks the crossing tick',
      () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    // loop AFTER setup — setAnimation resets the Brain's loop counter.
    player.loop = 1;
    player.play();
    expect(player.isFinished, isFalse, reason: 'a fresh play is not finished');

    // Budget matches external_clock_test's proven-generous 2000x16ms.
    for (var i = 0; i < 2000 && !player.isFinished; i++) {
      player.advance(const Duration(milliseconds: 16));
    }
    expect(player.isFinished, isTrue, reason: 'one loop should complete');
    // Sticky: it stays true once set, which is why onComplete exists for the
    // one-shot edge.
    player.advance(const Duration(milliseconds: 16));
    expect(player.isFinished, isTrue);

    // isLooped is the opposite shape — an edge cleared at the top of every
    // update — so it only reads true inside the tick that crossed.
    player.setAnimation(player.getAnimations().first);
    player.loop = -1;
    player.play();
    var sawLoopEdge = false;
    for (var i = 0; i < 2000 && !sawLoopEdge; i++) {
      player.advance(const Duration(milliseconds: 16));
      sawLoopEdge = player.isLooped;
    }
    expect(sawLoopEdge, isTrue, reason: 'an infinite loop must cross a boundary');
    expect(player.isFinished, isFalse, reason: 'an infinite loop never finishes');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
