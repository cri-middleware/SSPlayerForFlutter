import 'dart:io';

import 'package:test/test.dart';
import 'package:ssgen_dart/ssgen_dart.dart';

/// Exercises SsProjectSync — the "reconvert only the stale projects in a dir"
/// library behind a consumer-owned reconvert trigger (`ssgen_flutter`'s
/// `sswatch` runner calls it on a source save). The native libssconverter is
/// bundled by ssconverter_dart's hook/build.dart (native assets).
void main() {
  final overallDir = Directory('../../SpriteStudio-SDK/tests/overall');
  final overallSspj = File('${overallDir.path}/overall.sspj');

  group('SsProjectSync.reconvert (stale-only)', () {
    test('converts cold, skips when fresh, reconverts after a source touch',
        () async {
      if (!overallSspj.existsSync()) {
        markTestSkipped('overall.sspj not found at ${overallSspj.path}');
        return;
      }
      final tmp = await Directory.systemTemp.createTemp('ssgen_test_');
      addTearDown(() => tmp.delete(recursive: true));
      // Copy the project into temp so mtime edits stay hermetic (never mutate
      // the shared SDK fixture — that races other tests / reruns).
      final srcRoot = Directory('${tmp.path}/src');
      _copyDir(overallDir, srcRoot);
      final sspj = '${srcRoot.path}/overall.sspj';
      final out = '${tmp.path}/assets';

      // 1) cold: no output yet → converts into <out>/overall/.
      final first = await const SsProjectSync()
          .reconvert(sourceDir: srcRoot.path, outputDir: out);
      expect(first.converted.keys, contains(sspj));
      final basic = File('$out/overall/Basic.ssab');
      expect(basic.existsSync(), isTrue, reason: 'Basic.ssab emitted');

      // 2) warm: outputs newer than every source → skips.
      final second = await const SsProjectSync()
          .reconvert(sourceDir: srcRoot.path, outputDir: out);
      expect(second.converted, isEmpty, reason: 'nothing stale');
      expect(second.upToDate, contains(sspj));

      // 3) a source edit newer than the output → reconverts (mirrors saving
      //    the project in SpriteStudio while the watcher runs).
      final outMtime = basic.statSync().modified;
      File(sspj).setLastModifiedSync(outMtime.add(const Duration(seconds: 10)));
      final third = await const SsProjectSync()
          .reconvert(sourceDir: srcRoot.path, outputDir: out);
      expect(third.converted.keys, contains(sspj));
    });
  });

  group('SsProjectSyncConfig.resolve', () {
    test('defaults to SpriteStudio_Source → assets/spritestudio', () {
      final root = Directory.systemTemp.createTempSync('ssgen_cfg_');
      addTearDown(() => root.deleteSync(recursive: true));

      final cfg = SsProjectSyncConfig.resolve(root.path);
      expect(cfg.sourceDir, '${root.path}/SpriteStudio_Source');
      expect(cfg.outputDir, '${root.path}/assets/spritestudio');
      expect(cfg.embedded, isFalse);
    });

    test('spritestudio.yaml at the root overrides source/output/embedded', () {
      final root = Directory.systemTemp.createTempSync('ssgen_cfg_');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/spritestudio.yaml').writeAsStringSync(
        'source: art/ss\noutput: assets/anim\nembedded: true\n',
      );

      final cfg = SsProjectSyncConfig.resolve(root.path);
      expect(cfg.sourceDir, '${root.path}/art/ss');
      expect(cfg.outputDir, '${root.path}/assets/anim');
      expect(cfg.embedded, isTrue);
    });
  });
}

/// Recursively copies [from] into [to] (files only; parents created as needed).
void _copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  final prefix = from.path.length + 1;
  for (final e in from.listSync(recursive: true)) {
    if (e is! File) continue;
    final dest = File('${to.path}/${e.path.substring(prefix)}');
    dest.parent.createSync(recursive: true);
    e.copySync(dest.path);
  }
}
