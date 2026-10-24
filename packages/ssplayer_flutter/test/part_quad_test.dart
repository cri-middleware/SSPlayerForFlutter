// A part's outline as drawn, and the hit test built on it.
//
// The geometry of SsPartQuad is tested on its own; the read against Ringo,
// whose `apple` is a plain cell part, `head` a mesh and `root` a Null part. The
// strongest check is the last one: under a fit, every pixel the player draws
// lies inside the union of the outlines it reports.
//
//   flutter test test/part_quad_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SsPartQuad', () {
    // A 20x20 square turned 45°, centred on the origin.
    const diamond = SsPartQuad(
        Offset(0, -14.14), Offset(14.14, 0), Offset(-14.14, 0), Offset(0, 14.14));

    test('contains follows the turned outline, not its bounds', () {
      expect(diamond.contains(Offset.zero), isTrue);
      expect(diamond.contains(const Offset(6, 6)), isTrue);
      // Inside the bounds, outside the diamond.
      expect(diamond.contains(const Offset(10, 10)), isFalse);
      expect(diamond.bounds,
          const Rect.fromLTRB(-14.14, -14.14, 14.14, 14.14));
    });

    test('a quad folded over itself answers by the even-odd rule', () {
      // The right corners swapped: a bow tie crossing at x = 5.
      const bowTie = SsPartQuad(
          Offset(0, 0), Offset(10, 10), Offset(0, 10), Offset(10, 0));
      expect(bowTie.contains(const Offset(1, 5)), isTrue);
      expect(bowTie.contains(const Offset(5, 1)), isFalse);
    });
  });

  group('SpriteStudioInternalPlayer.partQuad (real Brain)', () {
    test('a cell part is its local corners through the part pose', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.rootTransform = const SsRootTransform(
          flipX: true, offset: Offset(7, -3), scale: 0.5);
      p.update(const Duration(milliseconds: 16));

      final apple = p.findPartIndex('apple');
      final quad = p.partQuad(apple)!;
      final pose = p.partWorldMatrix(apple)!;
      final local = p.localVertices();
      Offset corner(int c) {
        final v = pose.transform3(Vector3(
            local[apple * 10 + c * 2], local[apple * 10 + c * 2 + 1], 0));
        return Offset(v.x, v.y);
      }

      expect(quad.leftTop, _near(corner(0)));
      expect(quad.rightTop, _near(corner(1)));
      expect(quad.leftBottom, _near(corner(2)));
      expect(quad.rightBottom, _near(corner(3)));
      // Flipped, the cell's left edge is drawn on the right.
      expect(quad.leftTop.dx, greaterThan(quad.rightTop.dx));
    });

    test('a mesh part is the box around its world vertices', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      final head = p.findPartIndex('head');
      final at = p.meshVertexOffsets();
      expect(at[head + 1], greaterThan(at[head]), reason: 'head is a mesh');
      final xs = p.meshVerticesX(), ys = p.meshVerticesY();
      var box = Rect.fromLTRB(xs[at[head]], ys[at[head]], xs[at[head]],
          ys[at[head]]);
      for (var v = at[head]; v < at[head + 1]; v++) {
        box = box.expandToInclude(Rect.fromLTWH(xs[v], ys[v], 0, 0));
      }
      expect(p.partQuad(head)!.bounds, box);
    });

    test('hidden, Null and unknown parts have none', () {
      final p = _load();
      if (p == null) return;
      addTearDown(p.dispose);
      p.update(const Duration(milliseconds: 16));

      final hidden = p.findPartIndex('leg_r_1');
      expect(p.partHidden(hidden), isTrue, reason: 'attack1 hides leg_r_1');
      expect(p.partQuad(hidden), isNull);
      expect(p.partQuad(p.findPartIndex('root')), isNull);
      expect(p.partQuad(-1), isNull);
      expect(p.partQuad(9999), isNull);
    });
  });

  group('hitTestPart', () {
    test('answers the front-most part, or among the parts named', () async {
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      final bytes = _ringo();
      if (bytes == null) return;
      await player.load(bytes, animationName: 'attack1', loadTextures: false);

      final head = player.partQuad('head')!.bounds;
      final body = player.partQuad('body')!.bounds;
      final both = head.intersect(body);
      expect(both.isEmpty, isFalse, reason: 'head overlaps body');
      // The head is drawn over the body.
      expect(player.hitTestPart(both.center),
          player.findPartIndex('head'));
      expect(player.hitTestPart(both.center, parts: ['body']),
          player.findPartIndex('body'));
      expect(player.hitTestPart(both.center, parts: ['nope']), -1);
      expect(player.hitTestPart(const Offset(5000, 5000)), -1);
      expect(
          player.hitTestPartByIndex(both.center,
              parts: [player.findPartIndex('body')]),
          player.findPartIndex('body'));
    });

    test('is -1 and null before load', () {
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      expect(player.hitTestPart(Offset.zero), -1);
      expect(player.partQuad('apple'), isNull);
    });
  });

  test('under a fit, what is drawn lies inside the outlines', () async {
    final bytes = _ringo();
    if (bytes == null) return;
    final player = SpriteStudioPlayer(backend: SpriteStudioBackend.canvas);
    addTearDown(player.dispose);
    await player.loadAsset('assets/x/Ringo.ssab',
        animationName: 'attack1', bundle: _DirBundle(_ringoDir()!));
    const view = Size(200, 300);
    player.place(view, const SsPlacement(alignment: Alignment.bottomCenter));
    player.seek(5);

    Rect? union;
    for (final name in player.partNames.names) {
      final quad = player.partQuad(name);
      if (quad == null) continue;
      final b = quad.bounds.shift(view.center(Offset.zero));
      union = union?.expandToInclude(b) ?? b;
    }
    final drawn = await _alphaBounds(player, view);
    expect(drawn, isNotNull);
    // One pixel of slack for the rasterizer's coverage at the edges.
    expect(union!.inflate(1).expandToInclude(drawn!), union.inflate(1));
  });
}

Matcher _near(Offset o) => isA<Offset>()
    .having((x) => x.dx, 'dx', closeTo(o.dx, 1e-6))
    .having((x) => x.dy, 'dy', closeTo(o.dy, 1e-6));

Uint8List? _ringo() {
  final dir = _ringoDir();
  if (dir == null) {
    markTestSkipped('Ringo.ssab missing — run scripts/deploy-examples.sh');
    return null;
  }
  return File('$dir/Ringo.ssab').readAsBytesSync();
}

String? _ringoDir() {
  for (final p in const <String>[
    'examples/overall/assets/spritestudio/Ringo',
    '../../examples/overall/assets/spritestudio/Ringo',
  ]) {
    if (File('$p/Ringo.ssab').existsSync()) return p;
  }
  return null;
}

SpriteStudioInternalPlayer? _load() {
  final bytes = _ringo();
  if (bytes == null) return null;
  final p = SpriteStudioInternalPlayer.load(bytes,
      backend: SpriteStudioBackend.canvas);
  p.setupAnimation('attack1');
  return p;
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
  return Rect.fromLTRB(l.toDouble(), t.toDouble(), r + 1.0, b + 1.0);
}

/// Serves the files of one directory by their base name.
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
