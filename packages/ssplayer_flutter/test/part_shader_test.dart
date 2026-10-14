// Integration-shader (`SHDR`) tests. The pure pieces — the id_hash catalog, the
// cell-rect derivation and the flutter_gpu vertex bake — run everywhere; the
// FrameData reader is exercised against real converter output from Shader.ssab
// and skips when that asset is missing.
//
// The effects themselves are NOT covered here: fragment programs do not execute
// under headless `flutter test`. What IS covered is the contract between the
// Dart uniform writer and the compiled programs — every `ss_*.frag` must load
// and expose exactly the float count `_setSsShaderUniforms` writes — which is
// the failure the runtime hides (a rejected shader silently falls back to the
// plain path). Verify the visuals in `examples/overall` on the `Shader` pack.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

/// Floats `CanvasBackend._setSsShaderUniforms` writes, i.e. the float uniform
/// count of `shaders/ss_shader_common.glsl`:
/// uOrigin 2 + uInv 4 + uTexSize 2 + uCoef 4 + uRate 4 + uCol×4 16 + uUvA 4 +
/// uUvB 4 + uParams 4 + uCellRect 4.
const int _kSsUniformFloats = 48;

void main() {
  group('SsShaderId', () {
    test('the catalog is the 13 built-ins with their baked hashes', () {
      // These are `fnv1a_hash_str(id)` as the converter bakes it; the same
      // table appears in the Web (SSShaderLib.ts) and Godot ports. A mismatch
      // here silently downgrades that effect to the plain path, so pin them.
      expect(<SsShaderId, int>{
        for (final id in SsShaderId.values) id: id.hash,
      }, <SsShaderId, int>{
        SsShaderId.sepia: 0x36629dfc,
        SsShaderId.hsb: 0x8a5c3037,
        SsShaderId.step: 0x1b721788,
        SsShaderId.pix: 0xc488a527,
        SsShaderId.noise: 0x80d6d514,
        SsShaderId.bmask: 0x64e07450,
        SsShaderId.outline: 0x8f8307d4,
        SsShaderId.blur: 0xb59c8d1b,
        SsShaderId.wave: 0xe1df9a2b,
        SsShaderId.move: 0xe1c1ee07,
        SsShaderId.scatter: 0x45e35578,
        SsShaderId.circle: 0x9b90e282,
        SsShaderId.spot: 0x7140896a,
      });
    });

    test('fromHash resolves the catalog and rejects anything else', () {
      for (final id in SsShaderId.values) {
        expect(SsShaderId.fromHash(id.hash), id);
      }
      // SpriteStudio's `Default` passthrough — deliberately NOT implemented; it
      // must resolve to null so the part keeps the plain path.
      expect(SsShaderId.fromHash(0x19dc307e), isNull);
      expect(SsShaderId.fromHash(0), isNull);
    });

    test('the GPU branch ids match the declaration order', () {
      // shaders/gpu/ssshader.frag's SS_* constants are these indices; the Dart
      // side uploads `id.index`, so the order is load-bearing.
      expect(SsShaderId.sepia.index, 0);
      expect(SsShaderId.blur.index, 7);
      expect(SsShaderId.spot.index, 12);
      expect(SsShaderId.values.length, 13);
    });
  });

  group('PartColorQuad.cellRect', () {
    // A quad whose corner UVs are NOT axis-ordered (the part is flipped), so
    // min/max is doing real work rather than reading lt/rb off the ends.
    PartColorQuad quadWith(List<double> uvA, List<double> uvB) => PartColorQuad(
          corners: Float32List.fromList(<double>[0, 0, 1, 0, 0, 1, 1, 1]),
          originX: 0,
          originY: 0,
          inv: Float32List(4),
          uvA: Float32List.fromList(uvA),
          uvB: Float32List.fromList(uvB),
        );

    test('is the corner UVs bounding box, normalised by the texture size', () {
      // Cell at pixels x 32..96, y 16..48 on a 128×64 atlas.
      final quad = quadWith(<double>[32, 16, 96, 16], <double>[32, 48, 96, 48]);
      expect(quad.cellRect(128, 64), <double>[32 / 128, 16 / 64, 96 / 128, 48 / 64]);
    });

    test('a flipped part still yields (min, min, max, max)', () {
      // Horizontally flipped: LT carries the RIGHT edge. ss-circle/ss-spot
      // centre on the cell, so an inverted rect would put the disc off-cell.
      final quad = quadWith(<double>[96, 16, 32, 16], <double>[96, 48, 32, 48]);
      expect(quad.cellRect(128, 64), <double>[32 / 128, 16 / 64, 96 / 128, 48 / 64]);
    });

    test('a zero texture size degenerates to zeros rather than dividing by 0', () {
      expect(quadWith(<double>[1, 2, 3, 4], <double>[5, 6, 7, 8]).cellRect(0, 0),
          <double>[0, 0, 0, 0]);
    });
  });

  group('GeometryBuilder.buildSsShaderInterleaved', () {
    // Identity world, unit-square local quad, pixel UVs on a 16px texture.
    PartColorQuad quad() => PartColorQuad(
          corners: Float32List.fromList(<double>[0, 0, 1, 0, 0, 1, 1, 1]),
          originX: 0,
          originY: 0,
          inv: Float32List(4),
          uvA: Float32List.fromList(<double>[0, 0, 8, 0]),
          uvB: Float32List.fromList(<double>[0, 8, 8, 8]),
          center: Float32List.fromList(<double>[0.5, 0.5, 4, 4]),
        );

    PartColor gradient() => PartColor(
          coef: partColorCoef(fbs.BlendType.Mix),
          lt: const PartColorCorner(1, 0, 0, 1, 0.1),
          rt: const PartColorCorner(0, 1, 0, 1, 0.2),
          lb: const PartColorCorner(0, 0, 1, 1, 0.3),
          rb: const PartColorCorner(1, 1, 0, 1, 0.4),
        );

    const stride = GeometryBuilder.ssShaderStride; // 12

    test('is one fan in the ssshader.vert layout', () {
      final g = GeometryBuilder()
          .buildSsShaderInterleaved(quad(), gradient(), texWidth: 16, texHeight: 16);
      expect(g, isNotNull);
      expect(g!.vertexCount, 5);
      expect(g.vertices.length, 5 * stride);
      expect(g.indices, <int>[4, 0, 1, 4, 1, 3, 4, 3, 2, 4, 2, 0]);
      // lt: world (0,0), uv (0,0); rt: world (1,0), pixel uv (8,0) → (0.5, 0).
      expect(g.vertices.sublist(0, 4), <double>[0, 0, 0, 0]);
      expect(g.vertices.sublist(stride, stride + 4), <double>[1, 0, 0.5, 0]);
      // centre: world (0.5,0.5), pixel uv (4,4) → (0.25, 0.25).
      expect(g.vertices.sublist(4 * stride, 4 * stride + 4),
          <double>[0.5, 0.5, 0.25, 0.25]);
    });

    test('each corner carries its own colour + rate (the 4-corner gradient)', () {
      final pc = gradient();
      final g = GeometryBuilder()
          .buildSsShaderInterleaved(quad(), pc, texWidth: 16, texHeight: 16);
      final corners = <PartColorCorner>[pc.lt, pc.rt, pc.lb, pc.rb];
      for (var v = 0; v < 4; v++) {
        final o = v * stride;
        expect(g!.vertices[o + 4], closeTo(corners[v].r, 1e-6), reason: 'r $v');
        expect(g.vertices[o + 5], closeTo(corners[v].g, 1e-6), reason: 'g $v');
        expect(g.vertices[o + 6], closeTo(corners[v].b, 1e-6), reason: 'b $v');
        expect(g.vertices[o + 7], closeTo(corners[v].a, 1e-6), reason: 'a $v');
        // coef.xyz is constant across the quad; rate is this corner's own.
        expect(g.vertices[o + 8], closeTo(pc.coef[0], 1e-6));
        expect(g.vertices[o + 9], closeTo(pc.coef[1], 1e-6));
        expect(g.vertices[o + 10], closeTo(pc.coef[2], 1e-6));
        expect(g.vertices[o + 11], closeTo(corners[v].rate, 1e-6),
            reason: 'rate $v');
      }
      // The fan's centre takes the corners' average colour and rate.
      const o = 4 * stride;
      expect(g!.vertices.sublist(o + 4, o + 8),
          <double>[0.5, 0.5, 0.25, 1].map((x) => closeTo(x, 1e-6)).toList());
      expect(g.vertices[o + 11], closeTo(0.25, 1e-6));
    });

    test('the stride keeps every vec4 attribute 16-byte aligned', () {
      // The ShapeMask trap: Impeller misreads a vec4 off a 16-byte boundary.
      // a_color at float 4 (byte 16), a_coef at float 8 (byte 32), and the
      // stride itself a multiple of 16 so it recurs on every vertex.
      expect(stride * 4 % 16, 0);
      expect(4 * 4 % 16, 0);
      expect(8 * 4 % 16, 0);
    });
  });

  group('the compiled programs', () {
    // The one failure the runtime hides: an `ss_*.frag` impellerc rejects fails
    // to load and silently falls back to the plain path, and a uniform-block
    // edit that does not land in `_setSsShaderUniforms` writes garbage. Both
    // show up here.
    for (final id in SsShaderId.values) {
      test('${id.name} loads and takes exactly $_kSsUniformFloats floats',
          () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        // Package-local key: under `flutter test` the package's own assets sit
        // at the bundle root (the backend uses the `packages/…` form at runtime).
        final program =
            await ui.FragmentProgram.fromAsset('shaders/${id.asset}.frag');
        final shader = program.fragmentShader();
        addTearDown(shader.dispose);
        // The last index the writer touches must exist…
        shader.setFloat(_kSsUniformFloats - 1, 1.0);
        // …and be the last one, so the shared block has not drifted.
        expect(() => shader.setFloat(_kSsUniformFloats, 1.0), throwsA(anything));
      });
    }
  });

  test('PartShader.read resolves every built-in out of real Shader.ssab',
      () async {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Shader.ssab',
      '../../examples/overall/assets/spritestudio/overall/Shader.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Shader.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final info = SsAnimeInfo(bytes);

    final seen = <SsShaderId>{};
    final unknownHashes = <int>{};
    for (final name in info.animationNames) {
      final player = SpriteStudioInternalPlayer.load(bytes);
      addTearDown(player.dispose);
      if (!player.setupAnimation(name)) continue;
      player.play();
      // The sample animations are short; a couple of seconds at 60 fps covers
      // every one of them several times over.
      for (var i = 0; i < 180; i++) {
        player.update(const Duration(milliseconds: 16));
        final fd = player.getFrameData(player.frameNo);
        final parts = fd?.parts;
        if (fd == null || parts == null) continue;
        final table = fd.shaders;
        for (final p in parts) {
          if (p.shader < 0) continue;
          final sh = PartShader.read(table, p);
          if (sh != null) {
            seen.add(sh.id);
          } else if (table != null && p.shader < table.length) {
            unknownHashes.add(table[p.shader].idHash);
          }
        }
      }
    }

    // The pack exercises all 13, so this doubles as a check of the baked hash
    // table against real converter output.
    expect(seen, SsShaderId.values.toSet(),
        reason: 'Shader.ssab references every built-in ss-* effect');
    expect(unknownHashes, isEmpty,
        reason: 'unrecognised id_hash(es) in Shader.ssab — the catalog is stale');
  });

  test('a part with no SHDR attribute reads back as null', () async {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Basic.ssab',
      '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);
    expect(player.setupAnimation(SsAnimeInfo(bytes).animationNames.first), isTrue);
    player.play();

    var checked = 0;
    for (var i = 0; i < 30; i++) {
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      final parts = fd?.parts;
      if (fd == null || parts == null) continue;
      final table = fd.shaders;
      for (final p in parts) {
        expect(PartShader.read(table, p), isNull);
        checked++;
      }
    }
    expect(checked, greaterThan(0), reason: 'no parts were examined');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
