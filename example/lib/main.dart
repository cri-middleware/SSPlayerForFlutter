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
  //
  // Bundled sources: asset dir → its packs. A bundle can't be enumerated at
  // runtime (unlike a dropped folder), so the pack lists are declared here and
  // kept in sync with what `scripts/deploy-examples.sh` converts. Each dir's
  // stem matches its `.sspj` (see the deploy script / SsProjectSync convention).
  static const _bundledSources = <String, List<String>>{
    'assets/spritestudio/overall': <String>[
      'Shape',
      'Instance',
      'Effect',
      'Mesh',
      'Mask',
      'PartsColor',
      'Basic',
      'BlendMode',
      'Interpolation',
    ],
    'assets/spritestudio/Ringo': <String>['Ringo', 'Ringo_tyu'],
  };
  static const _defaultSource = 'assets/spritestudio/overall';

  AssetBundle _bundle = rootBundle;
  String _assetDir = _defaultSource;
  bool _dropped = false;

  // pack = a separate .ssab file in the current source directory.
  List<String> _packs = _bundledSources[_defaultSource]!;
  String _pack = _bundledSources[_defaultSource]!.first;

  // Animations inside the currently-loaded pack, enumerated from the .ssab via
  // SpriteStudioPlayer.getAnimations(); the second dropdown switches between
  // them without reloading the resource/textures.
  List<String> _animations = const <String>[];
  String? _anim;

  bool _dragging = false;

  // Pan/zoom of the animation within the view: drag to reposition, scroll or
  // pinch to zoom (also handy for inspecting rendering up close). Reset via the
  // AppBar's center-focus button.
  final TransformationController _view = TransformationController();

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

  // Switch between bundled sources (a deployed project dir, e.g. overall/Ringo).
  // Reloads the resource+textures from the new dir and plays its first pack.
  Future<void> _selectSource(String dir) async {
    if (!_dropped && dir == _assetDir) return;
    final packs = _bundledSources[dir]!;
    setState(() {
      _bundle = rootBundle;
      _assetDir = dir;
      _dropped = false;
      _packs = packs;
      _animations = const <String>[];
      _anim = null;
    });
    await _load(packs.first);
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
  String get ssAssetDir => _assetDir;

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
    _view.dispose();
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
          // Reset the pan/zoom back to the centered, 1:1 view.
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            tooltip: 'Reset view',
            onPressed: () => _view.value = Matrix4.identity(),
          ),
          // Menus read left→right: sspj (source project) · ssab (pack) · anime.
          // sspj = a bundled source = a deployed project dir (overall / Ringo).
          // Hidden once a folder is dropped (that source isn't in the map).
          if (!_dropped)
            _labeledMenu(
              'sspj',
              DropdownButton<String>(
                value: _assetDir,
                onChanged: (v) {
                  if (v != null) _selectSource(v);
                },
                items: [
                  for (final dir in _bundledSources.keys)
                    DropdownMenuItem<String>(
                      value: dir,
                      child: Text(dir.split('/').last),
                    ),
                ],
              ),
            ),
          // ssab = a separate .ssab pack file in the current source directory.
          _labeledMenu(
            'ssab',
            DropdownButton<String>(
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
          // anime = an animation within the current pack (player.getAnimations()).
          if (_animations.isNotEmpty)
            _labeledMenu(
              'anime',
              DropdownButton<String>(
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
          const SizedBox(width: 8),
        ],
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) {
          if (detail.files.isNotEmpty) _openDropped(detail.files.first.path);
        },
        child: Column(
          children: [
            // The display area fills the window and resizes with it. Omitting
            // width/height lets SpriteStudioView expand to the box constraints;
            // the animation stays centered (drag/zoom to reframe).
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(8),
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  border: Border.all(
                    color: _dragging ? Colors.tealAccent : Colors.transparent,
                    width: 3,
                  ),
                ),
                // Drag to reposition, scroll/pinch to zoom (clipped to the box).
                child: InteractiveViewer(
                  transformationController: _view,
                  minScale: 0.25,
                  maxScale: 16,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: SpriteStudioView(player: _player),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: [
                  Text(_status),
                  const SizedBox(height: 4),
                  Text(
                    'source: $source  ·  drag to move · scroll to zoom · drop a folder of .ssab here',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        // One-tap transport: pause when advancing, else resume (head-out when
        // stopped/finished). setState refreshes the icon to match.
        onPressed: () => setState(_player.togglePlayPause),
        child: Icon((_player.isPlaying && !_player.isPaused)
            ? Icons.pause
            : Icons.play_arrow),
      ),
    );
  }

  // A dropdown with a small inline role label (sspj / ssab / anime), kept on one
  // row so it fits the AppBar's toolbar height.
  Widget _labeledMenu(String label, Widget menu) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label:', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 4),
            menu,
          ],
        ),
      );
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
