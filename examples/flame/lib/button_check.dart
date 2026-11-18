// SpriteStudioButtonComponent, checked by eye. A second entry point beside
// main.dart:
//
//   bash scripts/setup-macos.sh   # once, for the macOS runner
//   flutter run -t lib/button_check.dart -d macos
//
// Three Ringo buttons, scaled down, that take a pointer on the whole box, on
// any part, and on the apple only; the outlines are the ones the hit test uses.
// Each state plays one of Ringo's animations through a clip, since Ringo has no
// labels named after the states. The panel sets what the game owns: disabled,
// its own focus, and reduced motion.

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ssplayer_flame/ssplayer_flame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadSsRuntime();
  runApp(const ButtonCheckApp());
}

const _clips = {
  SsUiState.normal: SsUiClip(animation: 'wait1'),
  SsUiState.hover: SsUiClip(animation: 'walk'),
  SsUiState.pressed: SsUiClip(animation: 'attack1'),
  SsUiState.disabled: SsUiClip(animation: 'dead'),
  SsUiState.focused: SsUiClip(animation: 'jump_wait'),
};

class ButtonCheckApp extends StatefulWidget {
  const ButtonCheckApp({super.key});

  @override
  State<ButtonCheckApp> createState() => _ButtonCheckAppState();
}

class _ButtonCheckAppState extends State<ButtonCheckApp> {
  late final ButtonCheckGame game = ButtonCheckGame();
  bool _disabled = false;
  bool _focused = false;
  bool _reducedMotion = false;

  void _apply() {
    for (final b in game.buttons) {
      b
        ..isDisabled = _disabled
        ..isFocused = _focused
        ..reducedMotion = _reducedMotion;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      body: Column(
        children: [
          Expanded(child: GameWidget(game: game)),
          Wrap(
            spacing: 16,
            children: [
              for (final (label, value, set) in [
                ('Disabled', _disabled, (bool v) => _disabled = v),
                ('Focused (the game\'s)', _focused, (bool v) => _focused = v),
                (
                  'Reduced motion',
                  _reducedMotion,
                  (bool v) => _reducedMotion = v,
                ),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: value,
                      onChanged: (v) => setState(() {
                        set(v);
                        _apply();
                      }),
                    ),
                    Text(label),
                  ],
                ),
            ],
          ),
          ValueListenableBuilder(
            valueListenable: game.log,
            builder: (context, log, _) => Text(log.join('   ')),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class ButtonCheckGame extends FlameGame {
  final List<SpriteStudioButtonComponent> buttons = [];

  /// The latest button callbacks, newest first.
  final ValueNotifier<List<String>> log = ValueNotifier(const []);

  void _note(String what) => log.value = [what, ...log.value.take(3)];

  @override
  Future<void> onLoad() async {
    const hits = <(String, List<String>?, bool)>[
      ('whole box', null, false),
      ('any part', null, true),
      ('apple', ['apple'], false),
    ];
    for (final (i, (label, parts, artwork)) in hits.indexed) {
      final button = SpriteStudioButtonComponent.asset(
        'assets/spritestudio/Ringo/Ringo.ssab',
        clips: _clips,
        hitParts: parts,
        hitOnArtwork: artwork,
        onPressed: () => _note('$label: pressed'),
        onReleased: () => _note('$label: released'),
        onCancelled: () => _note('$label: cancelled'),
        // Ringo stands on its origin, which goes in the middle of the box, so
        // the box reaches a full Ringo above it.
        size: Vector2(500, 1100),
        scale: Vector2.all(0.4),
        anchor: Anchor.center,
        position: Vector2(130 + 220.0 * i, 250),
        children: [
          _Outlines(parts, everyPart: artwork),
          _StateText(label),
        ],
      );
      buttons.add(button);
      add(button);
    }
  }

  @override
  void onDispose() {
    dispose();
    super.onDispose();
  }
}

/// The outlines the parent button's hit test uses.
class _Outlines extends Component with ParentIsA<SpriteStudioButtonComponent> {
  _Outlines(this.parts, {required this.everyPart});

  final List<String>? parts;
  final bool everyPart;
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..color = Colors.cyanAccent;

  @override
  void render(Canvas canvas) {
    final player = parent.player;
    if (player == null) return;
    if (parts == null && !everyPart) {
      canvas.drawRect(Offset.zero & parent.size.toSize(), _stroke);
      return;
    }
    canvas.save();
    canvas.translate(parent.size.x / 2, parent.size.y / 2);
    for (final name in parts ?? player.partNames.names) {
      final q = player.partQuad(name);
      if (q == null) continue;
      canvas.drawPath(
        Path()
          ..moveTo(q.leftTop.dx, q.leftTop.dy)
          ..lineTo(q.rightTop.dx, q.rightTop.dy)
          ..lineTo(q.rightBottom.dx, q.rightBottom.dy)
          ..lineTo(q.leftBottom.dx, q.leftBottom.dy)
          ..close(),
        _stroke,
      );
    }
    canvas.restore();
  }
}

/// The parent button's state, under it.
class _StateText extends TextComponent
    with ParentIsA<SpriteStudioButtonComponent> {
  _StateText(this.label)
    : super(
        textRenderer: TextPaint(
          style: const TextStyle(fontSize: 40, color: Colors.white),
        ),
      );

  final String label;

  @override
  void onMount() {
    super.onMount();
    position = Vector2(20, parent.size.y / 2 + 40);
  }

  @override
  void update(double dt) {
    final player = parent.player;
    text =
        '$label\n${parent.uiState.name}\n'
        '${player?.currentAnimation ?? '…'}'
        '${player == null || player.isPlaying ? '' : ' (held)'}';
  }
}
