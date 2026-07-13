import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show AssetBundle;

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

  /// Fired when playback reaches the end frame this frame.
  VoidCallback? onComplete;

  /// Fired when playback crossed a loop boundary this frame.
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
  }) async {
    _internal?.dispose();
    _lastTextureReport = null;
    _animeInfo = SsAnimeInfo(ssab);
    final internal = SpriteStudioInternalPlayer.load(
      ssab,
      textures: textures,
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
      final report = await SsTextureLoader.load(
        internal.textures,
        ssab,
        bundle: bundle,
        baseAssetDir: baseAssetDir,
      );
      // Guard against a concurrent reload/dispose while awaiting.
      if (_disposed || !identical(_internal, internal)) return;
      _lastTextureReport = report;
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
  }) async {
    final wasPlaying = isPlaying;
    final frame = frameNo;
    final anim = _currentAnimation;

    await load(
      ssab,
      textures: textures,
      baseAssetDir: baseAssetDir,
      bundle: bundle,
      loadTextures: loadTextures,
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

  void play() {
    _requireInternal().play();
    if (!_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
  }

  void pause() {
    _requireInternal().pause();
    if (_ticker.isActive) _ticker.stop();
  }

  void stop() {
    _requireInternal().stop();
    if (_ticker.isActive) _ticker.stop();
    notifyListeners();
  }

  void seek(double frame) {
    _requireInternal().seek(frame);
    notifyListeners();
  }

  set loop(int count) {
    _loop = count;
    _internal?.loop = count;
  }

  set speed(double rate) {
    _speed = rate;
    _internal?.speed = rate;
  }

  double get frameNo => _internal?.frameNo ?? 0;
  bool get isPlaying => _internal?.isPlaying ?? false;

  /// Draws the current frame — delegates to Layer 2's single paint path.
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _internal?.paint(canvas, dst: dst, sourceSize: sourceSize);
  }

  void _onTick(Duration elapsed) {
    final internal = _internal;
    if (internal == null || _disposed) return;

    final delta = _lastElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastElapsed;
    _lastElapsed = elapsed;

    internal.update(delta);

    final passed = internal.passedEventIndices();
    if (passed.isNotEmpty) onEvents?.call(passed);
    if (internal.isLooped) onLoop?.call();
    if (internal.isEndFrameReached) {
      onComplete?.call();
      if (_ticker.isActive) _ticker.stop();
    }

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
