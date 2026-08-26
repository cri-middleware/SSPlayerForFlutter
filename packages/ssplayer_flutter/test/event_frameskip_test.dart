// Frame-skip and sub-frame behaviour of event dispatch (§6C), verified against
// the HOST-built Brain with Sound.ssab (audio triggers on frames 0, 10, 20).
//
// The division of labour is the Brain's, not the Body's: `ss_runtime_update`
// enumerates every INTEGER frame the playhead crossed this step
// (`playback_controller.rs` `passed_frames`) and collects each crossed frame's
// events; the Body just polls the whole batch once and dispatches each. These
// tests pin the two consequences a Player author cares about:
//
//   * Frame-skip — a single large `advance` that jumps over several event
//     frames delivers ALL of their events together in one poll (nothing is
//     lost, no per-frame stepping needed on the Body side).
//   * Sub-frame — events live on integer frames, so sampling at fractional
//     sub-frame positions between them fires each event exactly once, never
//     once per sub-step.
//
// Requires scripts/build-runtime.sh + scripts/deploy-examples.sh.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

const _mp3 = 'MP3_44khz_mono_160kbps'; // frame 10, loop 3
const _wav = 'WAV_16khz_mono_256kbps_s16'; // frame 20, loop 1

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final path = _fixture('Sound.ssab');

  test('one large advance batches every skipped frame\'s events into one poll',
      () async {
    if (path == null) {
      markTestSkipped('Sound.ssab missing — run deploy-examples.sh');
      return;
    }

    final audios = <SsAudioEvent>[];
    final player = SpriteStudioPlayer()..onAudio = audios.add;
    addTearDown(player.dispose);

    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    await player.load(bytes, animationName: 'anime_1', loadTextures: false);
    player.loopCount = 1;
    player.play();

    // A SINGLE update with a delta large enough to cross frames 10 and 20 at
    // once. Frame-skip is on by default, so the Brain steps over them and
    // reports all their events in this one poll — the alternative (clamp to one
    // frame per update) would surface at most one.
    player.advance(const Duration(milliseconds: 1000));

    final names = audios.map((a) => a.soundName).toSet();
    expect(audios.length, greaterThanOrEqualTo(2),
        reason: 'skipped-frame events must arrive together, not one per update');
    expect(names, containsAll(<String>[_mp3, _wav]));
  });

  test('sub-frame sampling fires each integer-frame event exactly once',
      () async {
    if (path == null) {
      markTestSkipped('Sound.ssab missing — run deploy-examples.sh');
      return;
    }

    final audios = <SsAudioEvent>[];
    final player = SpriteStudioPlayer()..onAudio = audios.add;
    addTearDown(player.dispose);

    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    await player.load(bytes, animationName: 'anime_1', loadTextures: false);
    expect(player.subFrameEnabled, isTrue, reason: 'sub-frame is on by default');
    player.loopCount = 1;
    player.play();

    // Fine 4ms steps → several sub-frame samples per integer frame. If events
    // re-fired per sub-step, the frame-10/20 sounds would each fire many times.
    var completed = false;
    player.onAnimationFinished = () => completed = true;
    for (var i = 0; i < 4000 && !completed; i++) {
      player.advance(const Duration(milliseconds: 4));
    }
    expect(completed, isTrue, reason: 'should reach the end within the budget');

    int count(String name) =>
        audios.where((a) => a.soundName == name).length;
    expect(count(_mp3), 1, reason: 'no sub-frame double-fire');
    expect(count(_wav), 1, reason: 'no sub-frame double-fire');
  });
}

String? _fixture(String name) => _firstExisting([
      'examples/overall/assets/spritestudio/overall/$name',
      '../../examples/overall/assets/spritestudio/overall/$name',
    ]);

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
