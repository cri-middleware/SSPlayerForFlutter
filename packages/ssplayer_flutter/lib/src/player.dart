import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'event.dart';
import 'instance_loader.dart';
import 'internal_player.dart';
import 'ssab_info.dart';
import 'texture_loader.dart';
import 'texture_registry.dart';

/// Callback for frame-accurate events surfaced from the ssab (design §6C).
typedef SsEventCallback = void Function(List<int> passedEventIndices);

/// Layer 3 — the user-facing controller (ports the SDK's `SSPlayer`).
///
/// Wraps a single [SpriteStudioInternalPlayer] and notifies listeners each frame
/// so Layer-4 adapters (SpriteStudioView, Flame, CustomPaint) can repaint.
/// Widget-agnostic: one Player can back several adapters.
///
/// **Clock.** Pass a [vsync] to have the player drive its own time with a
/// [Ticker] (the Widget path: SpriteStudioView). Omit it for an
/// **externally-clocked** player — the host advances playback by calling
/// [advance] once per frame from its own loop (e.g. a Flame component's
/// `update(dt)`, or a headless test). Everything else — [load], transport,
/// events — is identical in both modes.
///
/// SKELETON: transport + ticker + repaint notification are wired; crossfade /
/// blend / audio dispatch are Phase-1+.
class SpriteStudioPlayer extends ChangeNotifier {
  SpriteStudioPlayer({
    TickerProvider? vsync,
  }) {
    _ticker = vsync?.createTicker(_onTick);
  }

  /// The self-clock used by the Widget path. Null when the player is
  /// **externally clocked** (constructed without a `vsync`): the host drives
  /// time via [advance], so there is no Ticker to start/stop and [play] /
  /// [resume] merely set the Brain playing.
  Ticker? _ticker;

  SpriteStudioInternalPlayer? _internal;
  SpriteStudioInternalPlayer? get internal => _internal;

  Duration _lastElapsed = Duration.zero;
  bool _disposed = false;
  bool _prevFinished = false;
  bool _subFrame = true;

  // Transport state cached on the Player (not just the internal) so it survives
  // a resource swap in [reload] and can be set before the first [load].
  // `subFrame` above is the pre-existing precedent for this pattern.
  String? _currentAnimation;
  int? _loop;
  double? _speed;

  /// Sub-frame interpolation (default ON): smooth playback beyond the source
  /// FPS. Applies to the current and future loaded animations.
  bool get subFrame => _internal?.subFrame ?? _subFrame;
  set subFrame(bool value) {
    _subFrame = value;
    _internal?.subFrame = value;
  }

  /// Invoked (on the UI isolate) with the raw event indices passed each frame.
  /// Low-level escape hatch; most callers want the decoded [onUserData] /
  /// [onSignal] / [onAudio] callbacks below instead.
  SsEventCallback? onEvents;

  /// Fired (on the UI isolate) for each **UserData** marker crossed this frame,
  /// decoded from the pack for [currentAnimation] (design §6C).
  SsUserDataCallback? onUserData;

  /// Fired for each active **Signal** crossed this frame (§6C). Inactive
  /// signals are not surfaced.
  SsSignalCallback? onSignal;

  /// Fired for each **Audio** trigger crossed this frame (§6C). SpriteStudio
  /// audio is trigger-only: this hands you the sound to play, but the player
  /// never produces sound itself — play it with your own audio stack.
  SsAudioCallback? onAudio;

  /// Fired once every configured loop has played. Never fires while [loop] is
  /// infinite, nor on a commanded [stop].
  VoidCallback? onComplete;

  /// Fired each time playback crosses a loop boundary. The final cycle does not
  /// loop, so it fires [onComplete] instead.
  VoidCallback? onLoop;

  TextureRegistry get textures =>
      _internal?.textures ?? (throw StateError('load() first'));

  /// Read-only metadata for the most recently [load]ed `.ssab` (null before the
  /// first load). Structural names (animations, cellmaps) live in the `.ssab`,
  /// not the Brain, so they are parsed from the bytes.
  SsAnimeInfo? _animeInfo;

  /// Names of the animations contained in the currently-loaded `.ssab`, in pack
  /// order (empty before [load]). Feed any of these to [setupAnimation] to
  /// switch animation without reloading the resource or its textures.
  List<String> getAnimations() =>
      _animeInfo?.animationNames ?? const <String>[];

  /// Resolves an [SsAudioEvent.soundNameHash] (from an [onAudio] trigger) to its
  /// pack-relative sound file path — e.g. `sound/foo.mp3` — or null before
  /// [load] / if unknown. Convenience over [SsAnimeInfo.soundFilePath] for
  /// playing audio triggers; the player stays audio-independent (design §6C), so
  /// you feed the path to your own audio stack.
  String? soundFilePath(int soundNameHash) =>
      _animeInfo?.soundFilePath(soundNameHash);

  /// The animation currently selected via [load] or [setupAnimation] (null
  /// before any is chosen). [reload] uses it to restore selection across a
  /// resource swap.
  String? get currentAnimation => _currentAnimation;

  /// The unresolved textures from the most recent [load] (empty on success).
  TextureLoadReport? get lastTextureReport => _lastTextureReport;
  TextureLoadReport? _lastTextureReport;

  /// The instance packs (§8) fetched by the most recent [load], and any that
  /// could not be resolved — an instance part whose pack is missing silently
  /// never draws, so this is the way to notice.
  InstancePackLoadResult? get lastInstanceReport => _lastInstanceReport;
  InstancePackLoadResult? _lastInstanceReport;

  /// Loads a `.ssab` **by asset key** — the front door for a bundled animation.
  /// Reads the bytes from [bundle] (or the root bundle) and derives the base
  /// directory for sibling **reference textures** and **instance packs**
  /// (`<dir>/<pack>.ssab`) from the key's own folder — so the usual "everything
  /// in one directory" layout needs no extra argument. Otherwise identical to
  /// [load].
  ///
  /// Only a *non-derivable* layout needs [load] directly: a shared atlas in
  /// another folder, or bytes that never came from an asset key (a network
  /// download, a device-push live-reload) — those pass `baseAssetDir` explicitly.
  Future<void> loadAsset(
    String assetKey, {
    String? animationName,
    TextureRegistry? textures,
    AssetBundle? bundle,
    bool loadTextures = true,
    Map<String, Uint8List>? instancePacks,
  }) async {
    final bnd = bundle ?? rootBundle;
    final data = await bnd.load(assetKey);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await load(
      bytes,
      animationName: animationName,
      textures: textures,
      baseAssetDir: _assetDirOf(assetKey),
      bundle: bnd,
      loadTextures: loadTextures,
      instancePacks: instancePacks,
    );
  }

  /// Loads a `.ssab`, prepares [animationName], and (by default) decodes its
  /// cellmap textures — both embedded and reference modes (design §16C).
  ///
  /// Low-level primitive: takes the bytes directly, so it stays agnostic to
  /// their source (asset bundle, filesystem, network, device push). For
  /// reference textures pass [baseAssetDir] (the asset folder that holds the
  /// sibling images) and optionally a [bundle]. Most callers loading a bundled
  /// asset want [loadAsset], which reads the bytes and derives [baseAssetDir].
  ///
  /// Returns once textures are loaded; the widget repaints when it resolves.
  Future<void> load(
    Uint8List ssab, {
    String? animationName,
    TextureRegistry? textures,
    String? baseAssetDir,
    AssetBundle? bundle,
    bool loadTextures = true,
    Map<String, Uint8List>? instancePacks,
  }) async {
    // Quiesce the clock and drop the old engine BEFORE the async fetch below.
    // A still-running ticker (from a prior `play`) would otherwise fire
    // `_onTick` during the await and drive the just-disposed internal
    // ("used after dispose"); nulling it also makes `_onTick` no-op through the
    // gap. Callers resume playback explicitly via `play`/`resume` (the ticker
    // then restarts with a fresh `_lastElapsed`, so no delta jump).
    if (_ticker?.isActive ?? false) _ticker!.stop();
    _internal?.dispose();
    _internal = null;
    _lastTextureReport = null;
    _animeInfo = SsAnimeInfo(ssab);

    // Instance children (§8) are built inside the sync `load` below — a child's
    // Context must exist before the first step — so their packs must be fetched
    // first. Same-pack sub-animations need nothing here; this is only for
    // `external_instances`, and resolves to an empty map for the vast majority
    // of animations.
    final packs = await SsInstanceLoader.load(
      ssab,
      bundle: bundle,
      baseAssetDir: baseAssetDir,
      provided: instancePacks,
    );
    if (_disposed) return;
    _lastInstanceReport = packs;

    final internal = SpriteStudioInternalPlayer.load(
      ssab,
      textures: textures,
      instancePacks: packs.packs,
    );
    _internal = internal;
    internal.subFrame = _subFrame;
    if (_loop != null) internal.loop = _loop!;
    if (_speed != null) internal.speed = _speed!;
    _currentAnimation = animationName;
    if (animationName != null) {
      internal.setupAnimation(animationName);
    }
    notifyListeners();

    if (loadTextures) {
      // Every pack's cellmaps land in the one registry the whole tree shares:
      // texture keys are cellmap name hashes, so a shared atlas resolves once
      // and a child-only cellmap simply adds to it. Without this pass an
      // instance child draws untextured.
      final reports = await Future.wait(<Future<TextureLoadReport>>[
        SsTextureLoader.load(internal.textures, ssab,
            bundle: bundle, baseAssetDir: baseAssetDir),
        for (final child in packs.packs.values)
          SsTextureLoader.load(internal.textures, child,
              bundle: bundle, baseAssetDir: baseAssetDir),
      ]);
      // Guard against a concurrent reload/dispose while awaiting.
      if (_disposed || !identical(_internal, internal)) return;
      _lastTextureReport = TextureLoadReport(
          <String>[for (final r in reports) ...r.unresolved]);
      notifyListeners();
    }
  }

  /// [reload] counterpart of [loadAsset]: re-reads the bytes for [assetKey] and
  /// derives the texture/pack base from its folder, preserving transport.
  ///
  /// A bundle caches by key, so this first [AssetBundle.evict]s [assetKey] to
  /// pick up *changed on-disk* bytes — the "re-read this asset" semantics. The
  /// live-reload loop instead drives [reload] with bytes the watcher already
  /// fetched, so this method is convenience-only.
  Future<void> reloadAsset(
    String assetKey, {
    TextureRegistry? textures,
    AssetBundle? bundle,
    bool loadTextures = true,
    Map<String, Uint8List>? instancePacks,
  }) async {
    final bnd = bundle ?? rootBundle;
    bnd.evict(assetKey);
    final data = await bnd.load(assetKey);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await reload(
      bytes,
      textures: textures,
      baseAssetDir: _assetDirOf(assetKey),
      bundle: bnd,
      loadTextures: loadTextures,
      instancePacks: instancePacks,
    );
  }

  /// Parent directory of an asset key (`a/b/c.ssab` → `a/b`); `''` for a bare
  /// key or one anchored at the root (`/c.ssab`). Fed as the derived
  /// `baseAssetDir`; the loaders treat an empty base as "join is a no-op".
  static String _assetDirOf(String assetKey) {
    final i = assetKey.lastIndexOf('/');
    return i <= 0 ? '' : assetKey.substring(0, i);
  }

  /// Live-swaps the resource to [ssab] while **preserving transport** — the
  /// selected animation ([currentAnimation]), the playhead ([frameNo]) and the
  /// play/pause state — so an on-disk asset change (a re-exported `.ssab`) can be
  /// hot-swapped in place without the rewind-to-frame-0 that [load] causes. This
  /// is the primitive behind dev-time live reload ("save in the editor → the
  /// preview updates"). Texture params mirror [load].
  ///
  /// If the previously-selected animation is gone from the new bytes it falls
  /// back to the first one; an out-of-range playhead is left to the Brain to
  /// clamp. Assumes single-flight — callers must not overlap [reload]/[load]
  /// (the dev watcher debounces to guarantee this).
  Future<void> reload(
    Uint8List ssab, {
    TextureRegistry? textures,
    String? baseAssetDir,
    AssetBundle? bundle,
    bool loadTextures = true,
    Map<String, Uint8List>? instancePacks,
  }) async {
    final wasPlaying = isPlaying;
    final frame = frameNo;
    final anim = _currentAnimation;

    // Instance packs (§8) are re-fetched by `load`, so a live-reload picks up an
    // edited child `.ssab` too — the child pack is a separate file the watcher
    // may well have just reconverted.
    await load(
      ssab,
      textures: textures,
      baseAssetDir: baseAssetDir,
      bundle: bundle,
      loadTextures: loadTextures,
      instancePacks: instancePacks,
    );
    if (_disposed || _internal == null) return;

    final names = getAnimations();
    final target = (anim != null && names.contains(anim))
        ? anim
        : (names.isEmpty ? null : names.first);
    if (target != null) setupAnimation(target);
    seek(frame);
    if (wasPlaying) play();
  }

  /// Switches the current animation (keeps the loaded resource).
  bool setupAnimation(String name) {
    final ok = _requireInternal().setupAnimation(name);
    if (ok) _currentAnimation = name;
    notifyListeners();
    return ok;
  }

  /// Starts (or restarts) playback from the head — the Brain's `play` is a
  /// head-out, so this rewinds to the start frame. Use [resume] to continue a
  /// paused animation in place.
  void play() {
    final internal = _requireInternal();
    internal.play();
    _prevFinished = false;
    _startTicker();
    notifyListeners();
  }

  /// Pauses playback in place (idempotent). The Brain's `pause` merely *toggles*
  /// its hold flag, so we gate on [isPaused] to avoid accidentally resuming.
  void pause() {
    final internal = _internal;
    if (internal == null) return;
    if (!internal.isPausing) internal.pause();
    if (_ticker?.isActive ?? false) _ticker!.stop();
    notifyListeners();
  }

  /// Resumes a paused animation in place (no head-out). If playback is stopped
  /// or finished rather than paused, falls back to [play] (a fresh head-out).
  void resume() {
    final internal = _internal;
    if (internal == null) return;
    if (!internal.isPlaying) {
      play();
      return;
    }
    if (internal.isPausing) internal.pause(); // toggle the hold off
    _prevFinished = false;
    _startTicker();
    notifyListeners();
  }

  /// One-tap transport for a play/pause button: pause when advancing, otherwise
  /// [resume] (which itself head-outs when stopped/finished).
  void togglePlayPause() => isPlaying && !isPaused ? pause() : resume();

  void stop() {
    _requireInternal().stop();
    if (_ticker?.isActive ?? false) _ticker!.stop();
    notifyListeners();
  }

  void _startTicker() {
    // No-op for an externally-clocked player (no Ticker): [play]/[resume] have
    // already set the Brain playing; the host's loop does the advancing.
    final ticker = _ticker;
    if (ticker != null && !ticker.isActive) {
      _lastElapsed = Duration.zero;
      ticker.start();
    }
  }

  void seek(double frame) {
    _requireInternal().seek(frame);
    notifyListeners();
  }

  /// Number of cycles to play: `n > 0` plays `n` times then fires [onComplete];
  /// `-1` loops forever. `0` is a synonym for `-1`, not "play once".
  set loop(int count) {
    _loop = count;
    _internal?.loop = count;
  }

  set speed(double rate) {
    _speed = rate;
    _internal?.speed = rate;
  }

  double get frameNo => _internal?.frameNo ?? 0;

  /// Whether the animation is active (playing or *paused*), i.e. not stopped and
  /// not finished. Pair with [isPaused] to distinguish a live pause; a UI toggle
  /// wanting "currently advancing" should check `isPlaying && !isPaused`.
  bool get isPlaying => _internal?.isPlaying ?? false;

  /// Whether playback is paused in place (still [isPlaying], just held).
  bool get isPaused => _internal?.isPausing ?? false;

  /// Draws the current frame — delegates to Layer 2's single paint path.
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _internal?.paint(canvas, dst: dst, sourceSize: sourceSize);
  }

  // The internal Ticker's callback (vsync mode only): derive the per-frame delta
  // from the monotonic elapsed time and hand it to [advance]. `_startTicker`
  // resets `_lastElapsed` on each (re)start, so the first tick has a zero delta.
  void _onTick(Duration elapsed) {
    final delta = _lastElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    advance(delta);
  }

  /// Advances playback by [delta], dispatches this frame's events / loop /
  /// complete callbacks, then notifies listeners so Layer-4 adapters repaint.
  ///
  /// The internal [Ticker] calls this each frame in vsync mode. An
  /// **externally-clocked** player (constructed without a `vsync`) must call it
  /// itself from its host clock — e.g. a Flame component forwarding its
  /// `update(dt)`, or a headless test stepping frames. Safe to call before
  /// [load] or after [dispose] (no-op).
  void advance(Duration delta) {
    final internal = _internal;
    // Defence in depth: `load` stops the ticker before swapping the engine, but
    // never drive a null or already-disposed internal even if a stray frame
    // slips through (it would throw "used after dispose").
    if (internal == null || internal.isDisposed || _disposed) return;

    internal.update(delta);

    final passed = internal.passedEventIndices();
    if (passed.isNotEmpty) {
      onEvents?.call(passed);
      _dispatchDecodedEvents(passed);
    }

    // `isLooped` is a pulse the runtime clears on entry to every update, so it
    // is read verbatim. `isFinished` is a sticky state, so it goes through a
    // rising edge that `play` re-arms.
    if (internal.isLooped) onLoop?.call();

    final finished = internal.isFinished;
    if (finished && !_prevFinished) {
      onComplete?.call();
      if (_ticker?.isActive ?? false) _ticker!.stop();
    }
    _prevFinished = finished;

    notifyListeners();
  }

  /// Decodes the raw [passed] event indices for [currentAnimation] and fires
  /// the per-event callbacks (design §6C). Skips the decode entirely when no
  /// decoded callback is registered, and when no animation is selected (the
  /// indices are relative to the current animation's `events()`).
  void _dispatchDecodedEvents(List<int> passed) {
    if (onUserData == null && onSignal == null && onAudio == null) return;
    final anim = _currentAnimation;
    final info = _animeInfo;
    if (anim == null || info == null) return;

    final decoded = info.decodePassedEvents(anim, passed);
    if (onUserData != null) {
      for (final u in decoded.userData) {
        onUserData!(u);
      }
    }
    if (onSignal != null) {
      for (final s in decoded.signals) {
        onSignal!(s);
      }
    }
    if (onAudio != null) {
      for (final a in decoded.audios) {
        onAudio!(a);
      }
    }
  }

  SpriteStudioInternalPlayer _requireInternal() =>
      _internal ?? (throw StateError('SpriteStudioPlayer.load() not called'));

  @override
  void dispose() {
    _disposed = true;
    _ticker?.dispose();
    _internal?.dispose();
    _internal = null;
    _animeInfo = null;
    _currentAnimation = null;
    super.dispose();
  }
}
