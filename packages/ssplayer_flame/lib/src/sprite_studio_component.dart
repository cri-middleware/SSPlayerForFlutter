import 'dart:typed_data';
import 'dart:ui' show Canvas, Rect, Size;

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

/// Layer 4 — the Flame drawing adapter (sibling to the Widget-based
/// `SpriteStudioView`).
///
/// A [PositionComponent] that plays a SpriteStudio 7 `.ssab` inside a
/// `FlameGame`. It owns an **externally-clocked** [SpriteStudioPlayer] (L3, no
/// `Ticker`): Flame's game loop drives time — `update(dt)` forwards to
/// [SpriteStudioPlayer.advance] and `render` delegates to the player's single
/// L2 paint path. Because the whole rich L3 surface (transport, events, instance
/// packs, texture loading, live reload) is reused as-is, a Flame game gets the
/// same player as the Widget path — it just supplies the clock.
///
/// The animation is centered inside the component's box (`size`): the world
/// origin lands on the box centre (`size / 2` in local space), exactly like
/// `SpriteStudioView`. With the default zero [size] that is the component's
/// [position]; give it a [size] (and, per Flame convention, `anchor:
/// Anchor.center` if you want [position] to be the centre) to place it in a box.
///
/// ```dart
/// // In your FlameGame.onLoad:
/// final bytes = (await rootBundle.load('assets/hero.ssab'))
///     .buffer.asUint8List();
/// add(SpriteStudioComponent(
///   ssab: bytes,
///   baseAssetDir: 'assets',        // reference textures live next to the .ssab
///   position: Vector2(200, 300),
/// ));
/// // …or straight from a bundled asset key:
/// add(SpriteStudioComponent.asset('assets/hero.ssab', baseAssetDir: 'assets'));
/// ```
class SpriteStudioComponent extends PositionComponent {
  /// Plays the in-memory `.ssab` [ssab].
  SpriteStudioComponent({
    required Uint8List ssab,
    String? animation,
    String? baseAssetDir,
    AssetBundle? bundle,
    int loop = -1,
    double speed = 1.0,
    bool subFrame = true,
    bool autoStart = true,
    SsEventCallback? onEvents,
    VoidCallback? onComplete,
    VoidCallback? onLoop,
    Vector2? position,
    Vector2? size,
    Vector2? scale,
    double? angle,
    Anchor? anchor,
    int? priority,
    ComponentKey? key,
    Iterable<Component>? children,
  }) : this._(
          bytes: ssab,
          animation: animation,
          baseAssetDir: baseAssetDir,
          bundle: bundle,
          loop: loop,
          speed: speed,
          subFrame: subFrame,
          autoStart: autoStart,
          onEvents: onEvents,
          onComplete: onComplete,
          onLoop: onLoop,
          position: position,
          size: size,
          scale: scale,
          angle: angle,
          anchor: anchor,
          priority: priority,
          key: key,
          children: children,
        );

  /// Plays a bundled `.ssab` resolved by asset key in [onLoad] (via [bundle],
  /// else the root bundle). [baseAssetDir] is the folder holding the sibling
  /// reference textures — usually the asset's own directory.
  SpriteStudioComponent.asset(
    String assetPath, {
    String? animation,
    String? baseAssetDir,
    AssetBundle? bundle,
    int loop = -1,
    double speed = 1.0,
    bool subFrame = true,
    bool autoStart = true,
    SsEventCallback? onEvents,
    VoidCallback? onComplete,
    VoidCallback? onLoop,
    Vector2? position,
    Vector2? size,
    Vector2? scale,
    double? angle,
    Anchor? anchor,
    int? priority,
    ComponentKey? key,
    Iterable<Component>? children,
  }) : this._(
          assetPath: assetPath,
          animation: animation,
          baseAssetDir: baseAssetDir,
          bundle: bundle,
          loop: loop,
          speed: speed,
          subFrame: subFrame,
          autoStart: autoStart,
          onEvents: onEvents,
          onComplete: onComplete,
          onLoop: onLoop,
          position: position,
          size: size,
          scale: scale,
          angle: angle,
          anchor: anchor,
          priority: priority,
          key: key,
          children: children,
        );

  SpriteStudioComponent._({
    Uint8List? bytes,
    String? assetPath,
    this.animation,
    this.baseAssetDir,
    this.bundle,
    this.loop = -1,
    this.speed = 1.0,
    this.subFrame = true,
    this.autoStart = true,
    this.onEvents,
    this.onComplete,
    this.onLoop,
    super.position,
    super.size,
    super.scale,
    super.angle,
    super.anchor,
    super.priority,
    super.key,
    super.children,
  })  : _bytes = bytes,
        _assetPath = assetPath;

  final Uint8List? _bytes;
  final String? _assetPath;

  /// Animation to select on load; when null the pack's first animation plays.
  final String? animation;

  /// Folder holding the sibling reference textures (design §16C); null for
  /// embedded-texture packs. Mirrors [SpriteStudioPlayer.load].
  final String? baseAssetDir;

  /// Bundle the `.ssab` (and, for [SpriteStudioComponent.asset], the asset key)
  /// resolve against; the root bundle when null.
  final AssetBundle? bundle;

  /// Loop count applied on load: `n > 0` plays n times, `-1` (default) forever.
  final int loop;

  /// Playback speed applied on load.
  final double speed;

  /// Sub-frame interpolation applied on load (default on).
  final bool subFrame;

  /// Whether to [SpriteStudioPlayer.play] as soon as the resource is loaded.
  /// When false, drive playback yourself via [player].
  final bool autoStart;

  /// Forwarded to [SpriteStudioPlayer.onEvents].
  final SsEventCallback? onEvents;

  /// Forwarded to [SpriteStudioPlayer.onComplete].
  final VoidCallback? onComplete;

  /// Forwarded to [SpriteStudioPlayer.onLoop].
  final VoidCallback? onLoop;

  SpriteStudioPlayer? _player;

  /// The underlying player — null until [onLoad] completes, then the full L3
  /// transport surface (`pause`, `seek`, `setupAnimation`, `getAnimations`, …).
  /// The clock is Flame's, so do NOT expect a Ticker; state still lives here.
  SpriteStudioPlayer? get player => _player;

  @override
  Future<void> onLoad() async {
    final player = SpriteStudioPlayer() // no vsync → Flame drives the clock
      ..onEvents = onEvents
      ..onComplete = onComplete
      ..onLoop = onLoop;

    final bytes = _bytes ?? await _resolveBytes();
    await player.load(
      bytes,
      animationName: animation,
      baseAssetDir: baseAssetDir,
      bundle: bundle,
    );

    // The component may have been removed while we awaited the fetch/decode.
    if (isRemoving || isRemoved) {
      player.dispose();
      return;
    }

    // load() only selects an animation when one is named; default to the first
    // so something plays out of the box (mirrors the Widget example).
    if (animation == null) {
      final names = player.getAnimations();
      if (names.isNotEmpty) player.setupAnimation(names.first);
    }
    // Apply transport AFTER the animation is set up: `setupAnimation` rewinds
    // and resets the Brain's loop/speed, so setting these earlier (or via
    // `load`) would be clobbered and `loop` would silently fall back to
    // infinite. subFrame is Body-side (safe either way; set here for symmetry).
    player
      ..loop = loop
      ..speed = speed
      ..subFrame = subFrame;
    if (autoStart) player.play();
    _player = player;
  }

  Future<Uint8List> _resolveBytes() async {
    final data = await (bundle ?? rootBundle).load(_assetPath!);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  @override
  void update(double dt) {
    // Flame hands `dt` in seconds; L3 wants a Duration. Microsecond rounding is
    // well below one 60fps frame, so no visible drift.
    _player?.advance(
        Duration(microseconds: (dt * Duration.microsecondsPerSecond).round()));
  }

  @override
  void render(Canvas canvas) {
    // The canvas is already in this component's local space (Flame applied the
    // position/anchor/scale/angle transform). L2 owns its own save/restore and
    // centers the animation on the box centre, so hand it the local box.
    _player?.paint(canvas,
        dst: Rect.fromLTWH(0, 0, size.x, size.y),
        sourceSize: Size(size.x, size.y));
  }

  @override
  void onRemove() {
    _player?.dispose();
    _player = null;
    super.onRemove();
  }
}
