// The IDE-friendly SpriteStudio live-reload watcher — the counterpart to `ssdev`
// that does NOT own `flutter run`.
//
//   dart run ssgen_flutter:sswatch --vmservice-uri-file=<path>
//
// You launch the app yourself (IDE Run/Debug, or `flutter run
// --vmservice-out-file=<path> --dart-define=SS_LIVE_RELOAD=true`); `sswatch`
// connects to that app's Dart VM Service, watches `SpriteStudio_Source/`, and on
// save reconverts the stale projects (host `libssconverter` via [SsProjectSync])
// then calls the app's `ext.ssgen.reload` service extension to hot-swap the pack
// in place — no `r`, and the IDE debugger stays attached.
//
// Why the VM Service extension (not the daemon `app.restart` that `ssdev` uses):
//   * it does not require owning `flutter run`, so it coexists with any launcher
//     including an IDE debug session, and
//   * it pushes the pack directly to the app (desktop reads the reconverted file
//     off disk), decoupled from Flutter's own hot reload / DevFS.
//
// Deliberately Flutter-free (`dart:*`, `ssgen_dart`, `vm_service`, `watcher`) so
// it runs under the plain Dart VM and the pure pieces are unit-testable.
library;

import 'dart:async';
import 'dart:io';

import 'package:ssgen_dart/ssgen_dart.dart';
import 'package:vm_service/utils.dart' show convertToWebSocketUrl;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart' show vmServiceConnectUri;
import 'package:watcher/watcher.dart';

import 'ss_defines.dart';
import 'ssdev.dart' show ChangeRunner;

/// Parsed `sswatch` invocation.
class SsWatchOptions {
  SsWatchOptions({
    this.vmServiceUri,
    this.vmServiceUriFile,
    this.projectRoot,
    this.sourceDir,
    this.debounceMs = 250,
    this.once = false,
    this.help = false,
  });

  /// A Dart VM Service URI (`http(s)://…` or `ws(s)://…`) to connect to.
  final String? vmServiceUri;

  /// A file the launcher wrote the VM Service URI to (via `flutter run`'s
  /// `--vmservice-out-file` flag). Polled until it appears.
  final String? vmServiceUriFile;

  /// Project root holding `SpriteStudio_Source/` (else the current directory).
  final String? projectRoot;

  /// Source dir override (else `spritestudio.yaml` / the convention).
  final String? sourceDir;

  /// Debounce window coalescing a burst of file events into one reconvert.
  final int debounceMs;

  /// Reconvert + push once, then exit (no watching).
  final bool once;

  /// Print usage and exit.
  final bool help;

  static const _uriFlag = '--vmservice-uri=';
  static const _uriFileFlag = '--vmservice-uri-file=';
  static const _projectRootFlag = '--project-root=';
  static const _sourceFlag = '--source=';
  static const _debounceFlag = '--debounce=';
  static const _onceFlag = '--once';

  /// Parses [argv] into options. Unknown args are ignored (kept lenient so the
  /// runner never dies on a stray flag).
  static SsWatchOptions parse(List<String> argv) {
    String? vmServiceUri;
    String? vmServiceUriFile;
    String? projectRoot;
    String? sourceDir;
    var debounceMs = 250;
    var once = false;
    var help = false;
    for (final arg in argv) {
      if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == _onceFlag) {
        once = true;
      } else if (arg.startsWith(_uriFlag)) {
        vmServiceUri = arg.substring(_uriFlag.length);
      } else if (arg.startsWith(_uriFileFlag)) {
        vmServiceUriFile = arg.substring(_uriFileFlag.length);
      } else if (arg.startsWith(_projectRootFlag)) {
        projectRoot = arg.substring(_projectRootFlag.length);
      } else if (arg.startsWith(_sourceFlag)) {
        sourceDir = arg.substring(_sourceFlag.length);
      } else if (arg.startsWith(_debounceFlag)) {
        debounceMs =
            int.tryParse(arg.substring(_debounceFlag.length)) ?? debounceMs;
      }
    }
    return SsWatchOptions(
      vmServiceUri: vmServiceUri,
      vmServiceUriFile: vmServiceUriFile,
      projectRoot: projectRoot,
      sourceDir: sourceDir,
      debounceMs: debounceMs,
      once: once,
      help: help,
    );
  }
}

/// Normalizes a Dart VM Service URI (as printed by `flutter run` or written to a
/// `--vmservice-out-file`) to the `ws(s)://…/ws` form [vmServiceConnectUri]
/// wants. A `ws`/`wss` URI is returned as-is; an `http`/`https` one is converted.
String normalizeVmServiceUri(String raw) {
  final uri = Uri.parse(raw.trim());
  if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri.toString();
  return convertToWebSocketUrl(serviceProtocolUrl: uri).toString();
}

/// Entry point behind `bin/sswatch.dart`.
Future<void> runSsWatch(List<String> argv) async {
  final opts = SsWatchOptions.parse(argv);
  if (opts.help) {
    _printUsage();
    return;
  }
  final projectRoot = opts.projectRoot ?? Directory.current.path;
  final cfg = SsProjectSyncConfig.resolve(projectRoot);
  final sourceDir = opts.sourceDir ?? cfg.sourceDir;
  const sync = SsProjectSync();

  final String wsUri;
  try {
    wsUri = await _discoverUri(opts);
  } catch (e) {
    stderr.writeln('[sswatch] $e');
    exitCode = 2;
    return;
  }

  stdout.writeln('[sswatch] connecting to $wsUri');
  final VmService service;
  try {
    service = await vmServiceConnectUri(wsUri);
  } catch (e) {
    stderr.writeln('[sswatch] could not connect to the VM Service: $e');
    exitCode = 2;
    return;
  }

  if (opts.once) {
    final report = await _safeReconvert(sync, projectRoot);
    if (report != null && report.converted.isNotEmpty) {
      _logConverted(report);
      await _pushConvertedDirs(service, report.converted.values);
    } else {
      stdout.writeln('[sswatch] nothing stale to reconvert.');
    }
    await service.dispose();
    return;
  }

  if (!Directory(sourceDir).existsSync()) {
    stderr.writeln('[sswatch] source dir not found: $sourceDir');
    await service.dispose();
    exitCode = 2;
    return;
  }

  final runner = ChangeRunner(
    debounce: Duration(milliseconds: opts.debounceMs),
    onChange: () async {
      final report = await _safeReconvert(sync, projectRoot);
      if (report == null || report.converted.isEmpty) return;
      _logConverted(report);
      await _pushConvertedDirs(service, report.converted.values);
    },
  );
  final sub = DirectoryWatcher(sourceDir).events.listen((_) => runner.bump());
  stdout.writeln(
    '[sswatch] watching $sourceDir — edit & save to live-reload. Ctrl-C to stop.',
  );

  final done = Completer<void>();
  unawaited(service.onDone.then((_) {
    stdout.writeln('[sswatch] VM Service closed (app exited).');
    if (!done.isCompleted) done.complete();
  }));
  late StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) async {
    runner.dispose();
    await sub.cancel();
    await sigint.cancel();
    stdout.writeln('\n[sswatch] stopped.');
    if (!done.isCompleted) done.complete();
  });

  await done.future;
  runner.dispose();
  await sub.cancel();
  await service.dispose();
}

/// Resolves the VM Service URI from the flags / env, polling a `--vmservice-uri-
/// file` until the launcher writes it. Throws with guidance if none is given.
Future<String> _discoverUri(SsWatchOptions opts) async {
  final direct = (opts.vmServiceUri != null && opts.vmServiceUri!.isNotEmpty)
      ? opts.vmServiceUri
      : Platform.environment['SS_VMSERVICE_URI'];
  if (direct != null && direct.isNotEmpty) return normalizeVmServiceUri(direct);

  final path = opts.vmServiceUriFile;
  if (path != null && path.isNotEmpty) {
    stdout.writeln('[sswatch] waiting for VM Service URI at $path …');
    final raw = await _pollFile(path);
    return normalizeVmServiceUri(raw);
  }

  throw StateError(
    'no VM Service URI. Pass --vmservice-uri=<uri>, or --vmservice-uri-file='
    '<path> and launch with `flutter run --vmservice-out-file=<path>` (or set '
    r'$SS_VMSERVICE_URI).',
  );
}

/// Polls [path] until it holds a non-empty line (the launcher writing the URI).
Future<String> _pollFile(
  String path, {
  Duration timeout = const Duration(seconds: 120),
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final file = File(path);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (file.existsSync()) {
      final s = (await file.readAsString()).trim();
      if (s.isNotEmpty) return s;
    }
    await Future<void>.delayed(interval);
  }
  throw StateError('timed out waiting for a VM Service URI at $path');
}

/// Pushes each reconverted output dir to the app's `ext.ssgen.reload`. The app
/// reloads only the pack it is currently showing (if that dir holds it), so an
/// unrelated pack in the same reconvert is a no-op for it.
Future<void> _pushConvertedDirs(
  VmService service,
  Iterable<String> dirs,
) async {
  final isolateIds = await _isolatesWithExtension(service);
  if (isolateIds.isEmpty) {
    stderr.writeln(
      '[sswatch] app exposes no $ssReloadExtensionMethod isolate yet — is it '
      'launched with --dart-define=$ssLiveReloadDefine=true and using the '
      'SsLiveReload mixin?',
    );
    return;
  }
  for (final dir in dirs) {
    final abs = File(dir).absolute.path;
    for (final id in isolateIds) {
      try {
        final resp = await service.callServiceExtension(
          ssReloadExtensionMethod,
          isolateId: id,
          args: {'source': 'file', 'dir': abs},
        );
        final json = resp.json ?? const <String, dynamic>{};
        if (json['ok'] == true) {
          final n = json['reloaded'] is int ? json['reloaded'] as int : 0;
          stdout.writeln(
            '[sswatch] pushed $dir → reloaded $n player(s)'
            '${n > 0 ? ' (animations=${json['animations']})' : ''}.',
          );
        } else {
          stderr.writeln('[sswatch] app reported: ${json['error']}');
        }
      } catch (e) {
        stderr.writeln('[sswatch] push failed for $dir: $e');
      }
    }
  }
}

/// The isolate ids that registered the reload extension (usually just the main
/// UI isolate). Re-enumerated per push so a hot restart's re-registration is
/// picked up as long as the VM Service connection survives.
Future<List<String>> _isolatesWithExtension(VmService service) async {
  final vm = await service.getVM();
  final ids = <String>[];
  for (final ref in vm.isolates ?? const <IsolateRef>[]) {
    final id = ref.id;
    if (id == null) continue;
    try {
      final iso = await service.getIsolate(id);
      if (iso.extensionRPCs?.contains(ssReloadExtensionMethod) ?? false) {
        ids.add(id);
      }
    } catch (_) {
      // Isolate vanished between listing and query — skip it.
    }
  }
  return ids;
}

Future<SsReconvertReport?> _safeReconvert(
  SsProjectSync sync,
  String projectRoot,
) async {
  try {
    return await sync.reconvert(projectRoot: projectRoot);
  } catch (e) {
    stderr.writeln('[sswatch] reconvert failed: $e');
    return null;
  }
}

void _logConverted(SsReconvertReport report) => report.converted.forEach(
      (sspj, out) => stdout.writeln('[sswatch] reconverted: $sspj -> $out'),
    );

void _printUsage() => stdout.writeln(
      'Usage: dart run ssgen_flutter:sswatch [options]\n'
      '  Watches SpriteStudio_Source/, reconverts stale projects on save, and\n'
      '  pushes the fresh pack to a running app over the VM Service — without\n'
      '  owning `flutter run` (IDE-debugger friendly).\n\n'
      '  --vmservice-uri-file=<path>  poll this file for the app VM Service URI\n'
      '                               (launch with `flutter run '
      '--vmservice-out-file=<path>`)\n'
      '  --vmservice-uri=<uri>        connect to this URI directly (http/ws)\n'
      '  --project-root=<dir>         root holding SpriteStudio_Source/ (cwd)\n'
      '  --source=<dir>               source dir override\n'
      '  --debounce=<ms>              coalesce a save burst (default 250)\n'
      '  --once                       reconvert + push once, then exit\n'
      '  -h, --help                   this help\n\n'
      r'  Also honors $SS_VMSERVICE_URI. Launch the app with '
      '--dart-define=$ssLiveReloadDefine=true.',
    );
