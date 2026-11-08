import 'dart:ui' show Offset;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:ssplayer_flutter/ui.dart';

import 'sprite_studio_component.dart';

/// A [SpriteStudioComponent] that is a button: one animation shows its
/// states, as `SpriteStudioStateView` does for a Flutter button.
///
/// A tap and a hover set the state, and [isDisabled] and [isFocused] are the
/// game's to set — Flame has no focus of its own, so a menu driven by a gamepad
/// or the keyboard marks the button it has selected. One state is shown,
/// disabled over pressed over hover over focused, and none of them is
/// [SsUiState.normal]. Each plays from the label of its own name to the frame
/// before the next label, looping, with the fallbacks and the [clips] that
/// [SsUiStateDriver] describes.
///
/// [onPressed] fires as the tap goes down, [onReleased] as it comes up, and
/// [onCancelled] when it is cancelled, as on Flame's `ButtonComponent`. A
/// disabled button fires none of them.
///
/// ```dart
/// add(SpriteStudioButtonComponent.asset(
///   'assets/ui/start.ssab',
///   hitParts: const ['face'],
///   onReleased: _start,
///   position: Vector2(200, 300),
///   size: Vector2(240, 120),
///   anchor: Anchor.center,
/// ));
/// ```
///
/// It takes its player's playback over: the states select the animations and
/// sections and play or hold them.
class SpriteStudioButtonComponent extends SpriteStudioComponent
    with TapCallbacks, HoverCallbacks {
  /// A button on the in-memory `.ssab` [ssab]. See
  /// [SpriteStudioComponent.new].
  SpriteStudioButtonComponent({
    required super.ssab,
    super.animation,
    super.baseAssetDir,
    super.bundle,
    super.subFrame,
    this.clips = const {},
    this.hitParts,
    this.hitOnArtwork = false,
    this.onPressed,
    this.onReleased,
    this.onCancelled,
    bool isDisabled = false,
    bool isFocused = false,
    bool reducedMotion = false,
    super.position,
    super.size,
    super.scale,
    super.angle,
    super.anchor,
    super.priority,
    super.key,
    super.children,
  }) : _isDisabled = isDisabled,
       _isFocused = isFocused,
       _reducedMotion = reducedMotion,
       super(autoStart: false);

  /// A button on a bundled `.ssab`. See [SpriteStudioComponent.asset].
  SpriteStudioButtonComponent.asset(
    super.assetPath, {
    super.animation,
    super.bundle,
    super.subFrame,
    this.clips = const {},
    this.hitParts,
    this.hitOnArtwork = false,
    this.onPressed,
    this.onReleased,
    this.onCancelled,
    bool isDisabled = false,
    bool isFocused = false,
    bool reducedMotion = false,
    super.position,
    super.size,
    super.scale,
    super.angle,
    super.anchor,
    super.priority,
    super.key,
    super.children,
  }) : _isDisabled = isDisabled,
       _isFocused = isFocused,
       _reducedMotion = reducedMotion,
       super.asset(autoStart: false);

  /// Per-state replacements for the labels named after the states. See
  /// [SsUiStateDriver.clips].
  final Map<SsUiState, SsUiClip> clips;

  /// The parts a pointer counts on, within the box ([size]) when it has one.
  /// Null leaves it the whole box, as for any [PositionComponent], unless
  /// [hitOnArtwork] is set.
  ///
  /// The parts are tested by their outlines as drawn
  /// ([SpriteStudioPlayer.hitTestPart]), so taps and hovers around an
  /// irregular button's artwork miss it.
  final List<String>? hitParts;

  /// With no [hitParts], whether a pointer counts on any part the player
  /// draws rather than on the whole box.
  final bool hitOnArtwork;

  /// Fired as a tap goes down on the button.
  void Function()? onPressed;

  /// Fired as a tap on the button comes up.
  void Function()? onReleased;

  /// Fired when a tap on the button is cancelled.
  void Function()? onCancelled;

  /// Whether the button takes no taps, and shows [SsUiState.disabled].
  bool get isDisabled => _isDisabled;
  set isDisabled(bool value) {
    if (value == _isDisabled) return;
    _isDisabled = value;
    if (value) _pressed = false;
    _show();
  }

  bool _isDisabled;

  /// Whether the game's own focus — a menu's selection — is on the button,
  /// which then shows [SsUiState.focused].
  bool get isFocused => _isFocused;
  set isFocused(bool value) {
    if (value == _isFocused) return;
    _isFocused = value;
    _show();
  }

  bool _isFocused;

  /// Whether to hold still: each state holds the first frame of its section,
  /// except where the animation has a `reduced_motion` label for
  /// [SsUiState.normal]. Flame reads no platform setting, so the game passes
  /// its own.
  bool get reducedMotion => _reducedMotion;
  set reducedMotion(bool value) {
    if (value == _reducedMotion) return;
    _reducedMotion = value;
    _show();
  }

  bool _reducedMotion;

  bool _pressed = false;
  SsUiStateDriver? _driver;

  /// The state the button shows.
  SsUiState get uiState => SsUiState.of(
    disabled: _isDisabled,
    pressed: _pressed,
    hovered: isHovered,
    focused: _isFocused,
  );

  @override
  Future<void> loadPlayer() async {
    await super.loadPlayer();
    final player = this.player;
    // A load superseded by a later one also returns here, to the later player.
    if (player == null || identical(player, _driver?.player)) return;
    _driver = SsUiStateDriver(player, animation: animation, clips: clips);
    _show();
  }

  @override
  void onRemove() {
    _driver = null;
    _pressed = false;
    super.onRemove();
  }

  void _show() => _driver?.show(uiState, reducedMotion: _reducedMotion);

  @override
  bool containsLocalPoint(Vector2 point) {
    final parts = hitParts;
    if (parts == null && !hitOnArtwork) return super.containsLocalPoint(point);
    final player = this.player;
    if (player == null) return false;
    final empty = size.x <= 0 || size.y <= 0;
    // The flutter_gpu backend crops the drawing to the box, so a part outside
    // it is not on screen there.
    if (!empty && !super.containsLocalPoint(point)) return false;
    // The animation is drawn about the middle of the box, or about the origin
    // when the box is empty.
    final at = Offset(
      point.x - (empty ? 0 : size.x / 2),
      point.y - (empty ? 0 : size.y / 2),
    );
    return player.hitTestPart(at, parts: parts) >= 0;
  }

  @override
  void onTapDown(TapDownEvent event) {
    if (_isDisabled) return;
    _pressed = true;
    _show();
    onPressed?.call();
  }

  @override
  void onTapUp(TapUpEvent event) {
    if (_isDisabled) return;
    _pressed = false;
    _show();
    onReleased?.call();
  }

  @override
  void onTapCancel(TapCancelEvent event) {
    if (_isDisabled) return;
    _pressed = false;
    _show();
    onCancelled?.call();
  }

  @override
  void onHoverEnter() => _show();

  @override
  void onHoverExit() => _show();

  @override
  void onHoverCancel() => _show();
}
