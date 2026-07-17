// Shape (§11) tests. The SoA slicing and the fan/colour bake run everywhere;
// the ssab-driven cases use the real Shape.ssab (a drawn Rectangle that is also
// a mask target, plus a draw_as_mask ShapeMask writer) and skip when the example
// assets haven't been prepared.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

/// A Rectangle exactly as the Brain lays one out: `[center, LT, RT, RB, LB, LT]`
/// — a center-first fan with a closing vertex — for a 100×200 box at the origin.
({Float32List verts, Float32List box, Int32List counts}) _rectPart({
  int partCount = 1,
  int part = 0,
}) {
  final verts = Float32List(partCount * ShapeBuffers.stride);
  final box = Float32List(partCount * ShapeBuffers.stride);
  final counts = Int32List(partCount);
  const hw = 50.0, hh = 100.0;
  // Y-up local space, matching compute_shape_vertices.
  const xs = <double>[0, -hw, hw, hw, -hw, -hw];
  const ys = <double>[0, hh, hh, -hh, -hh, hh];
  final o = part * ShapeBuffers.stride;
  for (var v = 0; v < 6; v++) {
    verts[o + 2 * v] = xs[v];
    verts[o + 2 * v + 1] = ys[v];
    // fx = (x + hw) / w, fy = (hh - y) / h — the Brain's formula.
    box[o + 2 * v] = (xs[v] + hw) / (hw * 2);
    box[o + 2 * v + 1] = (hh - ys[v]) / (hh * 2);
  }
  counts[part] = 6;
  return (verts: verts, box: box, counts: counts);
}

Float32List _identityWorld(int parts) {
  final w = Float32List(parts * DrawFrame.worldStride);
  for (var p = 0; p < parts; p++) {
    final m = p * DrawFrame.worldStride;
    w[m] = 1.0; // m0
    w[m + 5] = 1.0; // m5
    w[m + 10] = 1.0;
    w[m + 15] = 1.0;
  }
  return w;
}

void main() {
  group('ShapeBuffers.countOf', () {
    ShapeBuffers buffersWith(List<int> counts, {int? verts}) => ShapeBuffers(
          vertices: Float32List((verts ?? counts.length) * ShapeBuffers.stride),
          boxCoords: Float32List((verts ?? counts.length) * ShapeBuffers.stride),
          counts: Int32List.fromList(counts),
        );

    test('a fixed stride, not a CSR prefix sum', () {
      // The whole point of the guard: unlike the mesh there is no offsets array,
      // so counts is the ONLY slice and every part owns the same 24 floats.
      expect(ShapeBuffers.stride, 24);
      expect(ShapeBuffers.maxVertices, 12);
    });

    test('returns the live count for a shape part', () {
      expect(buffersWith(<int>[6, 0, 12]).countOf(0), 6);
      expect(buffersWith(<int>[6, 0, 12]).countOf(2), 12);
    });

    test('a non-shape part reads zero rather than garbage', () {
      // Every part has a 24-float slot whether or not it is a shape; the Brain
      // zero-fills the rest and reports count 0.
      expect(buffersWith(<int>[6, 0, 12]).countOf(1), 0);
    });

    test('rejects a degenerate or impossible count', () {
      // < 3 cannot form a triangle (the Brain skips such parts itself); > 12
      // cannot fit the stride, so it means the buffer is not what we think.
      expect(buffersWith(<int>[2]).countOf(0), 0);
      expect(buffersWith(<int>[13]).countOf(0), 0);
      expect(buffersWith(<int>[-1]).countOf(0), 0);
    });

    test('rejects an out-of-range part', () {
      expect(buffersWith(<int>[6]).countOf(1), 0);
      expect(buffersWith(<int>[6]).countOf(-1), 0);
    });

    test('rejects a count the buffer is too short for', () {
      // counts claims 3 parts of shapes but the vertex buffer only holds one.
      expect(buffersWith(<int>[6, 6, 6], verts: 1).countOf(2), 0);
    });
  });

  group('GeometryBuilder.buildShapeParts', () {
    DrawFrame frameWith({
      required ({Float32List verts, Float32List box, Int32List counts}) rect,
      Float32List? world,
      int parts = 1,
      double alphaScale = 1.0,
    }) =>
        DrawFrame(
          frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
          drawOrder: const <int>[0],
          partByIndex: const [],
          world: world ?? _identityWorld(parts),
          local: Float32List(parts * DrawFrame.vertexStride),
          uv: Float32List(parts * DrawFrame.vertexStride),
          shape: ShapeBuffers(
            vertices: rect.verts,
            boxCoords: rect.box,
            counts: rect.counts,
          ),
          alphaScale: alphaScale,
        );

    test('bakes a center-first fan, not a quad', () {
      final g = GeometryBuilder().buildShapeParts(<int>[0], frameWith(rect: _rectPart()))!;

      expect(g.positions.length, 6 * 2, reason: '6 vertices: center + 4 + close');
      // (count - 2) triangles, all fanning from vertex 0 — a rectangle is 4
      // triangles from its center, NOT 2 across a diagonal, so a per-corner
      // gradient interpolates from the middle instead of creasing.
      expect(g.indices, <int>[0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5]);
    });

    test('transforms the local vertices by the world matrix', () {
      // Shape is like Normal and unlike Mesh: the SoA is LOCAL space.
      final world = _identityWorld(1);
      world[0] = 2.0; // m0
      world[5] = 3.0; // m5
      world[12] = 10.0; // tx
      world[13] = 20.0; // ty

      final g = GeometryBuilder()
          .buildShapeParts(<int>[0], frameWith(rect: _rectPart(), world: world))!;

      // center (0,0) -> (10, 20)
      expect(g.positions[0], 10.0);
      expect(g.positions[1], 20.0);
      // LT (-50, 100) -> (2*-50+10, 3*100+20) = (-90, 320)
      expect(g.positions[2], -90.0);
      expect(g.positions[3], 320.0);
    });

    test('a shape samples no texture, so it carries no UVs', () {
      final g = GeometryBuilder().buildShapeParts(<int>[0], frameWith(rect: _rectPart()))!;
      expect(g.texCoords, isNull);
      // Vertices.raw would assert on a length mismatch if this regressed.
      addTearDown(g.toVertices().dispose);
      expect(g.toVertices(), isNotNull);
    });

    test('without PartColor every vertex is white at the part alpha', () {
      final g = GeometryBuilder().buildShapeParts(<int>[0], frameWith(rect: _rectPart()))!;
      // No PartState in partByIndex → alpha reads 1.0.
      expect(g.colors, everyElement(0xFFFFFFFF.toSigned(32)));
    });

    test('the instance chain scale reaches the plain path', () {
      final g = GeometryBuilder()
          .buildShapeParts(<int>[0], frameWith(rect: _rectPart(), alphaScale: 0.5))!;
      // alphaOf folds the chain scale in; 0.5 -> 128 (0.5*255 rounds to 128).
      for (final c in g.colors) {
        expect((c >> 24) & 0xFF, 128);
      }
    });

    test('concatenates several parts and rebases each fan', () {
      final a = _rectPart(partCount: 2, part: 0);
      final b = _rectPart(partCount: 2, part: 1);
      // Merge the two parts' slots into one buffer set.
      for (var i = 0; i < a.verts.length; i++) {
        a.verts[i] += b.verts[i];
        a.box[i] += b.box[i];
      }
      a.counts[1] = 6;

      final g = GeometryBuilder()
          .buildShapeParts(<int>[0, 1], frameWith(rect: a, parts: 2))!;

      expect(g.positions.length, 12 * 2);
      // A Shape batch is batchable (count > 1), so the second part's fan must be
      // rebased onto its vertex base or it would re-draw the first part.
      expect(g.indices.sublist(0, 12), <int>[0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5]);
      expect(g.indices.sublist(12),
          <int>[6, 7, 8, 6, 8, 9, 6, 9, 10, 6, 10, 11]);
    });

    test('skips a part with no shape this frame', () {
      final r = _rectPart(partCount: 2, part: 0);
      final g = GeometryBuilder()
          .buildShapeParts(<int>[0, 1], frameWith(rect: r, parts: 2))!;
      // Part 1 has count 0 — it must contribute nothing, not a zero-area blob.
      expect(g.positions.length, 6 * 2);
      expect(g.indices.length, 4 * 3);
    });

    test('returns null when nothing in the run has geometry', () {
      final r = _rectPart();
      r.counts[0] = 0;
      expect(GeometryBuilder().buildShapeParts(<int>[0], frameWith(rect: r)), isNull);
      expect(GeometryBuilder().buildShapeParts(<int>[], frameWith(rect: _rectPart())),
          isNull);
    });
  });

  group('GeometryBuilder.shapeWorldOutlineOf', () {
    test('returns every live vertex in world space', () {
      final frame = DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const <int>[0],
        partByIndex: const [],
        world: _identityWorld(1),
        local: Float32List(DrawFrame.vertexStride),
        uv: Float32List(DrawFrame.vertexStride),
        shape: ShapeBuffers(
          vertices: _rectPart().verts,
          boxCoords: _rectPart().box,
          counts: _rectPart().counts,
        ),
      );
      final out = GeometryBuilder.shapeWorldOutlineOf(0, frame)!;
      expect(out.length, 6 * 2);
      expect(out[2], -50.0); // LT.x
      expect(out[3], 100.0); // LT.y
    });

    test('returns null for a part with no shape', () {
      final frame = DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const <int>[0],
        partByIndex: const [],
        world: _identityWorld(1),
        local: Float32List(DrawFrame.vertexStride),
        uv: Float32List(DrawFrame.vertexStride),
      );
      expect(GeometryBuilder.shapeWorldOutlineOf(0, frame), isNull);
    });
  });

  group('MaskPartFlags — Shape roles', () {
    test('a Shape can write coverage; Mesh/Text/Nines still cannot', () {
      const shape = MaskPartFlags(
        pureMask: true,
        maskWrite: false,
        maskInfluence: false,
        visibleInsideMask: false,
        quadGeometry: false,
        shapeGeometry: true,
      );
      expect(shape.drawableWriter, isTrue);
      expect(shape.isWriter, isTrue);

      const mesh = MaskPartFlags(
        pureMask: false,
        maskWrite: true,
        maskInfluence: false,
        visibleInsideMask: false,
        quadGeometry: false,
      );
      expect(mesh.drawableWriter, isFalse,
          reason: 'a mesh writer would clip to the wrong shape');
    });

    test('a Normal part is still a quad writer', () {
      expect(MaskPartFlags.none.quadGeometry, isTrue);
      expect(MaskPartFlags.none.shapeGeometry, isFalse);
    });
  });

  group('Shape.ssab (real converter output)', () {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Shape.ssab',
      '../../examples/overall/assets/spritestudio/overall/Shape.ssab',
    ]);
    final bytes = ssabPath == null
        ? null
        : Uint8List.fromList(File(ssabPath).readAsBytesSync());

    test('reads the Shape roles out of the ssab', () {
      if (bytes == null) {
        markTestSkipped('Shape.ssab missing — run deploy-examples.sh');
        return;
      }
      final flags = MaskPartFlags.readAll(bytes);
      // The asset is built to exercise exactly this: a drawn shape that is a
      // mask TARGET, and a draw_as_mask shape that is a pure-mask WRITER.
      final writers = <int>[];
      final shapes = <int>[];
      for (var i = 0; i < flags.length; i++) {
        if (flags[i].shapeGeometry) shapes.add(i);
        if (flags[i].isWriter) writers.add(i);
      }
      expect(shapes, isNotEmpty, reason: 'Shape.ssab should host shape parts');
      expect(writers, isNotEmpty, reason: 'ShapeMask should be a writer');
      for (final w in writers) {
        expect(flags[w].drawableWriter, isTrue,
            reason: 'a shape writer must be rasterisable, not dropped');
        expect(flags[w].pureMask, isTrue,
            reason: 'draw_as_mask makes it a pure mask');
      }
    });

    test('the shape SoA is live and slices per part', () {
      if (bytes == null) {
        markTestSkipped('Shape.ssab missing');
        return;
      }
      final player = SpriteStudioInternalPlayer.load(bytes);
      addTearDown(player.dispose);
      expect(player.setupAnimation(SsAnimeInfo(bytes).animationNames.first), isTrue);
      player.play();
      player.update(const Duration(milliseconds: 33));
      player.getFrameData(player.frameNo);

      final shape = ShapeBuffers(
        vertices: player.shapeVertices(),
        boxCoords: player.shapeVertexBoxCoords(),
        counts: player.shapeVertexCounts(),
      );
      expect(shape.isEmpty, isFalse);
      // Fixed stride: the buffers cover every part, shape or not.
      expect(shape.vertices.length, shape.counts.length * ShapeBuffers.stride);
      expect(shape.boxCoords.length, shape.vertices.length);

      final live = <int>[
        for (var p = 0; p < shape.counts.length; p++)
          if (shape.countOf(p) > 0) p
      ];
      expect(live, isNotEmpty, reason: 'Shape.ssab must produce shape geometry');
      for (final p in live) {
        // Rectangle == center + 4 corners + closing vertex.
        expect(shape.countOf(p), 6);
      }
    });

    test('box coords span the unit box and put the fan center at (0.5, 0.5)', () {
      if (bytes == null) {
        markTestSkipped('Shape.ssab missing');
        return;
      }
      final player = SpriteStudioInternalPlayer.load(bytes);
      addTearDown(player.dispose);
      player.setupAnimation(SsAnimeInfo(bytes).animationNames.first);
      player.play();
      player.update(const Duration(milliseconds: 33));
      player.getFrameData(player.frameNo);

      final shape = ShapeBuffers(
        vertices: player.shapeVertices(),
        boxCoords: player.shapeVertexBoxCoords(),
        counts: player.shapeVertexCounts(),
      );
      final p = <int>[
        for (var i = 0; i < shape.counts.length; i++)
          if (shape.countOf(i) > 0) i
      ].first;
      final o = p * ShapeBuffers.stride;

      // Vertex 0 is the fan's center — the bilinear weights there must be an
      // even quarter each, which is what makes a gradient smooth.
      expect(shape.boxCoords[o], closeTo(0.5, 1e-5));
      expect(shape.boxCoords[o + 1], closeTo(0.5, 1e-5));
      for (var v = 0; v < shape.countOf(p); v++) {
        expect(shape.boxCoords[o + 2 * v], inInclusiveRange(0.0, 1.0));
        expect(shape.boxCoords[o + 2 * v + 1], inInclusiveRange(0.0, 1.0));
      }
    });

    test('paint emits a Shape batch and draws without throwing', () {
      if (bytes == null) {
        markTestSkipped('Shape.ssab missing');
        return;
      }
      final player = SpriteStudioInternalPlayer.load(bytes);
      addTearDown(player.dispose);
      player.setupAnimation(SsAnimeInfo(bytes).animationNames.first);
      player.play();
      player.update(const Duration(milliseconds: 33));

      final fd = player.getFrameData(player.frameNo)!;
      expect(
        fd.drawBatches!.where((b) => b.kind == fbs.DrawBatchKind.Shape),
        isNotEmpty,
        reason: 'Shape.ssab should emit Shape batches',
      );
      // A Shape batch reports no vertices — the counts SoA is the only truth.
      for (final b in fd.drawBatches!
          .where((b) => b.kind == fbs.DrawBatchKind.Shape)) {
        expect(b.vertexCount, 0);
        expect(b.indexCount, 0);
        expect(b.textureHash, 0, reason: 'a pure-colour shape has no cell');
      }

      final recorder = ui.PictureRecorder();
      player.paint(ui.Canvas(recorder), sourceSize: const ui.Size(256, 256));
      recorder.endRecording().dispose();
    });
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
