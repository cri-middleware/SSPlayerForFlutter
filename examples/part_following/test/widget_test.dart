// Drives the part-following demo far enough to prove the follower is real and
// the skinned-mesh hint is wired: the app loads the Ringo pack, the default
// target (`bone_14`) exists and is a GOOD target (not skinned), a hand IS a
// skinned mesh, and the marker widget is mounted over the animation.
//
// The demo runs on a Ticker, so this never pumpAndSettle()s — it pumps fixed
// durations, exactly as a human watching the app would judge it.
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

import 'package:ssplayer_part_following_example/main.dart';

void main() {
  testWidgets('loads Ringo and mounts a follower on the default part',
      (tester) async {
    if (!_deployed()) return _skipUndeployed();
    await tester.pumpWidget(const PartFollowingApp());
    await _load(tester);

    // The anchor is present and its marker mounted over the view.
    expect(find.byType(SpriteStudioView), findsOneWidget);
    expect(find.byType(SpriteStudioPartAnchor), findsOneWidget);
    expect(find.byIcon(Icons.star), findsOneWidget,
        reason: 'the marker sticks to a resolvable part');

    await _teardown(tester);
  });

  testWidgets('the default target is a good (non-skinned) part; a hand is skinned',
      (tester) async {
    // A rename in tests/Ringo would otherwise only show up as a demo whose
    // marker silently never appears; the skinned checks pin the teaching point.
    if (!_deployed()) return _skipUndeployed();
    await tester.pumpWidget(const PartFollowingApp());
    final player = await _load(tester);

    expect(player.findPartIndex(kDefaultPart), greaterThanOrEqualTo(0),
        reason: '$kDefaultPart must resolve');
    expect(player.isPartSkinnedMesh(kDefaultPart), isFalse,
        reason: '$kDefaultPart is a bone — a recommended follow target');
    expect(player.isPartSkinnedMesh('hand_r'), isTrue,
        reason: "Ringo's hand is a bone-bound mesh — a poor target");
    expect(player.partNames.names.where((n) => n.isNotEmpty), isNotEmpty);

    // After a pumped frame the default part has a live transform to follow.
    expect(player.partTransform(kDefaultPart), isNotNull);

    await _teardown(tester);
  });
}

/// The pack `scripts/deploy-examples.sh` writes. It is gitignored, so a fresh
/// clone has none: that is a skip, reported as one. A pack that is there and
/// still does not load is a failure — see [_load].
bool _deployed() =>
    File('assets/spritestudio/$kPack/$kPack.ssab').existsSync();

void _skipUndeployed() =>
    markTestSkipped('$kPack.ssab not deployed — run scripts/deploy-examples.sh');

/// The live player once the deployed pack has loaded and the follower mounted.
Future<SpriteStudioPlayer> _load(WidgetTester tester) async {
  final player = await _awaitLoad(tester);
  if (player == null) {
    fail('$kPack.ssab is deployed but never loaded: the follower did not mount');
  }
  return player;
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// Waits for `loadAsset` to finish and the follower to mount, returning the live
/// player, or null when the pack never loads. `testWidgets` runs in a fake-async
/// zone, so alternate
/// [WidgetTester.runAsync] (real event loop, so the file I/O can progress) with a
/// pumped frame (so the resulting setState is observable).
Future<SpriteStudioPlayer?> _awaitLoad(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
    // The anchor mounts only once `_loaded` is true; its presence proves the
    // pack loaded and the widget rebuilt.
    if (find.byType(SpriteStudioPartAnchor).evaluate().isNotEmpty) {
      // A couple more frames so the Ticker advances and the world matrices —
      // and therefore partTransform — are final.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      return _playerOf(tester);
    }
  }
  return null;
}

SpriteStudioPlayer? _playerOf(WidgetTester tester) {
  final finder = find.byType(PartFollowingPage);
  if (finder.evaluate().isEmpty) return null;
  return (tester.state(finder) as dynamic).player as SpriteStudioPlayer;
}
