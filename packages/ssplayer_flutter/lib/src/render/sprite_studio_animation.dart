import 'package:flutter/widgets.dart';

import '../player.dart';
import 'backend/backend_kind.dart';
import 'sprite_studio_view.dart';

/// Layer 4 — an animation you place, with nothing to own.
///
/// [SpriteStudioView] is the adapter: it draws a [SpriteStudioPlayer] that the
/// caller built, loaded, drove and disposed. That is the right shape for a
/// screen that already has a player — one it shares with a
/// [SpriteStudioPartAnchor], swaps animations on from a state machine, or ticks
/// from its own clock. It is the wrong shape for putting one animation on the
/// screen, which took a `StatefulWidget`, a `SingleTickerProviderStateMixin`, an
/// `initState`, an async `_init`, and a `dispose` before anything moved.
///
/// This widget is that boilerplate, once:
///
/// ```dart
/// SpriteStudioAnimation.asset('assets/overall/Basic.ssab')
/// ```
///
/// **It owns the player it builds** — the ticker, the load, and the disposal —
/// and rebuilds it when [assetKey], [bundle] or [backend] change. Reach the
/// player through [onPlayerCreated] when you need the rest of the L3 surface;
/// graduate to [SpriteStudioView] when you want to own its lifetime instead.
///
/// **Every other parameter reaches the player only when it changes.** A call
/// made on the player through [onPlayerCreated] therefore stands until the
/// matching parameter changes, rather than being put back on the next rebuild.
class SpriteStudioAnimation extends StatefulWidget {
  /// Plays [assetKey] from the asset bundle.
  ///
  /// Named rather than unnamed because a pack does not have to come from the
  /// bundle — bytes from a download or a device push go through
  /// [SpriteStudioPlayer.load], and that is what [SpriteStudioView] is for. This
  /// constructor is `Image.asset`'s shape because it does `Image.asset`'s job.
  const SpriteStudioAnimation.asset(
    this.assetKey, {
    super.key,
    this.animation,
    this.width,
    this.height,
    this.loopCount = -1,
    this.playing = true,
    this.speedScale = 1.0,
    this.flipX = false,
    this.flipY = false,
    this.bundle,
    this.backend = SpriteStudioBackend.auto,
    this.placeholder,
    this.onLoaded,
    this.onError,
    this.onPlayerCreated,
  });

  /// The `.ssab`'s key in the asset bundle. Reference textures resolve from the
  /// key's own folder, so the converter's output directory works as it stands.
  final String assetKey;

  /// Which animation to select, or null for **the pack's first**.
  ///
  /// Null is the useful default rather than "select nothing": a pack that has
  /// had no animation set up draws an empty box, which is indistinguishable from
  /// a pack that failed to load. ForGodot and ForReactNative default the same
  /// way. [SpriteStudioPlayer.load] does not — it is the primitive, and a
  /// caller who passes no name there has said so deliberately.
  ///
  /// Changing it switches on the same player, and while [playing] the new
  /// animation starts from its first frame — [SpriteStudioPlayer.setAnimation]
  /// alone selects and poses, which would leave a state-driven switch frozen.
  final String? animation;

  /// Passed to [SpriteStudioView]. Null takes the incoming constraints.
  final double? width;

  /// Passed to [SpriteStudioView]. Null takes the incoming constraints.
  final double? height;

  /// `-1` loops forever, `n > 0` plays n times. Applied before playback starts.
  final int loopCount;

  /// Whether the animation advances. On by default.
  ///
  /// A state, not a start-up flag: turning it off holds the playhead where it
  /// stands, and turning it back on carries on from there. Only a player that is
  /// not running at all heads out from the start — one built with this off,
  /// which leaves the first frame posed the way a `<video>` without `autoplay`
  /// shows a poster, or one whose loops have all played.
  final bool playing;

  /// Playback rate as a multiple of the authored one. See
  /// [SpriteStudioPlayer.speedScale].
  final double speedScale;

  /// Mirrors the drawn animation horizontally. See [SpriteStudioPlayer.flipX].
  final bool flipX;

  /// Mirrors the drawn animation vertically. See [SpriteStudioPlayer.flipY].
  final bool flipY;

  /// Which bundle to read [assetKey] from. Null is `rootBundle`.
  final AssetBundle? bundle;

  /// Which render backend the player draws with.
  final SpriteStudioBackend backend;

  /// Shown until the first frame can be drawn — the pack loaded and its textures
  /// decoded.
  ///
  /// Worth a parameter rather than left to the caller: until the load lands
  /// there is nothing to draw, and an empty box of the right size looks exactly
  /// like a pack that failed. Null draws nothing, which is the honest default
  /// for a load fast enough not to be seen.
  final Widget? placeholder;

  /// Called once the pack is loaded, the animation selected and, while
  /// [playing], playback started — the moment [placeholder] gives way to the
  /// first drawable frame.
  ///
  /// The counterpart of [onError]: between the two, a caller always learns how
  /// the load ended without polling for it.
  final void Function(SpriteStudioPlayer player)? onLoaded;

  /// Called when the load fails, instead of the error reaching the zone as an
  /// unhandled async error. The widget then keeps showing [placeholder].
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Handed the player as soon as it exists, before the load — for the parts of
  /// the L3 surface this widget does not wrap (events, part overrides, an
  /// anchor). Do not dispose it; this widget does.
  ///
  /// Called after the other parameters are applied, so what it sets on the
  /// player stands until the matching parameter changes.
  final void Function(SpriteStudioPlayer player)? onPlayerCreated;

  @override
  State<SpriteStudioAnimation> createState() => _SpriteStudioAnimationState();
}

class _SpriteStudioAnimationState extends State<SpriteStudioAnimation>
    with SingleTickerProviderStateMixin {
  SpriteStudioPlayer? _player;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(SpriteStudioAnimation old) {
    super.didUpdateWidget(old);
    // What the player IS built from. Anything else is applied to the player it
    // already has, so switching animation does not re-read the pack.
    if (old.assetKey != widget.assetKey ||
        old.bundle != widget.bundle ||
        old.backend != widget.backend) {
      _player?.dispose();
      _player = null;
      _ready = false;
      _build();
      return;
    }
    final player = _player;
    if (player == null) return;
    // The player caches these ahead of a load, so they go on at once.
    if (old.loopCount != widget.loopCount) player.loopCount = widget.loopCount;
    if (old.speedScale != widget.speedScale) {
      player.speedScale = widget.speedScale;
    }
    if (old.flipX != widget.flipX) player.flipX = widget.flipX;
    if (old.flipY != widget.flipY) player.flipY = widget.flipY;
    // Selecting and starting need the pack. A change made while it loads is not
    // lost: [_load] reads both off the widget as it stands when the load lands.
    if (!_ready) return;
    if (old.animation != widget.animation) _switch(player);
    if (old.playing != widget.playing) _applyPlaying(player);
  }

  void _build() {
    final player = SpriteStudioPlayer(vsync: this, backend: widget.backend);
    _player = player;
    // Before the load, so the first frame is already drawn with them, and before
    // [onPlayerCreated], so what that sets stands until the parameter changes.
    player
      ..loopCount = widget.loopCount
      ..speedScale = widget.speedScale
      ..flipX = widget.flipX
      ..flipY = widget.flipY;
    widget.onPlayerCreated?.call(player);
    _load(player);
  }

  Future<void> _load(SpriteStudioPlayer player) async {
    try {
      await player.loadAsset(widget.assetKey, bundle: widget.bundle);
    } catch (error, stack) {
      // A superseded load — the key changed while this one was in flight — has
      // already been disposed, and its failure is nobody's business.
      if (!mounted || !identical(_player, player)) return;
      final onError = widget.onError;
      if (onError == null) rethrow;
      onError(error, stack);
      return;
    }
    if (!mounted || !identical(_player, player)) return;
    _select(player);
    if (widget.playing) player.play();
    setState(() => _ready = true);
    widget.onLoaded?.call(player);
  }

  /// The pack's first animation is the default — see
  /// [SpriteStudioAnimation.animation].
  void _select(SpriteStudioPlayer player) {
    final name = widget.animation ??
        (player.animationNames.isEmpty ? null : player.animationNames.first);
    if (name != null) player.setAnimation(name);
  }

  /// Heads out into the new animation only if the selection actually moved:
  /// naming the one already selected — the pack's first, made explicit — must
  /// not rewind it, and a name the pack lacks leaves the old one playing.
  void _switch(SpriteStudioPlayer player) {
    final before = player.currentAnimation;
    _select(player);
    if (widget.playing && player.currentAnimation != before) player.play();
  }

  /// Maps the boolean onto the player's verbs. Off holds in place; on carries
  /// on from a hold, and heads out only when nothing is running at all.
  void _applyPlaying(SpriteStudioPlayer player) {
    if (!widget.playing) {
      player.pause();
    } else if (player.isPlaying) {
      player.resume();
    } else {
      player.play();
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (!_ready || player == null) {
      return widget.placeholder ??
          SizedBox(width: widget.width, height: widget.height);
    }
    return SpriteStudioView(
      player: player,
      width: widget.width,
      height: widget.height,
    );
  }
}
