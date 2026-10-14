// PartColor tests. The pure pieces (coefficient table + the frag→(s,t)
// affine in the geometry builder) run everywhere; the FrameData reader is
// exercised against real converter output from PartsColor.ssab and skips when
// that pack is not deployed (scripts/deploy-examples.sh):
//
//   flutter test test/part_color_test.dart
//
// The actual shader output is NOT covered here — fragment programs don't execute
// under headless `flutter test`; verify PartsColor.ssab visually in the example.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// Re-exports the FrameData readers and adds back the flatc write-side classes,
// which live outside lib/ (see scripts/strip_fbs_builders.dart).
import 'package:ssplayer_flutter/src/render/mask_context.dart';

import 'support/framedata_builders.g.dart' as fbs;

/// A two-tile mask replay as `MaskDraw.writeReplay` flattens it. Every value is
/// float32-exact, so the vertex round-trip is bit-identical.
Float32List _replay() {
  final draw = MaskDraw(
    const MaskBits(
        increment: <int>[5, 7], invert: <int>[6, 8], visibleInside: true),
    null,
    Float32List.fromList(<double>[2, 0, 0, 3]),
    Float32List.fromList(<double>[0.25, 0.5]),
    tilesX: 2,
  );
  final out = Float32List(MaskDraw.replayFloats);
  MaskDraw.writeReplay(draw, out);
  return out;
}

void main() {
  group('partColorCoef', () {
    test('rows for the four valid PartColor modes', () {
      expect(partColorCoef(fbs.BlendType.Mix), const [-1.0, 1.0, 0.0, 0.0]);
      expect(partColorCoef(fbs.BlendType.Mul), const [-1.0, 1.0, 1.0, 0.0]);
      expect(partColorCoef(fbs.BlendType.Add), const [0.0, 1.0, 0.0, 0.0]);
      expect(partColorCoef(fbs.BlendType.Sub), const [0.0, -1.0, 0.0, 0.0]);
    });

    test('framebuffer-only modes clamp to Mix', () {
      for (final t in const [
        fbs.BlendType.Mulalpha,
        fbs.BlendType.Screen,
        fbs.BlendType.Exclusion,
        fbs.BlendType.Invert,
        fbs.BlendType.Overlay2,
      ]) {
        expect(partColorCoef(t), partColorCoef(fbs.BlendType.Mix),
            reason: '$t should clamp to Mix');
      }
    });
  });

  group('GeometryBuilder.buildPartColorQuad', () {
    test('affine maps the four world corners back to unit-square (s,t)', () {
      // World matrix = scale (2,3) + translate (10,20); only m0,m1,m4,m5,m12,m13
      // are read. Local quad is the unit square (lt,rt,lb,rb + center).
      final world = Float32List.fromList(<double>[
        2, 0, 0, 0, //
        0, 3, 0, 0, //
        0, 0, 1, 0, //
        10, 20, 0, 1, //
      ]);
      final local = Float32List.fromList(
          <double>[0, 0, 1, 0, 0, 1, 1, 1, 0.5, 0.5]);
      final uv = Float32List.fromList(
          <double>[0, 0, 64, 0, 0, 64, 64, 64, 32, 32]);

      final frame = DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const [0],
        partByIndex: const [],
        world: world,
        local: local,
        uv: uv,
      );

      final quad = GeometryBuilder().buildPartColorQuad(0, frame);
      expect(quad, isNotNull);

      // World corners: transform(lx,ly) = (2lx+10, 3ly+20).
      expect(quad!.corners, <double>[10, 20, 12, 20, 10, 23, 12, 23]);
      expect(quad.originX, 10);
      expect(quad.originY, 20);
      // inv = [dv.y/det, -dv.x/det, -du.y/det, du.x/det], du=(2,0) dv=(0,3) det=6.
      expect(quad.inv[0], closeTo(0.5, 1e-6));
      expect(quad.inv[1], closeTo(0.0, 1e-6));
      expect(quad.inv[2], closeTo(0.0, 1e-6));
      expect(quad.inv[3], closeTo(1 / 3, 1e-6));
      expect(quad.uvA, <double>[0, 0, 64, 0]);
      expect(quad.uvB, <double>[0, 64, 64, 64]);
      // The centre vertex goes through the same transform; its UV stays pixels.
      expect(quad.center, <double>[11, 21.5, 32, 32]);

      // Round-trip: each world corner must map to its unit-square coordinate.
      Iterable<double> st(double fx, double fy) {
        final dx = fx - quad.originX, dy = fy - quad.originY;
        return [
          quad.inv[0] * dx + quad.inv[1] * dy,
          quad.inv[2] * dx + quad.inv[3] * dy,
        ];
      }

      expect(st(10, 20), [closeTo(0, 1e-6), closeTo(0, 1e-6)]); // lt
      expect(st(12, 20), [closeTo(1, 1e-6), closeTo(0, 1e-6)]); // rt
      expect(st(10, 23), [closeTo(0, 1e-6), closeTo(1, 1e-6)]); // lb
      expect(st(12, 23), [closeTo(1, 1e-6), closeTo(1, 1e-6)]); // rb
    });

    test('degenerate (zero-size) quad yields null', () {
      final world = Float32List(16)..[0] = 1; // all corners collapse to origin
      final local = Float32List(10); // every corner (0,0)
      final uv = Float32List(10);
      final frame = DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const [0],
        partByIndex: const [],
        world: world,
        local: local,
        uv: uv,
      );
      expect(GeometryBuilder().buildPartColorQuad(0, frame), isNull);
    });
  });

  group('GeometryBuilder.buildPartColorInterleaved', () {
    // Identity world; a unit-square local quad (lt,rt,lb,rb + center) so each
    // corner lands on its own world position, and pixel UVs on a 16px texture.
    DrawFrame frameWith({double cx = 0.5, double cy = 0.5}) {
      final world = Float32List.fromList(<double>[
        1, 0, 0, 0, //
        0, 1, 0, 0, //
        0, 0, 1, 0, //
        0, 0, 0, 1, //
      ]);
      final local = Float32List.fromList(
          <double>[0, 0, 1, 0, 0, 1, 1, 1, cx, cy]);
      final uv = Float32List.fromList(
          <double>[0, 0, 8, 0, 0, 8, 8, 8, cx * 8, cy * 8]);
      return DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const [0],
        partByIndex: const [],
        world: world,
        local: local,
        uv: uv,
      );
    }

    // A 4-corner gradient: each corner a distinct colour + rate, so the bake
    // must carry them per vertex (the rasteriser interpolates the gradient).
    PartColor gradient() => PartColor(
          coef: partColorCoef(fbs.BlendType.Mix),
          lt: const PartColorCorner(1, 0, 0, 1, 0.1),
          rt: const PartColorCorner(0, 1, 0, 1, 0.2),
          lb: const PartColorCorner(0, 0, 1, 1, 0.3),
          rb: const PartColorCorner(1, 1, 0, 1, 0.4),
        );

    const stride = GeometryBuilder.partColorStride; // 32

    test('each corner carries its own colour + rate (the 4-corner gradient)', () {
      final pc = gradient();
      final g = GeometryBuilder().buildPartColorInterleaved(
          <int>[0], <PartColor>[pc], <Float32List?>[null], frameWith(),
          texWidth: 16, texHeight: 16);
      expect(g, isNotNull);
      expect(g!.vertexCount, 5);
      final corners = <PartColorCorner>[pc.lt, pc.rt, pc.lb, pc.rb]; // lt,rt,lb,rb
      for (var v = 0; v < 4; v++) {
        final o = v * stride;
        expect(g.vertices[o + 4], closeTo(corners[v].r, 1e-6), reason: 'r $v');
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
      expect(g.vertices[o + 4], closeTo(0.5, 1e-6));
      expect(g.vertices[o + 5], closeTo(0.5, 1e-6));
      expect(g.vertices[o + 6], closeTo(0.25, 1e-6));
      expect(g.vertices[o + 7], closeTo(1, 1e-6));
      expect(g.vertices[o + 8], closeTo(pc.coef[0], 1e-6));
      expect(g.vertices[o + 9], closeTo(pc.coef[1], 1e-6));
      expect(g.vertices[o + 10], closeTo(pc.coef[2], 1e-6));
      expect(g.vertices[o + 11], closeTo(0.25, 1e-6));
    });

    test('positions are world-transformed and UVs normalised', () {
      final g = GeometryBuilder().buildPartColorInterleaved(
          <int>[0], <PartColor>[gradient()], <Float32List?>[null], frameWith(),
          texWidth: 16, texHeight: 16);
      // lt: world (0,0), uv (0,0).
      expect(g!.vertices.sublist(0, 4), <double>[0, 0, 0, 0]);
      // rt: world (1,0), pixel uv (8,0) → normalised (0.5, 0).
      expect(g.vertices.sublist(stride, stride + 4), <double>[1, 0, 0.5, 0]);
      // centre: world (0.5,0.5), pixel uv (4,4) → (0.25, 0.25).
      expect(g.vertices.sublist(4 * stride, 4 * stride + 4),
          <double>[0.5, 0.5, 0.25, 0.25]);
      // Four triangles around the centre.
      expect(g.indices, <int>[4, 0, 1, 4, 1, 3, 4, 3, 2, 4, 2, 0]);
    });

    test('a deformed part\'s centre is its own vertex, not the corners\' mean',
        () {
      final g = GeometryBuilder().buildPartColorInterleaved(
          <int>[0], <PartColor>[gradient()], <Float32List?>[null],
          frameWith(cx: 0.25, cy: 0.75),
          texWidth: 16, texHeight: 16);
      expect(g!.vertices.sublist(4 * stride, 4 * stride + 4),
          <double>[0.25, 0.75, 0.125, 0.375]);
    });

    test('an unmasked part writes mask enabled = 0 on every vertex', () {
      final g = GeometryBuilder().buildPartColorInterleaved(
          <int>[0], <PartColor>[gradient()], <Float32List?>[null], frameWith(),
          texWidth: 16, texHeight: 16);
      for (var v = 0; v < 5; v++) {
        expect(g!.vertices[v * stride + 15], 0.0, reason: 'enabled of $v');
      }
    });

    test('a masked part carries the replay set (flat) on every vertex', () {
      final mask = _replay();
      final g = GeometryBuilder().buildPartColorInterleaved(
          <int>[0], <PartColor>[gradient()], <Float32List?>[mask], frameWith(),
          texWidth: 16, texHeight: 16);
      for (var v = 0; v < 5; v++) {
        final o = v * stride;
        expect(g!.vertices.sublist(o + 12, o + stride), mask);
      }
      // `(visibleInside, enabled, tilesX, tilesY)`, then the per-tile sets.
      expect(mask.sublist(0, 4), <double>[1, 1, 2, 1]);
      expect(mask.sublist(12, 20), <double>[5, 7, 0, 0, 6, 8, 0, 0]);
    });

    test('a degenerate (zero-size) quad is dropped', () {
      final world = Float32List(16)..[0] = 1; // all corners collapse to origin
      final frame = DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const [0],
        partByIndex: const [],
        world: world,
        local: Float32List(10),
        uv: Float32List(10),
      );
      expect(
          GeometryBuilder().buildPartColorInterleaved(
              <int>[0], <PartColor>[gradient()], <Float32List?>[null], frame,
              texWidth: 16, texHeight: 16),
          isNull);
    });
  });

  // A plain part shares the PartColor bake's fan, so a deformed one bends at
  // its own centre whether or not it carries a PartColor.
  group('GeometryBuilder.buildNormalInterleaved', () {
    test('a deformed part is a fan around its own centre vertex', () {
      final world = Float32List(16)
        ..[0] = 1
        ..[5] = 1
        ..[10] = 1
        ..[15] = 1;
      final frame = DrawFrame(
        frameData: fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes()),
        drawOrder: const [0],
        partByIndex: const [],
        world: world,
        local: Float32List.fromList(
            <double>[0, 0, 1, 0, 0, 1, 1, 1, 0.25, 0.75]),
        uv: Float32List.fromList(<double>[0, 0, 8, 0, 0, 8, 8, 8, 2, 6]),
      );
      final g = GeometryBuilder()
          .buildNormalInterleaved(<int>[0], frame, texWidth: 16, texHeight: 16);
      expect(g!.vertexCount, 5);
      expect(g.indices, <int>[4, 0, 1, 4, 1, 3, 4, 3, 2, 4, 2, 0]);
      // centre: world (0.25,0.75), pixel uv (2,6) → (0.125, 0.375), white.
      expect(g.vertices.sublist(4 * 8, 5 * 8),
          <double>[0.25, 0.75, 0.125, 0.375, 1, 1, 1, 1]);
    });
  });

  group('PartColor.wholeTintMatrix', () {
    // The Mesh / Instance-subtree tint is the shader formula reduced
    // to one affine on rgb, so the matrix is checked against that formula
    // directly: for a source pixel, `matrix(pixel)` must equal what
    // `shaders/partcolor.frag` computes from the same corner.
    //
    //   rgb = pixel·(1 + coef₀·rate) + mix(1, pixel, coef₂)·colour·coef₁·rate
    List<double> shaderRgb(PartColor pc, List<double> pixel) {
      final rate = pc.lt.rate;
      final vx = 1.0 + pc.coef[0] * rate;
      final vy = pc.coef[1] * rate;
      final vz = pc.coef[2];
      final col = <double>[pc.lt.r, pc.lt.g, pc.lt.b];
      return <double>[
        for (var c = 0; c < 3; c++)
          pixel[c] * vx + (1.0 - vz + vz * pixel[c]) * col[c] * vy,
      ];
    }

    // The matrix as a caller applies it: row-major 4×5, translation in 0..255.
    List<double> matrixRgb(List<double> m, List<double> pixel) => <double>[
          for (var r = 0; r < 3; r++)
            m[r * 5 + 0] * pixel[0] +
                m[r * 5 + 1] * pixel[1] +
                m[r * 5 + 2] * pixel[2] +
                m[r * 5 + 4] / 255.0,
        ];

    PartColor tint(fbs.BlendType blend, double rate) => PartColor(
          coef: partColorCoef(blend),
          lt: PartColorCorner(0.25, 0.5, 0.75, 1.0, rate),
          // The other corners are deliberately different: whole-only means they
          // must not influence the result.
          rt: const PartColorCorner(1, 0, 0, 1, 1),
          lb: const PartColorCorner(0, 1, 0, 1, 1),
          rb: const PartColorCorner(0, 0, 1, 1, 1),
        );

    test('reproduces the shader formula for all four modes', () {
      const pixels = <List<double>>[
        <double>[0.0, 0.0, 0.0],
        <double>[0.2, 0.6, 1.0],
        <double>[1.0, 1.0, 1.0],
      ];
      for (final blend in const [
        fbs.BlendType.Mix,
        fbs.BlendType.Mul,
        fbs.BlendType.Add,
        fbs.BlendType.Sub,
      ]) {
        for (final rate in const [0.25, 0.5, 1.0]) {
          final pc = tint(blend, rate);
          final m = pc.wholeTintMatrix();
          expect(m, isNotNull, reason: '$blend @ $rate');
          expect(m!.length, 20);
          for (final pixel in pixels) {
            final want = shaderRgb(pc, pixel);
            final got = matrixRgb(m, pixel);
            for (var c = 0; c < 3; c++) {
              expect(got[c], closeTo(want[c], 1e-6),
                  reason: '$blend @ $rate, pixel $pixel, channel $c');
            }
          }
        }
      }
    });

    test('leaves alpha alone — it travels with the geometry, not the tint', () {
      // The corner alpha already carries the hierarchical alpha and is
      // applied as the vertex colour / instance chain scale. Folding it in here
      // as well would double-apply it.
      final m = tint(fbs.BlendType.Mix, 1.0).wholeTintMatrix()!;
      expect(m.sublist(15), <double>[0, 0, 0, 1, 0]);
    });

    test('rate 0 is a no-op and reports null', () {
      // The default (white × rate 0) is a plain passthrough, so the caller
      // must be able to stay on the un-filtered path.
      expect(tint(fbs.BlendType.Mix, 0.0).wholeTintMatrix(), isNull);
      expect(PartColor.identity.wholeTintMatrix(), isNull);
      expect(PartColor.passthrough(0.5).wholeTintMatrix(), isNull);
    });

    test('Mul folds the colour into the scale, Mix/Add/Sub into the offset', () {
      // The structural difference between the two coefficient shapes: Mul
      // (coef₂ == 1) scales the pixel by the colour, the others add a constant.
      final mul = tint(fbs.BlendType.Mul, 1.0).wholeTintMatrix()!;
      expect(mul[4], 0.0); // no red offset
      expect(mul[0], closeTo(0.25, 1e-6)); // scale == the colour itself at rate 1

      final add = tint(fbs.BlendType.Add, 1.0).wholeTintMatrix()!;
      expect(add[0], closeTo(1.0, 1e-6)); // pixel passes through
      expect(add[4], closeTo(0.25 * 255.0, 1e-6)); // colour is added

      final sub = tint(fbs.BlendType.Sub, 1.0).wholeTintMatrix()!;
      expect(sub[4], closeTo(-0.25 * 255.0, 1e-6)); // …and subtracted
    });
  });

  group('PartColor.instanceAlpha', () {
    test('without a tint the part alpha passes through', () {
      expect(
          PartColor.instanceAlpha(null, partAlpha: 0.4, chainScale: 0.5), 0.4);
    });

    test('with a tint the corner alpha replaces PartState.alpha', () {
      // The Brain pre-folded the hierarchical alpha into the corner, so
      // `partAlpha` must be dropped — multiplying the two would apply the
      // hierarchy twice (0.5 × 0.5 = 0.25 would be the bug).
      final pc = PartColor(
        coef: partColorCoef(fbs.BlendType.Mix),
        lt: const PartColorCorner(1, 1, 1, 0.5, 1),
        rt: const PartColorCorner(1, 1, 1, 1, 1),
        lb: const PartColorCorner(1, 1, 1, 1, 1),
        rb: const PartColorCorner(1, 1, 1, 1, 1),
      );
      expect(PartColor.instanceAlpha(pc, partAlpha: 0.5, chainScale: 1.0), 0.5);
      // …but the chain scale lives in the PARENT's FrameData, so it is still
      // owed and multiplies on top.
      expect(PartColor.instanceAlpha(pc, partAlpha: 0.5, chainScale: 0.5), 0.25);
    });
  });

  test('PartColor.read resolves real PartsColor.ssab part colours', () async {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/PartsColor.ssab',
      '../../examples/overall/assets/spritestudio/overall/PartsColor.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('PartsColor.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);

    final info = SsAnimeInfo(bytes);
    expect(player.setupAnimation(info.animationNames.first), isTrue);
    player.play();

    // PartColor may animate in/out; scan a range of frames for any part with a
    // resolvable PartColor and validate the extracted values.
    PartColor? found;
    for (var i = 0; i < 60 && found == null; i++) {
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      final parts = fd?.parts;
      if (fd == null || parts == null) continue;
      final table = fd.partsColor;
      for (final p in parts) {
        final pc = PartColor.read(table, p);
        if (pc != null) {
          found = pc;
          break;
        }
      }
    }

    expect(found, isNotNull,
        reason: 'PartsColor.ssab should have at least one PartColored part');
    final pc = found!;
    expect(pc.coef.length, 4);
    for (final c in [pc.lt, pc.rt, pc.lb, pc.rb]) {
      for (final ch in [c.r, c.g, c.b, c.a]) {
        expect(ch, inInclusiveRange(0.0, 1.0));
      }
      expect(c.rate.isFinite, isTrue);
    }
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
