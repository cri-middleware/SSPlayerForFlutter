import 'dart:io';

import 'package:test/test.dart';
import 'package:ssconverter_dart/ssconverter_dart.dart';

/// Smoke test for the host converter (native assets @Native bindings).
///
/// `dart test` runs `hook/build.dart`, which bundles the prebuilt
/// `libssconverter` (from `native/libs/`, produced by scripts/build-runtime.sh)
/// as a code asset; the `@Native` bindings resolve it.
void main() {
  const conv = SsConverter();

  // The SDK sample project, relative to the package dir (test cwd).
  final sspj = File('../../SpriteStudio-SDK/tests/overall/overall.sspj');

  test('converts overall.sspj → .ssab (normal + embedded)', () async {
    if (!sspj.existsSync()) {
      markTestSkipped('overall.sspj not found at ${sspj.path}');
      return;
    }

    final tmp = await Directory.systemTemp.createTemp('ssconvert_test_');
    try {
      final outNormal = '${tmp.path}/normal';
      final outEmbedded = '${tmp.path}/embedded';

      final retNormal = await conv.convert(sspj.path, outputDir: outNormal);
      final retEmbedded =
          await conv.convert(sspj.path, outputDir: outEmbedded, embedded: true);
      expect(retNormal, outNormal);
      expect(retEmbedded, outEmbedded);

      final basic = File('$outNormal/Basic.ssab');
      final basicEmbedded = File('$outEmbedded/Basic.ssab');
      expect(basic.existsSync(), isTrue, reason: 'normal Basic.ssab written');
      expect(basicEmbedded.existsSync(), isTrue,
          reason: 'embedded Basic.ssab written');
      expect(basic.lengthSync(), greaterThan(0));
      // Embedded inlines the textures, so it is strictly larger than the
      // reference (non-embedded) form — proves the `embedded` flag reaches the
      // Brain through the full FFI stack.
      expect(basicEmbedded.lengthSync(), greaterThan(basic.lengthSync()),
          reason: 'embedded .ssab inlines textures');
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('throws SsConverterException for a missing .sspj', () async {
    await expectLater(
      conv.convert('/no/such/project.sspj',
          outputDir: '${Directory.systemTemp.path}/ssconvert_missing'),
      throwsA(isA<SsConverterException>()),
    );
  });
}
