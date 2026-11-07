// Smoke test for the Layer 1/2 FFI pipeline against the HOST-built Brain.
//
// Requires:
//   * scripts/build-runtime.sh   (produces native/libs/<host>/libssruntime.*, which
//     native assets bundles)
//   * scripts/deploy-examples.sh (produces examples/overall/assets/spritestudio/overall/*.ssab)
//
//   flutter test test/internal_player_smoke_test.dart
//
// It drives load → setup → update → getFrameData → SoA and asserts the Brain
// returns non-empty geometry, without any on-screen rendering.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/ssab/ssab.g.dart' as ssab;

void main() {
  // Resolve a sample .ssab relative to the package (the native library is
  // bundled by ssruntime_dart's native-assets hook — no path needed).
  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Basic.ssab',
    '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
  ]);

  test('load → update → frame data → SoA returns geometry', () {
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = File(ssabPath).readAsBytesSync();
    // Sanity: the FlatBuffers file identifier lives at bytes 4..8.
    expect(String.fromCharCodes(bytes.sublist(4, 8)), 'SSAB');

    // Read the actual animation name from the .ssab (robust to naming).
    final anime = ssab.SsAnimeBinary(Uint8List.fromList(bytes));
    final animName = anime.animations!.first.name!;

    final player = SpriteStudioInternalPlayer.load(
      Uint8List.fromList(bytes),
    );
    addTearDown(player.dispose);

    expect(player.setupAnimation(animName), isTrue,
        reason: 'setAnimation("$animName") should succeed');
    player.play();

    // Advance ~one frame at 60fps and pull the results.
    final frame = player.update(const Duration(milliseconds: 16));
    expect(frame, greaterThanOrEqualTo(0));

    final fd = player.getFrameData(player.frameNo);
    expect(fd, isNotNull);
    expect(fd!.parts, isNotNull);
    expect(fd.drawBatches, isNotNull);
    expect(fd.drawOrder, isNotNull);

    final world = player.worldMatrices();
    final local = player.localVertices();
    final uvs = player.localUvs();
    expect(world.length, isNonZero);
    // SoA strides: world = parts×16, local = parts×10, uv = parts×10.
    expect(world.length % 16, 0);
    expect(local.length % 10, 0);
    expect(uvs.length % 10, 0);
    expect(local.length ~/ 10, world.length ~/ 16);
    expect(uvs.length ~/ 10, world.length ~/ 16);
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
