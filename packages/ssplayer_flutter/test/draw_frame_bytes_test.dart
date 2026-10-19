// A DrawFrame built from the frame's bytes reads what the generated accessors
// read: the draw order, and for every part index its state and alpha.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

import 'support/framedata_builders.g.dart' as fbs;

void main() {
  final soa = Float32List(0);

  DrawFrame? build(Uint8List bytes, {required bool fromBytes}) =>
      DrawFrame.build(
        frameData: fbs.FrameData(bytes),
        frameBytes: fromBytes ? bytes : null,
        world: soa,
        local: soa,
        uv: soa,
        alphaScale: 0.5,
      );

  test('reads the part states and the draw order the accessors read', () {
    // Out of index order, a gap at 2, index 1 twice (the later one holds), a
    // negative index, and an alpha past 1.
    final bytes = fbs.FrameDataObjectBuilder(
      parts: <fbs.PartStateObjectBuilder>[
        _part(3, 0.25),
        _part(1, 0.5),
        _part(0, 1.5),
        _part(1, 0.75),
        _part(-1, 0.1),
      ],
      drawOrder: const <int>[3, 0, 1, 2],
    ).toBytes();
    final raw = build(bytes, fromBytes: true)!;
    final plain = build(bytes, fromBytes: false)!;

    expect(raw.drawOrder, isA<Uint16List>(),
        reason: 'the frame should have been built from its bytes');
    expect(raw.drawOrder, plain.drawOrder);
    expect(raw.partCount, plain.partCount);
    for (var i = -1; i <= plain.partCount; i++) {
      expect(raw.alphaOf(i), plain.alphaOf(i), reason: 'alpha of $i');
      expect(raw.partOf(i)?.partIndex, plain.partOf(i)?.partIndex,
          reason: 'part $i');
      expect(raw.partOf(i)?.alpha, plain.partOf(i)?.alpha, reason: 'part $i');
    }
    expect(<double?>[for (final p in raw.partByIndex) p?.alpha],
        <double?>[for (var i = 0; i < plain.partCount; i++) plain.partOf(i)?.alpha]);
  });

  test('a frame without parts or a draw order builds nothing, as from the '
      'accessors', () {
    final noOrder = fbs.FrameDataObjectBuilder(
      parts: <fbs.PartStateObjectBuilder>[_part(0, 1)],
    ).toBytes();
    final noParts =
        fbs.FrameDataObjectBuilder(drawOrder: const <int>[0]).toBytes();
    expect(build(noOrder, fromBytes: true), isNull);
    expect(build(noParts, fromBytes: true), isNull);
  });
}

fbs.PartStateObjectBuilder _part(int index, double alpha) =>
    fbs.PartStateObjectBuilder(
      updateFlag: fbs.UpdateAttributeFlags.AttributeAlpha,
      positionX: 0,
      positionY: 0,
      positionZ: 0,
      rotationX: 0,
      rotationY: 0,
      rotationZ: 0,
      scaleX: 1,
      scaleY: 1,
      localScaleX: 1,
      localScaleY: 1,
      alpha: alpha,
      localAlpha: 1,
      priority: 0,
      pivotX: 0,
      pivotY: 0,
      anchorX: 0,
      anchorY: 0,
      sizeX: 0,
      sizeY: 0,
      uvTranslationX: 0,
      uvTranslationY: 0,
      uvRotationZ: 0,
      uvScaleX: 1,
      uvScaleY: 1,
      boundingRadius: 0,
      mask: 0,
      skewX: 0,
      skewY: 0,
      texture: 0,
      partIndex: index,
      cell: -1,
      partColor: -1,
      shader: -1,
      vertex: -1,
      deform: -1,
      flipH: false,
      flipV: false,
      $hide: false,
      imgFlipH: false,
      imgFlipV: false,
    );
