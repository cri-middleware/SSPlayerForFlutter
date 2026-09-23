import 'dart:typed_data';
import 'dart:ui' show Canvas, Offset, Rect;

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter/services.dart' show AssetBundle;
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

/// Layer 4 — the Flame drawing adapter (sibling to the Widget-based
/// `SpriteStudioView`).
///
/// A [PositionComponent] that plays a SpriteStudio `.ssab` inside a
/// `FlameGame`. It owns an **externally-clocked** [SpriteStudioPlayer] (L3, no
/// `Ticker`): Flame's game loopCount drives time — `update(dt)` forwards to
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
/// That box is also the frame on the flutter_gpu backend, which renders into an
/// offscreen its size and crops whatever falls outside — so an explicit [size]
/// wants to fit the art, not just position it. A SpriteStudio origin can sit
/// anywhere inside the authored canvas and the origin is what gets centred, so
/// the canvas size alone may not be enough; [render]'s zero-size fallback uses
/// 2x per axis for exactly that reason, and is a reasonable starting point for a
/// size you set yourself. The Canvas backend draws unbounded and never shows
/// this, which is why it is worth getting right rather than discovering on a
/// backend switch.
///
/// ```dart
/// // In your FlameGame.onLoad — straight from a bundled asset key; sibling
/// // reference textures resolve from the key's own folder:
/// add(SpriteStudioComponent.asset('assets/hero.ssab'));
/// // …or from in-memory bytes (network, device push): pass baseAssetDir for
/// // reference textures, since there is no key to derive it from.
/// final bytes = (await rootBundle.load('assets/hero.ssab'))
///     .buffer.asUint8List();
/// add(SpriteStudioComponent(
///   ssab: bytes,
///   baseAssetDir: 'assets',
///   position: Vector2(200, 300),
/// ));
/// ```
class SpriteStudioComponent extends PositionComponent {
  /// Plays the in-memory `.ssab` [ssab].
  SpriteStudioComponent({
    required Uint8List ssab,
    String? animation,
    String? baseAssetDir,
    AssetBundle? bundle,
    int loopCount = -1,
    double speed = 1.0,
    bool subFrame = true,
    bool autoStart = true,
    SsEventCallback? onEvents,
    VoidCallback? onAnimationStarted,
    VoidCallback? onAnimationFinished,
    VoidCallback? onAnimationLooped,
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
          loopCount: loopCount,
          speedScale: speed,
          subFrameEnabled: subFrame,
          autoStart: autoStart,
          onEvents: onEvents,
          onAnimationStarted: onAnimationStarted,
          onAnimationFinished: onAnimationFinished,
          onAnimationLooped: onAnimationLooped,
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
  /// else the root bundle). Sibling reference textures and instance packs
  /// resolve from the key's own folder — no `baseAssetDir` needed. For a shared
  /// atlas elsewhere, or bytes with no asset key, use the default ctor.
  SpriteStudioComponent.asset(
    String assetPath, {
    String? animation,
    AssetBundle? bundle,
    int loopCount = -1,
    double speed = 1.0,
    bool subFrame = true,
    bool autoStart = true,
    SsEventCallback? onEvents,
    VoidCallback? onAnimationStarted,
    VoidCallback? onAnimationFinished,
    VoidCallback? onAnimationLooped,
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
          bundle: bundle,
          loopCount: loopCount,
          speedScale: speed,
          subFrameEnabled: subFrame,
          autoStart: autoStart,
          onEvents: onEvents,
          onAnimationStarted: onAnimationStarted,
          onAnimationFinished: onAnimationFinished,
          onAnimationLooped: onAnimationLooped,
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
    this.loopCount = -1,
    this.speedScale = 1.0,
    this.subFrameEnabled = true,
    this.autoStart = true,
    this.onEvents,
    this.onAnimationStarted,
    this.onAnimationFinished,
    this.onAnimationLooped,
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

  /// Folder holding the sibling reference textures for the default
  /// (bytes) ctor; null for embedded-texture packs. Mirrors
  /// [SpriteStudioPlayer.load]. The [SpriteStudioComponent.asset] ctor ignores
  /// this and derives the folder from the asset key.
  final String? baseAssetDir;

  /// Bundle the `.ssab` (and, for [SpriteStudioComponent.asset], the asset key)
  /// resolve against; the root bundle when null.
  final AssetBundle? bundle;

  /// Loop count applied on load: `n > 0` plays n times, `-1` (default) forever.
  final int loopCount;

  /// Playback speed applied on load.
  final double speedScale;

  /// Sub-frame interpolation applied on load (default on).
  final bool subFrameEnabled;

  /// Whether to [SpriteStudioPlayer.play] as soon as the resource is loaded.
  /// When false, drive playback yourself via [player].
  final bool autoStart;

  /// Forwarded to [SpriteStudioPlayer.onEvents].
  final SsEventCallback? onEvents;

  /// Forwarded to [SpriteStudioPlayer.onAnimationStarted].
  final VoidCallback? onAnimationStarted;

  /// Forwarded to [SpriteStudioPlayer.onAnimationFinished].
  final VoidCallback? onAnimationFinished;

  /// Forwarded to [SpriteStudioPlayer.onAnimationLooped].
  final VoidCallback? onAnimationLooped;

  SpriteStudioPlayer? _player;

  /// The underlying player — null until [onLoad] completes, then the full L3
  /// transport surface (`pause`, `seek`, `setAnimation`, `animationNames`, …).
  /// The clock is Flame's, so do NOT expect a Ticker; state still lives here.
  ///
  /// Part overrides are reached the same way — `player!.setPartColorOverride`
  /// and friends, with [SsBlendOp] / [SsOverridePriority] re-exported by this
  /// package. They are deliberately not mirrored onto the component: the Brain
  /// owns the override table, so there is no component-side state to keep in
  /// sync and a passthrough would only be a second name for the same call.
  /// Note they need an animation selected first, which [onLoad] does.
  SpriteStudioPlayer? get player => _player;

  /// Why [onLoad] failed, or null if it did not.
  ///
  /// A load error is captured rather than thrown (see [onLoad]), so this is the
  /// only place it surfaces: [player] stays null and the component renders
  /// nothing. Check it after `add`ing if a missing or malformed `.ssab` is a
  /// case your game needs to react to.
  Object? get loadError => _loadError;
  Object? _loadError;

  /// Builds the player and loads the `.ssab`.
  ///
  /// **Never completes with an error.** Flame chains `onLoad` as
  /// `onLoadFuture.then((_) => _finishLoading())`, so a rejected future leaves
  /// `isLoaded` false forever; every subsequent lifecycle event on this parent
  /// then returns `block`, and the parent's whole add/remove queue stalls for
  /// the life of the app. A bad asset key must not be able to do that, so the
  /// failure is caught, the half-built player released, and the error parked in
  /// [loadError].
  @override
  Future<void> onLoad() async {
    final player = SpriteStudioPlayer() // no vsync → Flame drives the clock
      ..onEvents = onEvents
      ..onAnimationStarted = onAnimationStarted
      ..onAnimationFinished = onAnimationFinished
      ..onAnimationLooped = onAnimationLooped;

    try {
      // Route by ctor: in-memory bytes keep the explicit baseAssetDir; an asset
      // key delegates to loadAsset, which derives the texture/pack folder from it.
      if (_bytes != null) {
        await player.load(
          _bytes,
          animationName: animation,
          baseAssetDir: baseAssetDir,
          bundle: bundle,
        );
      } else {
        await player.loadAsset(
          _assetPath!,
          animationName: animation,
          bundle: bundle,
        );
      }

      // The component may have been removed while we awaited the fetch/decode.
      if (isRemoving || isRemoved) {
        player.dispose();
        return;
      }

      // load() only selects an animation when one is named; default to the first
      // so something plays out of the box (mirrors the Widget example).
      if (animation == null) {
        final names = player.animationNames;
        if (names.isNotEmpty) player.setAnimation(names.first);
      }
      // Apply transport AFTER the animation is set up: `setAnimation` rewinds
      // and resets the Brain's loopCount/speed, so setting these earlier (or via
      // `load`) would be clobbered and `loopCount` would silently fall back to
      // infinite. subFrame is Body-side (safe either way; set here for symmetry).
      player
        ..loopCount = loopCount
        ..speedScale = speedScale
        ..subFrameEnabled = subFrameEnabled;
      if (autoStart) player.play();
      _player = player;
    } catch (e) {
      _loadError = e;
      player.dispose();
    }
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
    final player = _player;
    if (player == null) return;
    // The canvas is already in this component's local space (Flame applied the
    // position/anchor/scale/angle transform), so the animation's world origin is
    // local (0,0). L2 owns its own save/restore and centers the animation on
    // `dst.center`.
    //
    // With an explicit [size] the render box IS that box. With the default zero
    // size the box is empty — which the Canvas backend tolerates (it only reads
    // `dst.center`, then draws in unbounded player-local space), but the
    // flutter_gpu backend renders into an offscreen target the size of `dst`, so
    // an empty box makes it allocate nothing and composite a blank frame. Fall
    // back to a finite box centred on the origin, sized from the animation's
    // authored canvas. It is 2× the canvas per axis because the runtime origin
    // can sit anywhere inside the canvas (Ringo's is near its feet, not the
    // centre), so a box centred on the origin must reach a full canvas-dimension
    // to the far side to never clip the art. Pass an explicit [size] to bound
    // the target exactly.
    final Rect box;
    if (size.x > 0 && size.y > 0) {
      box = Rect.fromLTWH(0, 0, size.x, size.y);
    } else {
      final canvasSize = player.canvasSize;
      if (canvasSize == null || canvasSize.isEmpty) return;
      box = Rect.fromCenter(
        center: Offset.zero,
        width: 2 * canvasSize.width,
        height: 2 * canvasSize.height,
      );
    }
    player.paint(canvas, dst: box, sourceSize: box.size);
  }

  /// Releases the player — the native Brain context and every decoded atlas.
  ///
  /// This is the component's only release path, and Flame reaches it only when
  /// the component is *removed from the tree*. Tearing down a `GameWidget` does
  /// not do that: `disposeCurrentGame` calls `finalizeRemoval()` and the game's
  /// `onDispose()`, neither of which walks the children (flame 1.38.0). So a
  /// game that is simply dropped — a popped route, a rebuilt widget — never runs
  /// this, and leaks one Brain plus one texture set per teardown.
  ///
  /// Override `onDispose` in your game and call `dispose()` on it:
  ///
  /// ```dart
  /// class MyGame extends FlameGame {
  ///   @override
  ///   void onDispose() => dispose(); // removeAll(children) → onRemove here
  /// }
  /// ```
  @override
  void onRemove() {
    _player?.dispose();
    _player = null;
    super.onRemove();
  }
}
