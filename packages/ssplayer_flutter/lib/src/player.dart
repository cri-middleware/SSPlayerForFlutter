import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show AssetBundle;

import 'instance_loader.dart';
import 'internal_player.dart';
import 'ssab_info.dart';
import 'texture_loader.dart';
import 'texture_registry.dart';

/// Callback for frame-accurate events surfaced from the ssab (design §6C).
typedef SsEventCallback = void Function(List<int> passedEventIndices);

/// Layer 3 — the user-facing controller (ports the SDK's `SSPlayer`).
///
/// Wraps a single [SpriteStudioInternalPlayer], drives time with a [Ticker],
/// and notifies listeners each frame so Layer-4 adapters (SpriteStudioView,
/// Flame, CustomPaint) can repaint. Widget-agnostic: one Player can back
/// several adapters.
///
/// SKELETON: transport + ticker + repaint notification are wired; crossfade /
/// blend / audio dispatch are Phase-1+.
class SpriteStudioPlayer extends ChangeNotifier {
  SpriteStudioPlayer({
    required TickerProvider vsync,
  }) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

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

  /// Invoked (on the UI isolate) with the event indices passed each frame.
  SsEventCallback? onEvents;

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

  /// Loads a `.ssab`, prepares [animationName], and (by default) decodes its
  /// cellmap textures — both embedded and reference modes (design §16C). For
  /// reference textures pass [baseAssetDir] (the asset folder that holds the
  /// sibling images) and optionally a [bundle].
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
    if (_ticker.isActive) _ticker.stop();
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
    if (_ticker.isActive) _ticker.stop();
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
    if (_ticker.isActive) _ticker.stop();
    notifyListeners();
  }

  void _startTicker() {
    if (!_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
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

  void _onTick(Duration elapsed) {
    final internal = _internal;
    // Defence in depth: `load` stops the ticker before swapping the engine, but
    // never drive a null or already-disposed internal even if a stray frame
    // slips through (it would throw "used after dispose").
    if (internal == null || internal.isDisposed || _disposed) return;

    final delta = _lastElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastElapsed;
    _lastElapsed = elapsed;

    internal.update(delta);

    final passed = internal.passedEventIndices();
    if (passed.isNotEmpty) onEvents?.call(passed);

    // `isLooped` is a pulse the runtime clears on entry to every update, so it
    // is read verbatim. `isFinished` is a sticky state, so it goes through a
    // rising edge that `play` re-arms.
    if (internal.isLooped) onLoop?.call();

    final finished = internal.isFinished;
    if (finished && !_prevFinished) {
      onComplete?.call();
      if (_ticker.isActive) _ticker.stop();
    }
    _prevFinished = finished;

    notifyListeners();
  }

  SpriteStudioInternalPlayer _requireInternal() =>
      _internal ?? (throw StateError('SpriteStudioPlayer.load() not called'));

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    _internal?.dispose();
    _internal = null;
    _animeInfo = null;
    _currentAnimation = null;
    super.dispose();
  }
}
