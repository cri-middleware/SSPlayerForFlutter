// The player hands consecutive batches to the backend as one span: Normal
// and Mesh batches on one texture and blend draw their plain parts as one run,
// and Effect batches group their particle commands across parts. The bakes are
// pinned against the per-kind and per-part bakes laid end to end — so merging
// batches cannot move a vertex or change a colour — and the player against
// Ringo and Effect.ssab. Those last cases need the Brain and skip when the
// example assets are absent.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/render/backend/render_backend.dart';
import 'package:ssplayer_flutter/src/render/backend/render_host.dart';
import 'package:ssplayer_flutter/src/render/geometry_builder.dart'
    show InterleavedGeometry;
import 'package:ssplayer_flutter/src/render/mask_context.dart';

import 'support/effect_draw_plan_builders.g.dart' as efbs;
import 'support/framedata_builders.g.dart' as fbs;

void main() {
  // Parts 0, 1 and 4 are Normal, 2 and 3 are Mesh (three vertices each), and
  // 5 is outside every SoA. Each has its own alpha, so a colour written from
  // the wrong part shows.
  DrawFrame frame() {
    const alphas = <double>[0.9, 0.5, 0.7, 0.3, 0.6, 1.0];
    final world = Float32List(5 * 16);
    final local = Float32List(5 * 10);
    final uv = Float32List(5 * 10);
    for (var p = 0; p < 5; p++) {
      world
        ..[p * 16] = 1.0 + p
        ..[p * 16 + 1] = 0.25 * p
        ..[p * 16 + 4] = -0.5 * p
        ..[p * 16 + 5] = 2.0
        ..[p * 16 + 12] = 10.0 * p
        ..[p * 16 + 13] = -3.0 * p
        ..[p * 16 + 15] = 1.0;
      for (var i = 0; i < 10; i++) {
        local[p * 10 + i] = (i * 7 + p * 3) % 11 - 5.0;
        uv[p * 10 + i] = (i * 5 + p * 13) % 64 + 0.5;
      }
    }
    final mesh = MeshBuffers(
      x: Float32List.fromList(<double>[0, 10, 0, 100, 110, 100]),
      y: Float32List.fromList(<double>[0, 0, 10, 50, 50, 60]),
      uv: Float32List.fromList(
          <double>[0, 0, 8, 0, 0, 8, 16, 16, 24, 16, 16, 24]),
      indices: Int32List.fromList(<int>[0, 1, 2, 0, 2, 1]),
      vertexOffsets: Uint32List.fromList(<int>[0, 0, 0, 3, 6, 6, 6]),
      indexOffsets: Uint32List.fromList(<int>[0, 0, 0, 3, 6, 6, 6]),
    );
    final bytes = fbs.FrameDataObjectBuilder(
      parts: <fbs.PartStateObjectBuilder>[
        for (var p = 0; p < alphas.length; p++) _part(p, alphas[p]),
      ],
      drawOrder: const <int>[0, 1, 2, 3, 4, 5],
    ).toBytes();
    return DrawFrame.build(
      frameData: fbs.FrameData(bytes),
      world: world,
      local: local,
      uv: uv,
      mesh: mesh,
    )!;
  }

  group('GeometryBuilder.buildTexturedGeometry', () {
    test('is the per-kind bakes laid end to end, indices rebased', () {
      final f = frame();
      final b = GeometryBuilder();
      final expected = _Raw.concat(<_Raw>[
        _Raw.of(b.buildNormalGeometry(<int>[0, 1], f)!),
        _Raw.of(b.buildMeshGeometry(<int>[2, 3], f)!),
        _Raw.of(b.buildNormalGeometry(<int>[4], f)!),
      ]);
      final merged = b.buildTexturedGeometry(
          <int>[0, 1, 2, 3, 4], <bool>[false, false, true, true, false], f)!;
      expect(merged.positions, expected.positions);
      expect(merged.texCoords, expected.texCoords);
      expect(merged.colors, expected.colors);
      expect(merged.indices, expected.indices);
    });

    test('a part that bakes nothing leaves the rebase intact', () {
      // Part 5 has no world matrix; part 1 marked Mesh owns no mesh range.
      final f = frame();
      final b = GeometryBuilder();
      final expected = _Raw.concat(<_Raw>[
        _Raw.of(b.buildMeshGeometry(<int>[3], f)!),
        _Raw.of(b.buildNormalGeometry(<int>[0], f)!),
        _Raw.of(b.buildMeshGeometry(<int>[2], f)!),
      ]);
      final merged = b.buildTexturedGeometry(
          <int>[5, 3, 1, 0, 2], <bool>[false, true, true, false, true], f)!;
      expect(merged.positions, expected.positions);
      expect(merged.texCoords, expected.texCoords);
      expect(merged.colors, expected.colors);
      expect(merged.indices, expected.indices);
    });

    test('declines a run past maxBakeVertices', () {
      final f = frame();
      final fits = GeometryBuilder.maxBakeVertices ~/ 5;
      final b = GeometryBuilder();
      expect(
          b.buildTexturedGeometry(
              List<int>.filled(fits, 0), List<bool>.filled(fits, false), f),
          isNotNull);
      expect(
          b.buildTexturedGeometry(List<int>.filled(fits + 1, 0),
              List<bool>.filled(fits + 1, false), f),
          isNull);
    });
  });

  group('GeometryBuilder.buildTexturedInterleaved', () {
    test('is the per-kind bakes laid end to end, indices rebased', () {
      final f = frame();
      final b = GeometryBuilder();
      final expected = _Interleaved.concat(<_Interleaved>[
        _Interleaved.of(b.buildNormalInterleaved(<int>[0, 1], f,
            texWidth: 64, texHeight: 32)!),
        _Interleaved.of(b.buildMeshInterleaved(<int>[2, 3], f,
            texWidth: 64, texHeight: 32)!),
        _Interleaved.of(b
            .buildNormalInterleaved(<int>[4], f, texWidth: 64, texHeight: 32)!),
      ]);
      final merged = b.buildTexturedInterleaved(
          <int>[0, 1, 2, 3, 4], <bool>[false, false, true, true, false], f,
          texWidth: 64, texHeight: 32)!;
      expect(merged.vertices, expected.vertices);
      expect(merged.indices, expected.indices);
      expect(merged.vertexCount, expected.vertexCount);
      expect(merged.indexCount, expected.indexCount);
    });

    test('a part that bakes nothing leaves the rebase intact', () {
      final f = frame();
      final b = GeometryBuilder();
      final expected = _Interleaved.concat(<_Interleaved>[
        _Interleaved.of(
            b.buildMeshInterleaved(<int>[3], f, texWidth: 64, texHeight: 32)!),
        _Interleaved.of(b
            .buildNormalInterleaved(<int>[0], f, texWidth: 64, texHeight: 32)!),
      ]);
      final merged = b.buildTexturedInterleaved(
          <int>[5, 3, 1, 0], <bool>[false, true, true, false], f,
          texWidth: 64, texHeight: 32)!;
      expect(merged.vertices, expected.vertices);
      expect(merged.indices, expected.indices);
      expect(merged.vertexCount, expected.vertexCount);
    });
  });

  group('GeometryBuilder.buildEffectRun', () {
    // Plan A runs on part 0, plan B on part 1: each part has its own world
    // matrix and alpha (see [frame]).
    test('is the per-part groups laid end to end, indices rebased', () {
      final f = frame();
      final a = _plan(<int>[1, 2], 1);
      final b = _plan(<int>[2], 2);
      final g = GeometryBuilder();
      final expected = _Raw.concat(<_Raw>[
        _Raw.of(g.buildEffectGroup(a, a.commands!, 0, f,
            texWidth: 64, texHeight: 32)!),
        _Raw.of(g.buildEffectGroup(b, b.commands!, 1, f,
            texWidth: 64, texHeight: 32)!),
      ]);
      final run = g.buildEffectRun(<efbs.EffectDrawPlan>[
        a,
        a,
        b
      ], <efbs.EffectDrawCommand>[
        ...a.commands!,
        ...b.commands!
      ], <int>[
        0,
        0,
        1
      ], f, texWidth: 64, texHeight: 32)!;
      expect(run.positions, expected.positions);
      expect(run.texCoords, expected.texCoords);
      expect(run.colors, expected.colors);
      expect(run.indices, expected.indices);
    });

    test('its flutter_gpu sibling likewise', () {
      final f = frame();
      final a = _plan(<int>[1, 2], 1);
      final b = _plan(<int>[2], 2);
      final g = GeometryBuilder();
      final expected = _Interleaved.concat(<_Interleaved>[
        _Interleaved.of(g.buildEffectGroupInterleaved(a, a.commands!, 0, f,
            texWidth: 64, texHeight: 32)!),
        _Interleaved.of(g.buildEffectGroupInterleaved(b, b.commands!, 1, f,
            texWidth: 64, texHeight: 32)!),
      ]);
      final run = g.buildEffectRunInterleaved(<efbs.EffectDrawPlan>[
        a,
        a,
        b
      ], <efbs.EffectDrawCommand>[
        ...a.commands!,
        ...b.commands!
      ], <int>[
        0,
        0,
        1
      ], f, texWidth: 64, texHeight: 32)!;
      expect(run.vertices, expected.vertices);
      expect(run.indices, expected.indices);
      expect(run.vertexCount, expected.vertexCount);
      expect(run.indexCount, expected.indexCount);
    });
  });

  test('texturedVertexCount is a fan per Normal part, a Mesh part\'s own', () {
    final f = frame();
    expect(GeometryBuilder.texturedVertexCount(0, false, f), 5);
    expect(GeometryBuilder.texturedVertexCount(2, true, f), 3);
    expect(GeometryBuilder.texturedVertexCount(1, true, f), 0);
  });

  test('Ringo\'s Normal and Mesh batches reach the backend as one span', () {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
      '../../examples/overall/assets/spritestudio/Ringo/Ringo.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Ringo.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final spy = _SpanSpy();
    final player =
        SpriteStudioInternalPlayer.load(bytes, renderBackendOverride: spy);
    addTearDown(player.dispose);
    expect(
        player.setupAnimation(SsAnimeInfo(bytes).animationNames.first), isTrue);
    player.play();
    for (var i = 0; i < 30; i++) {
      player.update(const Duration(milliseconds: 33));
      spy.spans.clear();
      final recorder = ui.PictureRecorder();
      player.paint(ui.Canvas(recorder),
          dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
      recorder.endRecording().dispose();
      // Several batches, all in the one call — what makes them one draw.
      expect(spy.spans, hasLength(1), reason: 'frame $i');
      expect(spy.spans.single.$1, 0, reason: 'frame $i');
      expect(spy.spans.single.$2, spy.batchCount, reason: 'frame $i');
      expect(spy.batchCount, greaterThan(1), reason: 'frame $i');
    }
  });

  test('consecutive Effect batches reach the backend as one span', () {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Effect.ssab',
      '../../examples/overall/assets/spritestudio/overall/Effect.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Effect.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final spy = _SpanSpy();
    final player =
        SpriteStudioInternalPlayer.load(bytes, renderBackendOverride: spy);
    addTearDown(player.dispose);
    expect(
        player.setupAnimation(SsAnimeInfo(bytes).animationNames.first), isTrue);
    player.play();
    var longest = 0;
    for (var i = 0; i < 30; i++) {
      player.update(const Duration(milliseconds: 33));
      spy.effectSpans.clear();
      final recorder = ui.PictureRecorder();
      player.paint(ui.Canvas(recorder),
          dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
      recorder.endRecording().dispose();
      for (final (from, to) in spy.effectSpans) {
        final kinds = spy.kinds;
        expect(kinds.sublist(from, to), everyElement(fbs.DrawBatchKind.Effect));
        // Maximal: an Effect batch on either side would have joined it.
        if (from > 0) {
          expect(kinds[from - 1], isNot(fbs.DrawBatchKind.Effect));
        }
        if (to < kinds.length) {
          expect(kinds[to], isNot(fbs.DrawBatchKind.Effect));
        }
        if (to - from > longest) longest = to - from;
      }
    }
    expect(longest, greaterThan(1),
        reason: 'Effect.ssab must put effect parts next to each other');
  });
}

/// An effect plan of one command per entry of [quads], each that many quads
/// on cellmap 7 under Add, with vertices, UVs and colours varied by [seed].
efbs.EffectDrawPlan _plan(List<int> quads, double seed) {
  final verts = <double>[];
  final uvs = <double>[];
  final colors = <double>[];
  final indices = <int>[];
  final commands = <efbs.EffectDrawCommandObjectBuilder>[];
  var offset = 0;
  for (final n in quads) {
    commands.add(efbs.EffectDrawCommandObjectBuilder(
        cellmapHash: 7, quadCount: n, particleOffset: offset, blend: 1));
    for (var q = 0; q < n; q++) {
      for (var c = 0; c < 4; c++) {
        verts.addAll(<double>[seed * 10 + offset + q * 3 + c, seed * 5 - c]);
        uvs.addAll(<double>[c.isEven ? 0.0 : 0.5, c < 2 ? 0.25 : 0.75]);
        colors.addAll(<double>[1.0, 0.25 * seed, 0.5, 0.8]);
      }
      final v = q * 4; // indices are 0-based within their command
      indices.addAll(<int>[v, v + 1, v + 2, v + 2, v + 1, v + 3]);
    }
    offset += n;
  }
  return efbs.EffectDrawPlan(efbs.EffectDrawPlanObjectBuilder(
    commands: commands,
    vertStride: 2,
    verts: verts,
    uvs: uvs,
    colors: colors,
    indices: indices,
  ).toBytes());
}

fbs.PartStateObjectBuilder _part(int index, double alpha) =>
    fbs.PartStateObjectBuilder(
      updateFlag: fbs.UpdateAttributeFlags.AttributeAlpha,
      positionX: 0,
      positionY: 0,
      positionZ: 0,
      rotationX: 0,
      rotationY: 0,
      rotationZ: 0,
      scaleX: 1,
      scaleY: 1,
      localScaleX: 1,
      localScaleY: 1,
      alpha: alpha,
      localAlpha: 1,
      priority: 0,
      pivotX: 0,
      pivotY: 0,
      anchorX: 0,
      anchorY: 0,
      sizeX: 0,
      sizeY: 0,
      uvTranslationX: 0,
      uvTranslationY: 0,
      uvRotationZ: 0,
      uvScaleX: 1,
      uvScaleY: 1,
      boundingRadius: 0,
      mask: 0,
      skewX: 0,
      skewY: 0,
      texture: 0,
      partIndex: index,
      cell: -1,
      partColor: -1,
      shader: -1,
      vertex: -1,
      deform: -1,
      flipH: false,
      flipV: false,
      $hide: false,
      imgFlipH: false,
      imgFlipV: false,
    );

/// A copy of a Canvas bake, which the next bake's scratch would overwrite.
class _Raw {
  _Raw(this.positions, this.texCoords, this.colors, this.indices);

  factory _Raw.of(MeshGeometry g) => _Raw(
      List<double>.of(g.positions),
      List<double>.of(g.texCoords!),
      List<int>.of(g.colors),
      List<int>.of(g.indices));

  /// [parts] laid end to end, each one's indices shifted past the vertices
  /// before it.
  factory _Raw.concat(List<_Raw> parts) {
    final out = _Raw(<double>[], <double>[], <int>[], <int>[]);
    for (final r in parts) {
      final base = out.colors.length;
      out.positions.addAll(r.positions);
      out.texCoords.addAll(r.texCoords);
      out.colors.addAll(r.colors);
      out.indices.addAll(r.indices.map((i) => i + base));
    }
    return out;
  }

  final List<double> positions;
  final List<double> texCoords;
  final List<int> colors;
  final List<int> indices;
}

/// [_Raw] for a flutter_gpu sprite-pipeline bake (8 floats a vertex).
class _Interleaved {
  _Interleaved(this.vertices, this.indices, this.vertexCount, this.indexCount);

  factory _Interleaved.of(InterleavedGeometry g) => _Interleaved(
      List<double>.of(g.vertices),
      List<int>.of(g.indices),
      g.vertexCount,
      g.indexCount);

  factory _Interleaved.concat(List<_Interleaved> parts) {
    final out = _Interleaved(<double>[], <int>[], 0, 0);
    for (final g in parts) {
      out.vertices.addAll(g.vertices);
      out.indices.addAll(g.indices.map((i) => i + out.vertexCount));
      out.vertexCount += g.vertexCount;
      out.indexCount += g.indexCount;
    }
    return out;
  }

  final List<double> vertices;
  final List<int> indices;
  int vertexCount;
  int indexCount;
}

/// A no-op [RenderBackend] that records each span it is handed.
class _SpanSpy implements RenderBackend {
  final List<(int, int)> spans = <(int, int)>[];
  final List<(int, int)> effectSpans = <(int, int)>[];
  List<fbs.DrawBatchKind> kinds = const <fbs.DrawBatchKind>[];
  int batchCount = 0;

  @override
  void emitTextured(ui.Canvas canvas, List<fbs.DrawBatch> batches, int from,
      int to, DrawFrame frame, RenderHost host, PlayerMask masking) {
    spans.add((from, to));
    batchCount = batches.length;
  }

  @override
  void emitEffect(ui.Canvas canvas, List<fbs.DrawBatch> batches, int from,
      int to, DrawFrame frame, RenderHost host) {
    effectSpans.add((from, to));
    kinds = <fbs.DrawBatchKind>[for (final b in batches) b.kind];
  }

  @override
  set onResourcesReady(ui.VoidCallback? callback) {}

  @override
  void beginFrame(ui.Canvas canvas,
      {ui.Rect? dst,
      ui.Size? sourceSize,
      SsRootTransform root = SsRootTransform.identity}) {}

  @override
  void finish() {}

  @override
  void releaseCoverage() {}

  @override
  void rewindShaderPools() {}

  @override
  void pushTransform(ui.Canvas canvas, Float64List world) {}

  @override
  void popTransform(ui.Canvas canvas) {}

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {}

  @override
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
          Map<int, int> textureByRank) =>
      null;

  @override
  void dispose() {}
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
