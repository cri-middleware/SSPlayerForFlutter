// `canvasSize` is the animation's `<canvasSize>`, never mixed with its
// `<pivot>`.
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
          canvasSize: ssab.Vec2ObjectBuilder(v1: width, v2: height),
          pivot: ssab.Vec2ObjectBuilder(v1: pivotX, v2: pivotY),
          partsInitialAttributes: [],
          partsAnimationData: [],
        ),
      ],
      parts: [],
    ).toBytes();

void main() {
  test('canvasSize is the authored size, whatever the pivot is', () {
    // A centred pivot.
    final centred = SsAnimeInfo(
        packWithCanvas(pivotX: 0, pivotY: 0, width: 320, height: 240));
    expect(centred.canvasSize('anime_1'), const Size(320, 240));

    // A moved pivot: the size must not move with it.
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
