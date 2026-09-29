import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'event.dart';
import 'instance_loader.dart';
import 'internal_player.dart';
import 'playback.dart';
import 'render/backend/backend_kind.dart';
import 'render/part_override.dart';
import 'render/placement.dart';
import 'render/root_transform.dart';
import 'ssab_info.dart';
import 'texture_loader.dart';
import 'texture_registry.dart';

/// Callback for frame-accurate events surfaced from the ssab.
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
/// Cross-fade / blend transitions between animations are not currently
/// supported: [setAnimation] switches instantly.
class SpriteStudioPlayer extends ChangeNotifier {
  SpriteStudioPlayer({
    TickerProvider? vsync,
    SpriteStudioBackend backend = SpriteStudioBackend.auto,
  }) : _backend = backend {
    _ticker = vsync?.createTicker(_onTick);
  }

  /// Which render backend the L2 player draws with. Defaults to
  /// [SpriteStudioBackend.auto]: the flutter_gpu backend where Impeller is
  /// available (mobile/desktop), falling back to Canvas otherwise (always on the
  /// Web). Pass [SpriteStudioBackend.canvas] to force the reference path. Fixed
  /// for the player's life and re-applied across [reload].
  final SpriteStudioBackend _backend;

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

  /// What the pack is called, for a report about it. `null` for bytes handed to
  /// [load] directly — a network download or a device push has no name to give.
  String? _sourceLabel;

  /// Carried from [loadAsset] into the [load] it delegates to, so that a report
  /// raised *during* the load (an `animationName` the pack does not have) can
  /// still say which pack. [load] takes it and clears it, which is what leaves a
  /// direct `load(bytes)` correctly unnamed.
  String? _pendingSourceLabel;

  /// The animation name already reported missing. [setAnimation] leaves
  /// [_currentAnimation] alone when the switch fails, so its own early return
  /// cannot absorb a repeat — a state machine asserting a typo every frame would
  /// report it every frame. Keyed on the name, so a second wrong one still gets
  /// its own line.
  String? _reportedMissingAnimation;
  int? _loop;
  double? _speed;
  bool? _skipFrames;
  int? _frameRate;

  /// Sub-frame interpolation (default ON): smooth playback beyond the source
  /// FPS. Applies to the current and future loaded animations.
  bool get subFrameEnabled => _internal?.subFrameEnabled ?? _subFrame;
  set subFrameEnabled(bool value) {
    _subFrame = value;
    _internal?.subFrameEnabled = value;
  }

  /// Mirror the drawn animation horizontally — the same idea as Flutter's own
  /// `Transform.flip(flipX: …)`, and as ForUnity's `FlipX` / ForGodot's
  /// `flip_h`.
  ///
  /// ```dart
  /// // Face the way we are walking.
  /// player.flipX = velocity.dx < 0;
  /// ```
  ///
  /// **Why not just wrap the view in `Transform.flip`?** Because that mirrors
  /// everything in the wrapped subtree. The case this exists for is a
  /// [SpriteStudioPartAnchor] stuck to a part: wrap the whole `Stack` and the
  /// anchored widgets come out mirrored too; wrap only the view and they stay
  /// where the *unflipped* animation was. Setting it here mirrors the animation,
  /// carries the anchors across with it, and leaves their own artwork upright
  /// when they ask for that ([SpriteStudioAnchorMirror.cancel]).
  ///
  /// Applies to the whole tree including instance children, and survives
  /// [reload]. Notifies listeners, so the view repaints.
  bool get flipX => rootTransform.flipX;
  set flipX(bool value) =>
      _setRootTransform(rootTransform.copyWith(flipX: value));

  /// Mirror the drawn animation vertically. See [flipX].
  bool get flipY => rootTransform.flipY;
  set flipY(bool value) =>
      _setRootTransform(rootTransform.copyWith(flipY: value));

  /// Shift the drawn animation by this many logical pixels without moving the
  /// widget — useful for nudging artwork off its authored origin while the view
  /// keeps marking the logical position. Applied after [flipX] / [flipY], so it
  /// is not itself mirrored.
  ui.Offset get offset => rootTransform.offset;
  set offset(ui.Offset value) =>
      _setRootTransform(rootTransform.copyWith(offset: value));

  /// Scale the drawn animation about its origin. Under a fitted view it
  /// multiplies the fit's scale rather than replacing it.
  double get scale => rootTransform.scale;
  set scale(double value) =>
      _setRootTransform(rootTransform.copyWith(scale: value));

  /// [flipX], [flipY], [offset] and [scale] as one value. Assign it to change
  /// several at once (one repaint).
  ///
  /// This is what the caller asked for. What is drawn, and what the part poses
  /// carry, is this fitted into the view's box by [place] — so it reads back as
  /// set, whatever the view did with it.
  SsRootTransform get rootTransform => _root;
  set rootTransform(SsRootTransform value) => _setRootTransform(value);

  SsRootTransform _root = SsRootTransform.identity;

  void _setRootTransform(SsRootTransform value) {
    if (value == _root) return;
    _root = value;
    _applyRoot();
    notifyListeners();
  }

  /// The view's box and how to fit into it, from the last [place]. Null until a
  /// view places the player, and for good under an adapter that never does.
  ui.Size? _placeView;
  SsPlacement? _placement;

  /// Fits the animation into a [view]-sized box by [placement], on top of
  /// [rootTransform] — what [SpriteStudioView] does from its layout. Null
  /// [placement] draws unfitted, with the origin at the box centre and the
  /// caller's scale. That is the default, and what an adapter that never calls
  /// this — the Flame component — draws with.
  ///
  /// Held here rather than in the view so that the part poses carry the fit as
  /// they carry the flip: [partTransform] is the pose as drawn, and a
  /// [SpriteStudioPartAnchor] over the view lands on the part without knowing
  /// the view fitted anything. It does not notify: the view calling it is
  /// laying out, and paints next.
  void place(ui.Size view, SsPlacement? placement) {
    if (view == _placeView && placement == _placement) return;
    _placeView = view;
    _placement = placement;
    _applyRoot();
  }

  /// [rootTransform] fitted by the last [place] — what the backends draw with.
  SsRootTransform get _placedRoot {
    final placement = _placement, view = _placeView;
    if (placement == null || view == null) return _root;
    return placement.resolve(view, _canvasRect, _root);
  }

  /// Pushed on every change to what [_placedRoot] reads, so L2 always holds the
  /// transform the next paint and part pose use.
  void _applyRoot() => _internal?.rootTransform = _placedRoot;

  /// Invoked (on the UI isolate) with the raw event indices passed each frame.
  /// Low-level escape hatch; most callers want the decoded [onUserData] /
  /// [onSignal] / [onAudio] callbacks below instead.
  SsEventCallback? onEvents;

  /// Fired (on the UI isolate) for each **UserData** marker crossed this frame,
  /// decoded from the pack for [currentAnimation].
  SsUserDataCallback? onUserData;

  /// Fired for each active **Signal** crossed this frame. Inactive
  /// signals are not surfaced.
  SsSignalCallback? onSignal;

  /// Fired for each **Audio** trigger crossed this frame. SpriteStudio
  /// audio is trigger-only: this hands you the sound to play, but the player
  /// never produces sound itself — play it with your own audio stack.
  SsAudioCallback? onAudio;

  /// Fired when playback **heads out** — a [play], including one an autoplay
  /// wrapper or a host state machine issued rather than your own code. A
  /// [resume] does not fire it: lifting a pause carries on, it does not start,
  /// and firing here would make the two indistinguishable to a listener.
  VoidCallback? onAnimationStarted;

  /// Fired once every configured loop has played. Never fires while [loopCount]
  /// is infinite, nor on a commanded [stop].
  VoidCallback? onAnimationFinished;

  /// Fired each time playback crosses a loop boundary. The final cycle does not
  /// loop, so it fires [onAnimationFinished] instead.
  VoidCallback? onAnimationLooped;

  TextureRegistry get textures =>
      _internal?.textures ?? (throw StateError('load() first'));

  /// Read-only metadata for the most recently [load]ed `.ssab` (null before the
  /// first load). Structural names (animations, cellmaps) live in the `.ssab`,
  /// not the Brain, so they are parsed from the bytes.
  SsAnimeInfo? _animeInfo;

  /// Names of the animations contained in the currently-loaded `.ssab`, in pack
  /// order (empty before [load]). Feed any of these to [setAnimation] to
  /// switch animation without reloading the resource or its textures.
  List<String> get animationNames =>
      _animeInfo?.animationNames ?? const <String>[];

  /// Names of the cellmaps in the loaded `.ssab`, without the `.ssce`
  /// extension (empty before [load]) — the first half of what
  /// [setPartCellOverride] needs.
  List<String> get cellmapNames => _animeInfo?.cellmapNames ?? const <String>[];

  /// Names of the cells inside [cellmapName] (empty before [load] / unknown
  /// cellmap) — the other half. Both names go to [setPartCellOverride] as-is.
  List<String> cellNames(String cellmapName) =>
      _animeInfo?.cellNames(cellmapName) ?? const <String>[];

  /// The [textures] key for the cellmap named [cellmapName] (null before [load]
  /// or for an unknown name). Feed it to `textures.register(hash, image)` to
  /// swap a whole cellmap's bitmap at runtime — every part that samples it,
  /// Normal and Mesh alike, then draws the new image.
  int? cellmapTextureHash(String cellmapName) =>
      _animeInfo?.cellmapTextureHash(cellmapName);

  // --- Runtime texture replacement -----------------------------------------
  //
  // Swap the bitmap a cellmap (or a TextureChange target file) samples, from
  // program code — costumes, dynamic expressions. Ports ForGodot's
  // `set_cellmap_texture`, and is NOT
  // the Override Layer: it is a texture-registry swap, not per-part state.
  // Like the override calls it notifies listeners on success (a swap changes
  // pixels without changing the frame, so a paused player would not otherwise
  // repaint), no-ops before [load] / for an unknown name, and never throws.

  /// Names every texture a runtime replacement can target — cellmap names
  /// (`common`) followed by TextureChange file names (`common.png`), for a
  /// picker. Empty before [load]. All are valid arguments to [setCellmapTexture].
  List<String> get replaceableTextureNames =>
      _animeInfo?.replaceableTextureNames ?? const <String>[];

  /// Replaces the bitmap the cellmap (or TextureChange target file) named [name]
  /// samples with [image] — a runtime costume / expression swap — or **restores
  /// the original** when [image] is null. Returns false before [load], for an
  /// unknown [name], after [dispose], or when restoring a [name] that had no
  /// override; true when an override was set or actually cleared.
  ///
  /// [name] is a cellmap name (no extension, e.g. `character`) or a TextureChange
  /// file name (with extension, e.g. `costume2.png`) — both listed by
  /// [replaceableTextureNames].
  ///
  /// [image] stays **yours**: the player borrows it and never disposes it. Keep
  /// it alive while it is set, and dispose it after you clear the override (or
  /// replace it). Use a same-size, same-layout atlas as the original — the UVs
  /// are in the original cellmap's pixel space.
  ///
  /// **Applies tree-wide.** Because instance children share this player's texture
  /// registry, the swap reaches every part sampling that texture — root or child
  /// alike — unlike ForGodot's per-player override.
  bool setCellmapTexture(String name, ui.Image? image) {
    final hash = _animeInfo?.textureHashForName(name);
    if (hash == null) return false;
    return setCellmapTextureByHash(hash, image);
  }

  /// Registry-key form of [setCellmapTexture] (skip the name lookup when you
  /// already hold the hash from [cellmapTextureHash] / [SsAnimeInfo]).
  bool setCellmapTextureByHash(int textureHash, ui.Image? image) =>
      _override((i) => i.setCellmapTexture(textureHash, image));

  /// The override image currently set for the texture named [name] (the OVERRIDE
  /// value only, never the loaded original — mirrors ForGodot's
  /// `get_cellmap_texture`), or null when it is unset / before [load] / for an
  /// unknown name.
  ui.Image? cellmapTextureOverride(String name) {
    final internal = _internal;
    final hash = _animeInfo?.textureHashForName(name);
    if (internal == null || hash == null) return null;
    return internal.cellmapTextureOverride(hash);
  }

  /// Resolves an [SsAudioEvent.soundNameHash] (from an [onAudio] trigger) to its
  /// pack-relative sound file path — e.g. `sound/foo.mp3` — or null before
  /// [load] / if unknown. Convenience over [SsAnimeInfo.soundFilePath] for
  /// playing audio triggers; the player stays audio-independent, so
  /// you feed the path to your own audio stack.
  String? soundFilePath(int soundNameHash) =>
      _animeInfo?.soundFilePath(soundNameHash);

  /// The animation currently selected via [load] or [setAnimation] (null
  /// before any is chosen). [reload] uses it to restore selection across a
  /// resource swap.
  String? get currentAnimation => _currentAnimation;

  /// The authored design-canvas size (SpriteStudio `<canvasSize>`) of the
  /// [currentAnimation], in player-local pixels, or null before an animation is
  /// selected / when the pack carries no canvas.
  ///
  /// A drawing adapter that must hand [paint] an explicit, finite render box can
  /// size one from this: the flutter_gpu backend renders into an offscreen
  /// target the size of `dst`, so a zero-sized [SpriteStudioComponent] bounds
  /// its target from the canvas instead of compositing a blank frame (the Canvas
  /// backend needs no size — it draws in unbounded player-local space).
  ui.Size? get canvasSize {
    final name = _currentAnimation;
    return name == null ? null : _animeInfo?.canvasSize(name);
  }

  /// The authored canvas a view fits, placed around the origin by its pivot, in
  /// player-local pixels — or null until an animation is selected, or when the
  /// pack carries no canvas.
  ///
  /// It is the canvas of the **first animation selected since the pack was
  /// loaded**, and stays put when the animation changes. Canvases differ between
  /// the animations of one pack — Ringo's `dead` is 1300 wide where the rest are
  /// 800 — and following each would re-lay a view out on every switch and shrink
  /// the character the moment it dies. To fit something else, give the view a
  /// `frame`.
  ui.Rect? get canvasRect => _canvasRect;
  ui.Rect? _canvasRect;

  /// The animation [canvasRect] came from, so a [reload] can take the box from
  /// the same one rather than from whichever is playing.
  String? _canvasAnimation;

  /// Takes the box from the first animation set up since the load.
  void _latchCanvas(String name) {
    if (_canvasRect != null) return;
    _canvasRect = _animeInfo?.canvasRect(name);
    if (_canvasRect != null) _canvasAnimation = name;
  }

  /// The unresolved textures from the most recent [load] (empty on success).
  TextureLoadReport? get lastTextureReport => _lastTextureReport;
  TextureLoadReport? _lastTextureReport;

  /// The instance packs fetched by the most recent [load], and any that
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
    _pendingSourceLabel = assetKey;
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
  /// cellmap textures — both embedded and reference modes.
  ///
  /// Low-level primitive: takes the bytes directly, so it stays agnostic to
  /// their source (asset bundle, filesystem, network, device push). For
  /// reference textures pass [baseAssetDir] (the asset folder that holds the
  /// sibling images) and optionally a [bundle]. Most callers loading a bundled
  /// asset want [loadAsset], which reads the bytes and derives [baseAssetDir].
  ///
  /// **Trust the bytes.** The Brain parses `.ssab` unchecked and is undefined
  /// behaviour on malformed input; a non-`.ssab`/truncated buffer is rejected
  /// with a [FormatException] (an identify check, not full validation). Load only
  /// `.ssab` you produced or bundled — never a pack from an untrusted source.
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
    _sourceLabel = _pendingSourceLabel;
    _pendingSourceLabel = null;
    _reportedMissingAnimation = null;
    _animeInfo = SsAnimeInfo(ssab);
    _canvasRect = null;

    // Instance children are built inside the sync `load` below — a child's
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
      backend: _backend,
    );
    _internal = internal;
    // The GPU backend uploads atlases asynchronously and draws without them
    // until they land, so it needs another paint once they do — a player that is
    // paused or drawn once has no next frame of its own and would stay blank.
    internal.onNeedsRepaint = () {
      if (!_disposed && identical(_internal, internal)) notifyListeners();
    };
    internal.subFrameEnabled = _subFrame;
    // Assigned from the result, not ahead of it. Assigning first left
    // `currentAnimation` naming an animation that was never set up — and, worse,
    // made [setAnimation] return `true` for that same name without doing
    // anything, because its early return compares against this field.
    if (animationName != null && !internal.setupAnimation(animationName)) {
      _reportMissingAnimation(animationName);
      _currentAnimation = null;
    } else {
      _currentAnimation = animationName;
      if (animationName != null) _latchCanvas(animationName);
    }
    _applyRoot();
    // Push the cached settings AFTER setupAnimation: the loop count is reset
    // there, so setting it any earlier would be clobbered.
    _applyTransportSettings(internal);
    notifyListeners();

    if (loadTextures) {
      // Every pack's cellmaps land in the one registry the whole tree shares:
      // texture keys are cellmap name hashes, so a shared atlas resolves once
      // and a child-only cellmap simply adds to it. Without this pass an
      // instance child draws untextured.
      // One pack at a time, so each sees what the previous ones registered and a
      // shared atlas decodes once instead of once per pack. Concurrently, every
      // pack would find the registry empty; a claim-taken-before-the-decode set
      // fixes that but then loses a cellmap this pack cannot resolve and the next
      // one can (embedded in one, referenced in the other) — see
      // [SsTextureLoader.load]. Cellmaps *within* a pack still decode
      // concurrently, which is where the parallelism is worth having.
      final reports = <TextureLoadReport>[];
      for (final pack in <Uint8List>[ssab, ...packs.packs.values]) {
        reports.add(await SsTextureLoader.load(internal.textures, pack,
            bundle: bundle, baseAssetDir: baseAssetDir));
        // Guard against a concurrent reload/dispose while awaiting.
        if (_disposed || !identical(_internal, internal)) return;
      }
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
    // [isPlaying] is "active", which stays true across a pause — a paused
    // preview must come back paused, not force-resumed.
    final wasPaused = isPausing;
    final frame = frameNo;
    final anim = _currentAnimation;
    final boxAnimation = _canvasAnimation;

    // Instance packs are re-fetched by `load`, so a live-reload picks up an
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

    final names = animationNames;
    // The box comes back from the animation it came from, re-read so an edit to
    // that canvas shows, and not from the one playing: reloading on Ringo's
    // `dead` must not refit the view to `dead`'s wider canvas.
    if (boxAnimation != null && names.contains(boxAnimation)) {
      _latchCanvas(boxAnimation);
    }
    final target = (anim != null && names.contains(anim))
        ? anim
        : (names.isEmpty ? null : names.first);
    if (target != null) setAnimation(target);
    // Transport first, playhead second. [play] is a head-out that rewinds to the
    // start frame, so seeking before it would simply be undone — the whole point
    // of [reload] is that the playhead survives. The head-out itself is right
    // here: every slot belongs to the freshly loaded resource and has no prior
    // state to preserve, so it is [play] (not [resume]) that re-arms them.
    if (wasPlaying) play();
    seek(frame);
    if (wasPaused) pause();
  }

  /// Switches the current animation (keeps the loaded resource), posing it on
  /// its first frame. Does not start playback — [play] does.
  ///
  /// **Selecting the animation already selected does nothing at all.** It is a
  /// switch, so with nothing to switch to it costs nothing and disturbs nothing:
  /// the playhead stays, the instance children are not rebuilt, and the override
  /// layer survives. That is what makes it safe for a state machine to assert
  /// its current clip every frame — and returning early is not just an
  /// optimisation, because [_applyTransportSettings] writes the loop count and
  /// the Brain RE-ARMS the remaining-loop counter on every write. Re-asserting
  /// each frame would reset the loop budget each frame, and a finite [loopCount]
  /// would never run out.
  ///
  /// To restart, call [play], which heads out. To drop the overrides, call
  /// [clearAllPartOverrides]. To drop a playback section, set one covering the
  /// whole animation.
  bool setAnimation(String name) {
    final internal = _requireInternal();
    // Against what is actually selected, which [load] resets — so a second pack
    // that happens to name an animation the same way as the first still gets
    // set up rather than being taken for one already selected.
    if (_currentAnimation == name) return true;
    final ok = internal.setupAnimation(name);
    if (!ok) {
      _reportMissingAnimation(name);
    } else {
      _currentAnimation = name;
      _reportedMissingAnimation = null;
      _latchCanvas(name);
      _applyRoot();
      // The Brain reset the loop count; restore the cached settings so a
      // mid-session animation switch (or [reload]) keeps the caller's loop count
      // instead of silently reverting to infinite looping.
      _applyTransportSettings(internal);
    }
    notifyListeners();
    return ok;
  }

  /// Say which pack was asked for what.
  ///
  /// The names that *would* have worked are deliberately absent: [animationNames]
  /// is public, so a caller who wants the list can print it, and a required list
  /// would mean deciding here how to truncate a pack with two hundred animations.
  void _reportMissingAnimation(String name) {
    if (_reportedMissingAnimation == name) return;
    _reportedMissingAnimation = name;
    final where = _sourceLabel ?? 'the loaded pack';
    // The Brain's own reason, verbatim. It used to say "has no animation",
    // which is the common case and not the only one: a player whose pack never
    // bound fails the same call with `SSAB data is not loaded`, and being told
    // the name is missing sends the reader to look at the wrong thing.
    final reason = _internal?.lastErrorMessage;
    final because = reason == null ? '' : ' — $reason';
    debugPrint(
        'SpriteStudioPlayer: $where could not select animation "$name"$because. '
        'Check animationNames for what it does have.');
  }

  /// Starts (or restarts) playback from the head — the Brain's `play` is a
  /// head-out, so this rewinds to the start frame. Use [resume] to continue a
  /// paused animation in place.
  ///
  /// Pass [startFrame] to head out from a given frame instead. That frame then
  /// becomes the reference the loop count counts from, which is why it is an
  /// argument here rather than a [seek] before the call — a seek would be
  /// undone by the rewind.
  void play([double? startFrame]) {
    final internal = _requireInternal();
    internal.play(startFrame);
    _prevFinished = false;
    _startTicker();
    onAnimationStarted?.call();
    notifyListeners();
  }

  /// Pauses playback in place. The Brain's `pause` is one-way and idempotent,
  /// and ignores a request made while nothing is playing, so no gate is needed.
  void pause() {
    final internal = _internal;
    if (internal == null) return;
    internal.pause();
    if (_ticker?.isActive ?? false) _ticker!.stop();
    notifyListeners();
  }

  /// Lifts a [pause], carrying on from the same frame (no head-out). Idempotent,
  /// and a **no-op on a stopped or finished animation** — starting one is
  /// [play]'s job, and it rewinds.
  ///
  /// It used to fall back to [play] when nothing was playing, which made a
  /// `resume()` that hit a stopped player silently lose the playhead here and
  /// nowhere else in the family. The Brain publishes four distinct verbs and
  /// asks Players not to fold them into three;
  /// mapping one button onto the four is [togglePlayPause]'s job, and it is the
  /// only place that knows a button exists.
  void resume() {
    final internal = _internal;
    if (internal == null) return;
    internal.resume();
    // The Brain ignores a resume while nothing is playing, so read the state
    // back rather than starting a ticker that would have nothing to advance.
    if (!internal.isPlaying) return;
    _startTicker();
    notifyListeners();
  }

  /// One-tap transport for a play/pause button: [pause] while advancing,
  /// [resume] while held, and [play] from the head when stopped or finished.
  ///
  /// The head-out lives here rather than in [resume] so that the verb stays the
  /// Brain's — see [resume].
  void togglePlayPause() {
    if (!isPlaying) {
      play();
    } else if (isPausing) {
      resume();
    } else {
      pause();
    }
  }

  /// Ends playback. The playhead **stays where it stands** — nothing rewinds,
  /// so the widget keeps painting the frame it stopped on. [play] is what
  /// returns to the head; [frameNo] seeks anywhere else.
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

  /// Number of cycles to play: `n > 0` plays `n` times then fires [onAnimationFinished];
  /// `-1` loops forever. `0` is a synonym for `-1`, not "play once".
  ///
  /// Reads back what was last set, not the Brain's normalized value: the Dart
  /// runtime API does not surface `get_loops`, so `0` reads back as the `0` you
  /// asked for rather than the `-1` it becomes.
  int get loopCount => _loop ?? -1;
  set loopCount(int count) {
    _loop = count;
    _internal?.loopCount = count;
  }

  /// Playback rate as a multiple of the clip's authored rate: `1.0` is as
  /// authored, `0.0` and below are a stop rather than reverse playback — that
  /// is [setPlaybackDirection]. Survives [setAnimation].
  double get speedScale => _speed ?? 1.0;
  set speedScale(double rate) {
    _speed = rate;
    _internal?.speedScale = rate;
  }

  /// Which way the playhead walks, and what it does at the far end. Both
  /// **survive** [setAnimation] — "play this backwards" describes the
  /// playback, not the clip that happens to be loaded (SDK #375), which is the
  /// same reason [speedScale] and [frameSkipEnabled] carry across. What does not carry is
  /// the heading within a round trip: a new animation always starts on the
  /// outward leg, so a transition never begins mid-bounce.
  ///
  /// With [SsPlaybackStyle.pingPong] one loop is a full round trip, so a
  /// [loopCount] of 1 plays there and back once.
  SsPlaybackDirection get playbackDirection =>
      _internal?.playbackDirection ?? SsPlaybackDirection.forward;

  /// See [playbackDirection].
  SsPlaybackStyle get playbackStyle =>
      _internal?.playbackStyle ?? SsPlaybackStyle.normal;

  /// See [playbackDirection]. Both are set together because the Brain takes
  /// them as one call — pass the current value for whichever you are not
  /// changing. Nothing is cached here because nothing needs to be: the Brain
  /// keeps the choice across a transition on its own.
  void setPlaybackDirection(
      SsPlaybackDirection direction, SsPlaybackStyle style) {
    _internal?.setPlaybackDirection(direction, style);
  }

  /// How a long tick is spent: ON (the default) advances by the elapsed time
  /// and drops the frames in between, keeping playback on the wall clock; OFF
  /// advances exactly one frame per tick, so nothing is ever skipped but a
  /// stalled app plays in slow motion.
  ///
  /// Turn it OFF when every frame matters — an animation whose events must all
  /// fire, or a deterministic recording. Re-applied across [setAnimation].
  bool get frameSkipEnabled => _internal?.frameSkipEnabled ?? _skipFrames ?? true;
  set frameSkipEnabled(bool value) {
    _skipFrames = value;
    _internal?.frameSkipEnabled = value;
  }

  /// Restricts playback to `[startFrame, endFrame]` of the **current**
  /// animation, so [play] / looping / ping-pong all work within that range.
  /// [startFrame] and [endFrame] report the result.
  ///
  /// Not restored across [setAnimation]: frame numbers only mean something
  /// inside the animation they were measured in, so carrying a section into a
  /// different one would clamp it to an arbitrary range. Call this again after
  /// each setup, and only once the animation is selected — a section set before
  /// [setAnimation] is wiped by it.
  void setAnimationSection(int startFrame, int endFrame) {
    _internal?.setAnimationSection(startFrame, endFrame);
  }

  /// Frames per second the animation advances at — the rate authored in the
  /// pack unless overridden. Before [load] there is no pack to read, so this
  /// reports the override if one was set and 0 otherwise.
  int get frameRate => _internal?.frameRate ?? _frameRate ?? 0;

  /// Overrides the advance rate, in absolute frames per second.
  ///
  /// The override is the host's rather than the clip's, so it **survives**
  /// [setAnimation] the way [speedScale] and [frameSkipEnabled] do (SDK #370). Hand it
  /// `0` (or any negative value) to clear it and go back to whatever each
  /// animation was authored at. To scale playback without replacing the
  /// authored rate, use [speedScale] instead.
  set frameRate(int fps) {
    _frameRate = fps;
    _internal?.frameRate = fps;
  }

  // `setupAnimation` resets the Brain's whole transport (loop, speed, fps,
  // direction, style, skip-frames and the section) to the new animation's
  // defaults, so anything the host chose has to be re-applied afterwards.
  //
  // The caller's own settings, pushed at a point where they are guaranteed to
  // reach a freshly set-up player. `loop` is the one that has to be here: the
  // Brain resets it on every transition. `speed` and `skipFrames` survive setup
  // on their own since SDK #369/#370, so these two only matter for the first
  // setup after a value was set.
  //
  // `frameRate` is here for the same reason as `speed` and `skipFrames`, and
  // not for the reason `loop` is: the Brain keeps an fps override across a
  // transition, so this is not about surviving setup. It is about reaching a
  // player that did not exist when the host set it — before the first [load],
  // and again after [reload] builds a new one.
  //
  // The playback direction / style are the ones that genuinely need nothing:
  // they survive setup in the Brain and have no pre-[load] path, because they
  // are set through a method rather than cached here. The section is the one
  // thing left to reset, and deliberately -- a range of frame numbers means
  // nothing against a different animation.
  void _applyTransportSettings(SpriteStudioInternalPlayer internal) {
    if (_loop != null) internal.loopCount = _loop!;
    if (_speed != null) internal.speedScale = _speed!;
    if (_skipFrames != null) internal.frameSkipEnabled = _skipFrames!;
    if (_frameRate != null) internal.frameRate = _frameRate!;
  }

  double get frameNo => _internal?.frameNo ?? 0;

  /// First and last frame of the range being played, and its length in frames
  /// ([endFrame] - [startFrame] + 1). All 0 before [load].
  ///
  /// These describe the range the transport actually walks, which is the whole
  /// animation today. Feed [totalFrames] to a scrubber; feed [startFrame] /
  /// [endFrame] to [seek] to jump to either end.
  int get startFrame => _internal?.startFrame ?? 0;

  /// See [startFrame].
  int get endFrame => _internal?.endFrame ?? 0;

  /// See [startFrame].
  int get totalFrames {
    final internal = _internal;
    if (internal == null) return 0;
    return internal.endFrame - internal.startFrame + 1;
  }

  /// Whether the animation is active (playing or *paused*), i.e. not stopped and
  /// not finished. Pair with [isPausing] to distinguish a live pause; a UI toggle
  /// wanting "currently advancing" should check `isPlaying && !isPausing`.
  bool get isPlaying => _internal?.isPlaying ?? false;

  /// Whether playback is paused in place (still [isPlaying], just held).
  bool get isPausing => _internal?.isPausing ?? false;

  /// Whether every configured loop has played. **Sticky** until the next [play]
  /// or [setAnimation], so polling it tells you the run is over but not when
  /// it ended — take the rising edge, or just use [onAnimationFinished]. Always false
  /// while [loopCount] is infinite.
  bool get isFinished => _internal?.isFinished ?? false;

  /// Whether the most recent advance crossed a loop boundary. This is the loop
  /// *edge*, cleared at the top of every update, so it only reads true inside
  /// the tick that crossed — poll it from a per-frame callback or use [onAnimationLooped].
  bool get justLooped => _internal?.justLooped ?? false;

  /// Which way the playhead is **actually** travelling this frame — not
  /// [playbackDirection], which is only the heading that was configured. Under
  /// [SsPlaybackStyle.pingPong] the return leg runs backward while
  /// [playbackDirection] still reads [SsPlaybackDirection.forward]. A
  /// [speedScale] of `0` or below is a stop rather than a reversal, so it does
  /// not flip this either.
  ///
  /// **Gate audio on it.** SpriteStudio has no reverse audio, so a key crossed
  /// on a backward leg is not meant to sound. This player reports audio rather
  /// than playing it, so it cannot apply that test for you — the players
  /// that own an audio backend apply it themselves, and here it is yours:
  ///
  /// ```dart
  /// _player.onAudio = (audio) {
  ///   if (!_player.isPlayingForward) return;
  ///   final path = _player.soundFilePath(audio.soundNameHash);
  ///   if (path != null) _audio.play(path, times: audio.loopNum);
  /// };
  /// ```
  ///
  /// `true` before anything has played: forward is the resting state, so the
  /// gate above does not silence a host on its first frame.
  bool get isPlayingForward => _internal?.isPlayingForward ?? true;

  /// Draws the current frame — delegates to Layer 2's single paint path.
  ///
  /// At most once per frame per player: the render backend recycles per-frame
  /// resources here, so two adapters painting the same player in one frame
  /// corrupt each other's output. One player per view; share a [TextureRegistry]
  /// between their `load`s if you want the atlases decoded once.
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
    // Cap the catch-up. A Ticker muted by `TickerMode` — which every pushed
    // route does to the page beneath it — stops delivering ticks but keeps
    // accumulating `elapsed`, so the first tick after the page returns carries
    // the entire off-screen span. Advancing the Brain by that in one step would
    // enumerate every frame it crossed, firing a whole animation's worth of
    // events at once and teleporting the playhead. One comparison per frame.
    advance(delta > _maxTickDelta ? _maxTickDelta : delta);
  }

  /// Largest delta [_onTick] will hand to [advance] in one step. Comfortably
  /// above real jank (so a genuinely slow frame still advances truthfully) and
  /// far below the multi-second spans a muted Ticker produces.
  static const Duration _maxTickDelta = Duration(milliseconds: 100);

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

    // `justLooped` is a pulse the runtime clears on entry to every update, so it
    // is read verbatim. `isFinished` is a sticky state, so it goes through a
    // rising edge that `play` re-arms.
    if (internal.justLooped) onAnimationLooped?.call();

    final finished = internal.isFinished;
    if (finished && !_prevFinished) {
      onAnimationFinished?.call();
      if (_ticker?.isActive ?? false) _ticker!.stop();
    }
    _prevFinished = finished;

    notifyListeners();
  }

  /// Decodes the raw [passed] event indices for [currentAnimation] and fires
  /// the per-event callbacks. Skips the decode entirely when no
  /// decoded callback is registered, and when no animation is selected (the
  /// indices are relative to the current animation's `events()`).
  void _dispatchDecodedEvents(List<int> passed) {
    if (onUserData == null && onSignal == null && onAudio == null) return;
    final anim = _currentAnimation;
    final info = _animeInfo;
    if (anim == null || info == null) return;

    final decoded =
        info.decodePassedEvents(anim, passed, partNames: partNames);
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

  // --- Part overrides (Override Layer) -------------------------------------
  //
  // Thin transport over Layer 2, plus the one thing this layer owes the caller:
  // a repaint. An override changes the pose WITHOUT changing the frame number,
  // so on a paused (or externally clocked, or simply idle) player nothing would
  // redraw and the API would look broken — the flagship players hit the same
  // trap through their frame caches. Every successful set/clear here
  // therefore notifies listeners; a rejected call does not (nothing changed).
  //
  // The Brain owns the override table and re-applies it itself, so these are
  // one-shot calls — never drive them from a per-frame callback. Precedence and
  // lifecycle are [SsOverridePriority]'s to explain.
  //
  // All of these no-op (returning false) before [load]; unlike the transport
  // calls they do not throw, because an override is a "best effort now" request
  // and a UI that fires one while the pack is still loading is not a bug.
  //
  // They also no-op until an animation is selected — [load] with an
  // `animationName`, or a [setAnimation] call. The Brain only sizes its
  // override table there, so a load with no animation leaves every index out of
  // range even though [partNames] already resolves. Note the ordering trap that
  // follows: [setAnimation] CLEARS every override that is not
  // [SsOverridePriority.permanent], so overrides are applied *after* choosing
  // the animation, never before.

  /// Pack-level part names / name→index lookup, or an empty table before
  /// [load]. Part indices are stable within one `.ssab`, so resolving a name
  /// once and reusing the index is the intended pattern.
  PartNameTable get partNames => _internal?.partNames ?? PartNameTable.empty;

  /// Resolves [name] to its part index, or -1 when unknown / before [load].
  int findPartIndex(String name) => _internal?.findPartIndex(name) ?? -1;

  // --- Part following (read a part's live pose) ----------------------------
  //
  // The read counterpart to the overrides below: pull a part's composed world
  // pose / hide out so a follower — the [SpriteStudioPartAnchor] widget, a Flame
  // component — can track it. Pure reads: unlike the overrides they owe no
  // repaint (nothing changed), and they no-op to null / false before [load] or
  // for an unknown part. Drive them from a listener on this player so a follower
  // re-reads right after each [advance], when the world matrices are final.

  /// The current-frame world transform of the part named [partName] as a
  /// [Matrix4] in player-local space, or null before [load] / for an unknown
  /// part. It is the pose as drawn: the flip, the offset and, under a view
  /// that fits, the fit ([place]) are folded in, measured from the centre of
  /// the view's box. See [SpriteStudioInternalPlayer.partWorldMatrix] for the
  /// affine contract (2D affine, Y-flip already baked in — pass straight to a
  /// `Transform` widget) and the same-frame sampling.
  Matrix4? partTransform(String partName) {
    final internal = _internal;
    if (internal == null) return null;
    return internal.partWorldMatrix(internal.findPartIndex(partName));
  }

  /// Index form of [partTransform] (skips the name lookup when the caller
  /// already resolved the index through [findPartIndex]).
  Matrix4? partTransformByIndex(int partIndex) =>
      _internal?.partWorldMatrix(partIndex);

  /// Whether the part named [partName] is hidden on the current frame (keyframe
  /// hide composed with any visibility override), or false before [load] / for
  /// an unknown part.
  bool isPartHidden(String partName) {
    final internal = _internal;
    if (internal == null) return false;
    return internal.partHidden(internal.findPartIndex(partName));
  }

  /// Index form of [isPartHidden].
  bool isPartHiddenByIndex(int partIndex) => _internal?.partHidden(partIndex) ?? false;

  /// Whether the part named [partName] is a **bone-bound (skinned) mesh**, or
  /// false before [load] / for an unknown part.
  ///
  /// A skinned mesh part is a poor [partTransform] / [SpriteStudioPartAnchor]
  /// target: its vertices are drawn by bone skinning, but the part's own
  /// transform stays at its setup node position (usually near the character
  /// root), so a follower snaps near the root instead of onto the visible art.
  /// To follow a mesh part's position, put a NULL / bone-point part at that spot
  /// in SpriteStudio and follow *that* by name; a bone (armature) or joint part
  /// works too. A rigid (deform-only) mesh reads false — it follows correctly.
  ///
  /// This is a **non-blocking hint** — following such a part is not prevented, so
  /// use it to warn or de-emphasise a part in a follow-target picker. The
  /// judgment mirrors the sibling players (shared `.ssab`, same field).
  bool isPartSkinnedMesh(String partName) {
    final internal = _internal;
    if (internal == null) return false;
    return internal.partSkinnedMesh(internal.findPartIndex(partName));
  }

  /// Index form of [isPartSkinnedMesh].
  bool isPartSkinnedMeshByIndex(int partIndex) =>
      _internal?.partSkinnedMesh(partIndex) ?? false;

  /// Force-hides a part, or reverts it to the animation. See
  /// [SpriteStudioInternalPlayer.setPartVisibilityOverride] for the cascade and
  /// instance-child caveats.
  bool setPartVisibilityOverrideByIndex(int partIndex, bool hide,
          {bool cascade = false}) =>
      _override((i) =>
          i.setPartVisibilityOverrideByIndex(partIndex, hide, cascade: cascade));

  /// Index form of [setPartVisibilityOverride].
  bool setPartVisibilityOverride(String partName, bool hide,
          {bool cascade = false}) =>
      _override((i) => i.setPartVisibilityOverride(partName, hide,
          cascade: cascade));

  /// Clears a part's visibility override (revert to the animation).
  bool clearPartVisibilityOverrideByIndex(int partIndex) =>
      _override((i) => i.clearPartVisibilityOverrideByIndex(partIndex));

  /// Index form of [clearPartVisibilityOverride].
  bool clearPartVisibilityOverride(String partName) =>
      _override((i) => i.clearPartVisibilityOverride(partName));

  /// Overrides a part's colour (one value to all four corners). Normal parts
  /// only; [color] is plain 8-bit sRGB and its alpha must not be pre-folded —
  /// see [SpriteStudioInternalPlayer.setPartColorOverride].
  ///
  /// The colour comes first and [blendOp] trails with a default, which is the
  /// family's order and lets the common
  /// case read `setPartColorOverride('hat', Colors.red)`. The C ABI puts the
  /// blend first; this face deliberately does not.
  bool setPartColorOverride(String partName, ui.Color color,
          {SsBlendOp blendOp = SsBlendOp.mix,
          SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      _override((i) => i.setPartColorOverride(partName, color,
          blendOp: blendOp, priority: priority));

  /// Index form of [setPartColorOverride].
  bool setPartColorOverrideByIndex(int partIndex, ui.Color color,
          {SsBlendOp blendOp = SsBlendOp.mix,
          SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      _override((i) => i.setPartColorOverrideByIndex(partIndex, color,
          blendOp: blendOp, priority: priority));

  /// Four-corner (gradient) form of [setPartColorOverride].
  ///
  /// [corners] is one argument rather than four, so the two colour methods read
  /// the same shape. Its fields are named, so the Brain's `lt, rt, lb, rb` order
  /// cannot be got wrong by position.
  bool setPartColorOverrideCorners(String partName, SsCornerColors corners,
          {SsBlendOp blendOp = SsBlendOp.mix,
          SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      _override((i) => i.setPartColorOverrideCorners(partName, corners,
          blendOp: blendOp, priority: priority));

  /// Index form of [setPartColorOverrideCorners].
  bool setPartColorOverrideCornersByIndex(int partIndex, SsCornerColors corners,
          {SsBlendOp blendOp = SsBlendOp.mix,
          SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      _override((i) => i.setPartColorOverrideCornersByIndex(partIndex, corners,
          blendOp: blendOp, priority: priority));

  /// Clears a part's colour override (revert to the animation).
  bool clearPartColorOverrideByIndex(int partIndex) =>
      _override((i) => i.clearPartColorOverrideByIndex(partIndex));

  /// Index form of [clearPartColorOverride].
  bool clearPartColorOverride(String partName) =>
      _override((i) => i.clearPartColorOverride(partName));

  /// Makes a part draw a different cell ([cellmapName] without `.ssce`).
  /// Resolved immediately — an unknown cell returns false. Two empty names
  /// revert the part to the animation.
  bool setPartCellOverrideByIndex(int partIndex, String cellmapName, String cellName,
          {SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      _override((i) => i.setPartCellOverrideByIndex(partIndex, cellmapName, cellName,
          priority: priority));

  /// Index form of [setPartCellOverride].
  bool setPartCellOverride(
          String partName, String cellmapName, String cellName,
          {SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      _override((i) => i.setPartCellOverride(
          partName, cellmapName, cellName,
          priority: priority));

  /// Clears a part's cell override (revert to the animation).
  bool clearPartCellOverrideByIndex(int partIndex) =>
      _override((i) => i.clearPartCellOverrideByIndex(partIndex));

  /// Index form of [clearPartCellOverride].
  bool clearPartCellOverride(String partName) =>
      _override((i) => i.clearPartCellOverride(partName));

  /// Clears every per-part override on this player.
  bool clearAllPartOverrides() => _override((i) => i.clearAllPartOverrides());

  /// Runs one override call against the live engine and repaints on success.
  /// Returns false (without notifying) before [load], after [dispose], or when
  /// the Brain rejected the call.
  bool _override(bool Function(SpriteStudioInternalPlayer) apply) {
    final internal = _internal;
    if (internal == null || internal.isDisposed || _disposed) return false;
    if (!apply(internal)) return false;
    notifyListeners();
    return true;
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
