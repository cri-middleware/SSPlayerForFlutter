import 'dart:io';

import 'package:test/test.dart';
import 'package:ssconverter_dart/ssconverter_dart.dart';

/// Smoke test for the host converter (libssconverter over dart:ffi).
///
/// libssconverter is resolved from the package's native/libs (built by
/// scripts/build-runtime.sh) via [SsConverter.openForHost] — no env var needed —
/// or from `SSCONVERTER_LIBRARY_PATH`. When neither is available the tests skip.
void main() {
  SsConverter? converter;

  setUpAll(() async {
    try {
      final c = await SsConverter.openForHost();
      c.version; // force a symbol lookup so a bad library fails here
      converter = c;
    } catch (_) {
      converter = null; // leave null → tests skip
    }
  });

  // The SDK sample project, relative to the package dir (test cwd).
  final sspj = File('../../SpriteStudio-SDK/tests/overall/overall.sspj');

  test('converts overall.sspj → .ssab (normal + embedded)', () async {
    final conv = converter;
    if (conv == null) {
      markTestSkipped('libssconverter not available (run build-runtime.sh)');
      return;
    }
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
    final conv = converter;
    if (conv == null) {
      markTestSkipped('libssconverter not available');
      return;
    }
    await expectLater(
      conv.convert('/no/such/project.sspj',
          outputDir: '${Directory.systemTemp.path}/ssconvert_missing'),
      throwsA(isA<SsConverterException>()),
    );
  });
}
