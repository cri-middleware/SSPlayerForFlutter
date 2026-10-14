// A Normal part's four-corner PartColor, rasterised: `shaders/partcolor.frag`
// rebuilds the corner gradient per fragment, and it must be the gradient of the
// part's fan — four triangles around a centre that takes the corners' average —
// which is what the flutter_gpu backend draws as vertices. A bilinear gradient
// matches the fan at the corners, the centre and the middle of each edge, and
// differs everywhere else, so this compares every pixel.
//
// `shaders/ss_shader_common.glsl` takes the same weights from the same include
// (`shaders/part_fan.glsl`).
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

const int _size = 32;

/// Straight RGB of the four corners, in uniform order (LT, RT, LB, RB): every
/// channel tells a different pair of corners apart.
const List<List<double>> _corners = <List<double>>[
  <double>[1, 0, 0],
  <double>[0, 1, 0],
  <double>[0, 0, 1],
  <double>[1, 1, 1],
];

/// The fan's weights on (LT, RT, LB, RB) at quad-local (s, t), the centre's
/// share spread over the corners it averages.
List<double> _fanWeights(double s, double t) {
  final double hub;
  final List<double> w;
  if (t <= s && t <= 1 - s) {
    hub = 2 * t;
    w = <double>[1 - s - t, s - t, 0, 0];
  } else if (t >= s && t >= 1 - s) {
    hub = 2 - 2 * t;
    w = <double>[0, 0, t - s, s + t - 1];
  } else if (s <= t) {
    hub = 2 * s;
    w = <double>[1 - s - t, 0, t - s, 0];
  } else {
    hub = 2 - 2 * s;
    w = <double>[0, s - t, 0, s + t - 1];
  }
  return <double>[for (final x in w) x + hub / 4];
}

void main() {
  test('partcolor.frag shades the four corners across the part\'s fan',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Package-local key: under `flutter test` the package's own assets sit at
    // the bundle root, as part_shader_test.dart does.
    final program =
        await ui.FragmentProgram.fromAsset('shaders/partcolor.frag');
    final shader = program.fragmentShader();
    addTearDown(shader.dispose);
    final white = await _whitePixel();
    addTearDown(white.dispose);

    // Mix at rate 1 over a white texel: the output is the corner gradient.
    final coef = partColorCoef(fbs.BlendType.Mix);
    // Declaration order of shaders/partcolor.frag, mirroring
    // CanvasBackend._setPartColorUniforms.
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    f(0); // uOrigin — the quad starts at the origin…
    f(0);
    f(1 / _size); // uInv — …and spans _size, so (s, t) is the unit square
    f(0);
    f(0);
    f(1 / _size);
    f(1); // uTexSize — a 1×1 texture
    f(1);
    for (var k = 0; k < 4; k++) {
      f(k < coef.length ? coef[k] : 0); // uCoef
    }
    for (var k = 0; k < 4; k++) {
      f(1); // uRate (LT, RT, LB, RB)
    }
    for (final c in _corners) {
      f(c[0]); // uColLT..uColRB, opaque
      f(c[1]);
      f(c[2]);
      f(1);
    }
    for (var k = 0; k < 8; k++) {
      f(0.5); // uUvA / uUvB — the middle of the single texel
    }
    f(0); // uMaskBits
    f(0); // masking off
    f(1); // the tile grid
    f(1);
    for (var k = 0; k < 6 + 8; k++) {
      f(0); // uMaskUv, uMaskOff, uMaskInc, uMaskInv
    }
    shader
      ..setImageSampler(0, white)
      ..setImageSampler(1, white);

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, _size * 1.0, _size * 1.0),
        ui.Paint()..shader = shader);
    final picture = recorder.endRecording();
    final image = await picture.toImage(_size, _size);
    final bytes = (await image.toByteData())!.buffer.asUint8List();
    picture.dispose();
    image.dispose();

    var worst = 0;
    var where = '';
    for (var y = 0; y < _size; y++) {
      for (var x = 0; x < _size; x++) {
        final w = _fanWeights((x + 0.5) / _size, (y + 0.5) / _size);
        for (var c = 0; c < 3; c++) {
          var expected = 0.0;
          for (var k = 0; k < 4; k++) {
            expected += w[k] * _corners[k][c];
          }
          final off =
              (bytes[(y * _size + x) * 4 + c] - (expected * 255).round()).abs();
          if (off > worst) {
            worst = off;
            where = '($x, $y) channel $c';
          }
        }
      }
    }
    expect(worst, lessThanOrEqualTo(2), reason: 'furthest off at $where');
  });
}

Future<ui.Image> _whitePixel() {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(Uint8List.fromList(<int>[255, 255, 255, 255]), 1,
      1, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}
