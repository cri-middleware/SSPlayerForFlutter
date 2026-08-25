// Verifies the externally-clocked L3 path added for the Flame adapter: a
// SpriteStudioPlayer built WITHOUT a `vsync` has no Ticker, so the host drives
// time by calling `advance(delta)` each frame (what a Flame component forwards
// from its `update(dt)`). The vsync path is exercised by transport/loop tests.
//
//   flutter test test/external_clock_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab/ssab.g.dart' as ssab;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Basic.ssab',
    '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
  ]);

  test('no-vsync player advances via advance() and fires completion', () async {
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final animName = ssab.SsAnimeBinary(bytes).animations!.first.name!;

    // No `vsync`: externally clocked. Constructing one used to be impossible
    // (vsync was required); this is the surface the Flame adapter relies on.
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);

    var completed = 0;
    player.onComplete = () => completed++;

    // loadTextures:false keeps the test hermetic (no asset bundle needed).
    await player.load(bytes, animationName: animName, loadTextures: false);
    // loop set AFTER setup: setAnimation resets the Brain's loop counter, so
    // an earlier `loop=1` would fall back to infinite and never complete.
    player.loopCount = 1; // play once so onComplete can fire
    player.play();
    expect(player.frameNo, 0, reason: 'play() head-outs to frame 0');
    expect(player.isPlaying, isTrue);

    // Host-driven clock: advance in 16ms steps. frameNo must climb.
    player.advance(const Duration(milliseconds: 16));
    final afterOne = player.frameNo;
    expect(afterOne, greaterThan(0), reason: 'advance() should drive the Brain');

    // Run well past the end of a single loop; onComplete fires exactly once on
    // the finished rising edge, with no Ticker involved. Budget matches
    // loop_events_test's proven-generous 2000×16ms (a single Basic loop is long).
    for (var i = 0; i < 2000 && completed == 0; i++) {
      player.advance(const Duration(milliseconds: 16));
    }
    expect(completed, 1, reason: 'onComplete should fire once, host-clocked');
    expect(player.frameNo, greaterThan(afterOne));
  });

  test('advance() is a no-op before load and after dispose', () {
    final player = SpriteStudioPlayer();
    // Before load: nothing to drive, must not throw.
    player.advance(const Duration(milliseconds: 16));
    player.dispose();
    // After dispose: still safe (guards on _disposed).
    player.advance(const Duration(milliseconds: 16));
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
