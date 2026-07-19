// Host-side one-shot reconvert for SpriteStudio dev live-reload.
//
//   dart run ssgen_flutter:ssreconvert     # reconvert stale SpriteStudio_Source
//
// Reconverts only the STALE projects under the current dir's
// `SpriteStudio_Source/` (or a `spritestudio.yaml` override) into
// `assets/spritestudio/**`. Run from the app dir so `SpriteStudio_Source`
// resolves.
//
// This is a plain "convert now" helper (CI, manual refresh). For a live session
// that also pushes the fresh pack to a running app, use `sswatch` — it watches
// and pushes over the VM Service (attach an IDE/`flutter run`, or `--run` to
// launch one). The old `--watch` mode is gone: `sswatch` supersedes it.
import 'dart:io';

import 'package:ssgen_dart/ssgen_dart.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run ssgen_flutter:ssreconvert\n'
      '  Reconvert the stale SpriteStudio_Source projects once (into\n'
      '  assets/spritestudio/**). For a live session that also hot-swaps a\n'
      '  running app, use `dart run ssgen_flutter:sswatch` instead.',
    );
    return;
  }
  final projectRoot = Directory.current.path;
  try {
    final report = await const SsProjectSync().reconvert(projectRoot: projectRoot);
    if (report.converted.isEmpty) {
      stdout.writeln(
        'ssreconvert: up to date (${report.upToDate.length} project(s)).',
      );
    } else {
      report.converted.forEach(
        (sspj, out) => stdout.writeln('ssreconvert: $sspj -> $out'),
      );
    }
  } catch (e) {
    stderr.writeln('ssreconvert: reconvert failed: $e');
    exitCode = 1;
  }
}
