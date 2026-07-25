// Framebuffer blend **pixel** parity (§7B): does the `ui.BlendMode` that
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

/// Runs [passes] over a 2×1-texel quad on an opaque grey backdrop, through the
/// same `drawVertices` + `ImageShader` + `modulate` shape the Canvas backend
/// uses, and returns the `(luminance, alpha)` of the covered and uncovered texel.
Future<((int, int), (int, int))> _replay(
    List<BlendPass> passes, ui.Image texture, int backdrop) async {
  final coordinates =
      Float32List.fromList(<double>[0, 0, 2, 0, 0, 1, 2, 0, 2, 1, 0, 1]);
  final vertices = ui.Vertices.raw(ui.VertexMode.triangles, coordinates,
      textureCoordinates: coordinates,
      colors: Int32List.fromList(List<int>.filled(6, 0xFFFFFFFF)));
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawRect(const ui.Rect.fromLTWH(0, 0, 2, 1),
        ui.Paint()..color = ui.Color.fromARGB(255, backdrop, backdrop, backdrop));
  for (final pass in passes) {
    canvas.drawVertices(
        vertices,
        ui.BlendMode.modulate,
        ui.Paint()
          ..blendMode = pass.mode
          ..colorFilter = pass.filter
          ..shader = ui.ImageShader(
              texture, ui.TileMode.clamp, ui.TileMode.clamp, _identity4x4));
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 1);
  final bytes = await image.toByteData();
  picture.dispose();
  image.dispose();
  return (
    (bytes!.getUint8(0), bytes.getUint8(3)),
    (bytes.getUint8(4), bytes.getUint8(7)),
  );
}

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
  // three-pass plan. These replay that plan through the same call shape the
  // backend uses (`drawVertices` + `ImageShader` + `BlendMode.modulate`) over a
  // 2×1 texture — one covered texel, one fully transparent — and require the
  // result to match the reference GL formula in BOTH, since a part's quad always
  // contains texels its cell does not cover.
  for (final type in [fbs.BlendType.Sub, fbs.BlendType.Invert]) {
    test('${type.name} is pixel-exact as a ${blendPassesFor(type).length}-pass '
        'plan over an opaque backdrop', () async {
      final passes = blendPassesFor(type);
      expect(passes.length, 3, reason: 'a reconstruction, not a single mode');
      for (final source in _sources) {
        final texture = await _texture(source[0], source[1]);
        final alphaS = source[0] / 255.0;
        final cs = (source[1] / 255.0) * alphaS;
        for (final backdrop in _backdrops) {
          final cb = backdrop / 255.0;
          final (covered, clear) = await _replay(passes, texture, backdrop);
          expect(covered.$1, closeTo((_reference(type, cs, alphaS, cb) * 255).round(), 2),
              reason: '${type.name} covered texel, Cb=$backdrop '
                  'src=(a${source[0]},${source[1].toRadixString(16)})');
          // The transparent texel: Cs == 0, so Sub leaves the backdrop alone
          // while Invert's ZERO dst factor blacks it out.
          expect(clear.$1, closeTo((_reference(type, 0, 0, cb) * 255).round(), 2),
              reason: '${type.name} uncovered texel, Cb=$backdrop');
          expect(covered.$2, 255,
              reason: '${type.name} must leave an opaque backdrop opaque');
        }
        texture.dispose();
      }
    });
  }

  test('a fully transparent Sub part is a no-op (both inversions cancel)',
      () async {
    final texture = await _texture(0, 0xFF);
    for (final backdrop in _backdrops) {
      final (covered, clear) =
          await _replay(blendPassesFor(fbs.BlendType.Sub), texture, backdrop);
      expect(covered.$1, closeTo(backdrop, 1));
      expect(clear.$1, closeTo(backdrop, 1));
      expect(covered.$2, 255);
    }
    texture.dispose();
  });

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

  // The effect blend byte (§8) is its own enum space; additive there is
  // `(ONE, ONE, ONE, ONE)` — alpha adds too, which `plus` does and `srcOver`
  // does not.
  test('effect additive adds all four channels', () async {
    expect(effectBlendModeFor(1), ui.BlendMode.plus);
    expect(effectBlendModeFor(0), ui.BlendMode.srcOver);
    final (got, _) = await _composite(effectBlendModeFor(1), 0x40, 128, 0xFF);
    expect(got, closeTo(0x40 + 128, 1)); // Cs premultiplied = 128/255
  });
}
