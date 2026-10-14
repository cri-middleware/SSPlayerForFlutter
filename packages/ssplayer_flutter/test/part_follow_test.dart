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
import 'dart:ui' as ui;

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

  // A follower reads the frame after an advance and before paint draws it. The
  // tick builds that frame; the reads and paint use it and build none.
  group('a tick builds its frame once, and the reads build none (real Brain)',
      () {
    test('the reads and paint add no evaluation to the tick', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.play();
      final apple = p.findPartIndex('apple');

      final before = p.debugEvaluations;
      p.update(const Duration(milliseconds: 16));
      p.partWorldMatrix(apple);
      p.partHidden(apple);
      _paint(p);
      expect(p.debugEvaluations, before + 1);

      p.update(const Duration(milliseconds: 16));
      p.partWorldMatrix(apple);
      p.partHidden(apple);
      _paint(p);
      expect(p.debugEvaluations, before + 2);
    });

    test('an override shows from the next update, however often it is read',
        () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));
      final apple = p.findPartIndex('apple');

      expect(p.setPartVisibilityOverrideByIndex(apple, true), isTrue);
      final evaluations = p.debugEvaluations;
      for (var i = 0; i < 3; i++) {
        expect(p.partHidden(apple), isFalse,
            reason: 'read ${i + 1} before the update');
      }
      expect(p.debugEvaluations, evaluations, reason: 'a read builds nothing');
      p.update(Duration.zero);
      expect(p.partHidden(apple), isTrue);

      expect(p.clearPartVisibilityOverrideByIndex(apple), isTrue);
      expect(p.partHidden(apple), isTrue);
      p.update(Duration.zero);
      expect(p.partHidden(apple), isFalse);
    });

    test('a read before the first update keeps an override set after play', () {
      // Apple's cell is keyed at frame 0, and the first update after play
      // passes frame 0. An overwrite-on-next-keyframe override set there holds
      // only if that update is the first to evaluate it, so a read that built
      // a frame before the update would hand it back to the animation.
      if (_ringo() == null) return;
      Float32List firstFrameUvs({required bool read, bool override = true}) {
        final p = _load()!;
        addTearDown(p.dispose);
        final apple = p.findPartIndex('apple');
        p.play();
        if (override) {
          expect(
              p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3',
                  priority: SsOverridePriority.overwriteOnNextKeyframe),
              isTrue);
        }
        if (read) {
          p.partHidden(apple);
          p.partWorldMatrix(apple);
        }
        p.update(const Duration(milliseconds: 16));
        return Float32List.fromList(
            p.localUvs().sublist(apple * 10, apple * 10 + 10));
      }

      final unread = firstFrameUvs(read: false);
      expect(firstFrameUvs(read: false, override: false), isNot(equals(unread)),
          reason: 'the override must actually take, or the test proves nothing');
      expect(firstFrameUvs(read: true), unread);
    });

    test('a follower and the paint see one overwrite-on-next-keyframe override',
        () {
      // Apple's cell is keyed at frame 0, and the override goes in before the
      // first update leaves it, so it holds only because the Brain skips its
      // own keyframe through that update. The follower and the paint both read
      // that update, and both must see the override.
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');
      Float32List uvs() {
        final sampled =
            p.subFrameEnabled ? p.frameNo : p.frameNo.floorToDouble();
        p.getFrameData(sampled);
        return Float32List.fromList(
            p.localUvs().sublist(apple * 10, apple * 10 + 10));
      }

      p.play();
      final animation = uvs();
      expect(
          p.setPartCellOverrideByIndex(apple, 'Ringo', 'effect3',
              priority: SsOverridePriority.overwriteOnNextKeyframe),
          isTrue);
      p.update(const Duration(milliseconds: 16));
      final follower = uvs();
      expect(follower, isNot(equals(animation)));
      expect(uvs(), follower);
    });

    // The Brain moves the playhead to a section's head when the section is set,
    // and nothing else is coming to build that frame on a paused player.
    test('a section builds the frame at the head it moves the playhead to', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');
      final head = p.partWorldMatrix(apple); // setup leaves it on the head
      p.seek(p.endFrame.toDouble());
      expect(p.partWorldMatrix(apple), isNot(head),
          reason: 'the last frame must pose the apple elsewhere');

      p.setAnimationSection(p.startFrame, p.endFrame);
      expect(p.frameNo, p.startFrame);
      expect(p.partWorldMatrix(apple), head);
    });

    test('a new animation is evaluated afresh at the same frame number', () {
      final names = _animations();
      if (names.length < 2) return;
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      final apple = p.findPartIndex('apple');
      p.partWorldMatrix(apple); // the first animation's frame 0

      expect(p.setupAnimation(names[1]), isTrue);
      final fresh = _load()!;
      addTearDown(fresh.dispose);
      expect(fresh.setupAnimation(names[1]), isTrue);
      expect(p.partWorldMatrix(apple), fresh.partWorldMatrix(apple));
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

    // A paused player has no tick coming, so a call that moves its pose must
    // notify for the view and its followers to show the move.
    test('a section on a paused player notifies, and the reads report its head',
        () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);
      final head = player.partTransform('apple')!;
      player
        ..play()
        ..advance(const Duration(milliseconds: 100))
        ..pause()
        ..seek(player.endFrame.toDouble());
      expect(player.partTransform('apple')!.storage, isNot(head.storage));

      var notified = 0;
      player.addListener(() => notified++);
      player.setAnimationSection(player.startFrame, player.endFrame);
      expect(notified, 1);
      expect(player.frameNo, player.startFrame);
      expect(player.partTransform('apple')!.storage, head.storage);
    });

    test('the sub-frame toggle notifies when it changes, and only then',
        () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);
      var notified = 0;
      player.addListener(() => notified++);

      player.subFrameEnabled = true; // already on
      expect(notified, 0);
      player.subFrameEnabled = false;
      expect(notified, 1);
      expect(player.subFrameEnabled, isFalse);
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

  group('an override on a player whose Ticker is stopped (L3)', () {
    testWidgets('shows on the next frame, in the reads', (tester) async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer(vsync: tester);
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: _animations().first, loadTextures: false);

      expect(player.setPartVisibilityOverride('apple', true), isTrue);
      expect(player.isPartHidden('apple'), isFalse,
          reason: 'it shows from the next tick, not at the call');
      await tester.pump();
      expect(player.isPartHidden('apple'), isTrue,
          reason: 'a stopped Ticker gets one zero-length tick for it');
      expect(player.isPlaying, isFalse, reason: 'the tick does not play');
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
void _paint(SpriteStudioInternalPlayer p) {
  final recorder = ui.PictureRecorder();
  p.paint(ui.Canvas(recorder), dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
  recorder.endRecording().dispose();
}

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
