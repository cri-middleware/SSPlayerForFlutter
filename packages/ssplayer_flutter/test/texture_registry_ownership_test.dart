// A shader the registry builds must never take an image down with it.
//
// Native and Skwasm shaders only borrow the image they sample, but CanvasKit's
// `ImageShader.dispose` disposes it — so a shader built straight from a
// registry image frees the loaded original (the registry's own `dispose` then
// disposes it a second time and asserts, which kills a web live-reload) or the
// caller's override image, the moment the shader is retired.
//
// Only CanvasKit can fail this, so the file stays free of `dart:io` to run
// there too: `flutter test --platform chrome test/texture_registry_ownership_test.dart`.
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

const _hash = 0x11111111;

Future<ui.Image> _image(ui.Color color) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 4, 4), ui.Paint()..color = color);
  return recorder.endRecording().toImage(4, 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('releasing shaders leaves the images they sampled live', () async {
    final registry = TextureRegistry();
    final original = await _image(const ui.Color(0xFF112233));
    final replacement = await _image(const ui.Color(0xFFAABBCC));
    registry.register(_hash, original);

    registry.shaderFor(_hash); // over the original
    registry.setOverride(_hash, replacement);
    registry.shaderFor(_hash); // over the override
    registry.clearOverride(_hash);
    registry.flushRetired(); // releases both
    expect(original.debugDisposed, isFalse);
    expect(replacement.debugDisposed, isFalse);

    registry.shaderFor(_hash);
    registry.dispose(); // the live shader, then the original — once each
    expect(original.debugDisposed, isTrue);
    expect(replacement.debugDisposed, isFalse);
    replacement.dispose();
  });
}
