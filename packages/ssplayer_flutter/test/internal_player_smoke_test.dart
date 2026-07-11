// Smoke test for the Layer 1/2 FFI pipeline against the HOST-built Brain.
//
// Requires:
//   * scripts/build-runtime.sh   (produces native/libs/<host>/libssruntime.*)
//   * scripts/prepare-example-assets.sh (produces example/assets/overall/*.ssab)
//   * SSRUNTIME_LIBRARY_PATH pointing at the built dylib, e.g.:
//
//   SSRUNTIME_LIBRARY_PATH=$PWD/native/libs/macos/libssruntime.dylib \
//     flutter test test/internal_player_smoke_test.dart
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
  // Resolve the host dylib + a sample .ssab relative to the package.
  final libPath = Platform.environment['SSRUNTIME_LIBRARY_PATH'];
  final ssabPath = _firstExisting([
    'example/assets/overall/Basic.ssab',
    '../../example/assets/overall/Basic.ssab',
  ]);

  test('load → update → frame data → SoA returns geometry', () {
    if (libPath == null || !File(libPath).existsSync()) {
      markTestSkipped('SSRUNTIME_LIBRARY_PATH not set / missing — run build-runtime.sh');
      return;
    }
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing — run prepare-example-assets.sh');
      return;
    }

    final runtime = SsRuntime.open(libraryPath: libPath);
    final bytes = File(ssabPath).readAsBytesSync();
    // Sanity: the FlatBuffers file identifier lives at bytes 4..8.
    expect(String.fromCharCodes(bytes.sublist(4, 8)), 'SSAB');

    // Read the actual animation name from the .ssab (robust to naming).
    final anime = ssab.SsAnimeBinary(Uint8List.fromList(bytes));
    final animName = anime.animations!.first.name!;

    final player = SpriteStudioInternalPlayer.load(
      Uint8List.fromList(bytes),
      runtime: runtime,
    );
    addTearDown(player.dispose);

    expect(player.setupAnimation(animName), isTrue,
        reason: 'setupAnimation("$animName") should succeed');
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
