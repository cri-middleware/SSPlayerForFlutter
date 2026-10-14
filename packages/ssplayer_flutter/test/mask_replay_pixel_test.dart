// Mask replay **pixel** semantics: `shaders/partcolor.frag` rebuilds
// the SS stencil per fragment out of the coverage bitmap, and this file
// rasterises that decision instead of trusting the source to read right.
//
// The rule being pinned: `Invert` (mask_influence == 1) and `IncrementWrap`
// (mask_influence == 0) are each their own inverse in isolation but do NOT
// commute, so they may not share one accumulator. Replaying both into a single
// 8-bit `stencil` — which this port did —
// makes coverage depend on the order the writers happen to be walked
// in: `incr then invert` lands on 254 (covered) where `invert then incr` wraps
// back to 0 (not covered). Two planes and their union is the fix; a GPU stencil
// gets there by splitting `WriteMask` per OP (which is what caps ForUnity's
// counter at 7 overlapping masks under URP), a shader replay by keeping two
// ordinary variables and taking no bit budget at all.
//
// The defect came from SS6PlayerForUnity and was fixed in SSPlayerForUnity and
// SSPlayerForGodot first; the same change lands in `shaders/gpu/partcolor.frag`,
// which headless tests cannot reach (see `_gpuNote` below).
//
// Scope is resolved on the CPU here — the shader receives the writers as
// two disjoint 24-bit sets — so a test drives it exactly as the backend does:
// hand it `bits` (what the coverage bitmap holds at this fragment) plus the
// `increment` / `invert` sets, and read back whether the fragment survived.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// `shaders/gpu/partcolor.frag` carries the same replay for the flutter_gpu
/// backend and gets the same two planes, but Impeller has no context under
/// flutter_tester. It is covered on-device by the Canvas-parity gate in
/// `examples/overall/integration_test/gpu_backend_test.dart` (the `Mask` pack),
/// which is what would catch the two shaders drifting apart.
const String _gpuNote = 'covered on-device by gpu_backend_test.dart';

void main() {
  // Polarity: with `visible_inside_mask == 0` a target draws OUTSIDE the
  // mask, so a covered fragment is the one that gets discarded. That makes the
  // read-back a direct probe of "did the replay call this fragment covered".
  group('the replay unions the parity and counter planes', () {
    test('two invert writers cancel — parity, and the pair case', () async {
      expect(await _covered(bits: 0x3, invert: 0x3), isFalse);
    });

    test('three invert writers cover — parity, NOT "exactly one"', () async {
      // The case that separates the two readings, and the reason the SS6PU
      // investigation insisted on a 3-overlap: with two writers "parity" and
      // "exactly one covers" agree, so only three tell them apart. SS7.5 is
      // parity.
      expect(await _covered(bits: 0x7, invert: 0x7), isTrue);
    });

    test('one invert writer covers', () async {
      expect(await _covered(bits: 0x1, invert: 0x1), isTrue);
    });

    test('increment writers union rather than cancel', () async {
      expect(await _covered(bits: 0x1, increment: 0x1), isTrue);
      expect(await _covered(bits: 0x3, increment: 0x3), isTrue);
      expect(await _covered(bits: 0x7, increment: 0x7), isTrue);
    });

    test('an increment and an invert writer overlapping cover, either way round',
        () async {
      // THE regression. One shared accumulator made these two disagree: bit 0
      // increment then bit 1 invert gave 254 (covered), the same two writers
      // swapped gave 0 (not covered) — the same picture, decided by which part
      // happened to sit earlier in draw_order.
      expect(await _covered(bits: 0x3, increment: 0x1, invert: 0x2), isTrue);
      expect(await _covered(bits: 0x3, increment: 0x2, invert: 0x1), isTrue);
    });

    test('a counter writer still covers where the parity plane cancels',
        () async {
      // Two inverts cancel to "not covered" on their own plane; the increment
      // writer covers on its own. The union is covered — with one accumulator
      // the increment was swallowed by the inverts around it.
      expect(await _covered(bits: 0x7, increment: 0x1, invert: 0x6), isTrue);
      expect(await _covered(bits: 0x7, increment: 0x4, invert: 0x3), isTrue);
    });

    test('a writer out of this target\'s scope is skipped', () async {
      // Scope is resolved on the CPU: a writer that does not reach this target is
      // in neither set, so its coverage bit must not touch either plane.
      expect(await _covered(bits: 0x7, invert: 0x1), isTrue); // odd count of 1
      expect(await _covered(bits: 0x7, invert: 0x3), isFalse); // even count of 2
      expect(await _covered(bits: 0x7), isFalse); // no writer in scope at all
    });

    test('no coverage under the fragment is never masked', () async {
      expect(await _covered(bits: 0x0, increment: 0x1, invert: 0x2), isFalse);
    });

    test('the topmost writer bit decodes (24 bits across R,G,B)', () async {
      // kMaskTileBits == 24: bit 23 is the high bit of the blue channel, and
      // the Canvas replay tests it with float arithmetic (runtime effects forbid
      // integer bitwise ops), so it is the one most likely to fall off.
      expect(await _covered(bits: 1 << 23, increment: 1 << 23), isTrue);
      expect(await _covered(bits: 1 << 23, invert: 1 << 23), isTrue);
      expect(await _covered(bits: 1 << 16, increment: 1 << 16), isTrue);
      expect(await _covered(bits: 1 << 8, increment: 1 << 8), isTrue);
    });
  });

  // Past 24 writers the coverage splits into tiles, each the same box at a
  // lower resolution; writer bit `b` lives in tile `b ~/ 24`. Two tiles side by
  // side here: the left texel is tile 0, the right one tile 1.
  group('a second coverage tile replays like the first', () {
    test('a writer in tile 1 covers on its own', () async {
      expect(await _covered(bits: 0, tile1: (0x1, 0x1, 0)), isTrue);
      expect(await _covered(bits: 0, tile1: (0x1, 0, 0x1)), isTrue);
    });

    test('tile 1 is read from its own texel, not tile 0\'s', () async {
      // Bit 0 set in tile 0 only: a tile-1 writer holding bit 0 must not see it.
      expect(await _covered(bits: 0x1, tile1: (0, 0x1, 0)), isFalse);
    });

    test('the planes union across tiles, parity included', () async {
      // An invert writer in each tile: two overlaps, an even count — cancelled.
      expect(await _covered(bits: 0x1, invert: 0x1, tile1: (0x1, 0, 0x1)),
          isFalse);
      // Plus an increment writer in tile 1: the counter plane covers.
      expect(await _covered(bits: 0x1, invert: 0x1, tile1: (0x3, 0x2, 0x1)),
          isTrue);
    });
  });

  group('polarity is the target\'s', () {
    test('visible_inside_mask draws where the same fragments were discarded',
        () async {
      // Same replay, opposite side: everything covered above now draws, and
      // everything uncovered does not.
      expect(await _drew(bits: 0x3, increment: 0x1, invert: 0x2,
          visibleInside: true), isTrue);
      expect(await _drew(bits: 0x3, invert: 0x3, visibleInside: true), isFalse);
      expect(await _drew(bits: 0x7, invert: 0x7, visibleInside: true), isTrue);
    });

    test('outside the coverage bitmap too, so a flipped polarity is the exact '
        'complement', () async {
      // The Canvas backend's hidden-fragment gate for Invert is this shader with
      // the polarity flipped, so it must answer the opposite everywhere.
      expect(await _drew(bits: 0x1, invert: 0x1, visibleInside: false,
          maskOffset: 2), isTrue);
      expect(await _drew(bits: 0x1, invert: 0x1, visibleInside: true,
          maskOffset: 2), isFalse);
    });
  });

  test('the flutter_gpu twin is verified elsewhere', () {
    expect(_gpuNote, isNotEmpty);
  }, skip: _gpuNote);
}

/// Renders one fragment through `shaders/partcolor.frag` with masking on and
/// reports whether the replay called it **covered**.
///
/// Drives the target as `visible_inside_mask == 0` (draw outside the mask), so
/// "covered" is exactly "the fragment was discarded".
Future<bool> _covered({
  required int bits,
  int increment = 0,
  int invert = 0,
  (int, int, int)? tile1,
}) async =>
    !await _drew(
        bits: bits,
        increment: increment,
        invert: invert,
        tile1: tile1,
        visibleInside: false);

/// Whether the fragment survived the mask test — the raw read-back.
///
/// [tile1] — `(bits, increment, invert)` of a second coverage tile — splits the
/// coverage into two tiles side by side. [maskOffset] shifts the coverage UV,
/// past 1 putting the fragment outside the bitmap.
Future<bool> _drew({
  required int bits,
  int increment = 0,
  int invert = 0,
  (int, int, int)? tile1,
  double maskOffset = 0,
  required bool visibleInside,
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Package-local key: under `flutter test` the package's own assets sit at the
  // bundle root (the backend uses the `packages/…` form at runtime), as
  // part_shader_test.dart does.
  final program = await ui.FragmentProgram.fromAsset('shaders/partcolor.frag');
  final shader = program.fragmentShader();

  // An opaque white texel, so a surviving fragment is unambiguously opaque: the
  // PartColor formula collapses to a texel passthrough at rate 0.
  final tex = await _rgbaPixel(255, 255, 255, 255);
  // The coverage bitmap this fragment samples. Bits live in RGB only — alpha is
  // the premultiplied-blend accumulator, so it stays opaque (mask.dart).
  List<int> texel(int b) =>
      <int>[b & 0xFF, (b >> 8) & 0xFF, (b >> 16) & 0xFF, 255];
  final cov = await _rgbaPixels(
      <int>[...texel(bits), if (tile1 != null) ...texel(tile1.$1)],
      tile1 == null ? 1 : 2);

  // Declaration order of shaders/partcolor.frag, mirroring
  // CanvasBackend._setPartColorUniforms.
  var i = 0;
  void f(double v) => shader.setFloat(i++, v);
  f(0); // uOrigin — the quad starts at the origin…
  f(0);
  f(1 / _size); // uInv — …and spans _size, so (s,t) lands in the unit square
  f(0);
  f(0);
  f(1 / _size);
  f(1); // uTexSize — a 1x1 texture…
  f(1);
  f(0); // uCoef — …with no PartColor: rate 0 is a passthrough
  f(0);
  f(0);
  f(0);
  f(0); // uRate (lt, rt, lb, rb)
  f(0);
  f(0);
  f(0);
  for (var c = 0; c < 4; c++) {
    f(1); // uColLT..uColRB — white, alpha 1
    f(1);
    f(1);
    f(1);
  }
  for (var c = 0; c < 8; c++) {
    f(0.5); // uUvA / uUvB — the middle of the single texel
  }
  f(visibleInside ? 1.0 : 0.0); // uMaskBits
  f(1.0); // masking on
  f(tile1 == null ? 1.0 : 2.0); // the tile grid
  f(1.0);
  f(1 / _size); // uMaskUv — local -> coverage UV over the same box…
  f(0);
  f(0);
  f(1 / _size);
  f(maskOffset); // uMaskOff — …with no offset, every fragment is inside it
  f(0);
  // uMaskInc / uMaskInv — one set per tile.
  for (final v in <int>[increment, tile1?.$2 ?? 0, 0, 0]) {
    f(v.toDouble());
  }
  for (final v in <int>[invert, tile1?.$3 ?? 0, 0, 0]) {
    f(v.toDouble());
  }
  shader.setImageSampler(0, tex);
  shader.setImageSampler(1, cov);

  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
      const ui.Rect.fromLTWH(0, 0, _size, _size), ui.Paint()..shader = shader);
  final picture = rec.endRecording();
  final image = await picture.toImage(_size.toInt(), _size.toInt());
  final data = await image.toByteData();

  shader.dispose();
  picture.dispose();
  image.dispose();
  tex.dispose();
  cov.dispose();

  final px = data!.buffer.asUint8List();
  // The shader has no `discard` (runtime effects forbid it) — a masked-out
  // fragment is written fully transparent, which is a no-op under every blend
  // mode the backend emits.
  return px[3] != 0;
}

/// Side of the rendered square. Small — every fragment gets the same answer
/// here, since the coverage bitmap is a single texel.
const double _size = 4;

Future<ui.Image> _rgbaPixel(int r, int g, int b, int a) =>
    _rgbaPixels(<int>[r, g, b, a], 1);

/// A [width]×1 RGBA image from [rgba].
Future<ui.Image> _rgbaPixels(List<int> rgba, int width) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(Uint8List.fromList(rgba), width, 1,
      ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}
