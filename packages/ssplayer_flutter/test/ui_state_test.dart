// The UI state rule, with no runtime: which state wins, which section each
// plays, where a state without a label falls back to, and what reduced motion
// holds. The label tables come from a synthetic `.ssab`, since no example pack
// names its labels after the states.
//
//   flutter test test/ui_state_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/ssab_info.dart' show labelTableOf;
import 'package:ssplayer_flutter/src/ui/ui_state.dart';

import 'support/ssab_builders.g.dart' as ssab;

ssab.AnimationDataObjectBuilder _anim(
  String name,
  int endFrame,
  Map<String, int> labels,
) => ssab.AnimationDataObjectBuilder(
  name: name,
  startFrame: 0,
  endFrame: endFrame,
  labels: [
    for (final e in labels.entries)
      ssab.LabelObjectBuilder(name: e.key, time: e.value),
  ],
);

final _info = SsAnimeInfo(
  ssab.SsAnimeBinaryObjectBuilder(
    name: 'pack',
    animations: [
      _anim('button', 99, {
        'normal': 0,
        'hover': 20,
        'pressed': 40,
        'disabled': 60,
        'reduced_motion': 80,
      }),
      _anim('only_normal', 49, {'normal': 10, 'other': 30}),
      _anim('with_hover', 49, {'normal': 0, 'hover': 25}),
      _anim('plain', 29, {}),
      _anim('glow', 39, {'calm': 5}),
      _anim('calm_only', 59, {'pressed': 20, 'reduced_motion': 40}),
    ],
  ).toBytes(),
);

SsUiSection? _resolve(
  SsUiState state,
  String animation, {
  Map<SsUiState, SsUiClip> clips = const {},
  bool reducedMotion = false,
  List<String>? missing,
}) => resolveUiSection(
  state,
  animation: animation,
  tableOf: (name) => labelTableOf(_info, name),
  clips: clips,
  reducedMotion: reducedMotion,
  onMissingClip: (s, c) => missing?.add('${s.name}:$c'),
);

(String, int, int, bool)? _flat(SsUiSection? s) =>
    s == null ? null : (s.animation, s.startFrame, s.endFrame, s.hold);

void main() {
  test('one state wins: disabled, pressed, hover, focused, normal', () {
    expect(
      SsUiState.of(disabled: true, pressed: true, hovered: true, focused: true),
      SsUiState.disabled,
    );
    expect(
      SsUiState.of(pressed: true, hovered: true, focused: true),
      SsUiState.pressed,
    );
    expect(SsUiState.of(hovered: true, focused: true), SsUiState.hover);
    expect(SsUiState.of(focused: true), SsUiState.focused);
    expect(SsUiState.of(), SsUiState.normal);
  });

  test('each state runs from its label to the frame before the next', () {
    expect(_flat(_resolve(SsUiState.normal, 'button')), (
      'button',
      0,
      19,
      false,
    ));
    expect(_flat(_resolve(SsUiState.hover, 'button')), (
      'button',
      20,
      39,
      false,
    ));
    expect(_flat(_resolve(SsUiState.pressed, 'button')), (
      'button',
      40,
      59,
      false,
    ));
    expect(_flat(_resolve(SsUiState.disabled, 'button')), (
      'button',
      60,
      79,
      false,
    ));
    // The last label runs to the end of the animation.
    expect(_flat(_resolve(SsUiState.normal, 'with_hover')), (
      'with_hover',
      0,
      24,
      false,
    ));
    expect(_flat(_resolve(SsUiState.hover, 'with_hover')), (
      'with_hover',
      25,
      49,
      false,
    ));
  });

  test('a state without a label falls back', () {
    // hover, focused and disabled to normal; pressed to hover, then normal.
    for (final s in [
      SsUiState.hover,
      SsUiState.focused,
      SsUiState.disabled,
      SsUiState.pressed,
    ]) {
      expect(_flat(_resolve(s, 'only_normal')), (
        'only_normal',
        10,
        29,
        false,
      ), reason: s.name);
    }
    expect(_flat(_resolve(SsUiState.pressed, 'with_hover')), (
      'with_hover',
      25,
      49,
      false,
    ));
    expect(_flat(_resolve(SsUiState.focused, 'button')), (
      'button',
      0,
      19,
      false,
    ));
  });

  test('with no normal either, the whole animation', () {
    expect(_flat(_resolve(SsUiState.hover, 'plain')), ('plain', 0, 29, false));
  });

  test('labels match exactly', () {
    final info = SsAnimeInfo(
      ssab.SsAnimeBinaryObjectBuilder(
        animations: [
          _anim('caps', 9, {'Normal': 0, 'HOVER': 5}),
        ],
      ).toBytes(),
    );
    final s = resolveUiSection(
      SsUiState.hover,
      animation: 'caps',
      tableOf: (n) => labelTableOf(info, n),
    );
    expect(_flat(s), ('caps', 0, 9, false));
  });

  test('a clip replaces a state, and the states that fall back to it', () {
    final clips = {
      SsUiState.hover: const SsUiClip(animation: 'glow'),
      SsUiState.disabled: const SsUiClip(label: 'reduced_motion'),
      SsUiState.focused: const SsUiClip(animation: 'glow', label: 'calm'),
    };
    expect(_flat(_resolve(SsUiState.hover, 'only_normal', clips: clips)), (
      'glow',
      0,
      39,
      false,
    ));
    // pressed has no label in only_normal, so it takes hover's clip.
    expect(_flat(_resolve(SsUiState.pressed, 'only_normal', clips: clips)), (
      'glow',
      0,
      39,
      false,
    ));
    expect(_flat(_resolve(SsUiState.disabled, 'button', clips: clips)), (
      'button',
      80,
      99,
      false,
    ));
    expect(_flat(_resolve(SsUiState.focused, 'button', clips: clips)), (
      'glow',
      5,
      39,
      false,
    ));
  });

  test('a clip the pack lacks is reported, and the label plays', () {
    final missing = <String>[];
    final s = _resolve(
      SsUiState.hover,
      'button',
      clips: {SsUiState.hover: const SsUiClip(animation: 'nope')},
      missing: missing,
    );
    expect(_flat(s), ('button', 20, 39, false), reason: 'hover');
    expect(missing, hasLength(1));
  });

  test('an animation the pack lacks has no section', () {
    expect(_resolve(SsUiState.normal, 'nope'), isNull);
  });

  group('reduced motion', () {
    test('holds the section of every state but normal', () {
      expect(_flat(_resolve(SsUiState.hover, 'button', reducedMotion: true)), (
        'button',
        20,
        39,
        true,
      ));
      expect(
        _flat(_resolve(SsUiState.disabled, 'button', reducedMotion: true)),
        ('button', 60, 79, true),
      );
    });

    test('plays reduced_motion in place of normal, where there is one', () {
      expect(_flat(_resolve(SsUiState.normal, 'button', reducedMotion: true)), (
        'button',
        80,
        99,
        false,
      ));
      // focused falls back to normal, so it plays the calm loop too.
      expect(
        _flat(_resolve(SsUiState.focused, 'button', reducedMotion: true)),
        ('button', 80, 99, false),
      );
    });

    test('plays reduced_motion where normal falls back to the whole animation',
        () {
      expect(
        _flat(_resolve(SsUiState.normal, 'calm_only', reducedMotion: true)),
        ('calm_only', 40, 59, false),
      );
      expect(
        _flat(_resolve(SsUiState.hover, 'calm_only', reducedMotion: true)),
        ('calm_only', 40, 59, false),
      );
      // A state with a label of its own still holds it.
      expect(
        _flat(_resolve(SsUiState.pressed, 'calm_only', reducedMotion: true)),
        ('calm_only', 20, 39, true),
      );
    });

    test('holds normal where there is none', () {
      expect(
        _flat(_resolve(SsUiState.normal, 'only_normal', reducedMotion: true)),
        ('only_normal', 10, 29, true),
      );
      expect(_flat(_resolve(SsUiState.normal, 'plain', reducedMotion: true)), (
        'plain',
        0,
        29,
        true,
      ));
    });
  });
}
