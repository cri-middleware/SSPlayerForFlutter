// Fit and align: the arithmetic, the box it fits, how the view sizes from it,
// and that the drawing and the part poses both carry the result.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

// Ringo's canvas is 800x600 with pivot (0, -0.5): the origin is on the
// canvas's bottom edge, so the box is entirely above it.
const _ringoBox = Rect.fromLTWH(-400, -600, 800, 600);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SsPlacement.resolve', () {
    const plain = SsRootTransform.identity;

    // Where a player-local point lands in the view: `centre + offset + s·p`,
    // the transform both backends apply.
    Offset drawn(SsRootTransform t, Size view, Offset p) => Offset(
        view.width / 2 + t.offset.dx + t.scaleX * p.dx,
        view.height / 2 + t.offset.dy + t.scaleY * p.dy);

    test('contain scales the box to fit and centres it', () {
      const view = Size(400, 400);
      final t = const SsPlacement().resolve(view, _ringoBox, plain);
      expect(t.scale, 0.5);
      // The box is 400x300 on screen, centred: 50 above and below.
      expect(drawn(t, view, _ringoBox.topLeft), const Offset(0, 50));
      expect(drawn(t, view, _ringoBox.bottomRight), const Offset(400, 350));
    });

    test('cover fills the view, overflowing the other axis', () {
      const view = Size(400, 100);
      final t = const SsPlacement(fit: BoxFit.cover)
          .resolve(view, _ringoBox, plain);
      expect(t.scale, 0.5);
      expect(drawn(t, view, _ringoBox.topLeft), const Offset(0, -100));
    });

    test('an alignment puts that point of the box on that point of the view',
        () {
      const view = Size(400, 600);
      final t = const SsPlacement(alignment: Alignment.bottomCenter)
          .resolve(view, _ringoBox, plain);
      // Ringo's origin is its ground line, so bottom-aligned it stands on the
      // view's bottom edge.
      expect(drawn(t, view, Offset.zero), const Offset(200, 600));
      final top = const SsPlacement(alignment: Alignment.topLeft)
          .resolve(view, _ringoBox, plain);
      expect(drawn(top, view, _ringoBox.topLeft), Offset.zero);
    });

    test('a flip changes which end of the box the alignment anchors', () {
      // A box off-centre on its origin, so mirroring moves it.
      const box = Rect.fromLTWH(-100, -600, 800, 600);
      const view = Size(800, 300); // s = 0.5, so 400 of 800 wide is spare
      for (final flipX in [false, true]) {
        final t = const SsPlacement(alignment: Alignment.centerLeft)
            .resolve(view, box, SsRootTransform(flipX: flipX));
        final a = drawn(t, view, box.centerLeft).dx;
        final b = drawn(t, view, box.centerRight).dx;
        // Whichever end is on the left after the flip, it is on the edge.
        expect([a, b].reduce((x, y) => x < y ? x : y), 0,
            reason: 'flipX: $flipX');
        expect((a - b).abs(), 400);
      }
    });

    test('the caller scale multiplies the fit, and the offset comes last', () {
      const view = Size(400, 400);
      final t = const SsPlacement().resolve(view, _ringoBox,
          const SsRootTransform(scale: 2, offset: Offset(7, -3)));
      expect(t.scale, 1.0);
      // The centre of the box sits at the view's centre, then moves by offset.
      expect(drawn(t, view, _ringoBox.center), const Offset(207, 197));
    });

    test('a frame replaces the canvas', () {
      const view = Size(100, 100);
      final t = const SsPlacement(frame: Rect.fromLTWH(-50, -100, 100, 100))
          .resolve(view, _ringoBox, plain);
      expect(t.scale, 1.0);
      expect(drawn(t, view, const Offset(-50, -100)), Offset.zero);
    });

    test('none, and a box or view with no size, leave the caller as is', () {
      const root = SsRootTransform(flipY: true, offset: Offset(1, 2));
      expect(
          const SsPlacement(fit: BoxFit.none)
              .resolve(const Size(10, 10), _ringoBox, root),
          root);
      expect(const SsPlacement().resolve(const Size(10, 10), null, root), root);
      expect(const SsPlacement().resolve(Size.zero, _ringoBox, root), root);
      expect(
          const SsPlacement()
              .resolve(const Size(10, 10), const Rect.fromLTWH(0, 0, 0, 5), root),
          root);
    });

    test('fit takes contain, cover and none only', () {
      expect(() => SsPlacement(fit: _fill()), throwsAssertionError);
    });
  });

  group('SsRootTransform scale', () {
    test('scales the pose, and mirrorCancel leaves the scale in', () {
      const t = SsRootTransform(flipX: true, scale: 2);
      expect(t.isIdentity, isFalse);
      expect(t.scaleX, -2);
      expect(t.scaleY, 2);
      final pose = t.compose(Matrix4.translationValues(10, 20, 0));
      expect(pose.getTranslation().x, -20);
      expect(pose.getTranslation().y, 40);
      // Only the flip's sign comes back out; the size stays.
      final cancelled = pose.multiplied(t.mirrorCancel);
      expect(cancelled.storage[0], 2);
      expect(cancelled.storage[5], 2);
    });
  });

  group('canvasRect', () {
    test('is the canvas placed around the origin by its pivot', () {
      final bytes = _ringo();
      if (bytes == null) return;
      expect(SsAnimeInfo(bytes).canvasRect('attack1'), _ringoBox);
    });

    test('stays with the first animation across a switch, and across a reload',
        () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await player.load(bytes, animationName: 'attack1', loadTextures: false);
      expect(player.canvasRect, _ringoBox);

      // `dead` is authored on a wider canvas; the box does not follow it.
      player.setAnimation('dead');
      expect(player.canvasSize!.width, greaterThan(800));
      expect(player.canvasRect, _ringoBox);

      await player.reload(bytes, loadTextures: false);
      expect(player.currentAnimation, 'dead');
      expect(player.canvasRect, _ringoBox);

      // A load starts over, from whatever it selects first.
      await player.load(bytes, animationName: 'dead', loadTextures: false);
      expect(player.canvasRect!.width, greaterThan(800));
    });
  });

  group('SpriteStudioView layout', () {
    testWidgets('sizes from the canvas inside a Column, as Image does',
        (tester) async {
      final player = await _loaded(tester);
      if (player == null) return;
      // A Column hands its children an unbounded height, which is where a view
      // that took the incoming constraints was given an infinite size.
      await tester.pumpWidget(_wrap(Center(
        child: SizedBox(
          width: 400,
          child: Column(children: [SpriteStudioView(player: player)]),
        ),
      )));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SpriteStudioView)), const Size(400, 300));
    });

    testWidgets('one dimension given keeps the canvas aspect', (tester) async {
      final player = await _loaded(tester);
      if (player == null) return;
      await tester.pumpWidget(_wrap(Center(
        child: SpriteStudioView(player: player, width: 200),
      )));
      expect(tester.getSize(find.byType(SpriteStudioView)), const Size(200, 150));
    });

    testWidgets('reports the canvas as its intrinsic size', (tester) async {
      final player = await _loaded(tester);
      if (player == null) return;
      await tester.pumpWidget(_wrap(Center(
        child: IntrinsicWidth(child: SpriteStudioView(player: player)),
      )));
      expect(tester.getSize(find.byType(SpriteStudioView)), const Size(800, 600));
    });

    testWidgets('is as small as allowed before there is a canvas, then grows',
        (tester) async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      await tester.pumpWidget(_wrap(Center(
        child: SpriteStudioView(player: player),
      )));
      expect(tester.getSize(find.byType(SpriteStudioView)), Size.zero);

      await tester.runAsync(() => player.load(bytes,
          animationName: 'attack1', loadTextures: false));
      await tester.pump();
      expect(tester.getSize(find.byType(SpriteStudioView)), const Size(800, 600));
    });
  });

  group('the fit reaches what is drawn', () {
    testWidgets('the part poses and a part anchor carry it', (tester) async {
      final fitted = await _loaded(tester);
      final raw = await _loaded(tester);
      if (fitted == null || raw == null) return;
      const view = Size(200, 300);
      final child = GlobalKey();
      await tester.pumpWidget(_wrap(Align(
        alignment: Alignment.topLeft,
        child: Stack(children: [
          SpriteStudioView(
              player: fitted,
              width: view.width,
              height: view.height,
              alignment: Alignment.bottomCenter),
          Positioned.fill(
            child: SpriteStudioPartAnchor(
              player: fitted,
              partName: 'apple',
              child: SizedBox(key: child, width: 1, height: 1),
            ),
          ),
        ]),
      )));

      final placed = const SsPlacement(alignment: Alignment.bottomCenter)
          .resolve(view, _ringoBox, SsRootTransform.identity);
      expect(fitted.internal!.rootTransform, placed);

      // The same frame, unfitted (never placed) and fitted.
      final p = raw.partTransform('apple')!.getTranslation();
      final q = fitted.partTransform('apple')!.getTranslation();
      expect(q.x, closeTo(placed.scale * p.x + placed.offset.dx, 1e-9));
      expect(q.y, closeTo(placed.scale * p.y + placed.offset.dy, 1e-9));

      // And the anchored child sits there, measured from the view's centre.
      final at = tester.getTopLeft(find.byKey(child));
      expect(at.dx, closeTo(view.width / 2 + q.x, 1e-6));
      expect(at.dy, closeTo(view.height / 2 + q.y, 1e-6));
    });

    test('the Canvas backend draws the art inside the fitted box', () async {
      final bytes = _ringo();
      if (bytes == null) return;
      final player = SpriteStudioPlayer(backend: SpriteStudioBackend.canvas);
      addTearDown(player.dispose);
      await player.loadAsset('assets/x/Ringo.ssab',
          animationName: 'wait1', bundle: _DirBundle(_ringoDir()!));

      // Unfitted and large enough to hold the whole pose: the reference.
      final whole = await _alphaBounds(player, const Size(1600, 1600));
      // Fitted into 200x300, bottom-aligned: s = min(200/800, 300/600) = 0.25.
      player.place(const Size(200, 300),
          const SsPlacement(alignment: Alignment.bottomCenter));
      final fitted = await _alphaBounds(player, const Size(200, 300));

      expect(fitted, isNotNull);
      expect(fitted!.height, closeTo(whole!.height * 0.25, 2));
      expect(fitted.width, closeTo(whole.width * 0.25, 2));
      // Ringo stands on its origin, which the fit put on the bottom edge.
      expect(fitted.bottom, closeTo(300, 2));
      expect(fitted.left, greaterThanOrEqualTo(0));
      expect(fitted.right, lessThanOrEqualTo(200));
    });
  });
}

// Built at run time: a const `SsPlacement(fit: BoxFit.fill)` would fail to
// compile rather than assert.
BoxFit _fill() => BoxFit.fill;

Widget _wrap(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

/// A Ringo player on `attack1`, textures skipped: layout and poses need none.
Future<SpriteStudioPlayer?> _loaded(WidgetTester tester) async {
  final bytes = _ringo();
  if (bytes == null) return null;
  final player = SpriteStudioPlayer();
  addTearDown(player.dispose);
  await tester.runAsync(() =>
      player.load(bytes, animationName: 'attack1', loadTextures: false));
  return player;
}

/// The bounds of every pixel [player] draws into a [size] box, or null when it
/// drew none.
Future<Rect?> _alphaBounds(SpriteStudioPlayer player, Size size) async {
  final recorder = ui.PictureRecorder();
  player.paint(ui.Canvas(recorder), dst: Offset.zero & size, sourceSize: size);
  final picture = recorder.endRecording();
  final w = size.width.toInt(), h = size.height.toInt();
  final image = await picture.toImage(w, h);
  final data = (await image.toByteData())!;
  picture.dispose();
  image.dispose();
  var l = w, t = h, r = -1, b = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (data.getUint8((y * w + x) * 4 + 3) == 0) continue;
      if (x < l) l = x;
      if (x > r) r = x;
      if (y < t) t = y;
      if (y > b) b = y;
    }
  }
  if (r < 0) return null;
  return Rect.fromLTRB(
      l.toDouble(), t.toDouble(), r + 1.0, b + 1.0);
}

String? _ringoDir() {
  for (final p in const <String>[
    'examples/overall/assets/spritestudio/Ringo',
    '../../examples/overall/assets/spritestudio/Ringo',
  ]) {
    if (Directory(p).existsSync()) return p;
  }
  return null;
}

Uint8List? _ringo() {
  final dir = _ringoDir();
  if (dir == null) {
    markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
    return null;
  }
  return File('$dir/Ringo.ssab').readAsBytesSync();
}

/// Serves any key by its basename out of a directory read into memory up front.
class _DirBundle extends CachingAssetBundle {
  _DirBundle(String dir) {
    for (final f in Directory(dir).listSync().whereType<File>()) {
      _files[f.uri.pathSegments.last] = f.readAsBytesSync();
    }
  }
  final Map<String, Uint8List> _files = {};

  @override
  Future<ByteData> load(String key) async {
    final bytes = _files[key.split('/').last];
    if (bytes == null) throw FlutterError('not in bundle: $key');
    return ByteData.sublistView(bytes);
  }
}
