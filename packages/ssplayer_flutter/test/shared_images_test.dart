// Registries loading the same encoded bytes share one decoded image, and each
// still owns what it does with it: its runtime replacements, and when it lets
// go.
//
// Free of `dart:io` so it runs under CanvasKit too, where a shader's dispose
// takes its image with it:
// `flutter test --platform chrome test/shared_images_test.dart`.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
import 'package:ssplayer_flutter/src/texture_registry.dart' show SharedImages;

const _hash = 0x22222222;

Future<ui.Image> _image(ui.Color color) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 4, 4), ui.Paint()..color = color);
  return recorder.endRecording().toImage(4, 4);
}

Future<Uint8List> _png(ui.Color color) async {
  final image = await _image(color);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registries loading the same bytes share one decode', () async {
    final shared = SharedImages.debugCount;
    final png = await _png(const ui.Color(0xFF112233));
    var decodes = 0;
    Future<ui.Image> decode(Uint8List bytes) {
      decodes++;
      return SsTextureLoader.decodeImage(bytes);
    }

    final a = TextureRegistry();
    final b = TextureRegistry();
    // At once, as players loading together do, and from two buffers, as two
    // asset loads hand over.
    await Future.wait([
      SharedImages.register(a, _hash, png, decode),
      SharedImages.register(b, _hash, Uint8List.fromList(png), decode),
    ]);
    expect(decodes, 1);
    final image = a.imageFor(_hash)!;
    expect(b.imageFor(_hash), same(image));
    expect(SharedImages.debugCount, shared + 1);

    a.shaderFor(_hash);
    a.dispose();
    expect(image.debugDisposed, isFalse);
    expect(b.shaderFor(_hash), isNotNull);

    b.dispose();
    expect(image.debugDisposed, isTrue);
    expect(SharedImages.debugCount, shared);
  });

  test('a replacement stays in the registry it was set on', () async {
    final png = await _png(const ui.Color(0xFF445566));
    final a = TextureRegistry();
    final b = TextureRegistry();
    await SharedImages.register(a, _hash, png, SsTextureLoader.decodeImage);
    await SharedImages.register(b, _hash, png, SsTextureLoader.decodeImage);
    final image = a.imageFor(_hash)!;
    final replacement = await _image(const ui.Color(0xFFAABBCC));

    a.setOverride(_hash, replacement);
    expect(a.imageFor(_hash), same(replacement));
    expect(b.imageFor(_hash), same(image));

    a.dispose();
    b.dispose();
    expect(replacement.debugDisposed, isFalse); // the caller's
    replacement.dispose();
  });

  test('registering over a shared image lets go of it', () async {
    final png = await _png(const ui.Color(0xFF778899));
    final a = TextureRegistry();
    final b = TextureRegistry();
    await SharedImages.register(a, _hash, png, SsTextureLoader.decodeImage);
    await SharedImages.register(b, _hash, png, SsTextureLoader.decodeImage);
    final image = a.imageFor(_hash)!;
    final own = await _image(const ui.Color(0xFF000000));

    a.register(_hash, own);
    expect(image.debugDisposed, isFalse); // b still draws it
    b.register(_hash, await _image(const ui.Color(0xFFFFFFFF)));
    expect(image.debugDisposed, isTrue);

    a.dispose();
    b.dispose();
    expect(own.debugDisposed, isTrue); // a's own
  });

  test('different bytes decode apart', () async {
    final a = TextureRegistry();
    final b = TextureRegistry();
    await SharedImages.register(a, _hash,
        await _png(const ui.Color(0xFF101010)), SsTextureLoader.decodeImage);
    await SharedImages.register(b, _hash,
        await _png(const ui.Color(0xFF202020)), SsTextureLoader.decodeImage);
    expect(b.imageFor(_hash), isNot(same(a.imageFor(_hash))));
    a.dispose();
    b.dispose();
  });

  test('a failed decode reaches every registry and leaves nothing behind',
      () async {
    final shared = SharedImages.debugCount;
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    Future<ui.Image> fail(Uint8List _) async => throw StateError('decode');
    final a = TextureRegistry();
    final b = TextureRegistry();
    final first = SharedImages.register(a, _hash, bytes, fail);
    final second = SharedImages.register(b, _hash, bytes, fail);
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);
    expect(a.contains(_hash), isFalse);
    expect(b.contains(_hash), isFalse);
    expect(SharedImages.debugCount, shared);
  });

  test('a registry disposed during its decode lets go of the image', () async {
    final shared = SharedImages.debugCount;
    final png = await _png(const ui.Color(0xFF334455));
    ui.Image? decoded;
    Future<ui.Image> decode(Uint8List bytes) async =>
        decoded = await SsTextureLoader.decodeImage(bytes);
    final a = TextureRegistry();
    final pending = SharedImages.register(a, _hash, png, decode);
    a.dispose();
    await pending;
    expect(a.contains(_hash), isFalse);
    expect(decoded!.debugDisposed, isTrue);
    expect(SharedImages.debugCount, shared);
  });
}
