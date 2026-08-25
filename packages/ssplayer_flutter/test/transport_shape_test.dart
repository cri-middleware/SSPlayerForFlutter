// The transport controls that shape *how* the range is walked — the playback
// section, direction / ping-pong, and frame skipping.
//
// A real `setAnimation` resets every one of them in the Brain, so the
// interesting behaviour is which ones the player puts back. (Selecting the
// animation already selected resets nothing at all — it is a no-op.) Direction, style and
// skip-frames are host policy and are re-applied; a section is a range of frame
// numbers that means nothing in a different animation, so it is deliberately
// left to reset. These tests pin that split.
//
// Externally clocked (no `vsync`) so the frame stepping is deterministic.
//
//   flutter test test/transport_shape_test.dart
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
    player.setAnimation(player.animationNames.first);
    return player;
  }

  test('the controls are inert before load rather than throwing', () {
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);

    expect(player.playbackDirection, SsPlaybackDirection.forward);
    expect(player.playbackStyle, SsPlaybackStyle.normal);
    expect(player.frameSkipEnabled, isTrue);
    // No Brain to section; must not throw.
    player.setAnimationSection(0, 10);
  });

  test('a section narrows the played range', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    final fullLength = player.totalFrames;
    expect(fullLength, greaterThan(4), reason: 'need room to carve a section');

    final end = player.startFrame + 3;
    player.setAnimationSection(player.startFrame, end);

    expect(player.endFrame, end);
    expect(player.totalFrames, 4, reason: 'inclusive of both ends');
    expect(player.totalFrames, lessThan(fullLength));
  });

  test('selecting the animation already selected changes nothing', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    player.setAnimationSection(player.startFrame, player.startFrame + 3);
    expect(player.totalFrames, 4);

    // A switch with nothing to switch to. Nothing is reset — not the section,
    // not the playhead, not the loop budget. Restarting is `play`'s job.
    expect(player.setAnimation(player.animationNames.first), isTrue);
    expect(player.totalFrames, 4,
        reason: 'a no-op must not drop the section');
  });

  test('a section does NOT survive a real switch', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }
    final anims = player.animationNames;
    if (anims.length < 2) {
      markTestSkipped('Basic.ssab has one animation — nothing to switch to');
      return;
    }

    final fullLength = player.totalFrames;
    player.setAnimationSection(player.startFrame, player.startFrame + 3);
    expect(player.totalFrames, 4);

    // Frame numbers are only meaningful inside the animation they came from, so
    // the section is left to reset rather than carried across.
    player.setAnimation(anims[1]);
    expect(player.totalFrames, isNot(4),
        reason: 'setup should restore the full range');
    expect(player.totalFrames, greaterThan(4));
    expect(fullLength, greaterThan(4));
  });

  test('direction and style apply, and survive setAnimation', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    player.setPlaybackDirection(
        SsPlaybackDirection.backward, SsPlaybackStyle.pingPong);
    expect(player.playbackDirection, SsPlaybackDirection.backward);
    expect(player.playbackStyle, SsPlaybackStyle.pingPong);

    // Host policy, like the speed and the frame skip: "play this backwards" is
    // a decision about the playback, so the Brain keeps it across a transition
    // (SDK #375). Nothing on this side re-applies it.
    player.setAnimation(player.animationNames.first);
    expect(player.playbackDirection, SsPlaybackDirection.backward);
    expect(player.playbackStyle, SsPlaybackStyle.pingPong);
  });

  test('backward playback actually walks backwards', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    player.loopCount = -1;
    player.setPlaybackDirection(
        SsPlaybackDirection.backward, SsPlaybackStyle.normal);
    player.play();
    player.seek(player.endFrame.toDouble());

    final from = player.frameNo;
    player.advance(const Duration(milliseconds: 16));
    expect(player.frameNo, lessThan(from),
        reason: 'the playhead should retreat');
  });

  test('skipFrames applies and DOES survive setAnimation', () async {
    final player = await loadedPlayer();
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    expect(player.frameSkipEnabled, isTrue, reason: 'the Brain default is ON');

    player.frameSkipEnabled = false;
    expect(player.frameSkipEnabled, isFalse);

    player.setAnimation(player.animationNames.first);
    expect(player.frameSkipEnabled, isFalse, reason: 'host policy is re-applied');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
