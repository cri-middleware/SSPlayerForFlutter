// Motion blending, checked by eye. A second entry point beside main.dart:
//
//   flutter run -t lib/motion_blend_check.dart -d windows
//   flutter run -t lib/motion_blend_check.dart -d windows --dart-define=pack=1
//
// The second starts on Doll's runs (`P` cycles the packs either way).
//
// Some of motion blending only the eye can judge — whether a crossfade reads as
// a blend or a cut, whether an additive overlay leaves the motion underneath
// showing — so every track call is on a key, and the state the player reports
// is printed beside the drawing. The keys are the ones the sibling viewers use.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadSsRuntime();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: MotionBlendCheck(),
  ));
}

/// The packs to check against, cycled with `P`: a character with many
/// animations, a pair of runs for the phase sync, and one that fires events.
const _packs = <String>[
  'assets/spritestudio/Ringo/Ringo.ssab',
  'assets/spritestudio/Doll/Action02_Body.ssab',
  'assets/spritestudio/overall/UserData.ssab',
];

const _crossfade = Duration(milliseconds: 400);
const _speeds = <double>[1, 2, 0.5];

const _keys = <(String, String)>[
  ('↑ / ↓', 'switch track 0 (setAnimation)'),
  ('C', 'crossfade track 0 to the next animation (400 ms)'),
  ('S', 'cycle the animation on track 1, or take it off'),
  ('1 / 2', 'track 1 alpha down / up'),
  ('A', 'track 1 mix / additive'),
  ('0', 'fade track 0 to the setup pose and back'),
  (', / .', 'scrub track 1 (speed 0)'),
  ('Y', 'track sync free / start (tracks 0 and 1)'),
  ('3', 'track 0 speed 1× / 2× / 0.5×'),
  ('T', 'track 0 loops once / forever'),
  ('4', 'track 1 loops once / forever'),
  ('E', 'outgoing side of a crossfade fires: never / first half'),
  ('Space', 'pause / resume'),
  ('R', 'play (head out track 0)'),
  ('P', 'next pack'),
];

class MotionBlendCheck extends StatefulWidget {
  const MotionBlendCheck({super.key});

  @override
  State<MotionBlendCheck> createState() => _MotionBlendCheckState();
}

class _MotionBlendCheckState extends State<MotionBlendCheck>
    with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  /// The pack to start on: `--dart-define=pack=1` opens Doll's runs.
  int _pack = const int.fromEnvironment('pack') % _packs.length;
  int _overlay = -1; // index into animationNames, -1 for none
  double _alpha = 1;
  bool _additive = false;
  bool _syncStart = false;
  int _speed = 0;
  bool _track0Once = false;
  bool _track1Once = false;
  bool _outgoingHalf = false;
  bool _baseFaded = false;
  double _scrub = 0;
  final List<String> _events = <String>[];

  List<String> get _names => _player.animationNames;

  @override
  void initState() {
    super.initState();
    _player
      ..onUserData = ((e) => _log('user data f${e.frameNo}', e.source))
      ..onSignal = ((e) => _log('signal "${e.commandId}" f${e.frameNo}', e.source))
      ..onAudio = ((e) => _log('audio f${e.frameNo}', e.source))
      ..onAnimationFinished = (() => _log('track 0 finished', null))
      ..onAnimationLooped = (() => _log('track 0 looped', null));
    _load();
  }

  void _log(String what, int? source) {
    _events.insert(0, source == null ? what : '$what  (source $source)');
    if (_events.length > 8) _events.removeLast();
  }

  Future<void> _load() async {
    await _player.loadAsset(_packs[_pack]);
    if (!mounted || _names.isEmpty) return;
    _overlay = -1;
    _player.setAnimation(_names.first);
    _applyTrackZero();
    _player.play();
    setState(() {});
  }

  /// What a setAnimation folds away or a new pack starts without.
  void _applyTrackZero() {
    _player
      ..speedScale = _speeds[_speed]
      ..loopCount = _track0Once ? 1 : -1
      ..setTrackSync(0, _syncStart ? SsTrackSync.start : SsTrackSync.free)
      ..setTrackOutgoingEventThreshold(0, _outgoingHalf ? 0.5 : double.infinity);
    _baseFaded = false;
  }

  void _applyTrackOne() {
    _player
      ..setTrackAlpha(1, _alpha)
      ..setTrackBlend(1, _additive ? SsTrackBlend.additive : SsTrackBlend.mix)
      ..setTrackLoopCount(1, _track1Once ? 1 : -1);
  }

  int get _current => _names.indexOf(_player.currentAnimation ?? '');

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final names = _names;
    if (names.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final n = names.length;

    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final step = key == LogicalKeyboardKey.arrowUp ? -1 : 1;
      _player.setAnimation(names[(_current + step + n) % n]);
      _overlay = -1; // setAnimation folds the stack
      _applyTrackZero();
      _player.play();
    } else if (key == LogicalKeyboardKey.keyC) {
      _player.crossfade(0, names[(_current + 1) % n], _crossfade);
    } else if (key == LogicalKeyboardKey.keyS) {
      _overlay = _overlay + 1 >= n ? -1 : _overlay + 1;
      if (_overlay < 0) {
        _player.clearTrack(1);
      } else {
        _player.setTrackSync(1, _syncStart ? SsTrackSync.start : SsTrackSync.free);
        _player.setTrackAnimation(1, names[_overlay]);
        _applyTrackOne();
      }
    } else if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.digit2) {
      _alpha = (_alpha + (key == LogicalKeyboardKey.digit1 ? -0.1 : 0.1))
          .clamp(0.0, 1.0);
      _player.setTrackAlpha(1, _alpha);
    } else if (key == LogicalKeyboardKey.keyA) {
      _additive = !_additive;
      _player.setTrackBlend(1, _additive ? SsTrackBlend.additive : SsTrackBlend.mix);
    } else if (key == LogicalKeyboardKey.digit0) {
      _baseFaded = !_baseFaded;
      _player.fadeTrack(0, _baseFaded ? 0 : 1, const Duration(milliseconds: 600));
    } else if (key == LogicalKeyboardKey.comma || key == LogicalKeyboardKey.period) {
      if (_overlay >= 0) {
        _scrub = (_player.trackFrame(1) ?? 0) +
            (key == LogicalKeyboardKey.comma ? -1 : 1);
        _player
          ..setTrackSpeed(1, 0)
          ..setTrackFrame(1, _scrub);
      }
    } else if (key == LogicalKeyboardKey.keyY) {
      _syncStart = !_syncStart;
      final sync = _syncStart ? SsTrackSync.start : SsTrackSync.free;
      _player
        ..setTrackSync(0, sync)
        ..setTrackSync(1, sync);
    } else if (key == LogicalKeyboardKey.digit3) {
      _speed = (_speed + 1) % _speeds.length;
      _player.speedScale = _speeds[_speed];
    } else if (key == LogicalKeyboardKey.keyT) {
      _track0Once = !_track0Once;
      _player.loopCount = _track0Once ? 1 : -1;
    } else if (key == LogicalKeyboardKey.digit4) {
      _track1Once = !_track1Once;
      _player.setTrackLoopCount(1, _track1Once ? 1 : -1);
    } else if (key == LogicalKeyboardKey.keyE) {
      _outgoingHalf = !_outgoingHalf;
      _player.setTrackOutgoingEventThreshold(
          0, _outgoingHalf ? 0.5 : double.infinity);
    } else if (key == LogicalKeyboardKey.space) {
      _player.togglePlayPause();
    } else if (key == LogicalKeyboardKey.keyR) {
      _player.play();
    } else if (key == LogicalKeyboardKey.keyP) {
      _pack = (_pack + 1) % _packs.length;
      _load();
    } else {
      return KeyEventResult.ignored;
    }
    setState(() {});
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _num(double? v, [int digits = 2]) =>
      v == null ? '—' : (v.isInfinite ? '∞' : v.toStringAsFixed(digits));

  List<String> _status() {
    final p = _player;
    final fade = p.trackFadeProgress(0);
    return <String>[
      'pack           ${_packs[_pack].split('/').last}',
      '',
      'TRACK 0',
      'current        ${p.currentAnimation ?? '—'}',
      'main source    ${p.trackMainSource(0) ?? '—'}',
      'frame          ${_num(p.frameNo, 1)}  (${p.startFrame}..${p.endFrame})',
      'speed          ${_num(p.trackSpeed(0))}',
      'loop count     ${p.trackLoopCount(0) ?? '—'}',
      'playing        ${p.isPlaying}${p.isPausing ? ' (paused)' : ''}',
      'finished       ${p.isFinished}',
      'fade           ${fade == null ? '—' : _num(fade)}',
      'alpha          ${_num(p.trackAlpha(0))}',
      'sync           ${p.trackSync(0)?.name ?? '—'}',
      'outgoing fires ${_num(p.trackOutgoingEventThreshold(0))}',
      '',
      'TRACK 1',
      'animation      ${_overlay < 0 ? '—' : _names[_overlay]}',
      'alpha / blend  ${_num(p.trackAlpha(1))} / ${p.trackBlend(1)?.name ?? '—'}',
      'frame          ${_num(p.trackFrame(1), 1)}',
      'speed          ${_num(p.trackSpeed(1))}',
      'loop count     ${p.trackLoopCount(1) ?? '—'}',
      'finished       ${p.isTrackFinished(1)}',
      '',
      'tracks         ${p.trackCount}',
      '',
      'EVENTS (newest first)',
      ..._events,
    ];
  }

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3);
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ColoredBox(
                color: const Color(0xFF2B2B2B),
                child: SpriteStudioView(player: _player),
              ),
            ),
            SizedBox(
              width: 360,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: ListenableBuilder(
                  listenable: _player,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_status().join('\n'), style: mono),
                      const Divider(),
                      for (final (key, what) in _keys)
                        Text('${key.padRight(7)} $what', style: mono),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
