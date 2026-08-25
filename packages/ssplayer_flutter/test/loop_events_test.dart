// Loop/finish semantics against the HOST-built Brain.
//
// Requires the same setup as internal_player_smoke_test.dart:
//   * scripts/build-runtime.sh
//   * scripts/deploy-examples.sh
//
// These pin the two cases that let a truncation bug live in the tick loop
// unnoticed: a finite loop count above 1, and a commanded stop.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab/ssab.g.dart' as ssab;

/// Drives the Brain a frame at a time, recording the events a Player would
/// observe by polling after each update — `justLooped` verbatim, `isFinished`
/// through a rising edge.
List<String> _collectEvents(SpriteStudioInternalPlayer player, int steps) {
  final events = <String>[];
  var prevFinished = false;
  for (var i = 0; i < steps; i++) {
    player.update(const Duration(milliseconds: 16));
    if (player.justLooped) events.add('looped');
    final finished = player.isFinished;
    if (finished && !prevFinished) events.add('finished');
    prevFinished = finished;
  }
  return events;
}

void main() {
  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Basic.ssab',
    '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
  ]);

  SpriteStudioInternalPlayer? setup(int loop) {
    if (ssabPath == null) return null;
    final bytes = File(ssabPath).readAsBytesSync();
    final anime = ssab.SsAnimeBinary(Uint8List.fromList(bytes));
    final animName = anime.animations!.first.name!;
    final player = SpriteStudioInternalPlayer.load(Uint8List.fromList(bytes));
    player.setupAnimation(animName);
    player.loopCount = loop;
    player.play();
    return player;
  }

  test('loop=3 emits looped, looped, finished', () {
    final player = setup(3);
    if (player == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }
    addTearDown(player.dispose);

    // Generous budget: must cover all three cycles, not just the first.
    expect(_collectEvents(player, 2000), ['looped', 'looped', 'finished']);
    expect(player.isPlaying, isFalse);
  });

  test('loop=1 emits finished with no looped', () {
    final player = setup(1);
    if (player == null) {
      markTestSkipped('Basic.ssab missing');
      return;
    }
    addTearDown(player.dispose);

    expect(_collectEvents(player, 2000), ['finished']);
  });

  test('infinite loop keeps looping and never finishes', () {
    final player = setup(-1);
    if (player == null) {
      markTestSkipped('Basic.ssab missing');
      return;
    }
    addTearDown(player.dispose);

    final events = _collectEvents(player, 2000);
    expect(events, isNotEmpty);
    expect(events, everyElement('looped'));
    expect(player.isFinished, isFalse);
    expect(player.isPlaying, isTrue);
  });

  test('loop=0 behaves as infinite, not as play-once', () {
    final player = setup(0);
    if (player == null) {
      markTestSkipped('Basic.ssab missing');
      return;
    }
    addTearDown(player.dispose);

    final events = _collectEvents(player, 2000);
    expect(events, isNotEmpty);
    expect(events, everyElement('looped'));
    expect(player.isFinished, isFalse);
  });

  test('stop() mid-playback does not report finished', () {
    final player = setup(3);
    if (player == null) {
      markTestSkipped('Basic.ssab missing');
      return;
    }
    addTearDown(player.dispose);

    player.update(const Duration(milliseconds: 16));
    player.stop();
    expect(player.isPlaying, isFalse);
    expect(player.isFinished, isFalse,
        reason: 'a commanded stop is not a completion');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
