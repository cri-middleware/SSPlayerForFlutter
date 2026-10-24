import 'package:flutter/foundation.dart' show debugPrint;

import '../player.dart';
import '../ssab_info.dart';

/// A state a SpriteStudio button shows. By default each plays from the label of
/// the same name in one animation, up to the frame before the next label.
///
/// Depends on no widget, so an adapter outside the widget tree can drive it
/// too.
enum SsUiState {
  normal,
  hover,
  pressed,
  disabled,
  focused;

  /// The one state to show when several hold at once: [disabled] over
  /// [pressed] over [hover] over [focused], and [normal] when none does.
  static SsUiState of({
    bool disabled = false,
    bool pressed = false,
    bool hovered = false,
    bool focused = false,
  }) {
    if (disabled) return SsUiState.disabled;
    if (pressed) return SsUiState.pressed;
    if (hovered) return SsUiState.hover;
    if (focused) return SsUiState.focused;
    return SsUiState.normal;
  }

  /// This state, then the states it falls back to when the animation has no
  /// label for it.
  List<SsUiState> get _chain => switch (this) {
    normal => const [normal],
    hover => const [hover, normal],
    pressed => const [pressed, hover, normal],
    disabled => const [disabled, normal],
    focused => const [focused, normal],
  };
}

/// What a state plays instead of the label named after it: the section of
/// [animation] that starts at [label].
///
/// With only [animation], the whole of it. With only [label], that label in the
/// animation the states are read from. A section runs to the frame before the
/// next label, or to the end of the animation.
class SsUiClip {
  const SsUiClip({this.animation, this.label})
    : assert(
        animation != null || label != null,
        'name an animation, a label, or both',
      );

  final String? animation;
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is SsUiClip && other.animation == animation && other.label == label;

  @override
  int get hashCode => Object.hash(animation, label);

  @override
  String toString() => 'SsUiClip(animation: $animation, label: $label)';
}

/// The label a calm loop plays from under reduced motion, in place of
/// [SsUiState.normal].
const String ssReducedMotionLabel = 'reduced_motion';

/// A section a state plays, and whether to hold its first frame rather than
/// play it.
typedef SsUiSection = ({
  String animation,
  int startFrame,
  int endFrame,
  bool hold,
});

/// The section starting at [label] in [table]: to the frame before the next
/// label, or to the end of the animation. Null when the table has no [label].
({int startFrame, int endFrame})? labelSectionOf(
  SsLabelTable table,
  String label,
) {
  final start = table.frameOf(label);
  if (start == null) return null;
  for (final l in table.labels) {
    if (l.frame > start) return (startFrame: start, endFrame: l.frame - 1);
  }
  return (startFrame: start, endFrame: table.endFrame);
}

/// The section [state] plays in [animation]: the first of its chain that has a
/// clip in [clips] or a label of its own name, or else the whole animation.
/// Null when [tableOf] knows no [animation].
///
/// Under [reducedMotion] the section is held, except where it came from
/// [SsUiState.normal] and [animation] has a `reduced_motion` label: that
/// label's section plays instead.
///
/// A clip that names an animation or a label the pack does not have is handed
/// to [onMissingClip], and the state goes on as if it had none.
///
/// Not exported: [SsUiStateDriver] is the public face.
SsUiSection? resolveUiSection(
  SsUiState state, {
  required String animation,
  required SsLabelTable? Function(String animation) tableOf,
  Map<SsUiState, SsUiClip> clips = const {},
  bool reducedMotion = false,
  void Function(SsUiState state, SsUiClip clip)? onMissingClip,
}) {
  final base = tableOf(animation);
  if (base == null) return null;
  var name = animation;
  ({int startFrame, int endFrame})? range;
  SsUiState? source;
  for (final s in state._chain) {
    final clip = clips[s];
    if (clip != null) {
      final clipName = clip.animation ?? animation;
      final table = clipName == animation ? base : tableOf(clipName);
      final label = clip.label;
      range = table == null
          ? null
          : label == null
          ? (startFrame: table.startFrame, endFrame: table.endFrame)
          : labelSectionOf(table, label);
      if (range != null) {
        name = clipName;
        source = s;
        break;
      }
      onMissingClip?.call(s, clip);
    }
    range = labelSectionOf(base, s.name);
    if (range != null) {
      source = s;
      break;
    }
  }
  range ??= (startFrame: base.startFrame, endFrame: base.endFrame);
  if (reducedMotion && source == SsUiState.normal) {
    final calm = labelSectionOf(base, ssReducedMotionLabel);
    if (calm != null) {
      return (
        animation: animation,
        startFrame: calm.startFrame,
        endFrame: calm.endFrame,
        hold: false,
      );
    }
  }
  return (
    animation: name,
    startFrame: range.startFrame,
    endFrame: range.endFrame,
    hold: reducedMotion,
  );
}

/// Plays the section a [SsUiState] calls for on a [player] the host owns.
///
/// [show] switches at once and plays the new section from its first frame,
/// looping; the section that was playing is dropped. Under reduced motion it
/// holds the section's first frame instead, so no event fires, except that
/// [SsUiState.normal] plays the `reduced_motion` label's section when the
/// animation has one.
///
/// It takes the player's playback over: it selects animations, sets sections
/// and the loop count, and plays and stops.
class SsUiStateDriver {
  SsUiStateDriver(this.player, {this.animation, this.clips = const {}});

  final SpriteStudioPlayer player;

  /// The animation the states' labels are read from. When null, the one the
  /// player has selected the first time a state is shown, or else the pack's
  /// first.
  final String? animation;

  /// Per-state replacements for the labels named after the states.
  final Map<SsUiState, SsUiClip> clips;

  String? _base;
  Object? _shownOn;
  SsUiState? _state;
  bool _reduced = false;
  final Set<String> _reported = <String>{};

  /// The state last shown, or null before one has been.
  SsUiState? get state => _state;

  /// Shows [state] — or nothing before the player has loaded a pack.
  ///
  /// Showing the state already shown, with the same [reducedMotion], does
  /// nothing until the player loads another pack; then it shows it again.
  void show(SsUiState state, {bool reducedMotion = false}) {
    final internal = player.internal;
    final info = animeInfoOf(player);
    if (internal == null || info == null) return;
    if (identical(internal, _shownOn) &&
        state == _state &&
        reducedMotion == _reduced) {
      return;
    }
    _shownOn = internal;
    _state = state;
    _reduced = reducedMotion;

    final names = player.animationNames;
    final base = _base != null && names.contains(_base)
        ? _base!
        : (animation ?? player.currentAnimation ?? names.firstOrNull);
    if (base == null) return;
    _base = base;

    final section = resolveUiSection(
      state,
      animation: base,
      tableOf: (name) => labelTableOf(info, name),
      clips: clips,
      reducedMotion: reducedMotion,
      onMissingClip: _reportMissingClip,
    );
    if (section == null) {
      // The pack has no [base]; selecting it is what reports that.
      player.setAnimation(base);
      return;
    }
    if (!player.setAnimation(section.animation)) return;
    player.setAnimationSection(section.startFrame, section.endFrame);
    if (section.hold) {
      player.stop();
    } else {
      player.loopCount = -1;
      player.play();
    }
  }

  void _reportMissingClip(SsUiState state, SsUiClip clip) {
    if (!_reported.add('${state.name}|${clip.animation}|${clip.label}')) {
      return;
    }
    final what = [
      if (clip.animation != null) 'animation "${clip.animation}"',
      if (clip.label != null) 'label "${clip.label}"',
    ].join(' with ');
    debugPrint(
      'SsUiStateDriver: the clip for ${state.name} names $what, '
      'which the loaded pack does not have, so it plays as if it had none.',
    );
  }
}
