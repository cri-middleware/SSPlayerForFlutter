// Framebuffer blend mapping tests — the `BlendType → ui.BlendMode` table
// ported from ssplayer-webgl (`SSWebGLRenderer.applyBlend`). Pure and fast; no
// Brain needed. The actual blended pixels can only be checked in the example
// (overall/BlendMode), but this locks the reference mapping so it can't drift.
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

void main() {
  group('blendModeFor', () {
    test('exact stock equivalents (premultiplied, opaque dst)', () {
      // Mix + Add + Mul are the pixel-exact rows the sibling ports agree on.
      expect(blendModeFor(fbs.BlendType.Mix), ui.BlendMode.srcOver);
      expect(blendModeFor(fbs.BlendType.Add), ui.BlendMode.plus);
      expect(blendModeFor(fbs.BlendType.Mul), ui.BlendMode.multiply);
      // Screen / Exclusion are also exact against Skia's premult definitions.
      expect(blendModeFor(fbs.BlendType.Screen), ui.BlendMode.screen);
      expect(blendModeFor(fbs.BlendType.Exclusion), ui.BlendMode.exclusion);
    });

    test('alias modes fold onto their base GL state', () {
      // ssplayer-webgl maps Mulalpha/Mul2 onto the Mul GL state and Screen2 onto
      // the Screen state.
      expect(blendModeFor(fbs.BlendType.Mulalpha), ui.BlendMode.multiply);
      expect(blendModeFor(fbs.BlendType.Mul2), ui.BlendMode.multiply);
      expect(blendModeFor(fbs.BlendType.Screen2), ui.BlendMode.screen);
    });

    test('Sub / Invert have no stock equivalent → difference approximation', () {
      // Reverse-subtract (Sub) and dst-replace `Cs·(1-Cb)` (Invert) are not
      // expressible in Flutter's fixed blend enum; both take the closest honest
      // approximation.
      expect(blendModeFor(fbs.BlendType.Sub), ui.BlendMode.difference);
      expect(blendModeFor(fbs.BlendType.Invert), ui.BlendMode.difference);
      expect(blendModeFor(fbs.BlendType.Sub), isNot(ui.BlendMode.darken));
    });

    test('modes with no upstream GL mapping fall back to Mix', () {
      // ssplayer-webgl's `default` clamps Div2 / Overlay2 to the Mix state.
      expect(blendModeFor(fbs.BlendType.Div2), ui.BlendMode.srcOver);
      expect(blendModeFor(fbs.BlendType.Overlay2), ui.BlendMode.srcOver);
    });

    test('every BlendType resolves (no enum falls through to a throw)', () {
      for (final t in fbs.BlendType.values) {
        expect(blendModeFor(t), isA<ui.BlendMode>());
      }
    });
  });
}
