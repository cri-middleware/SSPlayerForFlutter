// Mesh (§8) tests. The pure pieces — CSR slicing and the SoA→Vertices bake —
// run everywhere; the SoA contract is then checked against real converter
// output from Mesh.ssab and skips when the example assets haven't been prepared.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

void main() {
  // Two mesh parts: part 0 owns vertices [0,3) / indices [0,3), part 1 is a
  // non-mesh part (empty range), part 2 owns vertices [3,6) / indices [3,6).
  MeshBuffers twoPartMesh() => MeshBuffers(
        x: Float32List.fromList(<double>[0, 10, 0, 100, 110, 100]),
        y: Float32List.fromList(<double>[0, 0, 10, 50, 50, 60]),
        uv: Float32List.fromList(<double>[
          0, 0, 8, 0, 0, 8, // part 0 (u,v interleaved, texture pixels)
          16, 16, 24, 16, 16, 24, // part 2
        ]),
        indices: Int32List.fromList(<int>[0, 1, 2, 0, 2, 1]),
        vertexOffsets: Uint32List.fromList(<int>[0, 3, 3, 6]),
        indexOffsets: Uint32List.fromList(<int>[0, 3, 3, 6]),
      );

  group('MeshBuffers CSR slicing', () {
    test('slices each part and reports empty ranges as null', () {
      final mesh = twoPartMesh();
      expect(mesh.isEmpty, isFalse);
      expect(mesh.vertexRange(0), (0, 3));
      expect(mesh.vertexRange(1), isNull); // non-mesh part: offsets[p]==offsets[p+1]
      expect(mesh.vertexRange(2), (3, 6));
      expect(mesh.indexRange(0), (0, 3));
      expect(mesh.indexRange(1), isNull);
      expect(mesh.indexRange(2), (3, 6));
    });

    test('guards the CSR tail and out-of-range parts', () {
      final mesh = twoPartMesh();
      // offsets has length parts+1, so the last addressable part is length-2.
      expect(mesh.vertexRange(3), isNull);
      expect(mesh.vertexRange(-1), isNull);
    });

    test('rejects a range that overruns the data buffers', () {
      final bad = MeshBuffers(
        x: Float32List(2), // only 2 vertices…
        y: Float32List(2),
        uv: Float32List(4),
        indices: Int32List.fromList(<int>[0, 1, 2]),
        vertexOffsets: Uint32List.fromList(<int>[0, 3]), // …but 3 claimed
        indexOffsets: Uint32List.fromList(<int>[0, 3]),
      );
      expect(bad.vertexRange(0), isNull);
    });
  });

  group('GeometryBuilder.buildMeshParts', () {
    DrawFrame frameWith(MeshBuffers mesh) => DrawFrame(
          frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
          drawOrder: const [0, 2],
          partByIndex: const [],
          world: Float32List(0),
          local: Float32List(0),
          uv: Float32List(0),
          mesh: mesh,
        );

    test('passes world vertices and pixel UVs through untouched', () {
      // The Brain hands mesh vertices over already world-transformed, so the
      // bake must NOT apply a matrix (contrast buildNormalParts) — the output
      // must equal the SoA input exactly. This is the mesh path's #1 trap.
      final g =
          GeometryBuilder().buildMeshGeometry(<int>[0], frameWith(twoPartMesh()));
      expect(g, isNotNull);
      // part 0's three vertices, X/Y SoA interleaved into [x,y,…].
      expect(g!.positions, <double>[0, 0, 10, 0, 0, 10]);
      // UVs copied verbatim in texture-pixel space — no normalising, no scale.
      expect(g.texCoords, <double>[0, 0, 8, 0, 0, 8]);
      expect(g.indices, <int>[0, 1, 2]);
    });

    test('rebases part-local indices when batching several parts', () {
      // Part 0 and part 2 each carry part-local indices 0..2. Batched into one
      // block, part 2's must be shifted by the 3 vertices part 0 emitted —
      // a Mesh DrawBatch is batchable, so this rebase is load-bearing.
      final g = GeometryBuilder()
          .buildMeshGeometry(<int>[0, 2], frameWith(twoPartMesh()));
      expect(g, isNotNull);
      expect(g!.positions.length, 6 * 2); // 3 + 3 vertices
      expect(g.indices, <int>[0, 1, 2, 3, 5, 4]); // part 2's [0,2,1] → [3,5,4]
      // part 2's own world coords and UVs follow part 0's, untouched.
      expect(g.positions.sublist(6), <double>[100, 50, 110, 50, 100, 60]);
      expect(g.texCoords!.sublist(6), <double>[16, 16, 24, 16, 16, 24]);
    });

    test('reuses scratch across bakes: a smaller second bake trims cleanly', () {
      // Item-2 buffer-reuse contract: the builder bakes into grow-only scratch,
      // so a large bake followed by a smaller one on the SAME instance must
      // return a view trimmed to the second bake's exact size — no stale tail
      // from the first bake leaking through. Every real caller consumes a bake
      // before the next, which the copy-out below models.
      final builder = GeometryBuilder();
      final frame = frameWith(twoPartMesh());

      // Large bake: 2 parts → 6 verts, 6 indices. Copy it out (consume) BEFORE
      // the next bake overwrites the shared scratch.
      final big = builder.buildMeshGeometry(<int>[0, 2], frame)!;
      final bigPositions = Float32List.fromList(big.positions);
      expect(bigPositions.length, 12);
      expect(big.indices, <int>[0, 1, 2, 3, 5, 4]);

      // Smaller bake on the same builder: 1 part → 3 verts. Reuses the buffer
      // (no re-grow) and must expose exactly 3 verts, not the 6 from before.
      final small = builder.buildMeshGeometry(<int>[0], frame)!;
      expect(small.positions.length, 6); // 3 verts × (x,y), trimmed
      expect(small.positions, <double>[0, 0, 10, 0, 0, 10]);
      expect(small.indices, <int>[0, 1, 2]); // no stale [3,5,4] tail
    });

    test('vertex colour is white × the part alpha, ARGB-packed', () {
      final g =
          GeometryBuilder().buildMeshGeometry(<int>[0], frameWith(twoPartMesh()));
      // No PartState for these parts → alphaOf falls back to 1.0 → opaque white.
      // Colours are ARGB packed into an Int32List (what ui.Vertices.raw wants),
      // so 0xFFFFFFFF lands as -1 — signed, not a bug.
      expect(g!.colors, everyElement(0xFFFFFFFF.toSigned(32)));
    });

    test('a frame with no mesh buffers yields null', () {
      final frame = DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const [0],
        partByIndex: const [],
        world: Float32List(0),
        local: Float32List(0),
        uv: Float32List(0),
      );
      expect(GeometryBuilder().buildMeshParts(<int>[0], frame), isNull);
    });

    test('non-mesh parts contribute nothing', () {
      final frame = frameWith(twoPartMesh());
      expect(GeometryBuilder().buildMeshParts(<int>[1], frame), isNull);
    });

    test('a partial triangle range is rejected', () {
      final bad = MeshBuffers(
        x: Float32List(3),
        y: Float32List(3),
        uv: Float32List(6),
        indices: Int32List.fromList(<int>[0, 1]), // 2 indices — not a triangle
        vertexOffsets: Uint32List.fromList(<int>[0, 3]),
        indexOffsets: Uint32List.fromList(<int>[0, 2]),
      );
      expect(bad.indexRange(0), isNull);
      expect(GeometryBuilder().buildMeshParts(<int>[0], frameWith(bad)), isNull);
    });
  });

  test('the real Mesh.ssab exposes a Mesh batch with a consistent mesh SoA',
      () async {
    final ssabPath = _firstExisting([
      'example/assets/spritestudio/overall/Mesh.ssab',
      '../../example/assets/spritestudio/overall/Mesh.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Mesh.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);

    final info = SsAnimeInfo(bytes);
    expect(player.setupAnimation(info.animationNames.first), isTrue);
    player.play();

    var sawMeshBatch = false;
    for (var i = 0; i < 60 && !sawMeshBatch; i++) {
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      final batches = fd?.drawBatches;
      if (fd == null || batches == null) continue;
      if (!batches.any((b) => b.kind == fbs.DrawBatchKind.Mesh)) continue;
      sawMeshBatch = true;

      final mesh = MeshBuffers(
        x: player.meshVerticesX(),
        y: player.meshVerticesY(),
        uv: player.meshUvs(),
        indices: player.meshIndices(),
        vertexOffsets: player.meshVertexOffsets(),
        indexOffsets: player.meshIndexOffsets(),
      );
      expect(mesh.isEmpty, isFalse,
          reason: 'Direct render mode must fill the mesh SoA');
      // The CSR contract: both offset arrays are prefix sums of the same length.
      expect(mesh.vertexOffsets.length, mesh.indexOffsets.length);
      expect(mesh.vertexOffsets.first, 0);
      expect(mesh.indexOffsets.first, 0);
      expect(mesh.x.length, mesh.y.length);
      expect(mesh.uv.length, mesh.x.length * 2);
      expect(mesh.vertexOffsets.last, lessThanOrEqualTo(mesh.x.length));
      expect(mesh.indexOffsets.last, lessThanOrEqualTo(mesh.indices.length));

      // At least one part must actually own mesh geometry, and its triangles
      // must be whole and in-range (part-local, 0-based).
      var meshParts = 0;
      for (var p = 0; p + 1 < mesh.vertexOffsets.length; p++) {
        final vr = mesh.vertexRange(p);
        final ir = mesh.indexRange(p);
        if (vr == null || ir == null) continue;
        meshParts++;
        expect((ir.$2 - ir.$1) % 3, 0, reason: 'indices must form triangles');
        for (var k = ir.$1; k < ir.$2; k++) {
          expect(mesh.indices[k], inInclusiveRange(0, vr.$2 - vr.$1 - 1));
        }
      }
      expect(meshParts, greaterThan(0));

      // And the batch must bake into real geometry.
      final frame = DrawFrame.build(
        frameData: fd,
        world: player.worldMatrices(),
        local: player.localVertices(),
        uv: player.localUvs(),
        mesh: mesh,
      );
      expect(frame, isNotNull);
      final batch = batches.firstWhere((b) => b.kind == fbs.DrawBatchKind.Mesh);
      final parts = <int>[
        for (var k = 0; k < batch.count; k++)
          if (batch.startRank + k < frame!.drawOrder.length)
            frame.drawOrder[batch.startRank + k],
      ];
      final vertices = GeometryBuilder().buildMeshParts(parts, frame!);
      expect(vertices, isNotNull,
          reason: 'a Mesh batch should bake into non-empty Vertices');
      vertices!.dispose();
    }

    expect(sawMeshBatch, isTrue,
        reason: 'Mesh.ssab should emit a Mesh batch on some frame');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
