// SpriteStudio inside Flutter's buttons, checked by eye. A second entry point
// beside main.dart:
//
//   flutter run -t lib/ui_states_check.dart -d macos
//
// Ringo stands in for a button's artwork in two hosts: an InkWell whose hits a
// SpriteStudioHitRegion narrows to the parts picked below, and an
// ElevatedButton, whose padding puts the view off the button's box. Each state
// plays one of Ringo's animations through a clip, since Ringo has no labels
// named after the states. The outlines are the ones the hit test uses.
//
// The third is an ordinary text button with nothing of SpriteStudio in it: a
// particle effect is laid over it where it is clicked, played once, and taken
// away when it finishes. That needs no more than a player and a view.
import 'package:flutter/material.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadSsRuntime();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const UiStatesCheck(),
    ),
  );
}

const _pack = 'assets/spritestudio/Ringo/Ringo.ssab';
const _effectPack = 'assets/spritestudio/ParticleEffect/e023.ssab';
const _effectSize = 160.0;

const _clips = {
  SsUiState.normal: SsUiClip(animation: 'wait1'),
  SsUiState.hover: SsUiClip(animation: 'walk'),
  SsUiState.pressed: SsUiClip(animation: 'attack1'),
  SsUiState.disabled: SsUiClip(animation: 'dead'),
  SsUiState.focused: SsUiClip(animation: 'jump_wait'),
};

/// The choices for the parts the InkWell takes pointers on.
const _hitChoices = <String, List<String>?>{
  'the whole box': [],
  'any part': null,
  'apple': ['apple'],
  'head + body': ['head', 'body'],
};

class UiStatesCheck extends StatefulWidget {
  const UiStatesCheck({super.key});

  @override
  State<UiStatesCheck> createState() => _UiStatesCheckState();
}

class _UiStatesCheckState extends State<UiStatesCheck>
    with TickerProviderStateMixin {
  late final SpriteStudioPlayer _inkPlayer = SpriteStudioPlayer(vsync: this);
  late final SpriteStudioPlayer _buttonPlayer = SpriteStudioPlayer(vsync: this);
  final WidgetStatesController _inkStates = WidgetStatesController();
  final WidgetStatesController _buttonStates = WidgetStatesController();
  late final SpriteStudioPlayer _effectPlayer = SpriteStudioPlayer(vsync: this);
  final GlobalKey _plainButton = GlobalKey();
  Offset? _pointerAt;
  Offset? _effectAt;

  bool _enabled = true;
  bool? _reducedMotion;
  String _hit = 'apple';
  bool _outlines = true;
  final List<String> _taps = <String>[];

  @override
  void initState() {
    super.initState();
    _inkPlayer.loadAsset(_pack, animationName: 'wait1');
    _buttonPlayer.loadAsset(_pack, animationName: 'wait1');
    _effectPlayer
      ..loopCount = 1
      ..onAnimationFinished = (() => setState(() => _effectAt = null))
      ..loadAsset(_effectPack, animationName: 'flashexplosion');
  }

  @override
  void dispose() {
    _inkStates.dispose();
    _buttonStates.dispose();
    _inkPlayer.dispose();
    _buttonPlayer.dispose();
    _effectPlayer.dispose();
    super.dispose();
  }

  void _tapped(String who) => setState(() {
    _taps.insert(0, '$who tapped');
    if (_taps.length > 6) _taps.removeLast();
  });

  // Where the pointer went down, or the middle of the button when a key pressed
  // it. Nothing under reduced motion.
  void _burst() {
    _tapped('Plain button');
    final at =
        _pointerAt ?? _plainButton.currentContext!.size!.center(Offset.zero);
    _pointerAt = null;
    if (_reducedMotion ?? MediaQuery.disableAnimationsOf(context)) return;
    setState(() => _effectAt = at);
    _effectPlayer.play();
  }

  @override
  Widget build(BuildContext context) {
    final parts = _hitChoices[_hit];
    Widget art(
      SpriteStudioPlayer player,
      WidgetStatesController states, {
      List<String>? outlined,
    }) => Stack(
      children: [
        SpriteStudioStateView(
          player: player,
          statesController: states,
          clips: _clips,
          reducedMotion: _reducedMotion,
          semanticLabel: 'Ringo',
          width: 240,
          height: 180,
        ),
        if (_outlines)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _Outlines(player, outlined ?? const []),
              ),
            ),
          ),
      ],
    );

    final ink = InkWell(
      statesController: _inkStates,
      onTap: _enabled ? () => _tapped('InkWell') : null,
      child: art(
        _inkPlayer,
        _inkStates,
        outlined: parts ?? _inkPlayer.partNames.names,
      ),
    );

    // Flows onto as many rows as the window needs, down to the 800x600 the
    // macOS runner opens at.
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 32,
          runSpacing: 24,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _caption(
                  'InkWell, hits narrowed to: $_hit',
                  _inkStates,
                  _inkPlayer,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white24),
                  ),
                  child: parts != null && parts.isEmpty
                      ? ink
                      : SpriteStudioHitRegion(
                          player: _inkPlayer,
                          parts: parts,
                          child: ink,
                        ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _caption(
                  'ElevatedButton, the whole button',
                  _buttonStates,
                  _buttonPlayer,
                ),
                ElevatedButton(
                  statesController: _buttonStates,
                  onPressed: _enabled ? () => _tapped('ElevatedButton') : null,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: art(_buttonPlayer, _buttonStates),
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'A plain ElevatedButton, with an effect on click',
                  ),
                ),
                // The stack is the button's size, so a pointer's position on
                // the button is a position in the stack.
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Listener(
                      onPointerDown: (e) => _pointerAt = e.localPosition,
                      child: ElevatedButton(
                        key: _plainButton,
                        onPressed: _enabled ? _burst : null,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 20,
                          ),
                          child: Text('Tap me'),
                        ),
                      ),
                    ),
                    if (_effectAt case final at?)
                      Positioned(
                        left: at.dx - _effectSize / 2,
                        top: at.dy - _effectSize / 2,
                        child: IgnorePointer(
                          child: SpriteStudioView(
                            player: _effectPlayer,
                            width: _effectSize,
                            height: _effectSize,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            SizedBox(width: 320, child: _controls()),
          ],
        ),
      ),
    );
  }

  // Rebuilt from the player, which the view only drives outside a build: a
  // listener on the states controller would hear the button write `disabled`
  // from its own build, and could not rebuild this page then.
  Widget _caption(
    String title,
    WidgetStatesController states,
    SpriteStudioPlayer player,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ListenableBuilder(
      listenable: player,
      builder: (context, _) => Text(
        '$title\n'
        'states: ${states.value.map((s) => s.name).join(', ')}\n'
        'playing: ${player.currentAnimation} '
        '${player.startFrame}–${player.endFrame}'
        '${player.isPlaying ? '' : ' (held)'}',
      ),
    ),
  );

  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile(
        title: const Text('Enabled'),
        value: _enabled,
        onChanged: (v) => setState(() => _enabled = v),
      ),
      const Text('Reduced motion'),
      const SizedBox(height: 4),
      SegmentedButton<bool?>(
        segments: const [
          ButtonSegment(value: null, label: Text('system')),
          ButtonSegment(value: true, label: Text('on')),
          ButtonSegment(value: false, label: Text('off')),
        ],
        selected: {_reducedMotion},
        onSelectionChanged: (s) => setState(() => _reducedMotion = s.first),
      ),
      const SizedBox(height: 12),
      const Text('InkWell takes pointers on'),
      DropdownButton<String>(
        value: _hit,
        items: [
          for (final k in _hitChoices.keys)
            DropdownMenuItem(value: k, child: Text(k)),
        ],
        onChanged: (v) => setState(() => _hit = v!),
      ),
      SwitchListTile(
        title: const Text('Show the outlines the hit test uses'),
        value: _outlines,
        onChanged: (v) => setState(() => _outlines = v),
      ),
      const Divider(),
      const Text('Tab moves the focus between the buttons.'),
      const SizedBox(height: 8),
      for (final t in _taps) Text(t),
    ],
  );
}

/// The outlines of [parts], drawn over the view they belong to.
class _Outlines extends CustomPainter {
  _Outlines(this.player, this.parts) : super(repaint: player);

  final SpriteStudioPlayer player;
  final List<String> parts;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.cyanAccent;
    canvas.translate(size.width / 2, size.height / 2);
    for (final name in parts) {
      final q = player.partQuad(name);
      if (q == null) continue;
      canvas.drawPath(
        Path()
          ..moveTo(q.leftTop.dx, q.leftTop.dy)
          ..lineTo(q.rightTop.dx, q.rightTop.dy)
          ..lineTo(q.rightBottom.dx, q.rightBottom.dy)
          ..lineTo(q.leftBottom.dx, q.leftBottom.dy)
          ..close(),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_Outlines old) =>
      old.player != player || old.parts != parts;
}
