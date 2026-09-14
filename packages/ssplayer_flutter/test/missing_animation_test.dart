// A name the pack does not have has to come back as a failure and say so.
//
// Two paths reach `setupAnimation`, and both used to lose the answer: `load`
// assigned `currentAnimation` from its argument BEFORE setting it up, so a bad
// `animationName` left the player naming an animation it had never selected —
// and `setAnimation` compares against that same field, so re-asking for the very
// same bad name returned `true` without doing anything.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Basic.ssab',
    '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
  ]);

  Uint8List readSsab() => File(ssabPath!).readAsBytesSync();

  test('load() with a name the pack lacks does not claim it is selected',
      () async {
    if (ssabPath == null) {
      markTestSkipped('overall assets missing — run scripts/deploy-examples.sh');
      return;
    }
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);

    await player.load(readSsab(),
        animationName: 'no_such_animation', loadTextures: false);

    // Not 'no_such_animation': nothing was set up, so nothing is current.
    expect(player.currentAnimation, isNull);

    // The real bug this guards: `setAnimation` early-returns on
    // `currentAnimation == name`, so the stale assignment made a second attempt
    // at the same bad name report success.
    expect(player.setAnimation('no_such_animation'), isFalse);
  });

  test('setAnimation returns false for a name the pack lacks, and reports once',
      () async {
    if (ssabPath == null) {
      markTestSkipped('overall assets missing — run scripts/deploy-examples.sh');
      return;
    }
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);
    await player.load(readSsab(), loadTextures: false);

    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);

    expect(player.setAnimation('wakl'), isFalse);
    expect(player.setAnimation('wakl'), isFalse,
        reason: 'still false the second time — nothing was selected');

    // Once per wrong name: `setAnimation` leaves `currentAnimation` alone on
    // failure, so its own early return cannot absorb the repeat. A state machine
    // asserting a typo every frame must not fill the console.
    final missing = lines.where((l) => l.contains('wakl')).toList();
    expect(missing, hasLength(1), reason: lines.join('\n'));
    expect(missing.single, contains('could not select animation "wakl"'));
    // The Brain's own wording, carried through `ss_runtime_get_last_error` and
    // `ss_runtime_error_message`. Asserting it is what pins the whole chain:
    // the C ABI, the generated bindings, L2's accessor and L3's report.
    expect(missing.single, contains('Animation not found'),
        reason: 'the reason should come from the runtime, not be assumed');

    // A different wrong name is a different report.
    expect(player.setAnimation('also_wrong'), isFalse);
    expect(lines.where((l) => l.contains('also_wrong')), hasLength(1));

    // And a real one still works, with nothing reported.
    final real = player.animationNames.first;
    expect(player.setAnimation(real), isTrue);
    expect(player.currentAnimation, real);
    expect(lines.where((l) => l.contains('"$real"')), isEmpty);
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
