// End-to-end event dispatch against the HOST-built Brain: drive a real
// pack a frame at a time through the externally-clocked L3 path and assert the
// decoded `onUserData` / `onSignal` callbacks fire. This exercises the whole
// chain — `advance` → `passedEventIndices` → `SsAnimeInfo.decodePassedEvents`
// → dispatch — that the pure `event_test.dart` cannot (it decodes directly).
//
// Requires the same setup as internal_player_smoke_test.dart:
//   * scripts/build-runtime.sh
//   * scripts/deploy-examples.sh
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UserData markers surface through onUserData over one play-through',
      () async {
    final path = _fixture('UserData.ssab');
    if (path == null) {
      markTestSkipped('UserData.ssab missing — run deploy-examples.sh');
      return;
    }

    final collected = <SsUserData>[];
    final rawBatches = <List<int>>[];
    final player = SpriteStudioPlayer()
      ..onUserData = collected.add
      ..onEvents = rawBatches.add;
    addTearDown(player.dispose);

    await _playOnce(player, Uint8List.fromList(File(path).readAsBytesSync()));

    expect(rawBatches, isNotEmpty,
        reason: 'the pack should cross at least one event frame');
    expect(collected, isNotEmpty, reason: 'onUserData should have fired');
    for (final u in collected) {
      expect(u.partIndex, greaterThanOrEqualTo(0));
    }
  });

  test('A callback that sets up another animation loses nothing the update '
      'reported', () async {
    final path = _firstExisting(const [
      'examples/overall/assets/spritestudio/Doll/Action02_Body.ssab',
      '../../examples/overall/assets/spritestudio/Doll/Action02_Body.ssab',
    ]);
    if (path == null) {
      markTestSkipped('Action02_Body.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    final names = SsAnimeInfo(bytes).animationNames;
    expect(names.length, greaterThan(1), reason: 'fixture sanity');

    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);
    await player.load(bytes, animationName: names.first, loadTextures: false);
    player
      ..loopCount = 1
      ..play();

    var reported = false;
    var finished = false;
    player
      // A decoded callback is what makes a tick look up the events' sources.
      ..onUserData = ((_) {})
      ..onAnimationFinished = (() => finished = true)
      ..onEvents = (_) {
        reported = true;
        player.setAnimation(names[1]);
      };
    // One tick past the end, so it reports both the events and the finish.
    player.advance(const Duration(seconds: 100));

    expect(reported, isTrue,
        reason: 'fixture sanity: the animation has events');
    expect(player.currentAnimation, names[1]);
    expect(finished, isTrue,
        reason: 'the update reported it before the callback ran');
  });

  test('Signals surface through onSignal over one play-through', () async {
    final path = _fixture('Signal.ssab');
    if (path == null) {
      markTestSkipped('Signal.ssab missing — run deploy-examples.sh');
      return;
    }

    final collected = <SsSignal>[];
    final player = SpriteStudioPlayer()..onSignal = collected.add;
    addTearDown(player.dispose);

    await _playOnce(player, Uint8List.fromList(File(path).readAsBytesSync()));

    expect(collected, isNotEmpty, reason: 'onSignal should have fired');
    for (final s in collected) {
      expect(s.partIndex, greaterThanOrEqualTo(0));
      expect(s.commandId, isA<String>());
    }
  });

  test('Audio triggers surface through onAudio (trigger-only)', () async {
    final path = _fixture('Sound.ssab');
    if (path == null) {
      markTestSkipped('Sound.ssab missing — run deploy-examples.sh');
      return;
    }

    final collected = <SsAudioEvent>[];
    final player = SpriteStudioPlayer()..onAudio = collected.add;
    addTearDown(player.dispose);

    await _playOnce(player, Uint8List.fromList(File(path).readAsBytesSync()));

    expect(collected, isNotEmpty, reason: 'onAudio should have fired');
    final names = collected.map((a) => a.soundName).toSet();
    // Sound.ssab authors three triggers; the two mid-timeline ones are crossed
    // reliably on any play-through (the frame-0 one is start-edge dependent).
    expect(names, contains('MP3_44khz_mono_160kbps'));
    expect(names, contains('WAV_16khz_mono_256kbps_s16'));
    final mp3 = collected.firstWhere(
        (a) => a.soundName == 'MP3_44khz_mono_160kbps');
    expect(mp3.loopNum, 3, reason: 'authored loop count is carried through');
    for (final a in collected) {
      expect(a.partIndex, greaterThanOrEqualTo(0));
      expect(a.soundNameHash, isNonZero);
    }

    // The trigger's hash resolves to a playable pack-relative file (what an app
    // feeds its own audio stack — playback stays the app's job).
    expect(player.soundFilePath(mp3.soundNameHash),
        'sound/MP3_44khz_mono_160kbps.mp3');
  });

  test('a ping-pong return leg crosses the audio keys again, and '
      'isPlayingForward tells it apart inside onAudio', () async {
    final path = _fixture('Sound.ssab');
    if (path == null) {
      markTestSkipped('Sound.ssab missing — run deploy-examples.sh');
      return;
    }

    // What a host's reverse-audio gate reads: the heading at the moment the
    // callback runs, not the configured direction.
    final forward = <String?>[], backward = <String?>[];
    late final SpriteStudioPlayer player;
    player = SpriteStudioPlayer()
      ..onAudio = (a) =>
          (player.isPlayingForward ? forward : backward).add(a.soundName);
    addTearDown(player.dispose);

    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    await player.load(bytes,
        animationName: SsAnimeInfo(bytes).animationNames.first,
        loadTextures: false);
    player
      ..setPlaybackDirection(
          SsPlaybackDirection.forward, SsPlaybackStyle.pingPong)
      ..loopCount = 1
      ..play();
    var completed = false;
    player.onAnimationFinished = () => completed = true;
    for (var i = 0; i < 2000 && !completed; i++) {
      player.advance(const Duration(milliseconds: 16));
    }

    // The two mid-timeline triggers, crossed once each way.
    const mid = ['MP3_44khz_mono_160kbps', 'WAV_16khz_mono_256kbps_s16'];
    expect(forward, containsAll(mid));
    expect(backward, containsAll(mid),
        reason: 'the Brain reports a key whichever way it is crossed');
    expect(player.playbackDirection, SsPlaybackDirection.forward,
        reason: 'only the instantaneous heading saw the return leg');
  });
}

/// Loads [bytes] into [player] (first animation, no textures), plays it once,
/// and host-clocks it to completion in 16ms steps (budget mirrors the other
/// host-clocked tests). Events fire on the internal `advance` inside the loop.
Future<void> _playOnce(SpriteStudioPlayer player, Uint8List bytes) async {
  final animName = SsAnimeInfo(bytes).animationNames.first;
  // loadTextures:false keeps the test hermetic (no asset bundle needed) — event
  // dispatch is independent of the render pass.
  await player.load(bytes, animationName: animName, loadTextures: false);
  player.loopCount = 1; // set AFTER setup: setAnimation resets the loop counter.
  player.play();

  var completed = false;
  player.onAnimationFinished = () => completed = true;
  for (var i = 0; i < 2000 && !completed; i++) {
    player.advance(const Duration(milliseconds: 16));
  }
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
