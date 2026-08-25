// Player-level flip / offset (ForUnity's FlipX/FlipY/Offset, ForGodot's
// flip_h/flip_v/offset).
//
// The load-bearing property is not "the animation is mirrored" — it is that the
// geometry and the part poses are mirrored by the SAME transform. Split them and
// every SpriteStudioPartAnchor comes off its part the moment a player is
// flipped, which is worse than not having the feature. So the real-Brain tests
// below assert the two consumers against each other: what `beginFrame` handed
// the backend must be exactly what `partWorldMatrix` folded in.
//
// The pure-math group needs no Brain; the rest drive Ringo and skip when the
// example assets have not been deployed (`scripts/deploy-examples.sh`).
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/render/backend/canvas_backend.dart';
import 'package:ssplayer_flutter/src/render/backend/render_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SsRootTransform', () {
    test('identity draws as authored and short-circuits compose', () {
      const root = SsRootTransform.identity;
      expect(root.isIdentity, isTrue);
      expect(root.isMirrored, isFalse);
      expect(root.scaleX, 1.0);
      expect(root.scaleY, 1.0);

      final m = Matrix4.translationValues(7, 11, 0);
      expect(identical(root.compose(m), m), isTrue,
          reason: 'the common case must not allocate');
    });

    test('compose mirrors the flipped axis only, then adds the offset', () {
      const root =
          SsRootTransform(flipX: true, offset: ui.Offset(10, -20));
      final pose = Matrix4.identity()
        ..[0] = 2.0
        ..[1] = 3.0
        ..[4] = 4.0
        ..[5] = 5.0
        ..[12] = 100.0
        ..[13] = 200.0;

      final s = root.compose(pose).storage;
      expect(s[0], -2.0);
      expect(s[1], 3.0, reason: 'flipX must not touch the Y row');
      expect(s[4], -4.0);
      expect(s[5], 5.0);
      // Offset rides on top of the mirrored position and is not itself mirrored
      // (both siblings apply it after the scale).
      expect(s[12], -100.0 + 10.0);
      expect(s[13], 200.0 - 20.0);
    });

    test('a single flip is a reflection; two cancel', () {
      expect(const SsRootTransform(flipX: true).isMirrored, isTrue);
      expect(const SsRootTransform(flipY: true).isMirrored, isTrue);
      expect(const SsRootTransform(flipX: true, flipY: true).isMirrored, isFalse,
          reason: 'flipping both axes is a half turn, not a mirror');
    });

    test('mirrorCancel undoes the flip on the child, not on the position', () {
      const root = SsRootTransform(flipX: true);
      // A part sitting 30px to the right of the origin, unrotated.
      final pose = Matrix4.translationValues(30, 0, 0);
      final drawn = root.compose(pose);

      final cancelled = drawn.multiplied(root.mirrorCancel);
      // Followed to the mirrored side…
      expect(cancelled.storage[12], -30.0);
      expect(cancelled.storage[13], 0.0);
      // …but the child's own frame is back to identity: no mirror, and — the
      // part the siblings cannot manage — no leftover half turn either.
      expect(cancelled.storage[0], 1.0);
      expect(cancelled.storage[1], 0.0);
      expect(cancelled.storage[4], 0.0);
      expect(cancelled.storage[5], 1.0);
    });

    test('equality and copyWith carry each field', () {
      const a = SsRootTransform(flipX: true, offset: ui.Offset(1, 2));
      expect(a.copyWith(flipY: true).flipX, isTrue);
      expect(a.copyWith(offset: ui.Offset.zero), const SsRootTransform(flipX: true));
      expect(a, const SsRootTransform(flipX: true, offset: ui.Offset(1, 2)));
      expect(a == const SsRootTransform(offset: ui.Offset(1, 2)), isFalse);
    });
  });

  group('SpriteStudioInternalPlayer.rootTransform (real Brain)', () {
    test('defaults to identity and leaves part poses untouched', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      expect(p.rootTransform, SsRootTransform.identity);

      final apple = p.findPartIndex('apple');
      final m = p.partWorldMatrix(apple)!;
      final sampled = p.subFrameEnabled ? p.frameNo : p.frameNo.floorToDouble();
      p.getFrameData(sampled);
      final w = p.worldMatrices();
      final base = apple * 16;
      expect(m.storage[0], w[base + 0]);
      expect(m.storage[12], w[base + 12]);
    });

    test('a flip mirrors the part pose on that axis only', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      final apple = p.findPartIndex('apple');
      final plain = p.partWorldMatrix(apple)!.storage.toList();

      p.rootTransform = const SsRootTransform(flipX: true);
      final flipped = p.partWorldMatrix(apple)!.storage;
      expect(flipped[0], -plain[0]);
      expect(flipped[4], -plain[4]);
      expect(flipped[12], -plain[12]);
      expect(flipped[1], plain[1], reason: 'the Y row is not a flipX concern');
      expect(flipped[5], plain[5]);
      expect(flipped[13], plain[13]);

      p.rootTransform = const SsRootTransform(flipY: true);
      final flippedY = p.partWorldMatrix(apple)!.storage;
      expect(flippedY[1], -plain[1]);
      expect(flippedY[13], -plain[13]);
      expect(flippedY[0], plain[0]);
      expect(flippedY[12], plain[12]);
    });

    test('an offset shifts the part pose by exactly that much', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      final apple = p.findPartIndex('apple');
      final plain = p.partWorldMatrix(apple)!.storage.toList();

      p.rootTransform = const SsRootTransform(offset: ui.Offset(12, -34));
      final moved = p.partWorldMatrix(apple)!.storage;
      expect(moved[12], plain[12] + 12);
      expect(moved[13], plain[13] - 34);
      // A pure translation must not disturb the basis.
      expect(moved[0], plain[0]);
      expect(moved[5], plain[5]);
    });

    test('the backend draws with the same transform the part poses carry', () {
      final bytes = _ringo();
      if (bytes == null) return;
      final spy = _RootSpy();
      final p = SpriteStudioInternalPlayer.load(bytes,
          renderBackendOverride: spy);
      addTearDown(p.dispose);
      p.setupAnimation(SsAnimeInfo(bytes).animationNames.first);
      p.update(const Duration(milliseconds: 16));

      const root = SsRootTransform(flipX: true, offset: ui.Offset(5, 9));
      p.rootTransform = root;

      final apple = p.findPartIndex('apple');
      final pose = p.partWorldMatrix(apple)!;

      final recorder = ui.PictureRecorder();
      p.paint(ui.Canvas(recorder),
          dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
      recorder.endRecording().dispose();

      // The one place the flip is resolved, reaching both consumers.
      expect(spy.seen, root);

      // And the pose really is the drawn one: re-folding the raw world matrix
      // with what the backend got reproduces it term for term.
      final sampled = p.subFrameEnabled ? p.frameNo : p.frameNo.floorToDouble();
      p.getFrameData(sampled);
      final w = p.worldMatrices();
      final base = apple * 16;
      final raw = Matrix4.identity()
        ..[0] = w[base + 0]
        ..[1] = w[base + 1]
        ..[4] = w[base + 4]
        ..[5] = w[base + 5]
        ..[12] = w[base + 12]
        ..[13] = w[base + 13];
      expect(pose.storage, spy.seen!.compose(raw).storage);
    });
  });

  group('CanvasBackend placement', () {
    // The reference backend's half of the deal: what beginFrame leaves on the
    // canvas is what mirrors the pixels. (The flutter_gpu backend folds the same
    // transform into its ortho projection, which no headless test can reach —
    // it is covered on-device by examples/overall/integration_test/
    // gpu_backend_test.dart, whose Canvas-vs-GPU pixel compare would catch the
    // two drifting apart.)
    test('centres the origin, then applies the offset and the flip', () {
      const dst = ui.Rect.fromLTWH(0, 0, 200, 100);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      CanvasBackend().beginFrame(canvas,
          dst: dst,
          root: const SsRootTransform(flipX: true, offset: ui.Offset(7, -3)));
      final m = Matrix4.fromFloat64List(canvas.getTransform());
      recorder.endRecording().dispose();

      // A player-local point lands at `centre + offset + scale · local`.
      final p = MatrixUtils.transformPoint(m, const ui.Offset(10, 20));
      expect(p.dx, closeTo(100 + 7 - 10, 1e-9));
      expect(p.dy, closeTo(50 - 3 + 20, 1e-9));
    });
  });

  group('SpriteStudioPlayer flip / offset (L3)', () {
    test('round-trips through rootTransform and notifies', () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);

      var notifications = 0;
      player.addListener(() => notifications++);

      // Settable before load, and pushed down once the pack lands — the same
      // contract subFrame has.
      player.flipX = true;
      player.offset = const ui.Offset(4, 6);
      expect(notifications, 2);
      expect(player.rootTransform,
          const SsRootTransform(flipX: true, offset: ui.Offset(4, 6)));

      await player.load(bytes,
          animationName: SsAnimeInfo(bytes).animationNames.first,
          loadTextures: false);
      expect(player.internal!.rootTransform, player.rootTransform);

      // Setting the same value again is not a change, so it owes no repaint.
      final before = notifications;
      player.flipX = true;
      expect(notifications, before);

      player.advance(const Duration(milliseconds: 16));
      final apple = player.findPartIndex('apple');
      player.flipY = true;
      final both = player.partTransformOf(apple)!;
      player.rootTransform = SsRootTransform.identity;
      final plain = player.partTransformOf(apple)!;
      expect(both.storage[12], -plain.storage[12] + 4);
      expect(both.storage[13], -plain.storage[13] + 6);
    });
  });

  group('SpriteStudioPartAnchor under a flip (L4 widget)', () {
    testWidgets('follows the mirrored position; cancel keeps the child upright',
        (tester) async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes,
          animationName: SsAnimeInfo(bytes).animationNames.first,
          loadTextures: false);
      player.advance(const Duration(milliseconds: 16));
      player.flipX = true;

      const childKey = Key('anchored-child');
      Widget host(SpriteStudioAnchorMirror mirror) => Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: SpriteStudioPartAnchor(
                  player: player,
                  partName: 'apple',
                  // Mirroring is a sign on the scale, so this is only a question
                  // once the scale is followed — which is not the default.
                  scale: true,
                  onMirrored: mirror,
                  child: const SizedBox(key: childKey, width: 8, height: 8),
                ),
              ),
            ),
          );

      Matrix4 poseOf() => tester
          .widget<Transform>(find.ancestor(
              of: find.byKey(childKey), matching: find.byType(Transform)))
          .transform;

      await tester.pumpWidget(host(SpriteStudioAnchorMirror.follow));
      final followed = poseOf().clone();

      await tester.pumpWidget(host(SpriteStudioAnchorMirror.cancel));
      final cancelled = poseOf();

      // Same place either way — cancelling takes the mirror out of the child's
      // own frame, never out of the position it followed.
      expect(cancelled.storage[12], followed.storage[12]);
      expect(cancelled.storage[13], followed.storage[13]);

      // …and it really is un-mirrored: the 2D determinants are opposite in sign.
      double det(Matrix4 m) =>
          m.storage[0] * m.storage[5] - m.storage[4] * m.storage[1];
      expect(det(cancelled), closeTo(-det(followed), 1e-9));
      expect(det(cancelled), greaterThan(0),
          reason: "'apple' is authored unmirrored, so cancelling a single "
              'player flip must leave a proper basis');
    });
  });
}

/// A backend that records the root transform it is drawn with and ignores every
/// actual pixel operation.
class _RootSpy implements RenderBackend {
  SsRootTransform? seen;

  @override
  void beginFrame(ui.Canvas canvas,
      {ui.Rect? dst,
      ui.Size? sourceSize,
      SsRootTransform root = SsRootTransform.identity}) {
    seen = root;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
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
