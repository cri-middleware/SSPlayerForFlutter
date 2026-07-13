import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show AssetBundle, CachingAssetBundle, rootBundle;
import 'package:ssgen_dart/ssgen_dart.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ssplayer_flutter example',
      theme: ThemeData.dark(useMaterial3: true),
      home: const PlayerPage(),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player;
  String _status = 'loading…';

  // The current .ssab source. Starts on the bundled overall.sspj packs; drag &
  // drop a folder (or a .ssab) onto the window to swap to a filesystem source.
  static const _bundledPacks = <String>[
    'PartsColor',
    'Basic',
    'BlendMode',
    'Interpolation',
  ];
  AssetBundle _bundle = rootBundle;
  String _assetDir = 'assets/spritestudio/overall';
  bool _dropped = false;

  // pack = a separate .ssab file in the current source directory.
  List<String> _packs = _bundledPacks;
  String _pack = 'PartsColor';

  // Animations inside the currently-loaded pack, enumerated from the .ssab via
  // SpriteStudioPlayer.getAnimations(); the second dropdown switches between
  // them without reloading the resource/textures.
  List<String> _animations = const <String>[];
  String? _anim;

  bool _dragging = false;

  // Desktop dev live-reload single-flight guard (see reassemble()).
  bool _liveBusy = false;

  @override
  void initState() {
    super.initState();
    _player = SpriteStudioPlayer(vsync: this);
    _load(_pack);
  }

  Future<void> _load(String pack) async {
    setState(() {
      _pack = pack;
      _status = 'loading "$pack"…';
    });
    try {
      // The ssab and its sibling textures are resolved through the same bundle:
      // rootBundle (asset keys) for bundled packs, or _FileBundle (absolute
      // filesystem paths) for a dropped folder.
      final assetPath = '$_assetDir/$pack.ssab';
      final ByteData data = await _bundle.load(assetPath);
      final Uint8List bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      // overall.ssab uses REFERENCE textures (sibling PNGs) → pass baseAssetDir.
      await _player.load(bytes, bundle: _bundle, baseAssetDir: _assetDir);
      // Guard against a newer selection winning the race while we awaited.
      if (!mounted || _pack != pack) return;
      // Enumerate the pack's animations and start on the first one.
      final anims = _player.getAnimations();
      final animName = anims.isNotEmpty ? anims.first : null;
      if (animName != null) _player.setupAnimation(animName);
      _player
        ..loop = -1
        ..play();
      final missing = _player.lastTextureReport?.unresolved ?? const [];
      final label = animName ?? '(no animations)';
      final msg = missing.isEmpty
          ? 'playing "$label"'
          : 'playing "$label" (missing textures: ${missing.join(", ")})';
      // ignore: avoid_print
      print('[ssplayer] OK — $msg (frame=${_player.frameNo})');
      setState(() {
        _animations = anims;
        _anim = animName;
        _status = msg;
      });
    } catch (e, st) {
      // ignore: avoid_print
      print('[ssplayer] FAILED: $e\n$st');
      if (mounted) setState(() => _status = 'failed: $e');
    }
  }

  // Switch animation within the loaded pack — no reload, just re-setup + play.
  void _selectAnimation(String name) {
    if (name == _anim) return;
    _player
      ..setupAnimation(name)
      ..loop = -1
      ..play();
    setState(() {
      _anim = name;
      _status = 'playing "$name"';
    });
  }

  // Handle a dropped folder or .ssab: scan the directory for *.ssab, repopulate
  // the pack dropdown, and play from disk (textures resolved from that folder).
  Future<void> _openDropped(String path) async {
    setState(() => _dragging = false);
    try {
      final dir =
          FileSystemEntity.isDirectorySync(path) ? path : File(path).parent.path;
      final base = path.split(Platform.pathSeparator).last;
      final selected = base.toLowerCase().endsWith('.ssab')
          ? base.substring(0, base.length - '.ssab'.length)
          : null;

      final packs = _scanPacks(dir);
      if (packs.isEmpty) {
        setState(() => _status = 'no .ssab found in $dir');
        return;
      }
      final chosen =
          (selected != null && packs.contains(selected)) ? selected : packs.first;
      setState(() {
        _bundle = _FileBundle();
        _assetDir = dir;
        _dropped = true;
        _packs = packs;
        _pack = chosen;
        _animations = const <String>[];
        _anim = null;
      });
      await _load(chosen);
    } catch (e) {
      if (mounted) setState(() => _status = 'drop failed: $e');
    }
  }

  static List<String> _scanPacks(String dir) => Directory(dir)
      .listSync()
      .whereType<File>()
      .map((f) => f.path.split(Platform.pathSeparator).last)
      .where((n) => n.toLowerCase().endsWith('.ssab'))
      .map((n) => n.substring(0, n.length - '.ssab'.length))
      .toList()
    ..sort();

  // --- Desktop dev live-reload -------------------------------------------
  // Ride Flutter's own hot reload: pressing `r` (or an IDE Dart-save) fires
  // reassemble(), which also rebuilds the SpriteStudio art — reconvert only the
  // STALE SpriteStudio_Source projects via the host libssconverter, then
  // hot-swap the current pack in place (SpriteStudioPlayer.reload preserves the
  // animation, playhead and play state). Desktop + debug only: the host
  // converter can't run on a device. To try it, edit a project in SpriteStudio
  // (or just `touch example/SpriteStudio_Source/overall/overall.sspj`) and press
  // `r`. Run `flutter run` from example/ so the source dir resolves.
  @override
  void reassemble() {
    super.reassemble();
    if (!kDebugMode) return;
    if (_isDesktop) {
      _reconvertAndReload(); // host: reconvert stale SpriteStudio_Source + reload
    } else if (!kIsWeb) {
      _reloadFromBundle(); // device: reload-only (host reconvert + `r` synced it)
    }
  }

  // Device (iOS/Android) live-reload: the device can't run the host converter,
  // so the host rebuilds assets/ (run `dart run tool/ssreconvert.dart`) and `r`
  // DevFS-syncs the changed `.ssab` to the device + evicts its rootBundle cache.
  // We only re-read and hot-swap in place — converter-free on device.
  Future<void> _reloadFromBundle() async {
    if (_liveBusy || _dropped) return;
    _liveBusy = true;
    try {
      final key = '$_assetDir/$_pack.ssab';
      rootBundle.evict(key); // belt-and-braces; Flutter also evicts changed keys
      final data = await rootBundle.load(key);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await _player.reload(bytes, bundle: rootBundle, baseAssetDir: _assetDir);
      if (!mounted) return;
      setState(() => _status = 'live-reloaded "$_pack" (bundle)');
    } catch (e) {
      if (mounted) setState(() => _status = 'live-reload failed: $e');
    } finally {
      _liveBusy = false;
    }
  }

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  // Locate the project root (the dir holding SpriteStudio_Source). A macOS app's
  // Directory.current is its sandbox container, NOT the project, so derive it
  // from the executable path (holds for `flutter run` debug builds) — or take an
  // explicit `--dart-define=SS_PROJECT_ROOT=<dir>` override.
  static String? _projectRoot() {
    const sub = SsProjectSyncConfig.defaultSourceSubdir;
    const override = String.fromEnvironment('SS_PROJECT_ROOT');
    if (override.isNotEmpty) {
      return Directory('$override/$sub').existsSync() ? override : null;
    }
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 12; i++) {
      if (Directory('${dir.path}/$sub').existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  Future<void> _reconvertAndReload() async {
    if (_liveBusy) return; // single-flight: don't overlap reload()/load()
    _liveBusy = true;
    try {
      final root = _projectRoot();
      if (root == null) {
        if (mounted) {
          setState(() => _status = 'live-reload: SpriteStudio_Source not found '
              '(pass --dart-define=SS_PROJECT_ROOT=<example dir>)');
        }
        return;
      }
      final report = await const SsProjectSync().reconvert(projectRoot: root);
      if (!report.didConvert) return; // nothing stale → cheap no-op

      // Reload the current pack from whichever project just rebuilt it.
      String? found;
      for (final d in report.converted.values) {
        if (File('$d/$_pack.ssab').existsSync()) {
          found = d;
          break;
        }
      }
      if (found == null) return; // current pack not among the rebuilt projects
      final outDir = found;

      final bytes = await File('$outDir/$_pack.ssab').readAsBytes();
      final bundle = _FileBundle(); // fresh instance → no stale cached bytes
      await _player.reload(bytes, bundle: bundle, baseAssetDir: outDir);
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _assetDir = outDir;
        _dropped = true;
        _packs = _scanPacks(outDir);
        _animations = _player.getAnimations();
        _anim = _player.currentAnimation;
        _status = 'live-reloaded "$_pack" ← $outDir';
      });
      // ignore: avoid_print
      print('[ssplayer] live-reloaded ${report.converted.keys.join(", ")}');
    } catch (e) {
      if (mounted) setState(() => _status = 'live-reload failed: $e');
    } finally {
      _liveBusy = false;
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = _dropped ? _assetDir : 'bundled assets';
    return Scaffold(
      appBar: AppBar(
        title: const Text('ssplayer_flutter'),
        actions: [
          // Animation within the current pack (from player.getAnimations()).
          if (_animations.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: DropdownButton<String>(
                value: _anim,
                hint: const Text('animation'),
                onChanged: (v) {
                  if (v != null) _selectAnimation(v);
                },
                items: [
                  for (final a in _animations)
                    DropdownMenuItem<String>(value: a, child: Text(a)),
                ],
              ),
            ),
          // Pack = a separate .ssab file in the current source directory.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButton<String>(
              value: _pack,
              onChanged: (v) {
                if (v != null && v != _pack) _load(v);
              },
              items: [
                for (final p in _packs)
                  DropdownMenuItem<String>(value: p, child: Text(p)),
              ],
            ),
          ),
        ],
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) {
          if (detail.files.isNotEmpty) _openDropped(detail.files.first.path);
        },
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  border: Border.all(
                    color: _dragging ? Colors.tealAccent : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: SpriteStudioView(
                  player: _player,
                  width: 400,
                  height: 400,
                ),
              ),
              const SizedBox(height: 16),
              Text(_status),
              const SizedBox(height: 4),
              Text(
                'source: $source  ·  drop a folder of .ssab here',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () =>
            _player.isPlaying ? _player.pause() : _player.play(),
        child: const Icon(Icons.play_arrow),
      ),
    );
  }
}

/// AssetBundle whose keys are absolute filesystem paths, so a dropped folder's
/// `.ssab` and its sibling reference textures load through the exact same code
/// path as bundled assets — no library change, and `dart:io` stays in the app.
class _FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}
