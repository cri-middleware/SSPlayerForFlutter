// The SpriteStudio live-reload watcher — the single dev runner: it reconverts
// changed assets and pushes the fresh pack into the running app.
//
//   dart run ssgen_flutter:sswatch --run -d macos              # own flutter run
//   dart run ssgen_flutter:sswatch --vmservice-uri-file=<path> # attach (IDE)
//
// It watches `SpriteStudio_Source/`, and on save reconverts the stale projects
// (host `libssconverter` via [SsProjectSync]) then calls the app's
// `ext.ssgen.reload` service extension over the Dart VM Service to hot-swap the
// pack in place — no `r`. Two ergonomics over one mechanism:
//   * `--run` spawns `flutter run` (temp `--vmservice-out-file` + the define) and
//     attaches — a one-command session.
//   * attach mode: you launch the app (IDE Run/Debug, or a plain `flutter run
//     --vmservice-out-file=<path> --dart-define=SS_LIVE_RELOAD=true`) and point
//     `--vmservice-uri-file` here — so the IDE debugger stays attached.
//
// Why the VM Service extension (not a daemon `app.restart` / DevFS):
//   * it does not require owning `flutter run`, so it coexists with any launcher
//     including an IDE debug session, and
//   * it pushes the pack directly to the app (desktop reads the reconverted file
//     off disk; device gets an embedded `.ssab` as bytes), decoupled from
//     Flutter's own hot reload / DevFS.
//
// Deliberately Flutter-free (`dart:*`, `ssgen_dart`, `vm_service`, `watcher`) so
// it runs under the plain Dart VM and the pure pieces are unit-testable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ssgen_dart/ssgen_dart.dart';
import 'package:vm_service/utils.dart' show convertToWebSocketUrl;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart' show vmServiceConnectUri;
import 'package:watcher/watcher.dart';

import 'ss_defines.dart';

/// Parsed `sswatch` invocation.
class SsWatchOptions {
  SsWatchOptions({
    this.vmServiceUri,
    this.vmServiceUriFile,
    this.projectRoot,
    this.sourceDir,
    this.embeddedDir,
    this.debounceMs = 250,
    this.once = false,
    this.device = false,
    this.run = false,
    this.passthrough = const [],
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

  /// Where the device (`--device`) mode writes the embedded `.ssab` it pushes,
  /// kept OUT of `assets/` so the app's bundled reference packs are untouched
  /// (default: `<projectRoot>/.dart_tool/ssgen/embedded`).
  final String? embeddedDir;

  /// Debounce window coalescing a burst of file events into one reconvert.
  final int debounceMs;

  /// Reconvert + push once, then exit (no watching).
  final bool once;

  /// Device mode: a device (or the web) can't read a host path, so push a
  /// **self-contained embedded `.ssab`** as base64 bytes for the pack currently
  /// on screen (resolved via `ext.ssgen.targets`) rather than a `file` path.
  /// Desktop keeps the lighter file push (default). Use this with `-d chrome`
  /// too — the web reads no host filesystem, so it takes the byte push.
  final bool device;

  /// Owns-run convenience: also spawn `flutter run` (injecting the define and a
  /// temp `--vmservice-out-file`) and attach to it — a one-command session.
  /// Unrecognized args in [passthrough]
  /// (e.g. `-d emulator-5554`) are forwarded to `flutter run`.
  final bool run;

  /// Unrecognized args, forwarded verbatim to `flutter run` when [run] is set
  /// (e.g. `-d`, `--profile`). Ignored otherwise.
  final List<String> passthrough;

  /// Print usage and exit.
  final bool help;

  static const _uriFlag = '--vmservice-uri=';
  static const _uriFileFlag = '--vmservice-uri-file=';
  static const _projectRootFlag = '--project-root=';
  static const _sourceFlag = '--source=';
  static const _embeddedDirFlag = '--embedded-dir=';
  static const _debounceFlag = '--debounce=';
  static const _onceFlag = '--once';
  static const _deviceFlag = '--device';
  static const _runFlag = '--run';

  /// Parses [argv] into options. Unknown args are ignored (kept lenient so the
  /// runner never dies on a stray flag).
  static SsWatchOptions parse(List<String> argv) {
    String? vmServiceUri;
    String? vmServiceUriFile;
    String? projectRoot;
    String? sourceDir;
    String? embeddedDir;
    var debounceMs = 250;
    var once = false;
    var device = false;
    var run = false;
    var help = false;
    final passthrough = <String>[];
    for (final arg in argv) {
      if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == _onceFlag) {
        once = true;
      } else if (arg == _deviceFlag) {
        device = true;
      } else if (arg == _runFlag) {
        run = true;
      } else if (arg.startsWith(_uriFlag)) {
        vmServiceUri = arg.substring(_uriFlag.length);
      } else if (arg.startsWith(_uriFileFlag)) {
        vmServiceUriFile = arg.substring(_uriFileFlag.length);
      } else if (arg.startsWith(_projectRootFlag)) {
        projectRoot = arg.substring(_projectRootFlag.length);
      } else if (arg.startsWith(_sourceFlag)) {
        sourceDir = arg.substring(_sourceFlag.length);
      } else if (arg.startsWith(_embeddedDirFlag)) {
        embeddedDir = arg.substring(_embeddedDirFlag.length);
      } else if (arg.startsWith(_debounceFlag)) {
        debounceMs =
            int.tryParse(arg.substring(_debounceFlag.length)) ?? debounceMs;
      } else {
        // Unrecognized → forwarded to `flutter run` in --run mode (else ignored).
        passthrough.add(arg);
      }
    }
    return SsWatchOptions(
      vmServiceUri: vmServiceUri,
      vmServiceUriFile: vmServiceUriFile,
      projectRoot: projectRoot,
      sourceDir: sourceDir,
      embeddedDir: embeddedDir,
      debounceMs: debounceMs,
      once: once,
      device: device,
      run: run,
      passthrough: passthrough,
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

/// Ensures `flutter run` is launched with the SpriteStudio live-reload define so
/// [SsLiveReload] activates. No-op if the caller already passed one (any value —
/// lets you launch disabled with `=false`). Used by `--run`.
List<String> withLiveReloadDefine(List<String> flutterArgs) {
  final present = flutterArgs.any((a) => a.contains('$ssLiveReloadDefine='));
  return present
      ? flutterArgs
      : [...flutterArgs, '--dart-define=$ssLiveReloadDefine=true'];
}

/// Why `flutter run` with [flutterArgs] can never take a live-reload, or null
/// when it can. The push is a service extension, so it needs a debug build whose
/// VM Service the watcher reaches; these three launch modes give it none, and
/// waiting on one would only end in a timeout. Used by `--run`.
String? noLiveReloadReason(List<String> flutterArgs) {
  for (final arg in flutterArgs) {
    switch (arg) {
      case '--wasm':
        return 'a --wasm web build exposes no VM Service (flutter run offers no '
            'hot reload there either) — drop --wasm; the default web build '
            'takes the push';
      case '--release':
        return 'a release build has no VM Service';
      case '--profile':
        return 'a profile build keeps the VM Service but not the push channel, '
            'which the app registers in debug builds only';
    }
  }
  return null;
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

  /// Runs [onChange], coalescing anything that arrives while it is in flight.
  ///
  /// **Never completes with an error.** `bump` schedules this as a bare `Timer`
  /// callback, which drops the returned Future — so an escaping exception is an
  /// unhandled async error and takes the whole watcher process down with it,
  /// orphaning the `flutter run` child and leaking the temp dir. A save that
  /// races the app quitting (the VM Service call throws) is an ordinary event
  /// here, not a reason to stop watching: report it and wait for the next save.
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
    } catch (e) {
      stderr.writeln('[sswatch] reload failed: $e');
    } finally {
      _busy = false;
    }
  }

  void dispose() => _timer?.cancel();
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

  // --run: also own `flutter run` — a one-command session.
  // Reconvert the reference assets first so the build bundles current art, then
  // spawn flutter with a temp `--vmservice-out-file` + the live-reload define.
  Process? flutter;
  String? runUriFile;
  Directory? runTmpDir;
  void cleanupRunTmp() {
    try {
      runTmpDir?.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort: a leftover temp dir is harmless.
    }
    runTmpDir = null;
  }

  if (opts.run) {
    final unreachable = noLiveReloadReason(opts.passthrough);
    if (unreachable != null) {
      stderr.writeln('[sswatch] nothing to push to: $unreachable.');
      exitCode = 2;
      return;
    }
    final initial = await _safeReconvert(sync, projectRoot);
    if (initial != null && initial.converted.isNotEmpty) _logConverted(initial);
    final tmp = Directory.systemTemp.createTempSync('ssgen_sswatch');
    runTmpDir = tmp;
    runUriFile = '${tmp.path}/vmservice.txt';
    final args = [
      'run',
      '--vmservice-out-file=$runUriFile',
      ...withLiveReloadDefine(opts.passthrough),
    ];
    stdout.writeln('[sswatch] flutter ${args.join(' ')}');
    // `flutter run` gets this terminal itself, so its own keys (`r`, `R`, `q`)
    // reach it: a piped stdin would leave them with this process, which never
    // reads them.
    flutter = await Process.start('flutter', args,
        runInShell: Platform.isWindows, mode: ProcessStartMode.inheritStdio);
  }

  final String wsUri;
  try {
    wsUri = opts.run
        ? normalizeVmServiceUri(await _pollFile(runUriFile!, owner: flutter))
        : await _discoverUri(opts);
  } catch (e) {
    stderr.writeln('[sswatch] $e');
    flutter?.kill();
    cleanupRunTmp();
    exitCode = 2;
    return;
  }

  stdout.writeln('[sswatch] connecting to $wsUri');
  final VmService service;
  try {
    service = await vmServiceConnectUri(wsUri);
  } catch (e) {
    stderr.writeln('[sswatch] could not connect to the VM Service: $e');
    flutter?.kill();
    cleanupRunTmp();
    exitCode = 2;
    return;
  }

  // Asset dirs already explained as mis-routed, so a broken --device naming
  // convention is reported once rather than on every save.
  final warned = <String>{};

  // --once only makes sense without --run (a one-shot push to a running app).
  if (opts.once && !opts.run) {
    await _reconvertAndPush(service, sync, projectRoot, opts, warned,
        initial: true);
    await service.dispose();
    return;
  }

  if (!Directory(sourceDir).existsSync()) {
    stderr.writeln('[sswatch] source dir not found: $sourceDir');
    await service.dispose();
    flutter?.kill();
    cleanupRunTmp();
    exitCode = 2;
    return;
  }

  final runner = ChangeRunner(
    debounce: Duration(milliseconds: opts.debounceMs),
    onChange: () => _reconvertAndPush(service, sync, projectRoot, opts, warned),
  );
  final watcher = DirectoryWatcher(sourceDir);
  // onError matters as much as the data callback: package:watcher surfaces a
  // FileSystemException on the stream when the watched tree is renamed or
  // deleted, or when the OS watch limit is hit. Unhandled, that error kills the
  // session; the watch is dead either way, so say so and keep the process up
  // for the Ctrl-C / app-exit paths below to shut down cleanly.
  final sub = watcher.events.listen(
    (_) => runner.bump(),
    onError: (Object e) =>
        stderr.writeln('[sswatch] watch error (no longer watching): $e'),
  );
  // Don't claim to be watching until fs events are actually live, or an edit
  // made right after startup is missed (the watch initializes asynchronously).
  await watcher.ready;
  stdout.writeln(
    '[sswatch] watching $sourceDir — edit & save to live-reload '
    '(${opts.device ? 'device/embedded' : 'desktop/file'} push). Ctrl-C to stop.',
  );

  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  unawaited(service.onDone.then((_) {
    stdout.writeln('[sswatch] VM Service closed (app exited).');
    finish();
  }));
  if (flutter != null) {
    unawaited(flutter.exitCode.then((_) {
      stdout.writeln('[sswatch] flutter run exited.');
      finish();
    }));
  }
  late StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) async {
    await sigint.cancel();
    stdout.writeln('\n[sswatch] stopping…');
    finish();
  });

  await done.future;
  runner.dispose();
  await sub.cancel();
  await service.dispose();
  flutter?.kill(); // SIGTERM: `flutter run` tears the app down cleanly
  cleanupRunTmp();
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
///
/// With [owner] — the `flutter run` this watcher spawned — there is no deadline:
/// a first build can take minutes, and the URI only fails to come if that
/// process exits first. Without one (attach mode) nothing says the launcher is
/// still alive, so it gives up after [timeout].
Future<String> _pollFile(
  String path, {
  Process? owner,
  Duration timeout = const Duration(seconds: 120),
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final file = File(path);
  final deadline = DateTime.now().add(timeout);
  var ownerExited = false;
  unawaited(owner?.exitCode.then((_) => ownerExited = true));
  while (owner != null || DateTime.now().isBefore(deadline)) {
    if (file.existsSync()) {
      final s = (await file.readAsString()).trim();
      if (s.isNotEmpty) return s;
    }
    if (ownerExited) {
      throw StateError('flutter run exited before publishing a VM Service URI');
    }
    await Future<void>.delayed(interval);
  }
  throw StateError('timed out waiting for a VM Service URI at $path');
}

/// One reconvert+push cycle, routed by [SsWatchOptions.device]:
///   * desktop (file): reconvert into `assets/` and push a host path the app
///     reads off disk (cheap; picks up changed textures too).
///   * device (bytes): reconvert **embedded** into a temp dir (not `assets/`)
///     and push a self-contained `.ssab` as base64 for the on-screen pack only,
///     then refresh `assets/` as well so a hot restart keeps the new art.
Future<void> _reconvertAndPush(
  VmService service,
  SsProjectSync sync,
  String projectRoot,
  SsWatchOptions opts,
  Set<String> warned, {
  bool initial = false,
}) async {
  if (opts.device) {
    final embeddedDir =
        opts.embeddedDir ?? '$projectRoot/.dart_tool/ssgen/embedded';
    final report = await _safeReconvert(
      sync,
      projectRoot,
      outputDir: embeddedDir,
      embedded: true,
    );
    if (report == null || report.converted.isEmpty) {
      if (initial) stdout.writeln('[sswatch] nothing stale to reconvert.');
      return;
    }
    _logConverted(report);
    await _pushEmbeddedBytes(service, embeddedDir, report, warned);
    // A byte push only reaches the running isolate, and the embedded dir is
    // deliberately outside `assets/` — so without this the app's BUNDLE still
    // holds the art `flutter run` shipped at launch, and the first hot restart
    // silently throws the session's edits away. Desktop has no such gap: its
    // reconvert writes straight into `assets/`. Costs a second (non-embedded)
    // convert per save, taken AFTER the push so it never delays what you see.
    await _safeReconvert(sync, projectRoot);
  } else {
    final report = await _safeReconvert(sync, projectRoot);
    if (report == null || report.converted.isEmpty) {
      if (initial) stdout.writeln('[sswatch] nothing stale to reconvert.');
      return;
    }
    _logConverted(report);
    await _pushConvertedDirs(service, report.converted.values);
  }
}

/// Device push: ask the app which pack each target is showing
/// (`ext.ssgen.targets`), then push that pack's embedded `.ssab` bytes — only
/// for projects this pass reconverted, so an unrelated edit is a no-op.
///
/// [warned] carries the asset dirs already reported as mis-routed, so a broken
/// convention is explained once per session instead of on every save.
Future<void> _pushEmbeddedBytes(
  VmService service,
  String embeddedDir,
  SsReconvertReport report,
  Set<String> warned,
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
  final convertedStems = report.converted.keys.map(ssProjectStem).toSet();
  final projectStems = {
    ...convertedStems,
    ...report.upToDate.map(ssProjectStem),
  };
  for (final id in isolateIds) {
    final targets = await _queryTargets(service, id);
    for (final t in targets) {
      final pack = t['pack'];
      final assetDir = t['assetDir'];
      if (pack == null || pack.isEmpty || assetDir == null) continue;
      final file = File('$embeddedDir/${ssAssetDirStem(assetDir)}/$pack.ssab');
      final routing = routeEmbeddedPush(
        assetDir: assetDir,
        convertedStems: convertedStems,
        projectStems: projectStems,
        packExists: file.existsSync,
      );
      if (routing != SsPushRouting.push) {
        _warnMisroutedPush(routing, assetDir, pack, projectStems, warned);
        continue;
      }
      final b64 = base64Encode(await file.readAsBytes());
      try {
        final resp = await service.callServiceExtension(
          ssReloadExtensionMethod,
          isolateId: id,
          args: {'source': 'bytes', 'pack': pack, 'bytes': b64},
        );
        final json = resp.json ?? const <String, dynamic>{};
        if (json['ok'] == true) {
          final n = json['reloaded'] is int ? json['reloaded'] as int : 0;
          stdout.writeln(
            '[sswatch] pushed "$pack" (${file.lengthSync()}B embedded) → '
            'reloaded $n player(s)'
            '${n > 0 ? ' (animations=${json['animations']})' : ''}.',
          );
          _reportReloadErrors(json);
        } else {
          stderr.writeln('[sswatch] app reported: ${json['error']}');
        }
      } catch (e) {
        stderr.writeln('[sswatch] push failed for "$pack": $e');
      }
    }
  }
}

/// Explains a device push that routed nowhere — once per asset dir, and never
/// for [SsPushRouting.projectUnchanged], which is the ordinary "you edited a
/// different project" case.
void _warnMisroutedPush(
  SsPushRouting routing,
  String assetDir,
  String pack,
  Set<String> projectStems,
  Set<String> warned,
) {
  if (routing == SsPushRouting.projectUnchanged) return;
  if (!warned.add('$routing:$assetDir/$pack')) return;
  final known = (projectStems.toList()..sort()).join(', ');
  switch (routing) {
    case SsPushRouting.unknownProject:
      stderr.writeln(
        '[sswatch] nothing will be pushed to "$assetDir": --device routes the '
        'LAST segment of the app\'s ssAssetDir to a <stem>.sspj, and the source '
        'tree holds {$known}. Rename one to match, or drop --device (the '
        'desktop file push matches by pack name instead).',
      );
    case SsPushRouting.packMissing:
      stderr.writeln(
        '[sswatch] reconverted "${ssAssetDirStem(assetDir)}" but it emits no '
        '"$pack.ssab" — the app\'s ssPack must name a pack the project '
        'produces.',
      );
    case SsPushRouting.push:
    case SsPushRouting.projectUnchanged:
      break;
  }
}

/// Reads `ext.ssgen.targets` on [isolateId] → each target's `{assetDir, pack}`.
Future<List<Map<String, String>>> _queryTargets(
  VmService service,
  String isolateId,
) async {
  try {
    final resp = await service.callServiceExtension(
      ssTargetsExtensionMethod,
      isolateId: isolateId,
    );
    final list = (resp.json?['targets'] as List?) ?? const [];
    return [
      for (final e in list)
        if (e is Map)
          {'assetDir': '${e['assetDir']}', 'pack': '${e['pack']}'},
    ];
  } catch (_) {
    return const [];
  }
}

/// The `.sspj` stem (basename without extension), matching the reconvert
/// output-dir convention (`<outputBase>/<stem>/`).
String ssProjectStem(String path) {
  final base = path.split(RegExp(r'[/\\]')).last;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

/// The trailing segment of an app's `ssAssetDir` — the project stem a device
/// push routes by (`assets/spritestudio/Ringo` → `Ringo`). A directory name, so
/// unlike [ssProjectStem] nothing is stripped: a project called `My.Project`
/// converts into `My.Project/` and must match segment-for-segment. Tolerates a
/// trailing separator.
String ssAssetDirStem(String assetDir) {
  var p = assetDir;
  while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
    p = p.substring(0, p.length - 1);
  }
  return p.split(RegExp(r'[/\\]')).last;
}

/// Why a device (`--device`) push did or did not go out for one on-screen
/// target. Only [push] sends bytes; the rest say which link in the convention
/// broke, so a mismatch is reported instead of silently reloading nothing.
enum SsPushRouting {
  /// The target's project reconverted this pass and holds its pack — send it.
  push,

  /// The project exists but nothing in it changed — an ordinary no-op (you
  /// edited a different project than the one on screen).
  projectUnchanged,

  /// No `.sspj` in the source tree matches the target's asset dir, so this
  /// target can never be pushed to until the two names agree.
  unknownProject,

  /// The project reconverted, but its output holds no `<pack>.ssab` — the app
  /// is showing a pack this project does not emit.
  packMissing,
}

/// Routes one device-push target (`assetDir` + its pack) against a reconvert
/// pass: [convertedStems] is what this pass rebuilt, [projectStems] every
/// project the source tree holds, and [packExists] whether the reconverted
/// output has the pack (called only when the first two agree).
///
/// Pure, because this convention — the app's `ssAssetDir` last segment naming
/// the `<stem>.sspj` — is the one coupling in the device path that the desktop
/// file push does not have, and the one thing that used to fail in silence.
SsPushRouting routeEmbeddedPush({
  required String assetDir,
  required Set<String> convertedStems,
  required Set<String> projectStems,
  required bool Function() packExists,
}) {
  final stem = ssAssetDirStem(assetDir);
  if (!projectStems.contains(stem)) return SsPushRouting.unknownProject;
  if (!convertedStems.contains(stem)) return SsPushRouting.projectUnchanged;
  return packExists() ? SsPushRouting.push : SsPushRouting.packMissing;
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
          _reportReloadErrors(json);
        } else {
          stderr.writeln('[sswatch] app reported: ${json['error']}');
        }
      } catch (e) {
        stderr.writeln('[sswatch] push failed for $dir: $e');
      }
    }
  }
}

/// Prints each reload the app reported as having thrown. A push that reached a
/// target whose `reload` failed still answers `ok` with `reloaded 0`, and the
/// app's own error hook is empty by default — so without this the failure is
/// visible nowhere.
void _reportReloadErrors(Map<String, dynamic> json) {
  final errors = json['errors'];
  if (errors is! List) return;
  for (final e in errors) {
    stderr.writeln('[sswatch] reload failed in the app for $e');
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
  String projectRoot, {
  String? outputDir,
  bool? embedded,
}) async {
  try {
    return await sync.reconvert(
      projectRoot: projectRoot,
      outputDir: outputDir,
      embedded: embedded,
    );
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
      '  pushes the fresh pack to the app over the VM Service (no `r`). Use --run\n'
      '  for a one-command session, or attach to your own launcher (IDE-friendly).\n\n'
      '  --vmservice-uri-file=<path>  poll this file for the app VM Service URI\n'
      '                               (launch with `flutter run '
      '--vmservice-out-file=<path>`)\n'
      '  --vmservice-uri=<uri>        connect to this URI directly (http/ws)\n'
      '  --project-root=<dir>         root holding SpriteStudio_Source/ (cwd)\n'
      '  --source=<dir>               source dir override\n'
      '  --device                     push embedded .ssab bytes for the on-screen\n'
      '                               pack (iOS/Android/web -d chrome; desktop\n'
      '                               uses a file path). Routes the LAST segment\n'
      '                               of the app ssAssetDir to <stem>.sspj, and\n'
      '                               also refreshes assets/ so a hot restart\n'
      '                               keeps the new art\n'
      '  --embedded-dir=<dir>         where --device writes the embedded .ssab\n'
      '                               (default .dart_tool/ssgen/embedded)\n'
      '  --run [flutter args…]        also spawn `flutter run` and attach — a\n'
      '                               one-command session (e.g. --run -d macos).\n'
      '                               Unrecognized args go to `flutter run`.\n'
      '  --debounce=<ms>              coalesce a save burst (default 250)\n'
      '  --once                       reconvert + push once, then exit (no --run)\n'
      '  -h, --help                   this help\n\n'
      '  Attach mode (no --run): launch the app yourself with\n'
      '  --vmservice-out-file=<path> and pass --vmservice-uri-file=<path> here.\n'
      r'  Also honors $SS_VMSERVICE_URI. The app must be built with '
      '--dart-define=$ssLiveReloadDefine=true\n  (--run injects it).',
    );
