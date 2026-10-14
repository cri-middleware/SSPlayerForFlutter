// Guards the per-frame scratch reuse in the render path.
//
// The backends and the GeometryBuilder recycle buffers, run lists, `ui.Paint`s
// and `ui.Path`s across frames instead of allocating per part. Two assumptions
// hold that together, and each has its own group below:
//
//  1. A Canvas op copies its `Paint` / `Path` into the display list at record
//     time, so mutating either afterwards cannot disturb an already-recorded
//     draw. (Engine behaviour — asserted directly rather than assumed.)
//  2. Every recycled buffer is FULLY rewritten before it is read again. A slot
//     left unwritten silently inherits the previous part's value, which is the
//     one failure mode this optimisation can introduce.
//
// Coverage note for the end-to-end group: `flutter test` cannot resolve the
// backend's `packages/ssplayer_flutter/shaders/*.frag` asset keys (only the
// package-local `shaders/*.frag` form resolves, as mask_replay_pixel_test.dart
// uses), so `_LazyProgram` latches failed and the shader-gated paths — peeled
// PartColor, the mask coverage pass, the `ss_*` effects — do NOT run there.
// That group therefore covers the batched geometry paths only; the scratch those
// shader paths use is covered by the unit group instead.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'support/framedata_builders.g.dart' as fbs;

const int _kDim = 128;
const ui.Rect _kDst = ui.Rect.fromLTWH(0, 0, 128, 128);

Future<Uint32List> _record(void Function(ui.Canvas) body) async {
  final rec = ui.PictureRecorder();
  body(ui.Canvas(rec));
  final pic = rec.endRecording();
  final img = await pic.toImage(_kDim, _kDim);
  pic.dispose();
  final bd = (await img.toByteData())!;
  img.dispose();
  return bd.buffer.asUint32List();
}

fbs.FrameData _emptyFrameData() =>
    fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes());

void main() {
  group('a recorded draw is immune to later scratch mutation', () {
    test('reused + reset ui.Path == fresh Paths', () async {
      ui.Path tri(double dx) => ui.Path()
        ..moveTo(dx + 8, 8)
        ..lineTo(dx + 48, 8)
        ..lineTo(dx + 28, 56)
        ..close();

      final fresh = await _record((c) {
        c.drawPath(tri(0), ui.Paint()..color = const ui.Color(0xFFFF0000));
        c.drawPath(tri(56), ui.Paint()..color = const ui.Color(0xFF00FF00));
      });

      final scratch = ui.Path();
      final reused = await _record((c) {
        scratch
          ..reset()
          ..moveTo(8, 8)
          ..lineTo(48, 8)
          ..lineTo(28, 56)
          ..close();
        c.drawPath(scratch, ui.Paint()..color = const ui.Color(0xFFFF0000));
        // Mutate the SAME object after handing it to drawPath.
        scratch
          ..reset()
          ..moveTo(64, 8)
          ..lineTo(104, 8)
          ..lineTo(84, 56)
          ..close();
        c.drawPath(scratch, ui.Paint()..color = const ui.Color(0xFF00FF00));
      });

      expect(reused, fresh);
    });

    test('reused + mutated ui.Paint == fresh Paints', () async {
      const a = ui.Rect.fromLTWH(8, 8, 48, 48);
      const b = ui.Rect.fromLTWH(64, 64, 48, 48);

      final fresh = await _record((c) {
        c.drawRect(a, ui.Paint()..color = const ui.Color(0xFFFF0000));
        c.drawRect(
            b,
            ui.Paint()
              ..color = const ui.Color(0x8000FF00)
              ..blendMode = ui.BlendMode.plus);
      });

      final paint = ui.Paint();
      final reused = await _record((c) {
        c.drawRect(a, paint..color = const ui.Color(0xFFFF0000));
        c.drawRect(
            b,
            paint
              ..color = const ui.Color(0x8000FF00)
              ..blendMode = ui.BlendMode.plus);
      });

      expect(reused, fresh);
    });

    test('reused ui.Paint across saveLayer + inner draws == fresh Paints',
        () async {
      const r = ui.Rect.fromLTWH(16, 16, 80, 80);

      final fresh = await _record((c) {
        c.saveLayer(_kDst, ui.Paint()..blendMode = ui.BlendMode.srcOver);
        c.drawRect(r, ui.Paint()..color = const ui.Color(0xFF3366CC));
        c.drawRect(
            _kDst,
            ui.Paint()
              ..blendMode = ui.BlendMode.dstIn
              ..color = const ui.Color(0x80000000));
        c.restore();
      });

      final p = ui.Paint();
      final reused = await _record((c) {
        c.saveLayer(_kDst, p..blendMode = ui.BlendMode.srcOver);
        c.drawRect(
            r,
            p
              ..blendMode = ui.BlendMode.srcOver
              ..color = const ui.Color(0xFF3366CC));
        c.drawRect(
            _kDst,
            p
              ..blendMode = ui.BlendMode.dstIn
              ..color = const ui.Color(0x80000000));
        c.restore();
      });

      expect(reused, fresh);
    });
  });

  // Each of these drives a scratch-returning helper TWICE with different shapes,
  // which is the only way the "stale slot" failure mode can surface.
  group('a recycled buffer carries nothing forward', () {
    test('world2dOf overwrites every slot, not just the six it fills', () {
      // A world matrix whose Z/W row is junk the affine must not pass through.
      final world = Float32List.fromList(<double>[
        2, 3, 9, 9, //
        4, 5, 9, 9, //
        9, 9, 9, 9, //
        6, 7, 9, 9, //
      ]);
      final frame = DrawFrame(
        frameData: _emptyFrameData(),
        drawOrder: const <int>[0],
        partByIndex: const <fbs.PartState?>[],
        world: world,
        local: Float32List(10),
        uv: Float32List(10),
      );

      // Pre-dirty the scratch exactly as a previous part would have left it.
      final scratch = Float64List(16)..fillRange(0, 16, 99.0);
      final m = GeometryBuilder.world2dOf(0, frame, scratch)!;

      expect(m, GeometryBuilder.world2dOf(0, frame),
          reason: 'the scratch overload must equal the allocating one');
      expect(m[2], 0.0);
      expect(m[3], 0.0);
      expect(m[10], 1.0);
      expect(m[14], 0.0);
      expect(m[15], 1.0);
    });

    test('a world outline into an oversized scratch keeps an exact length', () {
      // 4 shape vertices for part 0, 3 for part 1 — the second must not report
      // the first's length, or MaskPlan.build folds stale points into the bbox.
      final world = Float32List(2 * DrawFrame.worldStride);
      world[0] = 1;
      world[5] = 1;
      world[DrawFrame.worldStride + 0] = 1;
      world[DrawFrame.worldStride + 5] = 1;
      final verts = Float32List(2 * ShapeBuffers.stride);
      for (var i = 0; i < 8; i++) {
        verts[i] = i.toDouble(); // part 0: 4 points
      }
      for (var i = 0; i < 6; i++) {
        verts[ShapeBuffers.stride + i] = 100.0 + i; // part 1: 3 points
      }
      final frame = DrawFrame(
        frameData: _emptyFrameData(),
        drawOrder: const <int>[0, 1],
        partByIndex: const <fbs.PartState?>[],
        world: world,
        local: Float32List(2 * DrawFrame.vertexStride),
        uv: Float32List(2 * DrawFrame.vertexStride),
        shape: ShapeBuffers(
          vertices: verts,
          boxCoords: Float32List(2 * ShapeBuffers.stride),
          counts: Int32List.fromList(<int>[4, 3]),
        ),
      );

      var scratch = Float32List(0);
      final a = GeometryBuilder.shapeWorldOutlineOf(0, frame, scratch)!;
      if (a.length > scratch.length) scratch = a;
      expect(a.length, 8);

      final b = GeometryBuilder.shapeWorldOutlineOf(1, frame, scratch)!;
      expect(b.length, 6, reason: 'must not report the larger scratch length');
      expect(b, <double>[100, 101, 102, 103, 104, 105]);

      // MaskPlan.build shares ONE buffer across all three outline kinds, so the
      // 8-float quad path must trim a buffer a longer outline grew as well.
      final wide = Float32List(32)..fillRange(0, 32, 77.0);
      final quad = GeometryBuilder.worldCornersOf(0, frame, wide)!;
      expect(quad.length, 8,
          reason: 'a quad outline in an oversized scratch must stay 8 floats');
      expect(quad.contains(77.0), isFalse);
    });

    test('a recycled partByIndex never resolves a previous frame\'s part', () {
      // Needs real PartStates, so this rides a real pack's FrameData.
      final path = _firstExisting(<String>[
        'examples/overall/assets/spritestudio/overall/Shape.ssab',
        '../../examples/overall/assets/spritestudio/overall/Shape.ssab',
      ]);
      if (path == null) {
        markTestSkipped('Shape.ssab missing — run deploy-examples.sh');
        return;
      }
      final bytes = Uint8List.fromList(File(path).readAsBytesSync());
      final player = SpriteStudioInternalPlayer.load(bytes);
      addTearDown(player.dispose);
      expect(player.setupAnimation(SsAnimeInfo(bytes).animationNames.first),
          isTrue);
      player.play();
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      expect(fd, isNotNull);
      final parts = fd!.parts!;
      expect(parts, isNotEmpty);

      // A scratch a previous, larger frame left full of ITS parts.
      final stale = List<fbs.PartState?>.filled(parts.length + 8, parts.first);
      final frame = DrawFrame.build(
        frameData: fd,
        world: player.worldMatrices(),
        local: player.localVertices(),
        uv: player.localUvs(),
        partByIndexScratch: stale,
      )!;

      expect(identical(frame.partByIndex, stale), isTrue,
          reason: 'a large-enough scratch must be adopted, not reallocated');
      expect(frame.partCount, lessThan(stale.length),
          reason: 'the scratch must really be oversized here');
      expect(frame.partOf(frame.partCount), isNull,
          reason: 'the stale tail belongs to a previous frame');
      expect(frame.partOf(stale.length - 1), isNull);
    });

    test('buildPartColorQuad refills its shared quad completely', () {
      Float32List worldOf(double sx, double sy, double tx, double ty) =>
          Float32List.fromList(<double>[
            sx, 0, 0, 0, //
            0, sy, 0, 0, //
            0, 0, 1, 0, //
            tx, ty, 0, 1, //
          ]);
      final local =
          Float32List.fromList(<double>[0, 0, 1, 0, 0, 1, 1, 1, 0.5, 0.5]);

      DrawFrame frameWith(Float32List world, Float32List uv) => DrawFrame(
            frameData: _emptyFrameData(),
            drawOrder: const <int>[0],
            partByIndex: const <fbs.PartState?>[],
            world: world,
            local: local,
            uv: uv,
          );

      final builder = GeometryBuilder();
      // First part primes every buffer the shared quad hands out.
      builder.buildPartColorQuad(
          0,
          frameWith(worldOf(2, 3, 10, 20),
              Float32List.fromList(<double>[0, 0, 64, 0, 0, 64, 64, 64, 32, 32])));

      // A second, differently shaped part must agree with a virgin builder.
      final second = frameWith(worldOf(5, 7, -3, -4),
          Float32List.fromList(<double>[1, 2, 3, 4, 5, 6, 7, 8, 0, 0]));
      final reused = builder.buildPartColorQuad(0, second)!;
      final fresh = GeometryBuilder().buildPartColorQuad(0, second)!;

      expect(reused.corners, fresh.corners);
      expect(reused.uvA, fresh.uvA);
      expect(reused.uvB, fresh.uvB);
      expect(reused.inv, fresh.inv);
      expect(reused.center, fresh.center);
      expect(reused.originX, fresh.originX);
      expect(reused.originY, fresh.originY);
      expect(builder.cellRectScratch(reused, 128, 64),
          GeometryBuilder().cellRectScratch(fresh, 128, 64));
    });
  });

  // Covers the batched geometry paths end to end (see the coverage note above):
  // the run lists, `_batchPaint` / `_shapePaint`, the SoA bakes, the recycled
  // `partByIndex`, `world2dOf`'s scratch and MaskPlan's outline scratch.
  group('rendering the same state twice is pixel-identical', () {
    for (final pack in const <String>['Shape.ssab', 'Mask.ssab']) {
      test(pack, () async {
        final path = _firstExisting(<String>[
          'examples/overall/assets/spritestudio/overall/$pack',
          '../../examples/overall/assets/spritestudio/overall/$pack',
        ]);
        if (path == null) {
          markTestSkipped('$pack missing — run deploy-examples.sh');
          return;
        }

        final bytes = Uint8List.fromList(File(path).readAsBytesSync());
        final player = SpriteStudioInternalPlayer.load(bytes);
        addTearDown(player.dispose);
        expect(player.setupAnimation(SsAnimeInfo(bytes).animationNames.first),
            isTrue);
        player.play();
        player.update(const Duration(milliseconds: 100));

        // Each picture is rasterised before the next `paint`, because `paint`
        // opens with `releaseCoverage()` — a still-unrasterised picture would be
        // reading a disposed coverage image (see render_lifetime_test.dart).
        final first = await _record((c) => player.paint(c, dst: _kDst));
        final second = await _record((c) => player.paint(c, dst: _kDst));

        // Without this the comparison could pass on two blank targets.
        expect(first.any((px) => px != 0), isTrue,
            reason: '$pack rendered nothing — the comparison would be vacuous');
        expect(second, first,
            reason: 'frame 2 differs from frame 1 at identical player state: '
                'some per-frame scratch leaked across the frame boundary');
      });
    }
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
