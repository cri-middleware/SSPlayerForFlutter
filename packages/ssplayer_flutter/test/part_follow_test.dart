// Part following — the read side of part overrides: pull a part's live world pose / hide
// out so a follower (the SpriteStudioPartAnchor widget, a Flame component) can
// track it. ForUnity's part tracker / ForGodot's part attachment, done the
// Flutter way.
//
// These drive a real Brain against Ringo.ssab and skip when the example assets
// have not been deployed (`scripts/deploy-examples.sh`). The strongest check is
// deterministic: partWorldMatrix must carry exactly the six affine terms of the
// raw SoA world matrix, with an identity Z/W row so no stray scale or
// perspective leaks into a `Transform` widget.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpriteStudioInternalPlayer.partWorldMatrix (real Brain)', () {
    test('carries only the 2D affine of the raw world matrix', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      final apple = p.findPartIndex('apple');
      final m = p.partWorldMatrix(apple);
      expect(m, isNotNull);

      // Re-sample the same frame the getter used and read the raw SoA slice.
      final sampled = p.subFrameEnabled ? p.frameNo : p.frameNo.floorToDouble();
      p.getFrameData(sampled);
      final w = p.worldMatrices();
      final base = apple * 16;
      final s = m!.storage;

      // The six affine terms (m0, m1, m4, m5, m12, m13) are copied verbatim.
      expect(s[0], w[base + 0]);
      expect(s[1], w[base + 1]);
      expect(s[4], w[base + 4]);
      expect(s[5], w[base + 5]);
      expect(s[12], w[base + 12]);
      expect(s[13], w[base + 13]);

      // The Z/W rows are identity — the contract that keeps a rogue Z scale or
      // perspective term out of the follower's Transform.
      expect(s[2], 0.0);
      expect(s[3], 0.0);
      expect(s[6], 0.0);
      expect(s[7], 0.0);
      expect(s[8], 0.0);
      expect(s[9], 0.0);
      expect(s[10], 1.0);
      expect(s[11], 0.0);
      expect(s[14], 0.0);
      expect(s[15], 1.0);
    });

    test('returns null for an out-of-range index', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      // -1 is what an unknown name resolves to; a huge index is out of the SoA.
      expect(p.partWorldMatrix(-1), isNull);
      expect(p.partWorldMatrix(1 << 20), isNull);
    });

    test('a drawn part reports not hidden', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      final apple = p.findPartIndex('apple');
      // `apple` is drawn in Ringo's first animation, so it is present and shown.
      expect(p.partHidden(apple), isFalse);
      expect(p.partHidden(-1), isFalse);
    });
  });

  group('SpriteStudioPlayer part-follow reads (L3)', () {
    test('are a safe null / false before load', () {
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);

      // A UI that queries a pose while the pack is still loading is not a bug —
      // like the overrides, these no-op rather than throw.
      expect(player.partTransform('apple'), isNull);
      expect(player.partTransformByIndex(0), isNull);
      expect(player.isPartHidden('apple'), isFalse);
      expect(player.isPartHiddenByIndex(0), isFalse);
      expect(player.isPartSkinnedMesh('apple'), isFalse);
      expect(player.isPartSkinnedMeshByIndex(0), isFalse);
    });

    test('resolve by name and by index to the same matrix after a frame',
        () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);
      player.advance(const Duration(milliseconds: 16));

      final apple = player.findPartIndex('apple');
      final byName = player.partTransform('apple');
      final byIndex = player.partTransformByIndex(apple);
      expect(byName, isNotNull);
      expect(byIndex, isNotNull);
      expect(byName!.storage, byIndex!.storage);

      expect(player.partTransform('no-such-part'), isNull);
      expect(player.isPartHidden('no-such-part'), isFalse);
    });

    test('isPartSkinnedMesh matches the pack\'s static PartData, both ways',
        () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);
      player.advance(const Duration(milliseconds: 16));

      // Ground truth off the very bytes we loaded — no per-part name is baked
      // into the test, so it holds whatever Ringo's mesh parts happen to be.
      final table = PartNameTable.readAll(bytes);
      for (var i = 0; i < table.length; i++) {
        final expected = table.isSkinnedMeshAt(i);
        expect(player.isPartSkinnedMeshByIndex(i), expected,
            reason: 'index $i (${table.nameAt(i)})');
        final name = table.nameAt(i);
        if (name != null && name.isNotEmpty) {
          expect(player.isPartSkinnedMesh(name), expected, reason: name);
        }
      }

      // It is a read, not a gate: unknown / out-of-range are a quiet false.
      expect(player.isPartSkinnedMesh('no-such-part'), isFalse);
      expect(player.isPartSkinnedMeshByIndex(-1), isFalse);
      expect(player.isPartSkinnedMeshByIndex(1 << 20), isFalse);
    });
  });

  group('SpriteStudioPartAnchor (L4 widget)', () {
    testWidgets('shows its child for a resolvable part, hides for an unknown one',
        (tester) async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);
      player.advance(const Duration(milliseconds: 16));

      const childKey = Key('anchored-child');
      Widget host(String partName) => Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: SpriteStudioPartAnchor(
                  player: player,
                  partName: partName,
                  child: const SizedBox(key: childKey, width: 8, height: 8),
                ),
              ),
            ),
          );

      await tester.pumpWidget(host('apple'));
      expect(find.byKey(childKey), findsOneWidget,
          reason: 'a resolvable part shows the child');

      await tester.pumpWidget(host('no-such-part'));
      expect(find.byKey(childKey), findsNothing,
          reason: 'an unknown part draws nothing');
    });

    testWidgets('scale is off by default, and asking for all three passes the affine through',
        (tester) async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);
      player.advance(const Duration(milliseconds: 16));

      const childKey = Key('anchored-child');
      Widget host({bool? scale}) => Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: SpriteStudioPartAnchor(
                  player: player,
                  partName: 'apple',
                  scale: scale ?? false,
                  child: const SizedBox(key: childKey, width: 8, height: 8),
                ),
              ),
            ),
          );

      Matrix4 appliedTransform() => tester
          .widgetList<Transform>(find.ancestor(
              of: find.byKey(childKey), matching: find.byType(Transform)))
          .first
          .transform;

      // The part's own pose, for comparison. `apple` carries a scale in Ringo,
      // so the two paths are distinguishable rather than incidentally equal.
      final world = player.partTransform('apple')!;

      await tester.pumpWidget(host(scale: true));
      final withScale = appliedTransform();

      await tester.pumpWidget(host());
      final withoutScale = appliedTransform();

      // Translation is followed either way — that is what `position` means.
      expect(withoutScale.storage[12], closeTo(withScale.storage[12], 1e-6));
      expect(withoutScale.storage[13], closeTo(withScale.storage[13], 1e-6));

      // ...but the basis is the identity's magnitude when scale is off, and the
      // part's when it is on.
      double basisLength(Matrix4 m) =>
          math.sqrt(m.storage[0] * m.storage[0] + m.storage[1] * m.storage[1]);
      expect(basisLength(withoutScale), closeTo(1.0, 1e-6),
          reason: 'the child keeps its own size by default');
      expect(basisLength(withScale), closeTo(basisLength(world), 1e-6),
          reason: 'asking for scale reproduces the part exactly');
    });

    testWidgets('a hidden part keeps its child by default; hideChild drops it',
        (tester) async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);
      player.advance(const Duration(milliseconds: 16));
      // Force-hidden rather than hunting for a frame Ringo hides 'apple' on:
      // this is an assertion about onHidden, not about the asset's keyframes.
      expect(player.setPartVisibilityOverride('apple', true), isTrue);
      player.advance(const Duration(milliseconds: 16));
      expect(player.isPartHidden('apple'), isTrue,
          reason: 'the override must actually take, or the test proves nothing');

      const childKey = Key('anchored-child');
      Widget host({SpriteStudioAnchorHidden? onHidden}) => Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: SpriteStudioPartAnchor(
                  player: player,
                  partName: 'apple',
                  onHidden: onHidden ?? SpriteStudioAnchorHidden.followAlways,
                  child: const SizedBox(key: childKey, width: 8, height: 8),
                ),
              ),
            ),
          );

      // The default, spelled by omission: it must match the sibling players'
      // follow-always, not the hide-the-child this player used to ship.
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: SpriteStudioPartAnchor(
              player: player,
              partName: 'apple',
              child: const SizedBox(key: childKey, width: 8, height: 8),
            ),
          ),
        ),
      ));
      expect(find.byKey(childKey), findsOneWidget,
          reason: 'the default keeps following a hidden part');

      await tester.pumpWidget(host(onHidden: SpriteStudioAnchorHidden.hideChild));
      expect(find.byKey(childKey), findsNothing,
          reason: 'hideChild drops the child while the part is hidden');
    });
  });
}

/// Ringo's bytes, or null (with the test marked skipped) when the example
/// assets have not been deployed.
Uint8List? _ringo() {
  for (final p in const <String>[
    'examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
    '../../examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
  ]) {
    final f = File(p);
    if (f.existsSync()) return f.readAsBytesSync();
  }
  markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
  return null;
}

/// A loaded Ringo player set up on its first animation.
SpriteStudioInternalPlayer? _load() {
  final bytes = _ringo();
  if (bytes == null) return null;
  final p = SpriteStudioInternalPlayer.load(bytes,
      backend: SpriteStudioBackend.canvas);
  p.setupAnimation(SsAnimeInfo(bytes).animationNames.first);
  return p;
}

/// Ringo's animation names, in pack order (they live in the `.ssab`).
List<String> _animations() =>
    SsAnimeInfo(_ringo() ?? Uint8List(0)).animationNames;
