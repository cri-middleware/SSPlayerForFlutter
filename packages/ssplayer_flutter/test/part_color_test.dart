// PartColor (§10) tests. The pure pieces (coefficient table + the frag→(s,t)
// affine in the geometry builder) run everywhere; the FrameData reader is
// exercised against real converter output from PartsColor.ssab and skips when
// the host Brain isn't built:
//
//   SSRUNTIME_LIBRARY_PATH=$PWD/native/libs/macos/libssruntime.framework/libssruntime \
//     flutter test test/part_color_test.dart
//
// The actual shader output is NOT covered here — fragment programs don't execute
// under headless `flutter test`; verify PartsColor.ssab visually in the example.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab/framedata.g.dart' as fbs;

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
        partByIndex: const {},
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
        partByIndex: const {},
        world: world,
        local: local,
        uv: uv,
      );
      expect(GeometryBuilder().buildPartColorQuad(0, frame), isNull);
    });
  });

  test('PartColor.read resolves real PartsColor.ssab part colours', () async {
    final libPath = Platform.environment['SSRUNTIME_LIBRARY_PATH'];
    final ssabPath = _firstExisting([
      'example/assets/overall/PartsColor.ssab',
      '../../example/assets/overall/PartsColor.ssab',
    ]);
    if (libPath == null || !File(libPath).existsSync()) {
      markTestSkipped('SSRUNTIME_LIBRARY_PATH not set — run build-runtime.sh');
      return;
    }
    if (ssabPath == null) {
      markTestSkipped('PartsColor.ssab missing — run prepare-example-assets.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final runtime = SsRuntime.open(libraryPath: libPath);
    final player = SpriteStudioInternalPlayer.load(bytes, runtime: runtime);
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
      for (final p in parts) {
        final pc = PartColor.read(fd, p);
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
