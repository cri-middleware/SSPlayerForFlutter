// Framebuffer blend **pixel** parity: does the `ui.BlendMode` that
// [blendModeFor] picks actually produce the SpriteStudio GL result?
//
// `blend_test.dart` pins the enum mapping; this file rasterises it. Each case
// draws an opaque backdrop `Cb`, composites a source `(αs, Cs)` on top with the
// mapped blend mode, and compares the read-back pixel against the reference
// fixed-function formula from ssplayer-webgl's `applyBlend`
// (`out = Cs·srcFactor ⊕ Cb·dstFactor`, premultiplied source):
//
//   Mix  ONE,1-αs   Add  ONE,ONE      Mul  DST,1-αs    Sub  ONE,ONE (rev-sub)
//   Screen 1-DST,ONE   Exclusion 1-DST,1-SRC   Invert 1-DST,ZERO
//
// The backdrop is opaque because SS renders onto an opaque target — that is the
// regime the mapping claims to be exact in. Sub / Invert have no stock
// equivalent, so their rows assert the *documented* partial match instead
// (exact in the regime each mode is authored for), which is what stops a future
// "cleanup" from swapping in a mode that looks equally plausible and is worse.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

/// Backdrop levels, including SS's own default canvas grey (0x32).
const _backdrops = <int>[0x00, 0x32, 0x80, 0xC0, 0xFF];

/// Sources as `(alpha, luminance)`, unpremultiplied — how a `ui.Color` is given.
const _sources = <List<int>>[
  [255, 0x00],
  [255, 0x40],
  [255, 0x80],
  [255, 0xC0],
  [255, 0xFF],
  [128, 0xFF],
  [128, 0x80],
  [64, 0x40],
];

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// The reference GL result for one channel over an **opaque** backdrop.
double _reference(fbs.BlendType type, double cs, double alphaS, double cb) {
  switch (type) {
    case fbs.BlendType.Add:
      return _clamp01(cs + cb);
    case fbs.BlendType.Mul:
    case fbs.BlendType.Mulalpha:
    case fbs.BlendType.Mul2:
      return _clamp01(cs * cb + cb * (1 - alphaS));
    case fbs.BlendType.Sub:
      return _clamp01(cb - cs);
    case fbs.BlendType.Screen:
    case fbs.BlendType.Screen2:
      return _clamp01(cs * (1 - cb) + cb);
    case fbs.BlendType.Exclusion:
      return _clamp01(cs * (1 - cb) + cb * (1 - cs));
    case fbs.BlendType.Invert:
      return _clamp01(cs * (1 - cb));
    case fbs.BlendType.Mix:
    case fbs.BlendType.Div2: // clamp to Mix upstream
    case fbs.BlendType.Overlay2:
      return _clamp01(cs + cb * (1 - alphaS));
  }
}

/// Composites `(alpha, luminance)` over an opaque grey `backdrop` with [mode] and
/// returns the resulting `(luminance, alpha)` bytes.
Future<(int, int)> _composite(
    ui.BlendMode mode, int backdrop, int alpha, int luminance) async {
  const rect = ui.Rect.fromLTWH(0, 0, 4, 4);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(rect,
        ui.Paint()..color = ui.Color.fromARGB(255, backdrop, backdrop, backdrop))
    ..drawRect(
        rect,
        ui.Paint()
          ..color = ui.Color.fromARGB(alpha, luminance, luminance, luminance)
          ..blendMode = mode);
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  final bytes = await image.toByteData(); // premultiplied RGBA8888
  picture.dispose();
  image.dispose();
  return (bytes!.getUint8(0), bytes.getUint8(3));
}

/// A 2×1 premultiplied texture: texel 0 is `(alpha, luminance)`, texel 1 is
/// fully transparent — the "part's cell covers this pixel / doesn't" pair.
Future<ui.Image> _texture(int alpha, int luminance) async {
  final premultiplied = (luminance * alpha / 255).round();
  final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(
      <int>[premultiplied, premultiplied, premultiplied, alpha, 0, 0, 0, 0]));
  final codec = await ui.ImageDescriptor.raw(buffer,
          width: 2, height: 1, pixelFormat: ui.PixelFormat.rgba8888)
      .instantiateCodec();
  return (await codec.getNextFrame()).image;
}

final Float64List _identity4x4 = Float64List.fromList(<double>[
  1, 0, 0, 0, //
  0, 1, 0, 0,
  0, 0, 1, 0,
  0, 0, 0, 1,
]);

/// One texel's side on screen in [_replay]. Large, because Impeller blends a
/// single-pixel target inexactly.
const _texelSide = 16;

/// Runs [passes] — with [tint], as a peeled Mesh part does — over a quad of
/// [texture]'s two texels on an opaque grey backdrop, through
/// [drawTexturedPass] as the Canvas backend does. Returns the RGBA of the
/// covered texel, the transparent one, and the backdrop beside the quad.
Future<(List<int>, List<int>, List<int>)> _replay(
    List<BlendPass> passes, ui.Image texture, int backdrop,
    {ui.ColorFilter? tint}) async {
  const w = 2.0 * _texelSide, h = 1.0 * _texelSide;
  final vertices = ui.Vertices.raw(ui.VertexMode.triangles,
      Float32List.fromList(<double>[0, 0, w, 0, 0, h, w, 0, w, h, 0, h]),
      textureCoordinates:
          Float32List.fromList(<double>[0, 0, 2, 0, 0, 1, 2, 0, 2, 1, 0, 1]),
      colors: Int32List.fromList(List<int>.filled(6, 0xFFFFFFFF)));
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawRect(const ui.Rect.fromLTWH(0, 0, 3 * w / 2, h),
        ui.Paint()..color = ui.Color.fromARGB(255, backdrop, backdrop, backdrop));
  final shader = ui.ImageShader(
      texture, ui.TileMode.clamp, ui.TileMode.clamp, _identity4x4,
      filterQuality: ui.FilterQuality.none);
  final paint = ui.Paint(), layerPaint = ui.Paint();
  for (final pass in passes) {
    drawTexturedPass(canvas, vertices, pass, shader,
        tint: tint,
        bounds: const ui.Rect.fromLTWH(0, 0, w, h),
        paint: paint,
        layerPaint: layerPaint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(3 * _texelSide, _texelSide);
  final bytes = (await image.toByteData())!;
  picture.dispose();
  image.dispose();
  List<int> at(int texel) {
    final offset = (_texelSide ~/ 2 * 3 * _texelSide +
            texel * _texelSide +
            _texelSide ~/ 2) *
        4;
    return bytes.buffer.asUint8List(offset, 4).toList();
  }

  return (at(0), at(1), at(2));
}

/// A whole-part red tint at rate 1 over Mix: what a peeled Mesh part's
/// PartColor puts on its draws.
final ui.ColorFilter _red = ui.ColorFilter.matrix(PartColor(
  coef: partColorCoef(fbs.BlendType.Mix),
  lt: const PartColorCorner(1.0, 0.0, 0.0, 1.0, 1.0),
  rt: const PartColorCorner(1.0, 0.0, 0.0, 1.0, 1.0),
  lb: const PartColorCorner(1.0, 0.0, 0.0, 1.0, 1.0),
  rb: const PartColorCorner(1.0, 0.0, 0.0, 1.0, 1.0),
).wholeTintMatrix()!);

/// Every sample as `(backdrop, alpha, luminance, premultiplied Cs, αs, Cb)`.
Iterable<(int, int, int, double, double, double)> _samples() sync* {
  for (final backdrop in _backdrops) {
    for (final source in _sources) {
      final alphaS = source[0] / 255.0;
      yield (
        backdrop,
        source[0],
        source[1],
        (source[1] / 255.0) * alphaS, // premultiplied
        alphaS,
        backdrop / 255.0,
      );
    }
  }
}

void main() {
  // The rows [blendModeFor] claims are exact. ±1 absorbs 8-bit rounding.
  const exactRows = <fbs.BlendType>[
    fbs.BlendType.Mix,
    fbs.BlendType.Add,
    fbs.BlendType.Mul,
    fbs.BlendType.Mulalpha,
    fbs.BlendType.Mul2,
    fbs.BlendType.Screen,
    fbs.BlendType.Screen2,
    fbs.BlendType.Exclusion,
    fbs.BlendType.Div2,
    fbs.BlendType.Overlay2,
  ];

  for (final type in exactRows) {
    test('${type.name} matches the reference GL formula over an opaque backdrop',
        () async {
      final mode = blendModeFor(type);
      for (final (backdrop, alpha, luminance, cs, alphaS, cb) in _samples()) {
        final (got, gotAlpha) = await _composite(mode, backdrop, alpha, luminance);
        final want = (_reference(type, cs, alphaS, cb) * 255).round();
        expect(got, closeTo(want, 1),
            reason: '${type.name} ($mode) Cb=$backdrop '
                'src=(a$alpha,${luminance.toRadixString(16)}): '
                'got $got, reference $want');
        // Every SS row composites alpha as source-over, so an opaque backdrop
        // stays opaque — a mode that eats alpha would punch a hole instead of
        // recolouring (the bug the GPU backend's Sub used to have).
        expect(gotAlpha, 255,
            reason: '${type.name} must not disturb an opaque backdrop alpha');
      }
    });
  }

  // --- The multi-pass reconstructions the Canvas backend actually draws ------
  //
  // `Sub` / `Invert` have no single stock mode, so `blendPassesFor` returns a
  // multi-pass plan. These replay that plan through the helper the backend
  // draws a textured part with ([drawTexturedPass]) over a 2×1 texture — one
  // covered texel, one fully transparent — and require the result to match the
  // reference GL formula in BOTH, since a part's quad always contains texels its
  // cell does not cover. Run them under `--enable-impeller` too: Impeller drops
  // a filter the helper put in the wrong place.
  for (final type in [fbs.BlendType.Sub, fbs.BlendType.Invert]) {
    test('${type.name} is pixel-exact as a ${blendPassesFor(type).length}-pass '
        'plan over an opaque backdrop', () async {
      final passes = blendPassesFor(type);
      expect(passes.length, greaterThan(1),
          reason: 'a reconstruction, not a single mode');
      for (final source in _sources) {
        final texture = await _texture(source[0], source[1]);
        final alphaS = source[0] / 255.0;
        final cs = (source[1] / 255.0) * alphaS;
        for (final backdrop in _backdrops) {
          final cb = backdrop / 255.0;
          final (covered, clear, outside) =
              await _replay(passes, texture, backdrop);
          expect(covered[0], closeTo((_reference(type, cs, alphaS, cb) * 255).round(), 2),
              reason: '${type.name} covered texel, Cb=$backdrop '
                  'src=(a${source[0]},${source[1].toRadixString(16)})');
          // The transparent texel: Cs == 0, so Sub leaves the backdrop alone
          // while Invert's ZERO dst factor blacks it out.
          expect(clear[0], closeTo((_reference(type, 0, 0, cb) * 255).round(), 2),
              reason: '${type.name} uncovered texel, Cb=$backdrop');
          expect(covered[3], 255,
              reason: '${type.name} must leave an opaque backdrop opaque');
          expect(outside, [backdrop, backdrop, backdrop, 255],
              reason: '${type.name} reaches past its geometry');
        }
        texture.dispose();
      }
    });
  }

  // `plus` does not clamp on every target — Impeller (measured on macOS) keeps
  // the sum above 1 — and no headless run shows it: where the target clamps,
  // the clamp pass changes nothing. Without it the last inversion turns the
  // excess into brightness, so the plan is pinned here.
  test('Sub clamps its sum before the last inversion', () {
    final passes = blendPassesFor(fbs.BlendType.Sub);
    expect([for (final pass in passes) pass.mode], [
      ui.BlendMode.difference,
      ui.BlendMode.plus,
      ui.BlendMode.darken,
      ui.BlendMode.difference,
    ]);
    expect(passes[2].source, BlendPassSource.coverage);
  });

  test('a fully transparent Sub part is a no-op (both inversions cancel)',
      () async {
    final texture = await _texture(0, 0xFF);
    for (final backdrop in _backdrops) {
      final (covered, clear, _) =
          await _replay(blendPassesFor(fbs.BlendType.Sub), texture, backdrop);
      expect(covered[0], closeTo(backdrop, 1));
      expect(clear[0], closeTo(backdrop, 1));
      expect(covered[3], 255);
    }
    texture.dispose();
  });

  test('a whole-part tint reaches the texel, and a coverage pass replaces it',
      () async {
    final texture = await _texture(255, 0x80);
    final mix = blendPassesFor(fbs.BlendType.Mix).single;
    final (tinted, _, _) = await _replay([mix], texture, 0x00, tint: _red);
    expect(tinted, [255, 0, 0, 255],
        reason: 'Mix at rate 1 paints the tint colour over the texel');

    // The coverage pass wants white wherever the part covers, tint or not;
    // `difference` against the black backdrop leaves it white.
    final coverage = blendPassesFor(fbs.BlendType.Sub).first;
    expect(coverage.source, BlendPassSource.coverage);
    final (covered, _, _) = await _replay([coverage], texture, 0x00, tint: _red);
    expect(covered, [255, 255, 255, 255]);
    texture.dispose();
  });

  // A tinted `modulate` pass goes through a layer; `modulate` with whatever
  // that layer leaves transparent would zero the destination there.
  for (final type in [fbs.BlendType.Sub, fbs.BlendType.Invert]) {
    test('a tinted ${type.name} part draws its tinted colour and nothing '
        'past its geometry', () async {
      final texture = await _texture(255, 0x80);
      const backdrop = 0x80;
      final (covered, clear, outside) = await _replay(
          blendPassesFor(type), texture, backdrop,
          tint: _red);
      final cb = backdrop / 255.0;
      for (final (channel, cs) in [(0, 1.0), (1, 0.0), (2, 0.0)]) {
        expect(covered[channel],
            closeTo((_reference(type, cs, 1.0, cb) * 255).round(), 2),
            reason: '${type.name} channel $channel of the tinted texel');
      }
      expect(clear[0], closeTo((_reference(type, 0, 0, cb) * 255).round(), 2));
      expect(outside, [backdrop, backdrop, backdrop, 255]);
      texture.dispose();
    });
  }

  test('every other mode stays a single pass', () async {
    for (final type in fbs.BlendType.values) {
      final passes = blendPassesFor(type);
      if (type == fbs.BlendType.Sub || type == fbs.BlendType.Invert) continue;
      expect(passes, hasLength(1), reason: '${type.name} must not go multi-pass');
      expect(passes.single.mode, blendModeFor(type));
      expect(passes.single.source, BlendPassSource.part);
      expect(passes.single.filter, isNull,
          reason: 'a single-pass draw must keep its own colour filter (tints)');
    }
  });

  // Sub: exact in the darkening regime it is authored for. Skia's premultiplied
  // `difference` is `Cs + Cb - 2·min(Cs·αb, Cb·αs)`, which collapses to the
  // reference `Cb - Cs` exactly while `Cs ≤ αs·Cb` — for the usual opaque source
  // that is simply "wherever the backdrop is the brighter one". This pins the
  // *one-pass* answer [blendModeFor] still hands to callers that cannot run a
  // plan; the Canvas backend uses the exact reconstruction above instead.
  test('Sub is exact where Cs <= alphaS*Cb (the regime it is authored for)',
      () async {
    final mode = blendModeFor(fbs.BlendType.Sub);
    expect(mode, ui.BlendMode.difference);
    var checked = 0;
    for (final (backdrop, alpha, luminance, cs, alphaS, cb) in _samples()) {
      if (cs > alphaS * cb) continue; // documented divergence
      final (got, _) = await _composite(mode, backdrop, alpha, luminance);
      final want = (_reference(fbs.BlendType.Sub, cs, alphaS, cb) * 255).round();
      expect(got, closeTo(want, 1),
          reason: 'Sub Cb=$backdrop src=(a$alpha,'
              '${luminance.toRadixString(16)}): got $got, reference $want');
      checked++;
    }
    expect(checked, greaterThan(10), reason: 'sample grid must cover Cb >= Cs');
  });

  // Invert: exact for the opaque-white overlay it is authored with, since
  // `|1 - Cb| == 1 - Cb`. Everything else is a documented approximation — Skia
  // has no dst-replace, so the flutter_gpu backend is the exact path.
  test('Invert is exact for an opaque white source', () async {
    final mode = blendModeFor(fbs.BlendType.Invert);
    expect(mode, ui.BlendMode.difference);
    for (final backdrop in _backdrops) {
      final (got, _) = await _composite(mode, backdrop, 255, 0xFF);
      final want =
          (_reference(fbs.BlendType.Invert, 1.0, 1.0, backdrop / 255.0) * 255)
              .round();
      expect(got, closeTo(want, 1),
          reason: 'Invert Cb=$backdrop: got $got, reference $want');
    }
  });

  // The effect blend byte is its own enum space; additive there is
  // `(ONE, ONE, ONE, ONE)` — alpha adds too, which `plus` does and `srcOver`
  // does not.
  test('effect additive adds all four channels', () async {
    expect(effectBlendModeFor(1), ui.BlendMode.plus);
    expect(effectBlendModeFor(0), ui.BlendMode.srcOver);
    final (got, _) = await _composite(effectBlendModeFor(1), 0x40, 128, 0xFF);
    expect(got, closeTo(0x40 + 128, 1)); // Cs premultiplied = 128/255
  });
}
