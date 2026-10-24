import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../player.dart';
import '../render/sprite_studio_view.dart';
import 'ui_state.dart';

/// A [SpriteStudioView] that shows the state of the button it sits in.
///
/// Give it the [statesController] the host button takes — `InkWell` and every
/// `ButtonStyleButton` accept one — and it plays the section each state calls
/// for, as [SsUiStateDriver] describes: `hovered`, `pressed`, `disabled` and
/// `focused` map to [SsUiState.hover], [SsUiState.pressed],
/// [SsUiState.disabled] and [SsUiState.focused], one at a time in that order of
/// precedence, and none of them to [SsUiState.normal].
///
/// The button keeps its role, its gestures and its focus; this only draws. To
/// make it take taps on its artwork only, wrap the button in a
/// [SpriteStudioHitRegion].
///
/// ```dart
/// final states = WidgetStatesController();
///
/// InkWell(
///   statesController: states,
///   onTap: _start,
///   child: SpriteStudioStateView(
///     player: _player,
///     statesController: states,
///     semanticLabel: 'Start',
///   ),
/// )
/// ```
///
/// It takes [player]'s playback over while it is mounted.
class SpriteStudioStateView extends StatefulWidget {
  const SpriteStudioStateView({
    super.key,
    required this.player,
    required this.statesController,
    this.animation,
    this.clips = const {},
    this.reducedMotion,
    this.semanticLabel,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.frame,
  });

  final SpriteStudioPlayer player;

  /// The states of the button, shared with it.
  final WidgetStatesController statesController;

  /// See [SsUiStateDriver.animation].
  final String? animation;

  /// See [SsUiStateDriver.clips].
  final Map<SsUiState, SsUiClip> clips;

  /// Whether to hold still. Null follows [MediaQuery.disableAnimationsOf].
  final bool? reducedMotion;

  /// A label for screen readers, read as an image's would be — as
  /// [Image.semanticLabel] is. Null leaves the drawing out of the semantics
  /// tree, as decoration.
  final String? semanticLabel;

  /// See [SpriteStudioView.width].
  final double? width;

  /// See [SpriteStudioView.height].
  final double? height;

  /// See [SpriteStudioView.fit].
  final BoxFit fit;

  /// See [SpriteStudioView.alignment].
  final AlignmentGeometry alignment;

  /// See [SpriteStudioView.frame].
  final Rect? frame;

  @override
  State<SpriteStudioStateView> createState() => _SpriteStudioStateViewState();
}

class _SpriteStudioStateViewState extends State<SpriteStudioStateView> {
  late SsUiStateDriver _driver = _newDriver();
  bool _reduced = false;
  bool _scheduled = false;

  SsUiStateDriver _newDriver() => SsUiStateDriver(
    widget.player,
    animation: widget.animation,
    clips: widget.clips,
  );

  @override
  void initState() {
    super.initState();
    widget.statesController.addListener(_request);
    widget.player.addListener(_request);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced =
        widget.reducedMotion ??
        MediaQuery.maybeDisableAnimationsOf(context) ??
        false;
    _request();
  }

  @override
  void didUpdateWidget(SpriteStudioStateView old) {
    super.didUpdateWidget(old);
    if (old.statesController != widget.statesController) {
      old.statesController.removeListener(_request);
      widget.statesController.addListener(_request);
    }
    if (old.player != widget.player) {
      old.player.removeListener(_request);
      widget.player.addListener(_request);
    }
    if (old.player != widget.player ||
        old.animation != widget.animation ||
        !mapEquals(old.clips, widget.clips)) {
      _driver = _newDriver();
    }
    _reduced =
        widget.reducedMotion ??
        MediaQuery.maybeDisableAnimationsOf(context) ??
        false;
    _request();
  }

  @override
  void dispose() {
    widget.statesController.removeListener(_request);
    widget.player.removeListener(_request);
    super.dispose();
  }

  // A change that arrives while the tree builds — a button writing `disabled`
  // from its own initState, a MediaQuery change — waits for the frame to end:
  // the player notifies its listeners, and one of the host's rebuilding then
  // would throw.
  void _request() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      _show();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _show();
    });
  }

  void _show() {
    final states = widget.statesController.value;
    _driver.show(
      SsUiState.of(
        disabled: states.contains(WidgetState.disabled),
        pressed: states.contains(WidgetState.pressed),
        hovered: states.contains(WidgetState.hovered),
        focused: states.contains(WidgetState.focused),
      ),
      reducedMotion: _reduced,
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = SpriteStudioView(
      player: widget.player,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      frame: widget.frame,
    );
    final label = widget.semanticLabel;
    if (label == null) return view;
    return Semantics(image: true, label: label, child: view);
  }
}
