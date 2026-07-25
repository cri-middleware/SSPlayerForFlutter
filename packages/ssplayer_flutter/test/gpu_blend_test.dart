// flutter_gpu framebuffer blend table (§7B): does `blendEquationFor` reproduce
// ssplayer-webgl's `applyBlend` fixed-function state row for row?
//
// A `ColorBlendEquation` is a plain value object, so the whole table is checkable
// headlessly (no Impeller context) — which is the only automated check this
// backend's blending gets: the on-device parity harness pixel-compares against
// the Canvas path, and Canvas is deliberately *wrong* for Sub / Invert, so it
// cannot be the reference for those. Here the reference is the GL table itself:
//
//   | SS BlendType    | srcRGB          | dstRGB          | rgbEq            |
//   | Mix             | ONE             | 1-SRC_ALPHA     | ADD              |
//   | Mul/Mulalpha/2  | DST_COLOR       | 1-SRC_ALPHA     | ADD              |
//   | Add             | ONE             | ONE             | ADD              |
//   | Sub             | ONE             | ONE             | REVERSE_SUBTRACT |
//   | Screen/2        | 1-DST_COLOR     | ONE             | ADD              |
//   | Exclusion       | 1-DST_COLOR     | 1-SRC_COLOR     | ADD              |
//   | Invert          | 1-DST_COLOR     | ZERO            | ADD              |
//
// …with `blendFuncSeparate(…, ONE, ONE_MINUS_SRC_ALPHA)` and an ADD alpha
// equation for *every* row: only RGB varies.
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/render/backend/flutter_gpu_backend.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

typedef _Row = (gpu.BlendFactor, gpu.BlendFactor, gpu.BlendOperation);

_Row _rgbOf(gpu.ColorBlendEquation e) => (
      e.sourceColorBlendFactor,
      e.destinationColorBlendFactor,
      e.colorBlendOperation,
    );

void main() {
  const one = gpu.BlendFactor.one;
  const zero = gpu.BlendFactor.zero;
  const oneMinusSrcAlpha = gpu.BlendFactor.oneMinusSourceAlpha;
  const oneMinusSrcColor = gpu.BlendFactor.oneMinusSourceColor;
  const dstColor = gpu.BlendFactor.destinationColor;
  const oneMinusDstColor = gpu.BlendFactor.oneMinusDestinationColor;
  const add = gpu.BlendOperation.add;
  const reverseSubtract = gpu.BlendOperation.reverseSubtract;

  const reference = <fbs.BlendType, _Row>{
    fbs.BlendType.Mix: (one, oneMinusSrcAlpha, add),
    fbs.BlendType.Add: (one, one, add),
    fbs.BlendType.Sub: (one, one, reverseSubtract),
    fbs.BlendType.Mul: (dstColor, oneMinusSrcAlpha, add),
    fbs.BlendType.Mulalpha: (dstColor, oneMinusSrcAlpha, add),
    fbs.BlendType.Mul2: (dstColor, oneMinusSrcAlpha, add),
    fbs.BlendType.Screen: (oneMinusDstColor, one, add),
    fbs.BlendType.Screen2: (oneMinusDstColor, one, add),
    fbs.BlendType.Exclusion: (oneMinusDstColor, oneMinusSrcColor, add),
    fbs.BlendType.Invert: (oneMinusDstColor, zero, add),
    // No GL mapping upstream either — ssplayer-webgl's `default` clamps to Mix.
    fbs.BlendType.Div2: (one, oneMinusSrcAlpha, add),
    fbs.BlendType.Overlay2: (one, oneMinusSrcAlpha, add),
  };

  test('every BlendType maps to its reference GL RGB state', () {
    for (final entry in reference.entries) {
      expect(_rgbOf(FlutterGpuBackend.blendEquationFor(entry.key)), entry.value,
          reason: '${entry.key.name} RGB state');
    }
  });

  test('the reference table covers every BlendType', () {
    // A new SS blend mode must be added to the table, not silently defaulted.
    expect(reference.keys, containsAll(fbs.BlendType.values));
  });

  test('alpha stays premultiplied source-over for every mode', () {
    // The bug this pins: a reverse-subtract (Sub) or `×dstAlpha` (Mul) on the
    // ALPHA channel makes the part erase what is under it — a transparent hole
    // punched through the offscreen — instead of darkening it.
    for (final type in fbs.BlendType.values) {
      final e = FlutterGpuBackend.blendEquationFor(type);
      expect(e.alphaBlendOperation, gpu.BlendOperation.add,
          reason: '${type.name} alpha op');
      expect(e.sourceAlphaBlendFactor, one, reason: '${type.name} src alpha');
      expect(e.destinationAlphaBlendFactor, oneMinusSrcAlpha,
          reason: '${type.name} dst alpha');
    }
  });

  test('no mode silently falls back to Mix except Div2 / Overlay2', () {
    // Mix's own state, i.e. "unimplemented" in the old table. Any *other* mode
    // resolving to it means a row was dropped.
    final mix = _rgbOf(FlutterGpuBackend.blendEquationFor(fbs.BlendType.Mix));
    final fellBack = fbs.BlendType.values
        .where((t) => _rgbOf(FlutterGpuBackend.blendEquationFor(t)) == mix)
        .toSet();
    expect(
        fellBack,
        <fbs.BlendType>{
          fbs.BlendType.Mix,
          fbs.BlendType.Div2,
          fbs.BlendType.Overlay2,
        },
        reason: 'Exclusion / Invert are fixed-function expressible; '
            'they must not fall back to source-over');
  });
}
