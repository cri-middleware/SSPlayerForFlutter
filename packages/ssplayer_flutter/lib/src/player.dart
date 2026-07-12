import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show AssetBundle;

import 'internal_player.dart';
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
    final internal = SpriteStudioInternalPlayer.load(
      ssab,
      textures: textures,
    );
    _internal = internal;
    internal.subFrame = _subFrame;
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

  /// Switches the current animation (keeps the loaded resource).
  bool setupAnimation(String name) {
    final ok = _requireInternal().setupAnimation(name);
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

  set loop(int count) => _requireInternal().loop = count;
  set speed(double rate) => _requireInternal().speed = rate;

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
    super.dispose();
  }
}
