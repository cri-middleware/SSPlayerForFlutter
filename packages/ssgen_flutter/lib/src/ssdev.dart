// The cross-platform SpriteStudio live-reload dev runner — the "Metro/Vite" for
// SpriteStudio. It wraps `flutter run --machine`, watches `SpriteStudio_Source/`,
// and on save reconverts the stale projects (host `libssconverter` via
// [SsProjectSync]) then triggers a tool-mediated hot reload over the daemon
// protocol — so the fresh `.ssab` is DevFS-synced to the device and the app's
// `reassemble` reloads it. One command replaces `flutter run` for a live session.
//
// Why the daemon protocol (not SIGUSR1, not a raw VM-Service `reloadSources`):
//   * SIGUSR1 needs POSIX signals → no Windows.
//   * A raw VM-Service `reloadSources` reloads Dart code but does NOT perform the
//     DevFS asset sync + `ext.flutter.evict` — so the new `.ssab` bytes never
//     reach the device. `app.restart` goes through the flutter tool, which does
//     the same work as pressing `r`, including the asset sync.
//
// This library is deliberately Flutter-free (only `dart:*`, `watcher`, and the
// pure-Dart `ssgen_dart`) so `dart run ssgen_flutter:ssdev` runs under the plain
// Dart VM, and the pure pieces below are unit-testable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ssgen_dart/ssgen_dart.dart';
import 'package:watcher/watcher.dart';

import 'ss_defines.dart';

/// Parsed `ssdev` invocation: the `--ss-*` options peeled off, everything else
/// forwarded verbatim to `flutter run --machine`.
class SsDevOptions {
  SsDevOptions({
    required this.flutterArgs,
    this.projectRoot,
    this.sourceDir,
    this.debounceMs = 250,
    this.noWatch = false,
  });

  /// Args passed straight to `flutter run --machine` (e.g. `-d <device>`).
  final List<String> flutterArgs;

  /// Project root holding `SpriteStudio_Source/` (else the current directory).
  final String? projectRoot;

  /// Source dir override (else `spritestudio.yaml` / the convention).
  final String? sourceDir;

  /// Debounce window coalescing a burst of file events into one reconvert.
  final int debounceMs;

  /// Disable the watcher — a pure `flutter run --machine` wrapper.
  final bool noWatch;

  static const _projectRootFlag = '--ss-project-root=';
  static const _sourceFlag = '--ss-source=';
  static const _debounceFlag = '--ss-debounce=';
  static const _noWatchFlag = '--ss-no-watch';

  /// Splits [argv] into `ssdev` options and `flutter` passthrough args.
  static SsDevOptions parse(List<String> argv) {
    final passthrough = <String>[];
    String? projectRoot;
    String? sourceDir;
    var debounceMs = 250;
    var noWatch = false;
    for (final arg in argv) {
      if (arg == _noWatchFlag) {
        noWatch = true;
      } else if (arg.startsWith(_projectRootFlag)) {
        projectRoot = arg.substring(_projectRootFlag.length);
      } else if (arg.startsWith(_sourceFlag)) {
        sourceDir = arg.substring(_sourceFlag.length);
      } else if (arg.startsWith(_debounceFlag)) {
        debounceMs =
            int.tryParse(arg.substring(_debounceFlag.length)) ?? debounceMs;
      } else {
        passthrough.add(arg);
      }
    }
    return SsDevOptions(
      flutterArgs: passthrough,
      projectRoot: projectRoot,
      sourceDir: sourceDir,
      debounceMs: debounceMs,
      noWatch: noWatch,
    );
  }
}

/// One decoded daemon message — an `event` (with [event]) or a response (with
/// [id]). Returns null for non-protocol lines the tool may print (`flutter run`
/// occasionally emits plain text before/around the machine stream).
class DaemonMessage {
  DaemonMessage({this.event, this.id, this.params, this.result, this.error});

  final String? event;
  final int? id;
  final Map<String, dynamic>? params;
  final Object? result;
  final Object? error;

  bool get isEvent => event != null;
  bool get isResponse => id != null;

  /// Decodes one line of daemon stdout. The wire format wraps a single object in
  /// a one-element JSON array: `[{...}]`.
  static DaemonMessage? decode(String line) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('[')) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
    if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
      return null;
    }
    final obj = (decoded.first as Map).cast<String, dynamic>();
    return DaemonMessage(
      event: obj['event'] as String?,
      id: obj['id'] as int?,
      params: (obj['params'] as Map?)?.cast<String, dynamic>(),
      result: obj['result'],
      error: obj['error'],
    );
  }
}

/// Encodes a daemon request line: `[{"method":..,"id":..,"params":..}]`.
String encodeDaemonRequest(int id, String method, Map<String, dynamic> params) =>
    jsonEncode([
      {'method': method, 'id': id, 'params': params},
    ]);

/// Ensures the app is launched with the SpriteStudio live-reload define so
/// [SsLiveReload] activates its `.ssab` reload path. No-op if the caller already
/// passed one (any value — lets you launch disabled with `=false`).
List<String> withLiveReloadDefine(List<String> flutterArgs) {
  final present = flutterArgs.any((a) => a.contains('$ssLiveReloadDefine='));
  return present
      ? flutterArgs
      : [...flutterArgs, '--dart-define=$ssLiveReloadDefine=true'];
}

/// Debounce + single-flight runner: coalesces a burst of [bump]s into one
/// [onChange], never overlapping runs, and re-running once if events arrived
/// while a run was in flight (so the last save always wins).
class ChangeRunner {
  ChangeRunner({required this.debounce, required this.onChange});

  final Duration debounce;
  final Future<void> Function() onChange;

  Timer? _timer;
  bool _busy = false;
  bool _pending = false;

  void bump() {
    _timer?.cancel();
    _timer = Timer(debounce, _fire);
  }

  Future<void> _fire() async {
    if (_busy) {
      _pending = true;
      return;
    }
    _busy = true;
    try {
      do {
        _pending = false;
        await onChange();
      } while (_pending);
    } finally {
      _busy = false;
    }
  }

  void dispose() => _timer?.cancel();
}

/// A running `flutter run --machine` child, speaking the daemon wire protocol.
class FlutterDaemon {
  FlutterDaemon._(this._proc);

  final Process _proc;
  int _nextId = 1;
  final _pending = <int, Completer<Object?>>{};
  final _startedCompleter = Completer<void>();
  String? appId;

  /// App stdout/stderr (via `app.log`) and stray non-protocol lines.
  void Function(String line, {required bool isError})? onLog;

  /// Tool status/error lines (via `daemon.logMessage`).
  void Function(String level, String message)? onDaemonLog;

  /// Completes once `app.started` (or `app.start`) has yielded an [appId].
  Future<void> get started => _startedCompleter.future;

  /// The child's exit code.
  Future<int> get exitCode => _proc.exitCode;

  /// Spawns `flutter run --machine [flutterArgs]`.
  static Future<FlutterDaemon> start(List<String> flutterArgs) async {
    final proc = await Process.start(
      'flutter',
      ['run', '--machine', ...flutterArgs],
      runInShell: Platform.isWindows, // resolve flutter.bat on Windows
    );
    final daemon = FlutterDaemon._(proc);
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(daemon._onLine);
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => daemon.onLog?.call(line, isError: true));
    return daemon;
  }

  void _onLine(String line) {
    final msg = DaemonMessage.decode(line);
    if (msg == null) {
      if (line.trim().isNotEmpty) onLog?.call(line, isError: false);
      return;
    }
    if (msg.isEvent) {
      _onEvent(msg.event!, msg.params ?? const {});
    } else if (msg.isResponse) {
      final completer = _pending.remove(msg.id);
      if (completer == null || completer.isCompleted) return;
      if (msg.error != null) {
        completer.completeError(StateError('daemon error: ${msg.error}'));
      } else {
        completer.complete(msg.result);
      }
    }
  }

  void _onEvent(String event, Map<String, dynamic> params) {
    switch (event) {
      case 'app.start':
        appId = params['appId'] as String?;
      case 'app.started':
        appId ??= params['appId'] as String?;
        if (!_startedCompleter.isCompleted) _startedCompleter.complete();
      case 'app.log':
        onLog?.call(
          params['log']?.toString() ?? '',
          isError: params['error'] == true,
        );
      case 'daemon.logMessage':
        onDaemonLog?.call(
          params['level']?.toString() ?? 'info',
          params['message']?.toString() ?? '',
        );
    }
  }

  Future<Object?> _send(String method, Map<String, dynamic> params) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _proc.stdin.writeln(encodeDaemonRequest(id, method, params));
    return completer.future;
  }

  /// Hot reload (`fullRestart:false`) — the same path as pressing `r`, so it
  /// carries the DevFS asset sync. Returns the daemon result `code` (0 = ok).
  Future<int> hotReload() => _restart(fullRestart: false);

  /// Hot restart (`fullRestart:true`) — rebuilds app state.
  Future<int> hotRestart() => _restart(fullRestart: true);

  Future<int> _restart({required bool fullRestart}) async {
    final result = await _send('app.restart', {
      'appId': appId,
      'fullRestart': fullRestart,
      'reason': 'manual',
      'pause': false,
      'debounce': false, // we debounce upstream; keep the tool call deterministic
    });
    if (result is Map && result['code'] is int) return result['code'] as int;
    return 0;
  }

  /// Stops the app (best-effort).
  Future<void> stop() async {
    try {
      await _send('app.stop', {'appId': appId});
    } catch (_) {
      // Already gone — fall through to a hard kill.
    }
    _proc.kill();
  }
}

/// Entry point behind `bin/ssdev.dart`.
Future<void> runSsDev(List<String> argv) async {
  final opts = SsDevOptions.parse(argv);
  final projectRoot = opts.projectRoot ?? Directory.current.path;
  final cfg = SsProjectSyncConfig.resolve(projectRoot);
  final sourceDir = opts.sourceDir ?? cfg.sourceDir;
  const sync = SsProjectSync();

  // Fresh assets before the initial build so `flutter run` bundles current art.
  await _safeReconvert(sync, projectRoot, initial: true);

  final flutterArgs = withLiveReloadDefine(opts.flutterArgs);
  stdout.writeln(
    '[ssdev] flutter run --machine ${flutterArgs.join(' ')}'.trimRight(),
  );
  final flutter = await FlutterDaemon.start(flutterArgs);
  flutter.onLog = (line, {required isError}) =>
      (isError ? stderr : stdout).writeln(line);
  flutter.onDaemonLog = (level, message) =>
      stdout.writeln('[flutter:$level] $message');

  // Bail if the child dies before it ever starts (bad args / no device).
  final ready = await Future.any([
    flutter.started.then((_) => true),
    flutter.exitCode.then((_) => false),
  ]);
  if (!ready) {
    stderr.writeln('[ssdev] flutter run exited before startup.');
    exit(await flutter.exitCode);
  }
  stdout.writeln('[ssdev] app started (appId=${flutter.appId}).');

  ChangeRunner? runner;
  if (!opts.noWatch) {
    final srcDir = Directory(sourceDir);
    if (srcDir.existsSync()) {
      runner = ChangeRunner(
        debounce: Duration(milliseconds: opts.debounceMs),
        onChange: () => _reconvertAndReload(sync, projectRoot, flutter),
      );
      DirectoryWatcher(sourceDir).events.listen((_) => runner!.bump());
      stdout.writeln('[ssdev] watching $sourceDir — edit & save to live-reload.');
    } else {
      stderr.writeln(
        '[ssdev] source dir not found: $sourceDir (watch disabled).',
      );
    }
  }
  _printControls();

  _wireKeyboard(flutter);
  late StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n[ssdev] stopping…');
    runner?.dispose();
    await sigint.cancel();
    await flutter.stop();
    _restoreStdin();
    exit(0);
  });

  final code = await flutter.exitCode;
  _restoreStdin();
  exit(code);
}

Future<void> _safeReconvert(
  SsProjectSync sync,
  String projectRoot, {
  bool initial = false,
}) async {
  try {
    final report = await sync.reconvert(projectRoot: projectRoot);
    if (report.converted.isNotEmpty) {
      report.converted.forEach(
        (sspj, out) => stdout.writeln('[ssdev] reconverted: $sspj -> $out'),
      );
    } else if (initial) {
      stdout.writeln(
        '[ssdev] assets up to date (${report.upToDate.length} project(s)).',
      );
    }
  } catch (e) {
    stderr.writeln('[ssdev] reconvert failed: $e');
  }
}

Future<void> _reconvertAndReload(
  SsProjectSync sync,
  String projectRoot,
  FlutterDaemon flutter,
) async {
  final SsReconvertReport report;
  try {
    report = await sync.reconvert(projectRoot: projectRoot);
  } catch (e) {
    stderr.writeln('[ssdev] reconvert failed: $e');
    return;
  }
  if (report.converted.isEmpty) return; // nothing changed → no reload
  report.converted.forEach(
    (sspj, out) => stdout.writeln('[ssdev] reconverted: $sspj -> $out'),
  );
  final code = await flutter.hotReload();
  if (code == 0) {
    stdout.writeln('[ssdev] hot-reloaded ${report.converted.length} project(s).');
  } else {
    stderr.writeln('[ssdev] hot reload failed (code $code).');
  }
}

void _wireKeyboard(FlutterDaemon flutter) {
  if (!stdin.hasTerminal) return; // piped/non-interactive: keyboard n/a
  try {
    stdin.echoMode = false;
    stdin.lineMode = false;
  } catch (_) {
    // Raw mode unavailable on this console — keys will need Enter; still works.
  }
  stdin.transform(utf8.decoder).listen((chunk) async {
    for (final ch in chunk.split('')) {
      switch (ch) {
        case 'r':
          stdout.writeln('[ssdev] manual hot reload…');
          await flutter.hotReload();
        case 'R':
          stdout.writeln('[ssdev] manual hot restart…');
          await flutter.hotRestart();
        case 'h':
          _printControls();
        case 'q':
        case '\u0003': // Ctrl-C (raw mode delivers the byte, not a signal)
          stdout.writeln('[ssdev] stopping…');
          await flutter.stop();
          _restoreStdin();
          exit(0);
      }
    }
  });
}

void _printControls() => stdout.writeln(
      '[ssdev] keys: r hot-reload · R hot-restart · q quit · h help',
    );

/// Restores cooked stdin so the terminal isn't left in raw mode after we exit.
void _restoreStdin() {
  if (!stdin.hasTerminal) return;
  try {
    stdin.echoMode = true;
    stdin.lineMode = true;
  } catch (_) {
    // Nothing to restore (raw mode was never engaged).
  }
}
