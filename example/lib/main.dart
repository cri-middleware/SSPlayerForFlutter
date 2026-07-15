import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show AssetBundle, CachingAssetBundle, rootBundle;
import 'package:ssgen_flutter/ssgen_flutter.dart';
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
    with SingleTickerProviderStateMixin, SsLiveReload<PlayerPage> {
  late final SpriteStudioPlayer _player;
  String _status = 'loading…';

  // The current .ssab source. Starts on the bundled overall.sspj packs; drag &
  // drop a folder (or a .ssab) onto the window to swap to a filesystem source.
  static const _bundledPacks = <String>[
    'Instance',
    'Effect',
    'Mesh',
    'Mask',
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
  String _pack = 'Instance';

  // Animations inside the currently-loaded pack, enumerated from the .ssab via
  // SpriteStudioPlayer.getAnimations(); the second dropdown switches between
  // them without reloading the resource/textures.
  List<String> _animations = const <String>[];
  String? _anim;

  bool _dragging = false;

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

  // --- Dev live-reload (the SsLiveReload mixin) --------------------------
  // Rides Flutter's own hot reload to also rebuild the SpriteStudio art —
  // desktop reconverts the stale SpriteStudio_Source projects in-process,
  // device reloads the fresh pack from the bundle. Opt-in via the
  // SS_LIVE_RELOAD define (see ssLiveReloadEnabled below). Recommended: run
  //   dart run ssgen_flutter:ssdev -d <device>
  // from example/ — it wraps `flutter run`, injects the define, and on save
  // reconverts + hot-reloads for you. Manual: `flutter run
  // --dart-define=SS_LIVE_RELOAD=true`, then after a REAL edit (a `touch` is
  // byte-identical) run `dart run ssgen_flutter:ssreconvert` and press `r`.
  @override
  SpriteStudioPlayer get ssPlayer => _player;

  @override
  String get ssAssetDir => 'assets/spritestudio/overall';

  @override
  String get ssPack => _pack;

  // Live-reload is opt-in: only when launched with the SpriteStudio define
  // (`ssdev` injects it; else `--dart-define=SS_LIVE_RELOAD=true`). Also
  // suspended while a drag-dropped (non-convention) source is shown.
  @override
  bool get ssLiveReloadEnabled =>
      kDebugMode && !_dropped && const bool.fromEnvironment(ssLiveReloadDefine);

  @override
  void ssOnLiveReloaded() {
    setState(() {
      _animations = _player.getAnimations();
      _anim = _player.currentAnimation;
      _status = 'live-reloaded "$_pack" (anims=${_animations.join(", ")})';
    });
    // ignore: avoid_print
    print('[ssplayer] live-reloaded "$_pack" (frame=${_player.frameNo})');
  }

  @override
  void ssOnLiveReloadError(Object error) {
    if (mounted) setState(() => _status = 'live-reload failed: $error');
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
