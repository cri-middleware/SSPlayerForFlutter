// Host-side reconvert runner for DEVICE (iOS/Android) dev live-reload.
//
//   dart run ssgen_flutter:ssreconvert            # reconvert stale once, print
//   dart run ssgen_flutter:ssreconvert --watch    # ...then reconvert on every save
//
// A device can't run the host libssconverter, so run this on the host after
// editing in SpriteStudio. `--watch` keeps `assets/spritestudio/**` fresh on
// each save WITHOUT owning `flutter run` — the IDE-friendly complement to
// `ssdev`: run the app from your IDE's Run/Debug (with
// `--dart-define=SS_LIVE_RELOAD=true`), keep this watching, and press the IDE's
// hot reload after an edit (the flutter tool DevFS-syncs the fresh `.ssab`).
// `ssdev` instead OWNS `flutter run` to trigger the reload for you too —
// zero-key, but no IDE debugger. Both reuse the same `SsProjectSync`.
//
// It reconverts only the STALE projects under the current dir's
// `SpriteStudio_Source/` (or a `spritestudio.yaml` override). Run from the app
// dir so `SpriteStudio_Source` resolves. On desktop the SsLiveReload mixin
// reconverts in-process on hot reload, so this runner is for device targets.
import 'dart:async';
import 'dart:io';

import 'package:ssgen_dart/ssgen_dart.dart';
import 'package:ssgen_flutter/ssdev.dart' show ChangeRunner;
import 'package:watcher/watcher.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run ssgen_flutter:ssreconvert [--watch]\n'
      '  (no args)  reconvert stale SpriteStudio_Source projects once\n'
      '  --watch    ...then watch and reconvert on save (IDE-friendly; pair with\n'
      '             `flutter run --dart-define=SS_LIVE_RELOAD=true` + IDE hot reload)',
    );
    return;
  }
  final watch = args.contains('--watch') || args.contains('-w');
  final projectRoot = Directory.current.path;
  const sync = SsProjectSync();

  await _reconvertOnce(sync, projectRoot);
  if (!watch) return;

  final sourceDir = SsProjectSyncConfig.resolve(projectRoot).sourceDir;
  if (!Directory(sourceDir).existsSync()) {
    stderr.writeln('ssreconvert: source dir not found: $sourceDir (nothing to watch).');
    exitCode = 2;
    return;
  }

  final runner = ChangeRunner(
    debounce: const Duration(milliseconds: 250),
    onChange: () => _reconvertOnce(sync, projectRoot),
  );
  final sub = DirectoryWatcher(sourceDir).events.listen((_) => runner.bump());
  stdout.writeln(
    'ssreconvert: watching $sourceDir — edit & save, then hot-reload in your '
    'IDE. Ctrl-C to stop.',
  );

  // Stay alive until Ctrl-C; watching SIGINT lets us stop the watcher cleanly.
  final done = Completer<void>();
  late StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) async {
    runner.dispose();
    await sub.cancel();
    await sigint.cancel();
    stdout.writeln('\nssreconvert: stopped.');
    if (!done.isCompleted) done.complete();
  });
  await done.future;
}

Future<void> _reconvertOnce(SsProjectSync sync, String projectRoot) async {
  try {
    final report = await sync.reconvert(projectRoot: projectRoot);
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
  }
}
