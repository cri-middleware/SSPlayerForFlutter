// Effect (§8) tests. The blend mapping and the plan→vertices bake run
// everywhere; the slot API is then driven against real converter output from
// Effect.ssab and skips when the example assets haven't been prepared.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/framedata.dart' as fbs;

void main() {
  group('effectBlendModeFor', () {
    test('maps the emitter blend byte, NOT the BlendType enum', () {
      // An emitter's blend is SS6-style: 0 = Mix, 1 = Add. Reading it as a
      // BlendType would make 1 mean Mul and turn additive particles into
      // multiply, so the two mappings must not be confused.
      expect(effectBlendModeFor(0), blendModeFor(fbs.BlendType.Mix));
      expect(effectBlendModeFor(1), blendModeFor(fbs.BlendType.Add));
      expect(effectBlendModeFor(1), isNot(blendModeFor(fbs.BlendType.Mul)));
    });

    test('anything else falls back to Mix', () {
      for (final blend in const [2, 3, 7, 255]) {
        expect(effectBlendModeFor(blend), blendModeFor(fbs.BlendType.Mix));
      }
    });
  });

  group('GeometryBuilder.buildEffectCommand', () {
    // One command, two quads. Verts are in the effect's own simulation space;
    // UVs are normalised 0..1; colours are RGBA 0..1; indices run 0..quads*4.
    efbs.EffectDrawPlan planWith({int vertStride = 2}) {
      final verts = <double>[];
      final uvs = <double>[];
      final colors = <double>[];
      final indices = <int>[];
      for (var q = 0; q < 2; q++) {
        for (var c = 0; c < 4; c++) {
          verts.addAll(<double>[q * 10.0 + c, q * 10.0 + c * 2]);
          if (vertStride == 3) verts.add(0);
          uvs.addAll(<double>[c.isEven ? 0.0 : 1.0, c < 2 ? 0.0 : 0.5]);
          colors.addAll(<double>[1.0, 0.5, 0.0, 1.0]);
        }
        final v = q * 4;
        indices.addAll(<int>[v, v + 1, v + 2, v + 2, v + 1, v + 3]);
      }
      return efbs.EffectDrawPlan(efbs.EffectDrawPlanObjectBuilder(
        commands: <efbs.EffectDrawCommandObjectBuilder>[
          efbs.EffectDrawCommandObjectBuilder(
            cellmapHash: 123,
            quadCount: 2,
            particleOffset: 0,
            blend: 1,
          ),
        ],
        vertStride: vertStride,
        verts: verts,
        uvs: uvs,
        colors: colors,
        indices: indices,
      ).toBytes());
    }

    // Part 0's world matrix: scale (2,3) + translate (100, 200).
    DrawFrame frame() => DrawFrame(
          frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
          drawOrder: const [0],
          partByIndex: const [],
          world: Float32List.fromList(<double>[
            2, 0, 0, 0, //
            0, 3, 0, 0, //
            0, 0, 1, 0, //
            100, 200, 0, 1, //
          ]),
          local: Float32List(0),
          uv: Float32List(0),
        );

    test('applies the effect part world matrix to the plan verts', () {
      // The slot API is never handed a matrix, so the plan's verts are in the
      // effect's own space — the Body must place them. This is the opposite of
      // the mesh path and the #1 thing to get wrong.
      final plan = planWith();
      final g = GeometryBuilder().buildEffectCommand(
          plan, plan.commands!.first, 0, frame(),
          texWidth: 64, texHeight: 32);
      expect(g, isNotNull);
      // vertex 0 is (0,0) → (100,200); vertex 1 is (1,2) → (2+100, 6+200).
      expect(g!.positions[0], closeTo(100, 1e-6));
      expect(g.positions[1], closeTo(200, 1e-6));
      expect(g.positions[2], closeTo(102, 1e-6));
      expect(g.positions[3], closeTo(206, 1e-6));
    });

    test('scales the normalised plan UVs up into texture pixels', () {
      // Effect UVs are normalised (the runtime divides by size_original), while
      // local_uvs / mesh_uvs are already pixels. Flutter's identity ImageShader
      // samples in pixels, so these must be scaled by the texture size.
      final plan = planWith();
      final g = GeometryBuilder().buildEffectCommand(
          plan, plan.commands!.first, 0, frame(),
          texWidth: 64, texHeight: 32);
      // corner UVs per quad: (0,0) (1,0) (0,0.5) (1,0.5) → ×(64,32)
      expect(g!.texCoords!.sublist(0, 8),
          <double>[0, 0, 64, 0, 0, 16, 64, 16]);
    });

    test('packs the 0..1 RGBA plan colours into ARGB', () {
      final plan = planWith();
      final g = GeometryBuilder().buildEffectCommand(
          plan, plan.commands!.first, 0, frame(),
          texWidth: 64, texHeight: 32);
      // (1.0, 0.5, 0.0, 1.0) → a=255 r=255 g=128 b=0; no PartState → alpha 1.
      expect(g!.colors, everyElement(0xFFFF8000.toSigned(32)));
    });

    test('copies the command-local indices without rebasing', () {
      final plan = planWith();
      final g = GeometryBuilder().buildEffectCommand(
          plan, plan.commands!.first, 0, frame(),
          texWidth: 64, texHeight: 32);
      // Values are already 0..quad_count*4 within the command.
      expect(g!.indices, <int>[0, 1, 2, 2, 1, 3, 4, 5, 6, 6, 5, 7]);
    });

    test('merges adjacent commands and rebases their per-command indices', () {
      // Two commands, one quad each, sharing cellmap + blend. Each command's
      // indices are 0-based WITHIN the command (the runtime's convention), so
      // the group bake must rebase the second onto the first's 4 vertices.
      final verts = <double>[];
      final uvs = <double>[];
      final colors = <double>[];
      final indices = <int>[];
      for (var cmd = 0; cmd < 2; cmd++) {
        for (var c = 0; c < 4; c++) {
          verts.addAll(<double>[cmd * 100.0 + c, cmd * 100.0 + c]);
          uvs.addAll(<double>[c.isEven ? 0.0 : 1.0, c < 2 ? 0.0 : 1.0]);
          colors.addAll(<double>[1, 1, 1, 1]);
        }
        indices.addAll(<int>[0, 1, 2, 2, 1, 3]); // 0-based within each command
      }
      final plan = efbs.EffectDrawPlan(efbs.EffectDrawPlanObjectBuilder(
        commands: <efbs.EffectDrawCommandObjectBuilder>[
          efbs.EffectDrawCommandObjectBuilder(
              cellmapHash: 7, quadCount: 1, particleOffset: 0, blend: 0),
          efbs.EffectDrawCommandObjectBuilder(
              cellmapHash: 7, quadCount: 1, particleOffset: 1, blend: 0),
        ],
        vertStride: 2,
        verts: verts,
        uvs: uvs,
        colors: colors,
        indices: indices,
      ).toBytes());

      final g = GeometryBuilder().buildEffectGroup(
          plan, plan.commands!, 0, frame(),
          texWidth: 10, texHeight: 10);
      expect(g, isNotNull);
      expect(g!.positions.length, 8 * 2); // 2 quads × 4 verts × (x,y), one draw
      // command 0's indices stay [0,1,2,2,1,3]; command 1's rebase by +4.
      expect(g.indices, <int>[0, 1, 2, 2, 1, 3, 4, 5, 6, 6, 5, 7]);
      // command 1's first vertex (100,100) → world (2·100+100, 3·100+200).
      expect(g.positions[8], closeTo(300, 1e-6));
      expect(g.positions[9], closeTo(500, 1e-6));
    });

    test('honours a vert_stride of 3 by skipping the z component', () {
      final plan = planWith(vertStride: 3);
      final g = GeometryBuilder().buildEffectCommand(
          plan, plan.commands!.first, 0, frame(),
          texWidth: 64, texHeight: 32);
      expect(g, isNotNull);
      expect(g!.positions.length, 8 * 2); // 2 quads × 4 corners × (x,y)
      expect(g.positions[2], closeTo(102, 1e-6)); // same as the stride-2 case
      expect(g.positions[3], closeTo(206, 1e-6));
    });

    test('an empty command yields null', () {
      final plan = efbs.EffectDrawPlan(efbs.EffectDrawPlanObjectBuilder(
        commands: <efbs.EffectDrawCommandObjectBuilder>[
          // The runtime still emits a command when the cell fails to resolve.
          efbs.EffectDrawCommandObjectBuilder(
              cellmapHash: 0, quadCount: 0, particleOffset: 0, blend: 0),
        ],
        vertStride: 2,
        verts: const <double>[],
        uvs: const <double>[],
        colors: const <double>[],
        indices: const <int>[],
      ).toBytes());
      expect(
          GeometryBuilder().buildEffectCommand(
              plan, plan.commands!.first, 0, frame(),
              texWidth: 64, texHeight: 32),
          isNull);
    });
  });

  test('EffectPart.readAll + the slot API drive the real Effect.ssab', () async {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Effect.ssab',
      '../../examples/overall/assets/spritestudio/overall/Effect.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Effect.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final parts = EffectPart.readAll(bytes);
    expect(parts, isNotEmpty, reason: 'Effect.ssab should host effect parts');
    for (final p in parts) {
      expect(p.effectNameHash, isNot(0),
          reason: 'an effect part must reference an effect');
    }

    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);
    final info = SsAnimeInfo(bytes);
    expect(player.setupAnimation(info.animationNames.first), isTrue);
    player.play();

    // Step until the effect emits, then check the plan against its contract.
    var sawPlan = false;
    for (var i = 0; i < 120 && !sawPlan; i++) {
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      final batches = fd?.drawBatches;
      if (fd == null || batches == null) continue;
      final effectBatches =
          batches.where((b) => b.kind == fbs.DrawBatchKind.Effect);
      if (effectBatches.isEmpty) continue;

      final frame = DrawFrame.build(
        frameData: fd,
        world: player.worldMatrices(),
        local: player.localVertices(),
        uv: player.localUvs(),
      );
      if (frame == null) continue;

      for (final batch in effectBatches) {
        for (var k = 0; k < batch.count; k++) {
          final rank = batch.startRank + k;
          if (rank >= frame.drawOrder.length) break;
          final plan = player.effectPlanFor(frame.drawOrder[rank]);
          final commands = plan?.commands;
          if (plan == null || commands == null || commands.isEmpty) continue;

          final stride = plan.vertStride;
          expect(stride, 2, reason: 'we asked for (x,y) pairs');
          for (final c in commands) {
            if (c.quadCount == 0) continue;
            sawPlan = true;
            // The documented slice contract, against real data.
            expect((c.particleOffset + c.quadCount) * 4 * stride,
                lessThanOrEqualTo(plan.verts!.length));
            expect((c.particleOffset + c.quadCount) * 4 * 2,
                lessThanOrEqualTo(plan.uvs!.length));
            expect((c.particleOffset + c.quadCount) * 4 * 4,
                lessThanOrEqualTo(plan.colors!.length));
            expect((c.particleOffset + c.quadCount) * 6,
                lessThanOrEqualTo(plan.indices!.length));
            expect(c.blend, inInclusiveRange(0, 1));
            // UVs are normalised — this is what distinguishes them from every
            // other kind's texture-pixel UVs.
            final uOff = c.particleOffset * 4 * 2;
            for (var u = uOff; u < uOff + c.quadCount * 4 * 2; u++) {
              expect(plan.uvs![u], inInclusiveRange(0.0, 1.0));
            }
            // Indices are command-local: 0 .. quad_count*4.
            final iOff = c.particleOffset * 6;
            for (var x = iOff; x < iOff + c.quadCount * 6; x++) {
              expect(plan.indices![x], inInclusiveRange(0, c.quadCount * 4 - 1));
            }
          }
        }
      }
    }

    expect(sawPlan, isTrue,
        reason: 'Effect.ssab should emit particles within 120 frames');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
