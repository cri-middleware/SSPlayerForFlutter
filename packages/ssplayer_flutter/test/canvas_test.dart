// The `.ssab`'s `canvas` field is not a rectangle.
//
// Its schema type says `Rect`, but the converter packs two unrelated things into
// it: `x1`/`y1` are the animation's `<pivot>` and `x2`/`y2` are its
// `<canvasSize>` (`ssconverter`, `model_t/animedata.rs`). Reading it as a rect
// and taking `x2 - x1` subtracts the pivot from the size — right only while the
// pivot is `0`, which is what most authored animations happen to have, and what
// every `overall` fixture has. The family's `ParticleEffect` packs carry
// `-0.5, 0` and `0, -0.5`, so the error is reachable with shipped data.
//
// Built here rather than read from a fixture: a synthetic pack pins the
// arithmetic with a pivot chosen to make a wrong reading obvious.
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

import 'support/ssab_builders.g.dart' as ssab;

Uint8List packWithCanvas({
  required double pivotX,
  required double pivotY,
  required double width,
  required double height,
}) =>
    ssab.SsAnimeBinaryObjectBuilder(
      name: 'pack',
      animations: [
        ssab.AnimationDataObjectBuilder(
          name: 'anime_1',
          // x1/y1 = pivot, x2/y2 = size. Not a min/max pair.
          canvas: ssab.RectObjectBuilder(
            x1: pivotX,
            y1: pivotY,
            x2: width,
            y2: height,
          ),
          partsInitialAttributes: [],
          partsAnimationData: [],
        ),
      ],
      parts: [],
    ).toBytes();

void main() {
  test('canvasSize is the authored size, whatever the pivot is', () {
    // A centred pivot: the old `x2 - x1` reading happened to be right here,
    // which is why this went unnoticed.
    final centred = SsAnimeInfo(
        packWithCanvas(pivotX: 0, pivotY: 0, width: 320, height: 240));
    expect(centred.canvasSize('anime_1'), const Size(320, 240));

    // A moved pivot: `x2 - x1` would report 320.5 x 240, and a caller sizing a
    // box from it would be wrong by the pivot rather than by the canvas.
    final moved = SsAnimeInfo(
        packWithCanvas(pivotX: -0.5, pivotY: 0, width: 320, height: 240));
    expect(moved.canvasSize('anime_1'), const Size(320, 240));

    final movedY = SsAnimeInfo(
        packWithCanvas(pivotX: 0, pivotY: -0.5, width: 320, height: 240));
    expect(movedY.canvasSize('anime_1'), const Size(320, 240));
  });

  test('null for an animation the pack does not have', () {
    final info =
        SsAnimeInfo(packWithCanvas(pivotX: 0, pivotY: 0, width: 1, height: 1));
    expect(info.canvasSize('nope'), isNull);
  });
}
