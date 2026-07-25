import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show AssetBundle, CachingAssetBundle, rootBundle;
import 'package:ssgen_flutter/ssgen_flutter.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

/// flutter_gpu bring-up switch. Run with `--dart-define=SS_BACKEND=gpu` to drive
/// the flutter_gpu backend (Impeller; mobile/desktop) instead of the Canvas
/// default. `gpu` falls back to Canvas where flutter_gpu is unavailable.
const String _backendName =
    String.fromEnvironment('SS_BACKEND', defaultValue: 'canvas');
SpriteStudioBackend get _selectedBackend =>
    _backendName == 'gpu' ? SpriteStudioBackend.gpu : SpriteStudioBackend.canvas;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On the web the Brain is a wasm module fetched at runtime; await it before the
  // player is created. A no-op on native (the native asset resolves eagerly).
  await loadSsRuntime();
  runApp(const ExampleApp());
}

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

  // The most recent timeline event (§6C), shown under the status line so the
  // UserData / Signal / Sound packs visibly demonstrate onUserData / onSignal /
  // onAudio.
  String _lastEvent = '';

  // Audio playback lives in the app, not the player (audio-independent, §6C).
  // Fire-and-forget: a throwaway player per trigger, so re-triggers (the anim
  // loops) and different sounds simply overlap — no channels, no playback-side
  // state. Tracked only to dispose them with the widget; each self-disposes when
  // it finishes.
  final Set<AudioPlayer> _audioPlayers = <AudioPlayer>{};

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
      // Every built-in `ss-*` integration shader (SHDR), one per animation.
      'Shader',
      'Basic',
      'BlendMode',
      'Interpolation',
      // Carries timeline events (§6C): UserData / Signal markers and Audio
      // triggers surfaced via onUserData / onSignal / onAudio (see _lastEvent).
      'UserData',
      'Signal',
      'Sound',
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

  static const double _minScale = 0.25;
  static const double _maxScale = 16;

  // Latest viewport of the display area, from the LayoutBuilder in [build] — the
  // "Reset view" button needs it to re-fit outside of layout.
  Size? _viewport;

  // The render box [_fitView] last fitted, so a new animation re-fits and an
  // ordinary rebuild does not stomp on the user's pan/zoom.
  Size? _fittedFor;

  /// Centres [box] in [viewport] at the largest scale that shows all of it.
  ///
  /// The animation's box is `canvasSize * 2` and the window is whatever it is, so
  /// neither "1:1" nor "always shrink" is right on its own — fit is what makes an
  /// arbitrary pack land fully in view on load. Clamped to the InteractiveViewer's
  /// own scale bounds, which it would otherwise enforce on the first gesture.
  void _fitView(Size box, Size viewport) {
    if (box.isEmpty || viewport.isEmpty) return;
    final scale = math
        .min(viewport.width / box.width, viewport.height / box.height)
        .clamp(_minScale, _maxScale);
    _view.value = Matrix4.identity()
      ..translateByDouble((viewport.width - box.width * scale) / 2,
          (viewport.height - box.height * scale) / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// The animation's render box for the current animation, or null before one is
  /// selected. 2x the authored canvas per axis — see the InteractiveViewer in
  /// [build] for why.
  Size? get _viewBox {
    final canvas = _player.canvasSize;
    return canvas == null ? null : Size(canvas.width * 2, canvas.height * 2);
  }

  @override
  void initState() {
    super.initState();
    // Web deep-link: `?pack=Effect` opens straight on that pack (used by the
    // docs "live preview" pages and for per-pack render checks). Native ignores
    // it. Falls back to the default first pack when absent/unknown.
    if (kIsWeb) {
      final wanted = Uri.base.queryParameters['pack'];
      if (wanted != null && _packs.contains(wanted)) _pack = wanted;
    }
    // Render backend selector for the flutter_gpu bring-up: run with
    // `--dart-define=SS_BACKEND=gpu` to exercise the flutter_gpu backend
    // (mobile/desktop only; falls back to Canvas where Impeller is unavailable),
    // otherwise the default Canvas path. Lets the same pack be A/B-compared.
    _player = SpriteStudioPlayer(vsync: this, backend: _selectedBackend)
      // Surface the decoded timeline events (§6C). Set once — the callbacks
      // persist across loadAsset, so switching packs keeps them wired.
      ..onAudio = (a) {
        _showEvent('♪ audio: "${a.soundName}" ×${a.loopNum}');
        _playAudio(a);
      }
      ..onUserData = (u) {
        final str = u.string != null ? ' "${u.string}"' : '';
        _showEvent('userData @part ${u.partIndex}$str');
      }
      ..onSignal = (s) {
        _showEvent('signal "${s.commandId}"');
      };
    _load(_pack);
  }

  // Store the latest timeline event for display. Fires on the UI isolate from
  // the player's per-frame event dispatch, so a plain setState is safe.
  void _showEvent(String text) {
    if (mounted) setState(() => _lastEvent = text);
  }

  // Play an audio trigger (§6C). The player only says WHAT to play; the app
  // decides HOW — here: fire it and forget it. Each trigger gets its own
  // throwaway player, so re-triggers (the anim loops) and different sounds just
  // overlap, with no channel bookkeeping and no "is it already playing" state.
  // `loopNum` is a play count (>= 1; SpriteStudio has no infinite loop), and
  // audioplayers has no "play N times", so replay on completion until spent,
  // then discard the player.
  //
  // Spec note (SDK 90_audio): audio should only play on FORWARD playback — the
  // Brain also reports events when running in reverse, which audio backends
  // rarely support. This demo only ever plays forward, so it needs no guard;
  // an app that reverses would gate on its own playback direction here.
  Future<void> _playAudio(SsAudioEvent a) async {
    // Only bundled packs ship their sounds as app assets. A drag-dropped folder
    // would need filesystem playback, which this demo skips.
    if (_dropped) return;
    final rel = _player.soundFilePath(a.soundNameHash); // e.g. sound/foo.mp3
    if (rel == null) return;
    // AssetSource paths are relative to the `assets/` root, so drop that prefix.
    final root = _assetDir.startsWith('assets/')
        ? _assetDir.substring('assets/'.length)
        : _assetDir;
    final source = AssetSource('$root/$rel');

    final player = AudioPlayer();
    _audioPlayers.add(player);
    var remaining = (a.loopNum < 1 ? 1 : a.loopNum) - 1;
    late final StreamSubscription<void> sub;
    sub = player.onPlayerComplete.listen((_) {
      if (remaining > 0) {
        remaining--; // still owe plays — loopNum is a count, so replay
        player.play(source);
      } else {
        sub.cancel();
        _audioPlayers.remove(player);
        player.dispose();
      }
    });
    await player.setReleaseMode(ReleaseMode.stop);
    await player.play(source);
  }

  Future<void> _load(String pack) async {
    setState(() {
      _pack = pack;
      _status = 'loading "$pack"…';
      _lastEvent = '';
    });
    try {
      // The ssab and its sibling textures are resolved through the same bundle:
      // rootBundle (asset keys) for bundled packs, or _FileBundle (absolute
      // filesystem paths) for a dropped folder.
      // overall.ssab uses REFERENCE textures (sibling PNGs); loadAsset reads the
      // bytes and derives the texture folder from the key's own directory.
      final assetPath = '$_assetDir/$pack.ssab';
      await _player.loadAsset(assetPath, bundle: _bundle);
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
  // Hot-swaps the SpriteStudio art in place, playhead preserved — no `r`. The
  // mixin just registers this player with the VM-Service push channel; run the
  // `sswatch` host runner alongside the app (opt-in via the SS_LIVE_RELOAD
  // define, injected by --run):
  //   Desktop (file push):    dart run ssgen_flutter:sswatch --run -d macos
  //   Device  (embedded push): dart run ssgen_flutter:sswatch --run -d <emu> --device
  //   Web     (embedded push): dart run ssgen_flutter:sswatch --run -d chrome --device
  //     (debug DDC only — via DWDS; not --wasm/release)
  //   IDE (attach, keep the debugger): launch from the IDE with
  //     --dart-define=SS_LIVE_RELOAD=true --vmservice-out-file=/tmp/ss.uri, then
  //     dart run ssgen_flutter:sswatch --vmservice-uri-file=/tmp/ss.uri [--device]
  // Then edit & save a SpriteStudio_Source file (a `touch` is byte-identical, so
  // edit for real to see a visible change).
  @override
  SpriteStudioPlayer get ssPlayer => _player;

  @override
  String get ssAssetDir => _assetDir;

  @override
  String get ssPack => _pack;

  // Live-reload is opt-in: only when launched with the SpriteStudio define
  // (`sswatch --run` injects it; else `--dart-define=SS_LIVE_RELOAD=true`). Also
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
    for (final p in _audioPlayers.toList()) {
      p.dispose();
    }
    _audioPlayers.clear();
    _view.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = _dropped ? _assetDir : 'bundled assets';
    final viewBox = _viewBox;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ssplayer_flutter'),
        actions: [
          // Reset the pan/zoom back to the whole animation, centered — the same
          // framing a fresh load gets, not 1:1 (which for a big canvas is a
          // corner of it).
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            tooltip: 'Reset view',
            onPressed: () {
              final box = viewBox, viewport = _viewport;
              if (box != null && viewport != null) {
                _fitView(box, viewport);
              } else {
                _view.value = Matrix4.identity();
              }
            },
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
            // The display area fills the window and resizes with it; the
            // animation gets its own box inside it (see the InteractiveViewer
            // below) and stays centered in that box.
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
                //
                // The view gets an explicit box sized from the animation's own
                // canvas, and `constrained: false` so InteractiveViewer pans
                // that box around instead of forcing it to the viewport. Both
                // halves matter for the flutter_gpu backend: it renders into an
                // offscreen the size of its box and crops everything outside
                // that box BEFORE any ancestor transform, so a viewport-sized
                // view (the `constrained: true` default) makes dragging slide an
                // already-cropped image around — the parts of the animation that
                // started off-box can never be revealed. The Canvas backend
                // draws unbounded and does not show it, which is exactly the
                // kind of backend disagreement worth not shipping in a demo.
                //
                // 2x the canvas per axis because the world origin can sit
                // anywhere inside it (Ringo's is near its feet, not the centre),
                // so a box centred on the origin needs a full canvas-dimension
                // of reach to the far side. Same reasoning, same factor, as
                // SpriteStudioComponent's zero-size fallback in ssplayer_flame.
                // `constrained: false` also means InteractiveViewer no longer
                // scales the child to fit, so the initial view is the box at 1:1
                // anchored top-left — a corner of anything bigger than the
                // window. [LayoutBuilder] supplies the viewport so [_fitView] can
                // set that starting transform itself.
                child: LayoutBuilder(builder: (context, constraints) {
                  final viewport = constraints.biggest;
                  _viewport = viewport;
                  if (viewBox != null && _fittedFor != viewBox) {
                    _fittedFor = viewBox;
                    // After this frame: the controller is a ValueNotifier, and
                    // setting it mid-build would notify listeners during build.
                    // Deliberately keyed on the box, not the viewport, so a window
                    // resize leaves the framing the user chose alone.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _fitView(viewBox, viewport);
                    });
                  }
                  return InteractiveViewer(
                    transformationController: _view,
                    minScale: _minScale,
                    maxScale: _maxScale,
                    // Before the first animation is selected there is no canvas to
                    // size from; stay constrained until there is, since a null
                    // width/height under unbounded constraints resolves to
                    // infinity.
                    constrained: viewBox == null,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    child: SpriteStudioView(
                      player: _player,
                      width: viewBox?.width,
                      height: viewBox?.height,
                    ),
                  );
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: [
                  Text(_status),
                  // Latest timeline event (§6C) — non-empty for the UserData /
                  // Signal / Sound packs. Reserve the row so layout is stable.
                  SizedBox(
                    height: 20,
                    child: Text(
                      _lastEvent,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
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
