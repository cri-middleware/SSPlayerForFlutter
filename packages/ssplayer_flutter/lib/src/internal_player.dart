import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/ssruntime_dart.dart';
import 'playback.dart';
import 'render/backend/backend_kind.dart';
import 'render/backend/canvas_backend.dart';
import 'render/backend/gpu_backend_factory.dart';
import 'render/backend/gpu_capability.dart';
import 'render/backend/render_backend.dart';
import 'render/backend/render_host.dart';
import 'render/blend.dart';
import 'render/effect.dart';
import 'render/geometry_builder.dart';
import 'render/instance.dart';
import 'render/mask.dart';
import 'render/mask_context.dart';
import 'render/part_color.dart';
import 'render/part_override.dart';
import 'render/part_quad.dart';
import 'render/root_transform.dart';
import 'ssab_pack.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;
import 'texture_registry.dart';

/// Layer 2 — the Widget-agnostic drawing engine (ports the SDK's
/// `SSInternalPlayer`).
///
/// Owns the Brain's [SsContext] and a hold on the shared [SsabPack], advances
/// time, pulls the per-frame `FrameData` + SoA buffers from the Brain, and
/// drives a [RenderBackend] (Canvas or flutter_gpu) to turn each `DrawBatch`
/// into pixels.
/// It is `dispose`-able and reusable from higher layers (Player) or headless
/// tests. As [RenderHost] it exposes the per-player data the backend draws from.
class SpriteStudioInternalPlayer implements InstanceChild, RenderHost {
  SpriteStudioInternalPlayer._(
    this._context,
    this._pack,
    this.textures,
    this._effects,
    this._backend,
    this._ownsTextures,
  )   : _maskFlags = _pack.maskFlags,
        _partNames = _pack.partNames {
    // Backstop finalizer: if the caller forgets dispose(), the Brain-side
    // Context is still reclaimed on GC, and the pack's parse goes with the last
    // player that held it. The Arc refcount inside the runtime makes destroy
    // order irrelevant.
    ssRuntime.registerForGc(this, context: _context);
  }

  SsContext _context;

  /// The `.ssab` this player binds, shared with every other player of the same
  /// bytes, its own instance children among them.
  final SsabPack _pack;

  /// The pack this player holds, for a test to compare holders by.
  @visibleForTesting
  SsabPack get pack => _pack;

  /// texture_hash → decoded image / shader. Populated by the caller. Public as
  /// part of [RenderHost].
  @override
  final TextureRegistry textures;

  /// Called when the backend finishes preparing a resource the last paint drew
  /// without (a GPU texture upload), so the frame should be painted again.
  ///
  /// L3 points this at its `notifyListeners`. Without it a player that is not
  /// continuously animating — paused, seeked, or drawn once — keeps whatever the
  /// first, texture-less paint produced, which for a single-atlas animation is a
  /// blank frame. Fires outside paint (the upload awaits), and only on the
  /// backend this player owns, so an instance child (which draws through its
  /// parent's) does not double-notify.
  ui.VoidCallback? onNeedsRepaint;

  /// Whether [dispose] should release [textures]. True only when [load] created
  /// the registry itself; a caller-supplied one stays the caller's (it may well
  /// outlive this player or be shared between several), and an instance child
  /// draws from its parent's and must never release it.
  final bool _ownsTextures;

  /// Static per-part mask flags, read once from the `.ssab` `PartData` at
  /// load — they never change per frame. Empty when the pack has no parts, which
  /// disables the whole mask path.
  final List<MaskPartFlags> _maskFlags;

  /// Static per-part mask role; [MaskPartFlags.none] past the part range.
  /// Public as part of [RenderHost] — the backend reads it to peel mask targets.
  @override
  MaskPartFlags flagsFor(int partIndex) => partIndex < _maskFlags.length
      ? _maskFlags[partIndex]
      : MaskPartFlags.none;

  /// Pack-level part name → index table, read once from the `.ssab` `PartData`
  /// alongside [_maskFlags]. Backs the by-name part-override overloads; indices
  /// are stable within one `.ssab`.
  final PartNameTable _partNames;

  /// Per-part particle-effect slots, stepped from [updateMs] because they
  /// need a delta time. Empty when the pack hosts no effects.
  final EffectSlots _effects;

  /// Per-part instance slots and the nested child players they drive,
  /// stepped from [updateMs] alongside the effects. Empty when the pack hosts no
  /// instances. Assigned right after construction ([load]) because building the
  /// children needs the finished parent.
  late final InstanceSlots<SpriteStudioInternalPlayer> _instances;

  /// Pure SoA→vertex baker (Widget/FFI-free); the shared compute both render
  /// backends draw from. Exposed to the backend as [geometry] ([RenderHost]).
  final GeometryBuilder _geometry = GeometryBuilder();

  /// drawRank → texture hash for [_buildTreeMask]. Rebuilt each frame and
  /// consumed inside `renderCoverage`, which never retains it.
  final Map<int, int> _textureByRankScratch = <int, int>{};

  /// This player's draw ranks on the instance tree's sequence, numbered by the
  /// top-level player's [_buildTreeMask] each frame something in the tree
  /// writes a mask (see [MaskWriter.open]). Read only while that frame draws.
  Int32List _maskSeq = Int32List(0);

  /// Whether any of this pack's parts can write coverage at all. Static: the
  /// flags are read once at load.
  late final bool _hasWriterParts =
      _maskFlags.any((f) => f.isWriter && f.drawableWriter);

  /// The instance part's world matrix in [_emitInstanceBatch]. One per player,
  /// not per part: an instance child recurses with its OWN player (and so its
  /// own scratch), and the matrix is fully consumed — composed into the mask
  /// affine, then pushed onto the backend's transform stack, which copies it —
  /// before the next part refills it.
  final Float64List _world2dScratch = Float64List(16);

  /// The render backend that turns this player's `DrawBatch`es into pixels —
  /// Canvas (`Canvas.drawVertices`) by default, flutter_gpu when requested and
  /// available. Chosen in [load] from the requested [SpriteStudioBackend] via the
  /// capability probe. Owns the shader pools, batch paint and coverage resources;
  /// disposed with the player.
  final RenderBackend _backend;

  /// [RenderHost]: the shared SoA→vertex baker.
  @override
  GeometryBuilder get geometry => _geometry;

  /// [RenderHost]: whether this player hosts any effect parts.
  @override
  bool get hasEffects => !_effects.isEmpty;

  /// When true (default), rendering samples the Brain's fractional (sub-frame)
  /// frame number, giving smooth playback beyond the source FPS on high-refresh
  /// displays. Set false to snap to integer frames.
  ///
  /// Propagates to instance children: a child left
  /// on the other setting visibly stutters at integer frames while its parent
  /// runs smooth.
  bool get subFrameEnabled => _subFrame;
  /// See [SpriteStudioPlayer.subFrameEnabled].
  set subFrameEnabled(bool value) {
    _subFrame = value;
    for (final part in _instances.parts) {
      _instances.slotFor(part.partIndex)?.child.subFrameEnabled = value;
    }
    // Effects sample `subFrameEnabled ? frame : floor(frame)`, so on a frozen frame the
    // toggle would otherwise not show until something advances the clock.
    // ForGodot's `setSubFrameEnabled` re-resolves for the same reason.
    _stepSlots(frameNo, 0.0, false);
    _buildFrame();
  }

  bool _subFrame = true;

  /// The player-level flip / offset (default [SsRootTransform.identity]) — see
  /// [SsRootTransform] for what it is and why it lives at this layer.
  ///
  /// Read by exactly two consumers, which is the whole point of storing it here:
  /// [paint] hands it to the backend's `beginFrame`, and [partWorldMatrix] folds
  /// it into the pose it reports. Split them and a follower comes off its part
  /// the moment the player is flipped.
  ///
  /// **Top-level players only.** An instance child draws through its parent's
  /// backend under the parent's transform, so the parent's flip already covers
  /// it; setting one here too would apply it twice.
  SsRootTransform rootTransform = SsRootTransform.identity;

  bool _disposed = false;

  /// Whether [dispose] has run. Every call but this one is then an error.
  bool get isDisposed => _disposed;

  // GC backstop is [SsRuntime.registerForGc].

  /// Loads `ssab` into a fresh Context, binds it, and recursively spawns any
  /// instance children.
  ///
  /// Steps: open the pack (the static Dart-side tables and the runtime's parse,
  /// shared with every open player of the same bytes) → create context → bind →
  /// set coordinate system. The Brain does NOT validate the
  /// `.ssab` (unchecked parse, undefined behaviour on malformed input);
  /// [SsRuntime.createResourceCopy] rejects a non-`.ssab` header, but that is an
  /// identify check, not full validation. Do not load `.ssab` from untrusted
  /// sources.
  ///
  /// [instancePacks] maps a pack's `name_hash` to that pack's `.ssab` bytes and
  /// resolves `external_instances` references. Fetching those bytes is async
  /// (asset bundle / disk) while this factory is sync, so the host does the
  /// fetching — L3 `SpriteStudioPlayer.load` builds the map from
  /// [InstancePart.externalPackNames]. A same-pack sub-animation needs no entry;
  /// it resolves against [ssab] itself. Parts whose pack is missing get no child
  /// and are silently not drawn.
  factory SpriteStudioInternalPlayer.load(
    Uint8List ssab, {
    TextureRegistry? textures,
    Map<int, Uint8List>? instancePacks,
    SpriteStudioBackend backend = SpriteStudioBackend.auto,
    @visibleForTesting RenderBackend? renderBackendOverride,
  }) {
    // Throws on a malformed pack before the runtime allocates anything.
    final pack = SsabPack.open(ssab);

    final context = ssRuntime.createContext();
    if (context == null) {
      pack.close();
      throw StateError('ss_runtime_create returned null');
    }

    final registry = textures ?? TextureRegistry();
    // Until the constructor attaches the GC finalizer, the Context and the hold
    // on the pack are owned by nothing, so any throw in between must release
    // them by hand.
    late final SpriteStudioInternalPlayer player;
    try {
      if (!ssRuntime.bindResource(context, pack.resource)) {
        throw StateError('ss_runtime_bind_resource failed');
      }
      // Direct render mode (the default): the Brain fills the SoA buffers this
      // Body reads and skips redundant FrameData vertices/cells/deforms.
      // ForGodot relies on the same default.
      ssRuntime.setRenderMode(context, 0);
      // Coordinate system = 1 (Y-Down) like ForGodot: the Brain applies the
      // flip once, so the Body must NOT flip again. Origin/unit are left at the
      // runtime defaults (Center / Pixel) — ForGodot sets neither.
      ssRuntime.setCoordinateSystem(context, 1); // 1 = Y-Down

      // Resolve the requested backend through the capability probe: gpu only when
      // flutter_gpu is actually usable, else Canvas (which never throws). A whole
      // instance tree shares one backend (children draw through the parent's), so
      // the override is applied at the root only; children inherit it by drawing
      // through the same instance. Tests use it to observe the per-frame lifetime
      // contract without a real engine.
      final renderBackend = renderBackendOverride ??
          (resolveBackend(backend) == SpriteStudioBackend.gpu
              ? createFlutterGpuBackend()
              : CanvasBackend());
      player = SpriteStudioInternalPlayer._(
        context,
        pack,
        registry,
        EffectSlots(pack.resource, pack.effectParts),
        renderBackend,
        textures == null, // we built `registry`, so we release it
      );
      // Route the backend's "a resource I was preparing is ready" signal up to
      // whoever drives repaints (L3 sets [onNeedsRepaint] to notifyListeners).
      renderBackend.onResourcesReady = () => player.onNeedsRepaint?.call();
    } catch (_) {
      ssRuntime.destroyContext(context);
      pack.close();
      rethrow;
    }

    // Instance children. Unlike effect slots these cannot be lazy: each is
    // a whole nested player, and `ss_instance_slot_step` needs its Context from
    // the very first tick. `_instances` is assigned right after construction
    // because building the children needs the finished parent in scope.
    //
    // Nesting is expanded eagerly and without a depth cap, like every sibling
    // player: a cap buys nothing against real content (it would only ever fire
    // on nesting the SpriteStudio editor cannot practically author) while silently
    // dropping the innermost child if it ever did. A pathological cyclic `.ssab`
    // recurses until it exhausts the stack; the per-child guard below then unwinds
    // it, skipping the offending child rather than crashing the load.
    player._instances = InstanceSlots<SpriteStudioInternalPlayer>.build(
      pack.instanceParts,
      (part) {
        final bytes = InstancePart.resolvePack(
          part,
          // The pack's buffer rather than [ssab], which another player's may
          // have matched: a same-pack child then finds the pack by identity
          // instead of comparing every byte.
          ownBytes: pack.bytes,
          ownPackHash: pack.packHash,
          packs: instancePacks,
        );
        if (bytes == null) return null; // unresolved external pack
        final SpriteStudioInternalPlayer child;
        try {
          child = SpriteStudioInternalPlayer.load(
            bytes,
            // Children share the parent's registry: cellmap hashes are global, so
            // a shared atlas resolves once and a child-only cellmap simply adds to
            // it. The host loads each pack's textures into this same registry.
            textures: registry,
            instancePacks: instancePacks,
            backend: backend, // inherit the parent's backend choice
          );
        } catch (_) {
          // A corrupt / unloadable child pack is skipped (not drawn) rather than
          // failing the whole parent load — same outcome as an unresolved pack.
          return null;
        }
        if (!child.setupAnimation(part.animeName)) {
          // The pack resolved but the animation name did not — authored garbage.
          child.dispose();
          return null;
        }
        // This must propagate, and recursively: a child left on
        // the other setting stutters at integer frames while its parent is
        // smooth.
        child.subFrameEnabled = player.subFrameEnabled;
        // Stopped until an EventInstance starts it (ForGodot does the same
        // at setup). A child left playing would advance its own clock from frame
        // 0 and be out of position the moment its key finally fires.
        child.stop();
        return child;
      },
    );
    return player;
  }

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('SpriteStudioInternalPlayer used after dispose()');
    }
  }

  // --- Setup / transport ---------------------------------------------------

  /// Why the last call that tracks a reason failed, or null when it succeeded.
  ///
  /// Read it straight after the call that returned `false` — it is the reason
  /// for the *last* failure, not a log.
  String? get lastErrorMessage => ssRuntime.lastErrorMessage(_context);

  /// Selects the animation to play by name and rewinds to frame 0.
  bool setupAnimation(String name) {
    _ensureAlive();
    final ok = ssRuntime.setupAnimation(_context, name);
    if (ok) {
      // A different animation has different effect/instance keys — drop each
      // slot's "last started key" memory so the new animation fires its own.
      _resetSlots();
      // Then resolve them *at* the frame we just rewound to. `setupAnimation`
      // poses the first frame without playing,
      // and without this the instance children are
      // missing from that pose until something advances the clock. ForGodot
      // ends its `_fetchAnimation` with the same re-resolve.
      _stepSlots(frameNo, 0.0, false);
      _buildFrame();
    }
    return ok;
  }

  /// Canonical name→id hash (never re-implement FNV-1a on the Dart side).
  int hashString(String name) => ssRuntime.hashString(name);

  /// See [SpriteStudioPlayer.play].
  void play([double? startFrame]) {
    _ensureAlive();
    if (startFrame == null) {
      ssRuntime.play(_context);
    } else {
      ssRuntime.playWithStartFrame(_context, startFrame);
    }
    // An explicit head-out: without this the slot debounces the first key as
    // "the one I already started" and a replayed animation never re-fires.
    _resetSlots();
  }

  /// Re-arms every slot-based kind on an explicit head-out (`play` / a new
  /// `setupAnimation`), recursing into instance children — ForGodot's
  /// `_reset_slots_playback_state`.
  void _resetSlots() {
    _effects.reset();
    _instances.reset();
  }

  /// See [SpriteStudioPlayer.pause].
  void pause() {
    _ensureAlive();
    ssRuntime.pause(_context);
  }

  /// See [SpriteStudioPlayer.resume].
  void resume() {
    _ensureAlive();
    ssRuntime.resume(_context);
  }

  /// See [SpriteStudioPlayer.stop].
  void stop() {
    _ensureAlive();
    ssRuntime.stop(_context);
  }

  /// See [SpriteStudioPlayer.isPlaying].
  bool get isPlaying => ssRuntime.isPlaying(_context);

  /// Whether playback is paused. Note the Brain keeps [isPlaying] `true` while
  /// paused (pause is a *hold*, not a stop). `false` before the first `play`
  /// and after `stop` — the Brain keeps "paused" implying "playing" — so this
  /// can be read on its own.
  bool get isPausing => ssRuntime.isPausing(_context);

  /// The character's clock, which every track and every fade runs on: started
  /// by [play], stopped by [stop] and by a successful [setupAnimation]. Not
  /// [isPlaying], which is track 0's — track 0 running out leaves it running
  /// for the overlays and fades.
  bool get isClockPlaying => ssRuntime.isClockPlaying(_context);

  /// Whether a [pause] holds the clock, track 0 finished or not. Implies
  /// [isClockPlaying].
  bool get isClockPausing => ssRuntime.isClockPausing(_context);

  /// Whether the track stack moves the pose for a reason other than track 0's
  /// own animation stepping: a fade in flight, or another source playing at a
  /// speed and weight above zero on a track that is heard. The Brain's verdict,
  /// not a copy kept here — a crossfade that completes releases its outgoing
  /// source on its own, and a copy would keep counting it.
  ///
  /// It does not read the clock: pair it with [isClockPlaying] and
  /// [isClockPausing].
  bool get isStackInMotion => ssRuntime.isStackInMotion(_context);

  /// Every configured loop has played. Sticky until the next play/setup, so
  /// callers wanting a one-shot notification must take the rising edge.
  bool get isFinished => ssRuntime.isFinished(_context);

  /// See [SpriteStudioPlayer.justLooped].
  bool get justLooped => ssRuntime.justLooped(_context);

  /// Which way the playhead is actually travelling — see
  /// [SpriteStudioPlayer.isPlayingForward].
  bool get isPlayingForward => ssRuntime.isPlayingForward(_context);
  /// See [SpriteStudioPlayer.frameNo].
  double get frameNo => ssRuntime.frameNo(_context);
  /// See [SpriteStudioPlayer.startFrame].
  int get startFrame => ssRuntime.startFrame(_context);
  /// See [SpriteStudioPlayer.endFrame].
  int get endFrame => ssRuntime.endFrame(_context);
  /// See [SpriteStudioPlayer.frameRate].
  int get frameRate => ssRuntime.frameRate(_context);

  /// See [SpriteStudioPlayer.loopCount].
  set loopCount(int count) => ssRuntime.setLoopCount(_context, count);
  /// See [SpriteStudioPlayer.speedScale].
  set speedScale(double rate) => ssRuntime.setSpeedScale(_context, rate);
  /// See [SpriteStudioPlayer.frameRate].
  set frameRate(int fps) => ssRuntime.setFrameRate(_context, fps);
  /// Moves the playhead, then re-resolves the slot-based kinds *at the new
  /// frame*. Without that second half an instance child keeps whatever
  /// visibility and child frame the last [updateMs] left it on, so a scrubbed or
  /// frozen frame can drop the children entirely.
  ///
  /// The delta is zero — a seek is a jump, not elapsed time. That is exactly
  /// right for **synced** slots, which are a pure function of the parent frame
  /// (`ss_instance_slot_step` re-seeks the child with `set_frame_relative`, and
  /// an effect slot re-derives its relative frame from `parent_frame`), so they
  /// land where playing to [frame] would have left them. **Independent** slots
  /// ride their own real-time clock and a zero delta deliberately leaves them
  /// untouched: the SDK defines seeking them as undefined
  /// ([InstanceSlot.isIndependent]).
  void seek(double frame) {
    _ensureAlive();
    ssRuntime.seek(_context, frame);
    // Read the frame back rather than reusing the argument: the Brain confines a
    // seek to the animation section, and the slots must see where it landed.
    _stepSlots(frameNo, 0.0, false);
    _buildFrame();
  }

  /// Restricts playback to `[startFrame, endFrame]` of the current animation.
  /// Reflected by [startFrame] / [endFrame], which report the *played* range.
  ///
  /// The Brain also moves the playhead to the section's head (its tail when
  /// playing backward), so the slots and the frame follow it as after a [seek]:
  /// otherwise a paused or stopped player keeps drawing, and its part reads
  /// keep reporting, the frame it left.
  ///
  /// Returns false when the Brain refuses the section — both ends inside the
  /// animation and the end before the start — and [lastErrorMessage] says why;
  /// the section and the playhead stay as they were.
  bool setAnimationSection(int startFrame, int endFrame) {
    _ensureAlive();
    if (!ssRuntime.setAnimationSection(_context, startFrame, endFrame)) {
      return false;
    }
    _stepSlots(frameNo, 0.0, false);
    _buildFrame();
    return true;
  }

  /// See [SpriteStudioPlayer.setPlaybackDirection].
  void setPlaybackDirection(SsPlaybackDirection direction,
          SsPlaybackStyle style) =>
      ssRuntime.setPlaybackDirection(_context, direction.value, style.value);

  /// See [SpriteStudioPlayer.playbackDirection].
  SsPlaybackDirection get playbackDirection =>
      SsPlaybackDirection.fromValue(ssRuntime.playbackDirection(_context));

  /// See [SpriteStudioPlayer.playbackStyle].
  SsPlaybackStyle get playbackStyle =>
      SsPlaybackStyle.fromValue(ssRuntime.playbackStyle(_context));

  /// See [SpriteStudioPlayer.frameSkipEnabled].
  set frameSkipEnabled(bool skip) => ssRuntime.setSkipFrames(_context, skip);
  /// See [SpriteStudioPlayer.frameSkipEnabled].
  bool get frameSkipEnabled => ssRuntime.skipFrames(_context);

  // --- Per-frame update ----------------------------------------------------

  /// Advances internal time. Returns the new (sub-frame) frame number.
  ///
  /// The Brain's `ss_runtime_update` takes a delta in milliseconds. We pass the
  /// [delta] in milliseconds; use [updateMs] to control the raw value.
  double update(Duration delta) => updateMs(delta.inMicroseconds / 1000.0);

  /// [update] with the delta in milliseconds, as the Brain takes it.
  double updateMs(double deltaMs) {
    _ensureAlive();
    // Read before the update: a fade or an overlay that ends on this one still
    // moved the pose getting there, and its last frame has to be built.
    final stackMoves =
        isStackInMotion && isClockPlaying && !isClockPausing;
    final frame = ssRuntime.update(_context, deltaMs);
    final rebuild = _rebuildPending;
    _rebuildPending = false;
    // The same frame of the same pose evaluates to the same FrameData, so a
    // tick that moved nothing — paused, or between two frames with sub-frame
    // off — keeps the one it has. Effects and instances simulate on their own
    // and are stepped every tick regardless.
    _keptFrame = !rebuild &&
        !stackMoves &&
        _frameData != null &&
        (subFrameEnabled ? frame : frame.floorToDouble()) == _frameDataNo &&
        _effects.isEmpty &&
        _instances.isEmpty;
    if (_keptFrame) return frame;
    // `just_looped` is per-update (cleared at the top of each update), so it is
    // the loop *edge* the slots want, not "looping is enabled".
    _stepSlots(frame, deltaMs, justLooped);
    _buildFrame();
    return frame;
  }

  /// Whether a call that changes the pose without moving the clock — a track
  /// call, a part override — still waits for the update that builds it: the
  /// Brain applies those when it next builds a frame.
  ///
  /// A one-shot, cleared by that update. It is never left standing, or every
  /// tick after it would rebuild an unchanged pose.
  bool get isFrameInvalidated => _rebuildPending;

  bool _rebuildPending = false;

  /// Whether the last [updateMs] kept the frame it already had, so the pose it
  /// leaves is the one already drawn.
  bool get keptFrame => _keptFrame;
  bool _keptFrame = false;

  /// Drives the slot-based kinds one tick at [frame].
  ///
  /// Shared by [updateMs] (a root player, which has just advanced its own clock)
  /// and [instanceStepSlots] (an instance child, whose clock the parent's slot
  /// advanced instead) — both need their effects and nested instances ticked,
  /// and neither should duplicate the rules for doing it.
  void _stepSlots(double frame, double deltaMs, bool looped) {
    // Every caller has just moved the clock, or the frame `paint` samples.
    _frameData = null;
    if (!_effects.isEmpty) {
      // Effects simulate themselves rather than riding the SoA, so they are
      // stepped here, where the delta is known; `paint` then draws the plans.
      //
      // Note this diverges from ForGodot, which steps effects inside its
      // draw pass and therefore needs an `is_independent` probe to stop its
      // redraw dedup from also skipping simulation ticks. Flutter's Ticker
      // drives update→paint 1:1, so stepping here keeps the clock honest with
      // no such workaround.
      //
      // Sample the same frame `paint` will draw, or the effect and the rest
      // of the animation disagree by up to a frame with sub-frame off.
      final sampled = subFrameEnabled ? frame : frame.floorToDouble();
      _effects.step(
        _context,
        parentFrame: sampled,
        deltaSeconds: deltaMs / 1000.0,
        // The rate the animation plays at, the override included (converts the
        // delta to frames for independent slots), NOT the display's.
        fps: frameRate > 0 ? frameRate.toDouble() : 60.0,
        parentLooped: looped,
        // Which effect parts that frame draws: a hidden one keeps time without
        // building the particles `paint` would skip. `paint` then draws this
        // same evaluation ([getFrameData]).
        frame: getFrameData(sampled),
      );
    }
    if (!_instances.isEmpty) {
      // Instances are stepped here for the same reason as effects — the delta
      // only exists on this side of the frame. An independent child keeps
      // running even while this player is paused, because `ss_runtime_update`
      // not advancing our frame does not stop us handing the slot a delta.
      _instances.step(
        _context,
        // NOT rounded: the Brain diffs this against the slot's own notion of the
        // parent clock to spot EventInstance edges, and `paint`'s rounding is a
        // display concern that must not leak into playback state.
        parentFrame: frame,
        deltaMs: deltaMs,
        parentLooped: looped,
      );
    }
  }

  /// Parses the FlatBuffers `FrameData` for [frameNo]. The returned view aliases
  /// the Brain's internal buffer and is only valid until the next update — read
  /// it within the current frame.
  ///
  /// Asked for the same frame again before the clock moves, this returns the
  /// frame it already evaluated: evaluating it again would cost the Brain the
  /// whole frame for the same result. An override does not change that; it
  /// waits for the next frame built ([_buildFrame]).
  fbs.FrameData? getFrameData(double frameNo) {
    _ensureAlive();
    if (_frameData != null && frameNo == _frameDataNo) return _frameData;
    final bytes = ssRuntime.getFrameData(_context, frameNo);
    _frameDataNo = frameNo;
    _debugEvaluations++;
    _frameBytes = bytes;
    // Zero-copy typed view over the Brain buffer; FrameData reads it in place.
    return _frameData = bytes == null ? null : fbs.FrameData(bytes);
  }

  /// Builds the frame at the playhead, sampled as [paint] samples it.
  ///
  /// Every call that moves this player's pose ends here — [updateMs], [seek],
  /// [setAnimationSection], [setupAnimation], the [subFrameEnabled] toggle — so
  /// [paint] draws that frame and the part reads report it without building one
  /// of their own. An override therefore shows from the next of them, as in
  /// every sibling. A read
  /// that built a frame would also change what the next update builds: an
  /// `overwriteOnNextKeyframe` override set right after [play] or [seek] goes
  /// back to the animation if any frame is built before that update.
  void _buildFrame() =>
      getFrameData(subFrameEnabled ? frameNo : frameNo.floorToDouble());

  // What [getFrameData] last evaluated, and at which frame. Null when the clock
  // has moved since ([_stepSlots]) and nothing has built the new frame yet.
  fbs.FrameData? _frameData;
  // The bytes [_frameData] reads, which [GeometryBuilder.buildFrame] reads
  // the part states from directly.
  Uint8List? _frameBytes;

  int _debugEvaluations = 0;

  /// How many times [getFrameData] has asked the Brain to evaluate a frame,
  /// for tests.
  @visibleForTesting
  int get debugEvaluations => _debugEvaluations;
  double _frameDataNo = 0.0;

  // --- SoA buffers (zero-copy typed views, valid until next update) -------

  /// Per-part 4×4 world matrices (parts × 16 floats).
  Float32List worldMatrices() => ssRuntime.worldMatrices(_context);

  /// Per-part local vertices (parts × 10 floats: lt,rt,lb,rb,center).
  Float32List localVertices() => ssRuntime.localVertices(_context);

  /// Per-part local UVs (parts × 10 floats: lt,rt,lb,rb,center in texture pixels).
  Float32List localUvs() => ssRuntime.localUvs(_context);

  /// Per-part cell meta (parts × 6: pivot_x,pivot_y,w,h,rect_left,rect_top).
  Float32List cellMeta() => ssRuntime.cellMeta(_context);

  // --- Mesh SoA ------------------------------------------------------------
  //
  // Unlike the Normal path's `local_vertices`, mesh vertices arrive **already
  // world-transformed** — do NOT apply the world matrix again. All four data
  // buffers are concatenated across parts and sliced by a CSR prefix sum
  // (length = parts + 1): part `p` owns `[offsets[p], offsets[p + 1])`, and a
  // non-mesh part has an empty range. Empty under Indirect render mode (we set
  // Direct at load).

  /// Mesh per-vertex X coordinates, **world space**, all parts concatenated.
  Float32List meshVerticesX() => ssRuntime.meshVerticesX(_context);

  /// Mesh per-vertex Y coordinates (SoA companion to [meshVerticesX]).
  Float32List meshVerticesY() => ssRuntime.meshVerticesY(_context);

  /// Mesh per-vertex UVs in **texture-pixel** space, interleaved `[u,v,…]` and
  /// sliced by [meshVertexOffsets] (so vertex `v` is at `2v`, `2v+1`). Static.
  Float32List meshUvs() => ssRuntime.meshUvs(_context);

  /// Mesh triangle indices, **part-local and 0-based**, sliced by
  /// [meshIndexOffsets]. Static.
  Int32List meshIndices() => ssRuntime.meshIndices(_context);

  /// CSR prefix sum into [meshVerticesX] / [meshVerticesY] / [meshUvs].
  Uint32List meshVertexOffsets() => ssRuntime.meshVertexOffsets(_context);

  /// CSR prefix sum into [meshIndices].
  Uint32List meshIndexOffsets() => ssRuntime.meshIndexOffsets(_context);

  // --- Shape SoA -----------------------------------------------------------

  /// Shape polygon vertices in **local** space, interleaved `[x,y,…]` at a fixed
  /// stride of 24 floats per part ([ShapeBuffers.stride]) — not CSR like the
  /// mesh. Apply the world matrix; pivot and the Y-Down flip are already in.
  Float32List shapeVertices() => ssRuntime.shapeVertices(_context);

  /// Normalised `[fx,fy,…]` box coordinates paired with [shapeVertices], same
  /// stride — the weights for per-vertex PartColor.
  Float32List shapeVertexBoxCoords() =>
      ssRuntime.shapeVertexBoxCoords(_context);

  /// Live vertex count per part for [shapeVertices]. The only valid slice: a
  /// Shape batch's `vertex_count` / `index_count` are 0.
  Int32List shapeVertexCounts() => ssRuntime.shapeVertexCounts(_context);

  // --- Effects -------------------------------------------------------------

  /// The effect-hosting parts in this pack (empty when it has none).
  List<EffectPart> get effectParts => _effects.parts;

  /// The particle plan for effect part [partIndex] as of the last [update], or
  /// null when that slot drew nothing (dead, unstarted, past its lifetime, or
  /// its part hidden).
  ///
  /// Like the SoA views this aliases the Brain's memory: it is only valid until
  /// that slot is stepped again, i.e. until the next [update].
  @override
  efbs.EffectDrawPlan? effectPlanFor(int partIndex) =>
      _effects.planFor(partIndex);

  // --- Instances -----------------------------------------------------------

  /// The instance-hosting parts in this pack (empty when it has none).
  List<InstancePart> get instanceParts => _instances.parts;

  /// The live slot for instance part [partIndex] — the child player and the
  /// frame the Brain last stepped it to — or null when the part has no child
  /// (its pack did not resolve).
  ///
  /// The child is owned by this player and dies with it; do not dispose it.
  InstanceSlot<SpriteStudioInternalPlayer>? instanceSlotFor(int partIndex) =>
      _instances.slotFor(partIndex);

  /// Whether an effect or instance part in this tree runs on its own clock, and
  /// so has to keep getting ticks through a [pause].
  bool get playsOnItsOwn =>
      _effects.anyIndependent ||
      _instances.slots.any((s) => s.isIndependent || s.child.playsOnItsOwn);

  // --- Events (polling) ----------------------------------------------------

  /// Indices, into an ssab `events()` table, that were passed on the last
  /// update. The caller resolves user data / signals / audio from the ssab.
  ///
  /// Each index addresses the table of **the animation of the source that
  /// fired it** — [passedEventSourceHandles] at the same position, resolved by
  /// [sourceAnimationIndex]. Until a crossfade on track 0 that is the animation
  /// [setupAnimation] chose; from the crossfade on it is the incoming one, and
  /// an outgoing side or another track may fire too.
  List<int> passedEventIndices() {
    _ensureAlive();
    final count = ssRuntime.passedEventCount(_context);
    if (count <= 0) return const [];
    return List<int>.generate(
        count, (i) => ssRuntime.passedEventIndex(_context, i));
  }

  /// The source that fired each of [passedEventIndices], in the same order;
  /// `-1` where the Brain names none.
  List<int> passedEventSourceHandles() {
    _ensureAlive();
    final count = ssRuntime.passedEventCount(_context);
    if (count <= 0) return const [];
    return List<int>.generate(count,
        (i) => ssRuntime.passedEventSourceHandle(_context, i) ?? -1);
  }

  // --- Animation mixing (the track stack) ----------------------------------
  //
  // Pass-throughs to the Brain's tracks and sources on this player's context.
  // Tracks fold onto the setup pose in ascending order: a track's alpha is its
  // strength, and a source's weight only sets proportions among the
  // animations sharing one track. [setupAnimation] folds the stack back to
  // track 0 alone.
  //
  // Like an override, a change here shows from the next frame this player
  // builds; L3 ticks a stopped player once so it does. Instance children are
  // not layered: they run their own contexts, driven by their slots from this
  // player's frame.
  //
  // A read of a track or source that does not exist is null. A setter returns
  // false when the Brain refused it, and [lastErrorMessage] says why.

  /// Passes a pose-changing call's result through, and on success makes the
  /// next update build its frame ([isFrameInvalidated]). The overrides below go
  /// through it too.
  bool _posed(bool ok) {
    if (ok) _rebuildPending = true;
    return ok;
  }

  /// [_posed] for a call that returns the new source, or null when refused.
  int? _posedSource(int? source) {
    if (source != null) _rebuildPending = true;
    return source;
  }

  /// See [SpriteStudioPlayer.setTrackAnimation].
  bool setTrackAnimation(int track, String name) {
    _ensureAlive();
    return _posed(ssRuntime.setTrackAnimation(_context, track, name));
  }

  /// See [SpriteStudioPlayer.trackCount].
  int get trackCount => ssRuntime.trackCount(_context);

  /// See [SpriteStudioPlayer.clearTrack].
  bool clearTrack(int track) {
    _ensureAlive();
    return _posed(ssRuntime.clearTrack(_context, track));
  }

  /// See [SpriteStudioPlayer.setTrackAlpha].
  bool setTrackAlpha(int track, double alpha) {
    _ensureAlive();
    return _posed(ssRuntime.setTrackAlpha(_context, track, alpha));
  }

  /// See [SpriteStudioPlayer.trackAlpha].
  double? trackAlpha(int track) => ssRuntime.trackAlpha(_context, track);

  /// See [SpriteStudioPlayer.setTrackBlend].
  bool setTrackBlend(int track, SsTrackBlend blend) {
    _ensureAlive();
    return _posed(ssRuntime.setTrackBlend(_context, track, blend.value));
  }

  /// See [SpriteStudioPlayer.trackBlend].
  SsTrackBlend? trackBlend(int track) {
    final blend = ssRuntime.trackBlend(_context, track);
    return blend == null ? null : SsTrackBlend.fromValue(blend);
  }

  /// See [SpriteStudioPlayer.setTrackSync].
  bool setTrackSync(int track, SsTrackSync sync) {
    _ensureAlive();
    return ssRuntime.setTrackSync(_context, track, sync.value);
  }

  /// See [SpriteStudioPlayer.trackSync].
  SsTrackSync? trackSync(int track) {
    final sync = ssRuntime.trackSync(_context, track);
    return sync == null ? null : SsTrackSync.fromValue(sync);
  }

  /// See [SpriteStudioPlayer.crossfade].
  bool crossfade(int track, String name, Duration duration) {
    _ensureAlive();
    return _posed(ssRuntime.crossfade(
        _context, track, name, duration.inMicroseconds / 1000.0));
  }

  /// See [SpriteStudioPlayer.fadeTrack].
  bool fadeTrack(int track, double targetAlpha, Duration duration) {
    _ensureAlive();
    return _posed(ssRuntime.fadeTrack(
        _context, track, targetAlpha, duration.inMicroseconds / 1000.0));
  }

  /// See [SpriteStudioPlayer.trackFadeProgress].
  double? trackFadeProgress(int track) =>
      ssRuntime.trackFadeProgress(_context, track);

  /// See [SpriteStudioPlayer.cancelTrackFade].
  bool cancelTrackFade(int track) {
    _ensureAlive();
    return _posed(ssRuntime.cancelTrackFade(_context, track));
  }

  /// See [SpriteStudioPlayer.setTrackFrame].
  bool setTrackFrame(int track, double frame) {
    _ensureAlive();
    return _posed(ssRuntime.setTrackFrame(_context, track, frame));
  }

  /// See [SpriteStudioPlayer.trackFrame].
  double? trackFrame(int track) => ssRuntime.trackFrame(_context, track);

  /// See [SpriteStudioPlayer.setTrackSpeed].
  bool setTrackSpeed(int track, double speed) {
    _ensureAlive();
    return ssRuntime.setTrackSpeed(_context, track, speed);
  }

  /// See [SpriteStudioPlayer.trackSpeed].
  double? trackSpeed(int track) => ssRuntime.trackSpeed(_context, track);

  /// See [SpriteStudioPlayer.setTrackFrameRate].
  bool setTrackFrameRate(int track, int fps) {
    _ensureAlive();
    return ssRuntime.setTrackFrameRate(_context, track, fps);
  }

  /// See [SpriteStudioPlayer.trackFrameRate].
  int? trackFrameRate(int track) => ssRuntime.trackFrameRate(_context, track);

  /// See [SpriteStudioPlayer.setTrackFrameSkipEnabled].
  bool setTrackFrameSkipEnabled(int track, bool skip) {
    _ensureAlive();
    return ssRuntime.setTrackSkipFrames(_context, track, skip);
  }

  /// See [SpriteStudioPlayer.trackFrameSkipEnabled].
  bool? trackFrameSkipEnabled(int track) =>
      ssRuntime.trackSkipFrames(_context, track);

  /// See [SpriteStudioPlayer.setTrackPlaybackDirection].
  bool setTrackPlaybackDirection(
      int track, SsPlaybackDirection direction, SsPlaybackStyle style) {
    _ensureAlive();
    return ssRuntime.setTrackPlaybackDirection(
        _context, track, direction.value, style.value);
  }

  /// See [SpriteStudioPlayer.trackPlaybackDirection].
  SsPlaybackDirection? trackPlaybackDirection(int track) {
    final direction = ssRuntime.trackPlaybackDirection(_context, track);
    return direction == null ? null : SsPlaybackDirection.fromValue(direction);
  }

  /// See [SpriteStudioPlayer.trackPlaybackStyle].
  SsPlaybackStyle? trackPlaybackStyle(int track) {
    final style = ssRuntime.trackPlaybackStyle(_context, track);
    return style == null ? null : SsPlaybackStyle.fromValue(style);
  }

  /// See [SpriteStudioPlayer.setTrackLoopCount].
  bool setTrackLoopCount(int track, int count) {
    _ensureAlive();
    return ssRuntime.setTrackLoopCount(_context, track, count);
  }

  /// See [SpriteStudioPlayer.trackLoopCount].
  int? trackLoopCount(int track) => ssRuntime.trackLoopCount(_context, track);

  /// See [SpriteStudioPlayer.isTrackFinished].
  bool isTrackFinished(int track) => ssRuntime.isTrackFinished(_context, track);

  /// A pulse, like [justLooped]: the Brain clears it on entry to every update,
  /// so it describes the last one.
  bool trackJustLooped(int track) => ssRuntime.trackJustLooped(_context, track);

  /// See [SpriteStudioPlayer.setTrackOutgoingEventThreshold].
  bool setTrackOutgoingEventThreshold(int track, double threshold) {
    _ensureAlive();
    return ssRuntime.setTrackOutgoingEventThreshold(_context, track, threshold);
  }

  /// See [SpriteStudioPlayer.trackOutgoingEventThreshold].
  double? trackOutgoingEventThreshold(int track) =>
      ssRuntime.trackOutgoingEventThreshold(_context, track);

  /// See [SpriteStudioPlayer.trackMainSource].
  int? trackMainSource(int track) => ssRuntime.trackMainSource(_context, track);

  /// See [SpriteStudioPlayer.addTrackSource].
  int? addTrackSource(int track, String name, double weight) {
    _ensureAlive();
    return _posedSource(ssRuntime.addTrackSource(_context, track, name, weight));
  }

  /// See [SpriteStudioPlayer.setSourceWeight].
  bool setSourceWeight(int source, double weight) {
    _ensureAlive();
    return _posed(ssRuntime.setSourceWeight(_context, source, weight));
  }

  /// See [SpriteStudioPlayer.sourceWeight].
  double? sourceWeight(int source) => ssRuntime.sourceWeight(_context, source);

  /// See [SpriteStudioPlayer.setSourceFrame].
  bool setSourceFrame(int source, double frame) {
    _ensureAlive();
    return _posed(ssRuntime.setSourceFrame(_context, source, frame));
  }

  /// See [SpriteStudioPlayer.sourceFrame].
  double? sourceFrame(int source) => ssRuntime.sourceFrame(_context, source);

  /// See [SpriteStudioPlayer.setSourceEventThreshold].
  bool setSourceEventThreshold(int source, double threshold) {
    _ensureAlive();
    return ssRuntime.setSourceEventThreshold(_context, source, threshold);
  }

  /// See [SpriteStudioPlayer.sourceEventThreshold].
  double? sourceEventThreshold(int source) =>
      ssRuntime.sourceEventThreshold(_context, source);

  /// Index into the pack's animations of what [source] plays — the table its
  /// passed events address.
  int? sourceAnimationIndex(int source) =>
      ssRuntime.sourceAnimationIndex(_context, source);

  /// Index into the pack's animations of what track 0's main source plays:
  /// the animation [setupAnimation] chose, or what a crossfade or track
  /// animation on track 0 handed over to.
  int? get currentAnimationIndex => ssRuntime.currentAnimationIndex(_context);

  // --- Part overrides (Override Layer) -------------------------------------
  //
  // An imperative "make this part this colour / cell / hidden now" that wins
  // over both the keyframes and the blend. The Brain applies them at a seam
  // AFTER the keyframe mix and BEFORE FrameData is composed, and it owns the
  // whole table and its lifecycle — so this player keeps no copy and must NOT
  // re-apply them per frame. `setupAnimation` clears everything but
  // `SsOverridePriority.permanent`; a new pack clears everything.
  //
  // Parts are addressed by index; the by-name overloads resolve once through
  // [partNames] (an unknown name is -1, and the call is a no-op returning
  // false). A `false` return means the call was REJECTED — a part whose type
  // the attribute does not apply to (a colour override on a Null part, say)
  // still returns true and is simply ignored at the seam, so never use the
  // return value to decide whether an override is visible.
  //
  // **[setupAnimation] must have run first.** The Brain's override table is a
  // dense per-part array that only `setup_animation` sizes (`bind_resource`
  // empties it), so before an animation is selected EVERY index is out of range
  // and every call here returns false.
  // [partNames] is read from the pack and so works either way, which is
  // exactly how a caller ends up with a valid index and a failing set.
  //
  // A set or clear shows from the next frame this player builds ([updateMs],
  // [seek], [setupAnimation]); until then [paint] and the part reads keep the
  // frame they have. L3 `SpriteStudioPlayer` runs a zero-length tick for a
  // player whose Ticker is stopped, so a paused one shows it on the next frame.

  /// Pack-level part names / name→index lookup. Indices are stable
  /// within one `.ssab`; resolve once and reuse.
  PartNameTable get partNames => _partNames;

  /// Resolves [name] to its part index, or -1 when this pack has no such part.
  int findPartIndex(String name) => _partNames.indexOf(name);

  /// Force-hides [partIndex] ([hide] true) or reverts it to the animation.
  /// With [cascade] the force-hide propagates to the part's descendants.
  ///
  /// Visibility has no priority mode — it always wins, and `setupAnimation`
  /// always clears it. Note the cascade only propagates override-driven hiding:
  /// a keyframe `hide` stays per-part, so do not add your own parent→
  /// child propagation on top.
  ///
  /// An instance part's own force-hide does NOT reach into its child animation
  /// (a separate context); skipping the child's drawing is the Body's job.
  bool setPartVisibilityOverrideByIndex(int partIndex, bool hide,
      {bool cascade = false}) {
    _ensureAlive();
    if (partIndex < 0) return false;
    // force: 0 = clear/revert, 1 = force-hide (2 = force-visible is reserved).
    return _posed(ssRuntime.setPartVisibilityOverride(
        _context, partIndex, hide ? 1 : 0,
        cascade: cascade));
  }

  /// Index form of [setPartVisibilityOverride].
  bool setPartVisibilityOverride(String partName, bool hide,
          {bool cascade = false}) =>
      setPartVisibilityOverrideByIndex(findPartIndex(partName), hide, cascade: cascade);

  /// Clears [partIndex]'s visibility override (revert to the animation).
  bool clearPartVisibilityOverrideByIndex(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return _posed(ssRuntime.clearPartVisibilityOverride(_context, partIndex));
  }

  /// Index form of [clearPartVisibilityOverride].
  bool clearPartVisibilityOverride(String partName) =>
      clearPartVisibilityOverrideByIndex(findPartIndex(partName));

  /// Overrides [partIndex]'s colour with one value flowed to all four corners.
  /// Normal parts only — other types return true and are ignored at the seam.
  ///
  /// [color] is read in the same 8-bit sRGB space as the authored PartColor and
  /// the Brain pre-multiplies the part's composed alpha itself, so do NOT
  /// gamma-convert it or fold `PartState.alpha` in. Overriding a part the
  /// animation gave no PartColor makes the Brain emit it as a 5-vertex fan
  /// instead of a quad; the bake path handles both, so nothing else changes.
  bool setPartColorOverrideByIndex(int partIndex, ui.Color color,
      {SsBlendOp blendOp = SsBlendOp.mix,
      SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation}) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return _posed(ssRuntime.setPartColorOverride(
        _context, partIndex, blendOp.value, packRgba(color), priority.value));
  }

  /// Index form of [setPartColorOverride].
  bool setPartColorOverride(String partName, ui.Color color,
          {SsBlendOp blendOp = SsBlendOp.mix,
          SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      setPartColorOverrideByIndex(findPartIndex(partName), color,
          blendOp: blendOp, priority: priority);

  /// Four-corner form of [setPartColorOverride] (a gradient). The corner order
  /// is the Brain's: left-top, right-top, left-bottom, right-bottom — swapping
  /// `leftBottom` and `rightTop` silently mirrors the gradient.
  bool setPartColorOverrideCornersByIndex(
    int partIndex,
    SsCornerColors corners, {
    SsBlendOp blendOp = SsBlendOp.mix,
    SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation,
  }) {
    _ensureAlive();
    if (partIndex < 0) return false;
    final packed = Uint32List(4)
      ..[0] = packRgba(corners.leftTop)
      ..[1] = packRgba(corners.rightTop)
      ..[2] = packRgba(corners.leftBottom)
      ..[3] = packRgba(corners.rightBottom);
    return _posed(ssRuntime.setPartColorOverrideCorners(
        _context, partIndex, blendOp.value, packed, priority.value));
  }

  /// Index form of [setPartColorOverrideCorners].
  bool setPartColorOverrideCorners(
    String partName,
    SsCornerColors corners, {
    SsBlendOp blendOp = SsBlendOp.mix,
    SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation,
  }) =>
      setPartColorOverrideCornersByIndex(findPartIndex(partName), corners,
          blendOp: blendOp, priority: priority);

  /// Clears [partIndex]'s colour override (revert to the animation).
  bool clearPartColorOverrideByIndex(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return _posed(ssRuntime.clearPartColorOverride(_context, partIndex));
  }

  /// Index form of [clearPartColorOverride].
  bool clearPartColorOverride(String partName) =>
      clearPartColorOverrideByIndex(findPartIndex(partName));

  /// Makes [partIndex] draw a different cell. [cellmapName] carries NO `.ssce`
  /// extension. Normal + Mask parts only.
  ///
  /// The cell is resolved once, here — an unresolvable cellmap/cell name fails
  /// immediately (false) rather than costing a hash lookup per frame. Passing
  /// two empty names reverts the part to the animation. If the new cell lives on
  /// another texture the batch split changes; [paint] just re-reads
  /// `draw_batches`, so only a caller that assumed a fixed batch count breaks.
  bool setPartCellOverrideByIndex(int partIndex, String cellmapName, String cellName,
      {SsOverridePriority priority = SsOverridePriority.holdUntilNextAnimation}) {
    _ensureAlive();
    if (partIndex < 0) return false;
    // (0, 0) is the Brain's "follow the animation" sentinel, and an empty name
    // hashes to 0 — so empty/empty reverts, exactly as documented.
    return _posed(ssRuntime.setPartCellOverride(
        _context,
        partIndex,
        _hashName(cellmapName),
        _hashName(cellName),
        priority.value));
  }

  /// Index form of [setPartCellOverride].
  bool setPartCellOverride(
          String partName, String cellmapName, String cellName,
          {SsOverridePriority priority =
              SsOverridePriority.holdUntilNextAnimation}) =>
      setPartCellOverrideByIndex(findPartIndex(partName), cellmapName, cellName,
          priority: priority);

  /// Clears [partIndex]'s cell override (revert to the animation).
  bool clearPartCellOverrideByIndex(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    return _posed(ssRuntime.clearPartCellOverride(_context, partIndex));
  }

  /// Index form of [clearPartCellOverride].
  bool clearPartCellOverride(String partName) =>
      clearPartCellOverrideByIndex(findPartIndex(partName));

  /// Clears every per-part override on this player (all parts, all attributes).
  /// Does not recurse into instance children — each child owns its own context
  /// and therefore its own override table.
  bool clearAllPartOverrides() {
    _ensureAlive();
    return _posed(ssRuntime.clearAllPartOverrides(_context));
  }

  /// FNV-1a via the Brain's own hasher, so a cell override keys on exactly the
  /// hashes the pack was built with (never re-implement it in Dart). An empty
  /// name hashes to 0 — the revert sentinel.
  int _hashName(String name) => name.isEmpty ? 0 : ssRuntime.hashString(name);

  // --- Part following (read a part's live pose) ----------------------------
  //
  // The read mirror of the overrides above: those push a pose in, these pull the
  // composed pose out, so a Body-side follower — the [SpriteStudioPartAnchor]
  // widget, a Flame component — can stick to a part (ForUnity's part tracker /
  // ForGodot's part attachment, done the Flutter way). No C-API of its own: the
  // Brain already emits a world matrix per part every update; these read the
  // current frame, which [paint] then draws without evaluating it again, and
  // slice it. Address parts by index (resolve a name once through
  // [findPartIndex]); the results are built per call from borrows, so read them
  // within the frame.

  /// The current-frame world transform of [partIndex] as a [Matrix4] in
  /// player-local (animation) space, or null when the index is out of range or
  /// no frame is available.
  ///
  /// Only the 2D affine (`m0, m1, m4, m5, m12, m13`) is carried, with an identity
  /// Z row — the same contract as [GeometryBuilder.world2dOf] the Instance path
  /// places children through, so a follower lands exactly where the part draws.
  /// The Y-Down flip is already baked in by the Brain (never re-flip); position,
  /// rotation and scale ride in the matrix — hand it straight to a `Transform`
  /// widget. It is **skew-free**: the Brain applies a part's Skew as a
  /// non-inheriting local-vertex deform, so skew never reaches the world matrix
  /// (nor a follower), matching SpriteStudio, where Skew does not propagate.
  ///
  /// [rootTransform] is folded in, so this is the pose as **drawn**, flip and
  /// offset included. Note that the result can be a *reflection* — a matrix no
  /// rotation can express — and that this port carries that fact without loss
  /// precisely because it never decomposes: `Transform` takes the whole
  /// [Matrix4]. Callers that do decompose (reading a rotation out of it) inherit
  /// the siblings' caveats and should check `determinant()` first. The sign is
  /// the *product* of this flip and any mirroring authored on the part, so the
  /// two cancel in pairs — never infer it from the flip settings.
  ///
  /// Reads the frame this player last built ([updateMs], [seek],
  /// [setupAnimation]), which is the frame [paint] draws, and builds none of its
  /// own: an override shows from the next frame built. Null before any frame
  /// has been built.
  Matrix4? partWorldMatrix(int partIndex) {
    _ensureAlive();
    if (partIndex < 0 || _frameData == null) return null;
    final w = worldMatrices();
    final m = partIndex * DrawFrame.worldStride;
    if (m + DrawFrame.worldStride > w.length) return null;
    // Identity seeds [10]/[15] = 1; overwrite only the six affine terms so a
    // stray Z scale or perspective row can never leak into `Transform`.
    final world = Matrix4.identity()
      ..[0] = w[m]
      ..[1] = w[m + 1]
      ..[4] = w[m + 4]
      ..[5] = w[m + 5]
      ..[12] = w[m + 12]
      ..[13] = w[m + 13];
    // The same root transform `beginFrame` gave the backend — read from the one
    // place that resolves it, so the pose can never drift from the geometry.
    return rootTransform.compose(world);
  }

  /// Whether [partIndex] is hidden on the frame this player last built — the
  /// keyframe `hide` composed with any visibility override, read from the
  /// FrameData [paint] draws. Like [partWorldMatrix] it builds nothing: an
  /// override shows from the next frame built, and before any frame has been
  /// built every part reads as not hidden. A part absent from the frame's `parts`
  /// reads as not hidden (its world matrix is still valid), matching ForGodot's
  /// and ForUnity's followers. Out-of-range → false.
  bool partHidden(int partIndex) {
    _ensureAlive();
    if (partIndex < 0) return false;
    final parts = _frameData?.parts;
    if (parts == null) return false;
    for (final p in parts) {
      if (p.partIndex == partIndex) return p.$hide;
    }
    return false;
  }

  /// Whether [partIndex] is a **bone-bound (skinned) mesh** part — a static fact
  /// read once from the `.ssab` `PartData` at load, not a per-frame value.
  ///
  /// Such a part is a poor part-following target: its vertices are drawn by bone
  /// skinning while its own node transform (what [partWorldMatrix] returns) stays
  /// at the setup pose, usually near the character root. Following it snaps the
  /// follower near the root rather than onto the visible art. A rigid
  /// (deform-only) mesh reads false — it follows correctly. Out-of-range → false.
  /// Backs [SpriteStudioPlayer.isPartSkinnedMesh].
  bool partSkinnedMesh(int partIndex) => _partNames.isSkinnedMeshAt(partIndex);

  /// The outline [partIndex] is drawn with on the frame this player last built,
  /// in the space [partWorldMatrix] reports, or null when the part is hidden,
  /// draws nothing of its own, or no frame has been built.
  ///
  /// A part with a cell is its four drawn corners, skew and vertex deform
  /// included. A Mesh part is the axis-aligned box around its vertices, which
  /// the runtime hands over in world space and a skinned mesh's own transform
  /// does not describe. A part with a size and no cell — a Shape — is that size
  /// around its pivot. Null, bone, Instance and Effect parts have no size, and
  /// read null.
  ///
  /// Like [partWorldMatrix] it builds no frame of its own, and is built per
  /// call from borrows.
  SsPartQuad? partQuad(int partIndex) {
    _ensureAlive();
    final parts = _frameData?.parts;
    if (parts == null) return null;
    final state = _partStateOf(parts, partIndex);
    if (state == null || state.$hide) return null;
    return _quadOf(partIndex, state);
  }

  /// The front-most part whose [partQuad] holds [point], among [parts] (every
  /// part when null), on the frame this player last built — or -1 when none
  /// does. [point] is in the space [partQuad] reports.
  int hitTestPart(ui.Offset point, {Iterable<int>? parts}) {
    _ensureAlive();
    final states = _frameData?.parts;
    final order = _frameData?.drawOrder;
    if (states == null || order == null) return -1;
    final targets = parts?.toSet();
    // Back to front, and the runtime leaves hidden parts out of it.
    for (var rank = order.length - 1; rank >= 0; rank--) {
      final index = order[rank];
      if (targets != null && !targets.contains(index)) continue;
      final state = _partStateOf(states, index);
      if (state == null || state.$hide) continue;
      if (_quadOf(index, state)?.contains(point) ?? false) return index;
    }
    return -1;
  }

  static fbs.PartState? _partStateOf(List<fbs.PartState> parts, int index) {
    if (index < 0) return null;
    // The runtime writes them in part order; the scan is the fallback.
    if (index < parts.length) {
      final p = parts[index];
      if (p.partIndex == index) return p;
    }
    for (final p in parts) {
      if (p.partIndex == index) return p;
    }
    return null;
  }

  SsPartQuad? _quadOf(int part, fbs.PartState state) {
    final w = worldMatrices();
    final m = part * DrawFrame.worldStride;
    if (m + DrawFrame.worldStride > w.length) return null;
    final sx = rootTransform.scaleX, sy = rootTransform.scaleY;
    final o = rootTransform.offset;
    ui.Offset drawn(double x, double y) =>
        ui.Offset(sx * x + o.dx, sy * y + o.dy);
    ui.Offset placed(double x, double y) => drawn(
        w[m] * x + w[m + 4] * y + w[m + 12],
        w[m + 1] * x + w[m + 5] * y + w[m + 13]);

    final meshAt = meshVertexOffsets();
    if (part + 1 < meshAt.length && meshAt[part + 1] > meshAt[part]) {
      final xs = meshVerticesX(), ys = meshVerticesY();
      var l = double.infinity, t = double.infinity;
      var r = double.negativeInfinity, b = double.negativeInfinity;
      for (var v = meshAt[part]; v < meshAt[part + 1]; v++) {
        if (xs[v] < l) l = xs[v];
        if (xs[v] > r) r = xs[v];
        if (ys[v] < t) t = ys[v];
        if (ys[v] > b) b = ys[v];
      }
      return SsPartQuad(drawn(l, t), drawn(r, t), drawn(l, b), drawn(r, b));
    }
    if (state.cell >= 0) {
      final local = localVertices();
      final v = part * DrawFrame.vertexStride;
      if (v + 8 > local.length) return null;
      return SsPartQuad(
          placed(local[v], local[v + 1]),
          placed(local[v + 2], local[v + 3]),
          placed(local[v + 4], local[v + 5]),
          placed(local[v + 6], local[v + 7]));
    }
    final width = state.sizeX, height = state.sizeY;
    if (width <= 0 || height <= 0) return null;
    final left = -(0.5 + state.pivotX) * width;
    final top = -(0.5 + state.pivotY) * height;
    return SsPartQuad(placed(left, top), placed(left + width, top),
        placed(left, top + height), placed(left + width, top + height));
  }

  // --- Runtime texture replacement -----------------------------------------
  //
  // Swap the bitmap a whole cellmap (or a TextureChange's target file) samples,
  // from program code — costume changes, dynamic expressions. Ports ForGodot's
  // `set_cellmap_texture`.
  //
  // It is NOT part of the Override Layer (per-part colour/cell/visibility,
  // owned by the Brain). This is a pure Body concern: [textures] maps
  // `texture_hash → image` and the draw loop already binds by
  // `DrawBatch.texture_hash`, so a swap "just draws" — for both backends (Canvas
  // reads the registry every draw; the GPU backend keys its uploads on the image
  // the registry hands it, so a replacement is an upload of its own).
  //
  // Address by the registry key: [SsAnimeInfo.textureHashForName] resolves a
  // cellmap/external-texture NAME to it, and L3 [SpriteStudioPlayer] carries the
  // name-taking face and the repaint.
  //
  // **The registry is shared across the whole instance tree here** (children draw
  // from the parent's registry so a shared atlas decodes once), so an override
  // reaches every part in the tree that samples that hash — ROOT and INSTANCE
  // CHILD alike. That is the opposite of ForGodot, where each child owns its own
  // `_textures` and the override does not propagate; this port's
  // shared-registry design makes it a tree-wide, hash-keyed swap instead.
  //
  // A part under a TextureChange binds the FILE-name hash on the frames it fires,
  // not the cellmap-name hash: to replace what it shows there, target the
  // external-texture name (`common.png`), not the cellmap name (`common`).

  /// Replaces the texture registered under [textureHash] with [image], or
  /// restores the loaded original when [image] is null. Returns false for the
  /// reserved `0` hash (a TCHG "no override" / an unresolved name) and for a null
  /// [image] when no override was set (nothing changed). [image] stays the
  /// caller's — the registry borrows it and never disposes it.
  bool setCellmapTexture(int textureHash, ui.Image? image) {
    _ensureAlive();
    if (textureHash == 0) return false;
    if (image != null) {
      textures.setOverride(textureHash, image);
    } else if (!textures.clearOverride(textureHash)) {
      return false;
    }
    return true;
  }

  /// The runtime override currently set for [textureHash] (the override VALUE
  /// only, never the loaded original), or null when none is set.
  ui.Image? cellmapTextureOverride(int textureHash) =>
      textures.overrideImageFor(textureHash);

  // --- Rendering -----------------------------------------------------------

  /// Draws the current frame into [canvas] (ports ForGodot's
  /// `_drawAnimation`). Gathers the FlatBuffers `FrameData` + SoA views into one
  /// [DrawFrame], hands frame placement to the [RenderBackend] (which centers the
  /// animation's world origin in [dst]), then dispatches each `DrawBatch` on its
  /// `kind` to the backend.
  ///
  /// The batch loop, mask pre-pass planning and instance recursion stay here
  /// (backend-agnostic control flow); only the pixel operations go to the
  /// backend. Nines / Text are pre-cut seams and not drawn. Fitting into [dst]
  /// is not done here: it arrives already solved, in [rootTransform].
  ///
  /// **Call this at most once per frame per player.** The hooks below recycle
  /// resources that stay live until the recorded picture rasterises, and this is
  /// the only place they run — so painting one player into two adapters (two
  /// [SpriteStudioView]s, a view plus a Flame component) within a single frame
  /// makes the second call free and rebind what the first call's already-recorded
  /// draws still point at: a disposed coverage bitmap, or a pooled shader whose
  /// uniforms are overwritten before it rasterises. The visible result is the
  /// wrong mask or tint in the first view, or "Image has been disposed". Give
  /// each view its own player: players of one pack share its parse and its
  /// decoded atlases, so another one costs little more than its playback state.
  void paint(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize}) {
    _ensureAlive();
    // Dispose shaders orphaned by a runtime texture replacement since the last
    // frame — once per top-level frame, where the previous frame's recorded
    // picture is guaranteed to have rasterised (the same boundary the backend's
    // pool rewind relies on), so a live swap can never free a shader a pending
    // picture still reads. Instance children draw through this player's registry
    // and never reach here, so it runs exactly once for the whole tree.
    textures.flushRetired();
    // Per-FRAME, not per-player: both hooks recycle resources that stay live
    // until the recorded picture rasterises, so an instance child must never run
    // them — doing so frees/rebinds what the parent's already-recorded draws are
    // still pointing at (a disposed coverage bitmap, or a pooled shader whose
    // uniforms get overwritten before it is rasterised).
    _backend.releaseCoverage();
    _backend.rewindShaderPools();
    _backend.beginFrame(canvas,
        dst: dst, sourceSize: sourceSize, root: rootTransform);
    // The whole tree draws through THIS player's backend — including instance
    // children, which share it so their geometry lands in the same target
    // (GPU) / on the same canvas (Canvas) under a pushed transform.
    _paintTree(canvas, _backend);
    _backend.finish();
  }

  /// Draws this player's batches into the *already positioned* [canvas] — the
  /// recursive half of [paint].
  ///
  /// Split out for Instance: a child is drawn by calling this under the
  /// instance part's world transform, so it must not re-apply [paint]'s origin
  /// placement. [frameOverride] is the child's Brain-owned clock, and
  /// [alphaScale] the instance chain's opacity.
  void _paintTree(
    ui.Canvas canvas,
    RenderBackend backend, {
    double? frameOverride,
    double alphaScale = 1.0,
    PlayerMask? masking,
  }) {
    // Sub-frame ON (default): sample the fractional frame for smooth playback;
    // OFF: snap to the integer frame. This is the ONLY place a frame gets
    // rounded — the playback state that feeds `ss_instance_slot_step` stays raw.
    final sampled = frameOverride ?? frameNo;
    final frameData = getFrameData(subFrameEnabled ? sampled : sampled.floorToDouble());
    final batches = frameData?.drawBatches;
    if (frameData == null || batches == null) return;

    // Decide which optional SoA blocks this frame needs in ONE pass over the
    // batch plan. Mesh SoA is fetched only when a
    // Mesh batch is present; shape SoA when a Shape OR Mask batch is — a
    // *pure-mask* shape's colour batch is emitted with `kind == Mask`, not
    // `Shape`, so keying only off Shape would starve the coverage pass of its
    // geometry. The common mesh/shape-free animation fetches neither.
    var hasMesh = false;
    var hasShapeGeom = false;
    for (final b in batches) {
      switch (b.kind) {
        case fbs.DrawBatchKind.Mesh:
          hasMesh = true;
        case fbs.DrawBatchKind.Shape:
        case fbs.DrawBatchKind.Mask:
          hasShapeGeom = true;
        default:
          break;
      }
    }

    // One zero-copy SoA gather per frame (mirrors ForGodot's single-block
    // fetch); the views are valid only until the next update.
    final frame = _geometry.buildFrame(
      frameData: frameData,
      frameBytes: _frameBytes,
      world: worldMatrices(), // parts × 16
      local: localVertices(), // parts × 10
      uv: localUvs(), // parts × 10 (texture-pixel space)
      mesh: hasMesh
          ? MeshBuffers(
              x: meshVerticesX(),
              y: meshVerticesY(),
              uv: meshUvs(),
              indices: meshIndices(),
              vertexOffsets: meshVertexOffsets(),
              indexOffsets: meshIndexOffsets(),
            )
          : null,
      shape: hasShapeGeom
          ? ShapeBuffers(
              vertices: shapeVertices(),
              boxCoords: shapeVertexBoxCoords(),
              counts: shapeVertexCounts(),
            )
          : null,
      alphaScale: alphaScale,
    );
    if (frame == null) return;

    // Masking is a pre-pass: collect this frame's writers, rasterise their
    // coverage bitmap, then let the batch loop test each target against it.
    //
    // ONE coverage serves the whole instance tree, and the top-level player
    // ([masking] == null) builds it: every writer of the tree, however deeply
    // nested, is baked into it and placed on one sequence numbering the tree's
    // parts in draw order. That is how SpriteStudio 7.6 scopes them — a mask
    // inside an instance clips the sub-animation's own parts, a clipping mask
    // keeps clipping the caller's later parts, and an outer mask reaches every
    // level below. An instance child receives its view of it ([PlayerMask])
    // from the part that calls it and builds nothing.
    final mask = masking ?? _buildTreeMask(backend, frame, batches);

    // A mask reaches the peel-maskable kinds — Normal, Shape and Mesh —
    // resolved per part. Effect is not peeled (its plan carries its own
    // colours), so no mask gates it. A nested Instance hands its view another
    // level down.
    for (var i = 0; i < batches.length; i++) {
      final batch = batches[i];
      switch (batch.kind) {
        case fbs.DrawBatchKind.Normal:
        case fbs.DrawBatchKind.Mesh:
          var end = i + 1;
          while (end < batches.length &&
              _continuesTextured(batch, batches[end])) {
            end++;
          }
          backend.emitTextured(canvas, batches, i, end, frame, this, mask);
          i = end - 1;
        case fbs.DrawBatchKind.Effect:
          var end = i + 1;
          while (end < batches.length &&
              batches[end].kind == fbs.DrawBatchKind.Effect) {
            end++;
          }
          backend.emitEffect(canvas, batches, i, end, frame, this);
          i = end - 1;
        case fbs.DrawBatchKind.Instance:
          _emitInstanceBatch(canvas, backend, batch, frame, mask);
        case fbs.DrawBatchKind.Shape:
          backend.emitShape(canvas, batch, frame, this, mask);
        case fbs.DrawBatchKind.Mask: // coverage only, never colour
        case fbs.DrawBatchKind.Nines: // 9-slice: not yet supported
        case fbs.DrawBatchKind.Text: // no SDK render path
          break; // kinds not yet ported are skipped
      }
    }
  }

  /// Whether [next] joins the span of textured batches [first] opened: a
  /// Normal or Mesh batch on the same texture and blend, which
  /// [RenderBackend.emitTextured] draws through one run of plain parts.
  /// Only a blend Canvas draws as one coefficient pass spans. Without
  /// framebuffer fetch an advanced mode (Mul, Exclusion) blends a whole draw
  /// at once, and Sub and Invert draw in several passes, each of their parts
  /// on its own.
  static bool _continuesTextured(fbs.DrawBatch first, fbs.DrawBatch next) {
    final kind = next.kind;
    if (kind != fbs.DrawBatchKind.Normal && kind != fbs.DrawBatchKind.Mesh) {
      return false;
    }
    final blend = first.blendType;
    if (next.textureHash != first.textureHash || next.blendType != blend) {
      return false;
    }
    final mode = blendModeFor(blend);
    return mode == ui.BlendMode.srcOver ||
        mode == ui.BlendMode.plus ||
        mode == ui.BlendMode.screen;
  }

  /// Emits one Instance batch: draws each child animation in-place.
  ///
  /// The child is a whole nested player whose clock the Brain advanced during
  /// [updateMs]; all that is left here is placement. Its parts are in *child*
  /// space, so the instance part's world matrix goes on the canvas and the child
  /// paints beneath it — where ForGodot instead re-parents a retained
  /// CanvasItem and lets Godot's scene graph do the multiply.
  ///
  /// The whole child occupies exactly the instance part's z-slot: it can never
  /// interleave with this player's other parts. Painting it recursively at this
  /// point in the batch loop reproduces that ordering for free.
  void _emitInstanceBatch(
      ui.Canvas canvas,
      RenderBackend backend,
      fbs.DrawBatch batch,
      DrawFrame frame,
      PlayerMask masking) {
    for (var k = 0; k < batch.count; k++) {
      final rank = batch.startRank + k;
      if (rank >= frame.drawOrder.length) break;
      final part = frame.drawOrder[rank];
      final state = _instances.slotFor(part);
      // Invisible is the fail-safe: no slot (unresolved pack) or a
      // Brain-reported dead child both draw nothing.
      if (state == null || !state.visible) continue;

      final world = GeometryBuilder.world2dOf(part, frame, _world2dScratch);
      if (world == null) continue;

      // The instance part's own alpha modulates the entire child, and compounds
      // down a nested chain. It is `PartState.alpha` whether or not the part has
      // a PartColor, whose corner alphas also carry the colour's own.
      final alpha = frame.alphaOf(part);
      if (alpha <= 0.0) continue;

      // The child tests its parts against the tree's one coverage, through
      // the UV affine re-composed with the slot matrix and on the ranks the
      // tree walk numbered for it. The instance part's `mask_influence` /
      // `visible_inside_mask` compose with each child part's own — one level
      // only, and whether or not anything masks here.
      final childMask = masking.forInstance(flagsFor(part), world,
          masking.tree == null ? null : state.child._maskSeq);

      // The child draws through THIS player's [backend] (shared across the
      // recursion) under the composed transform — Canvas: save+transform; GPU:
      // the world matrix folds into the projection. So the child's geometry lands
      // in the same target/canvas at the instance part's place.
      // ALPHA crosses the instance boundary; COLOUR does not. That is the whole
      // family's rule, not a simplification here: SSPlayerForGodot modulates the
      // child's CanvasItem with `Color(1, 1, 1, part_alpha)`, and
      // SSPlayerForWgpu spells it out — "Colour deliberately does not cross the
      // boundary — no player propagates an instance part's tint."
      // The Editor agrees: a sub-animation under an instance
      // part carrying a Mul PartColor renders untinted there.
      //
      // Isolating the subtree in a layer to apply a tint would also break every
      // framebuffer blend inside it: an `add` child part would composite against
      // the empty layer instead of the scene.
      backend.pushTransform(canvas, world);
      state.child._paintTree(
        canvas,
        backend,
        frameOverride: state.childFrame,
        alphaScale: alpha,
        masking: childMask,
      );
      backend.popTransform(canvas);
    }
  }

  /// Builds the instance tree's mask plan for this frame and rasterises its
  /// coverage, returning the top-level player's view of it — or
  /// [PlayerMask.none] when nothing in the tree writes a mask (the
  /// overwhelmingly common case, decided from the static flags alone).
  ///
  /// Three steps, after ForGodot: number every part of the tree
  /// on one sequence ([_numberMaskTree]), collect every writer of every
  /// visible player into one plan, each on its interval of that sequence
  /// ([MaskPlan.collect]), then bake them all into one bitmap in this player's
  /// local space — a descendant's through the chain of instance matrices.
  PlayerMask _buildTreeMask(
      RenderBackend backend, DrawFrame frame, List<fbs.DrawBatch> batches) {
    if (!_treeCanWriteMask()) return PlayerMask.none;

    final nodes = <_MaskTreeNode>[];
    _numberMaskTree(frame, 0, null, nodes);

    final writers = <MaskWriter>[];
    final bakes = <BubbledWriter>[];
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    void fold(Float32List outline, Float64List? m) {
      for (var c = 0; c * 2 + 1 < outline.length; c++) {
        var x = outline[c * 2], y = outline[c * 2 + 1];
        if (m != null) {
          // Column-major: x' = m0·x + m4·y + m12.
          final ox = x;
          x = m[0] * ox + m[4] * y + m[12];
          y = m[1] * ox + m[5] * y + m[13];
        }
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }

    var dropped = false;
    if (_hasWriterParts) {
      dropped = MaskPlan.collect(frame, _maskFlags, seq: _maskSeq,
          add: (w, outline) {
        writers.add(w);
        fold(outline, null);
      });
    }
    for (final n in nodes) {
      if (dropped) break;
      final child = n.player;
      if (!child._hasWriterParts) continue;
      dropped = MaskPlan.collect(
        n.frame,
        child._maskFlags,
        comp: n.comp,
        seq: child._maskSeq,
        startSeq: n.startSeq,
        firstBit: writers.length,
        add: (w, outline) {
          // Scope, bit and op are the writer's own; only its geometry lives
          // elsewhere — in the descendant, placed by [n.toRoot].
          writers.add(MaskWriter(
            partIndex: kBubbledWriterPart,
            drawRank: w.drawRank,
            bit: w.bit,
            opInvert: w.opInvert,
            isClipping: w.isClipping,
            threshold: w.threshold,
            open: w.open,
            close: w.close,
          ));
          bakes.add(BubbledWriter(
            geometry: child.geometry,
            textures: child.textures,
            frame: n.frame,
            flags: child.flagsFor(w.partIndex),
            childPartIndex: w.partIndex,
            bit: w.bit,
            threshold: w.threshold,
            textureHash: n.textureByRank[w.drawRank],
            slot: n.toRoot,
          ));
          fold(outline, n.toRoot);
        },
      );
    }

    if (dropped && !_warnedMaskCap) {
      _warnedMaskCap = true;
      debugPrint('[ssplayer] an animation masks with more than '
          '$kMaxMaskWriters mask parts at once (instances count each time '
          'they are placed); the rest are ignored.');
    }
    if (writers.isEmpty) return PlayerMask.none;
    if (!(right > left) || !(bottom > top)) return PlayerMask.none;
    final plan = MaskPlan.fromWriters(
      writers: writers,
      bounds: ui.Rect.fromLTRB(left, top, right, bottom),
      bubbled: bakes,
    );

    // This player's writers take their texel from the batch that owns each
    // rank (a descendant's carry their texture hash themselves).
    final textureByRank = _textureByRankScratch..clear();
    for (final batch in batches) {
      for (var k = 0; k < batch.count; k++) {
        textureByRank[batch.startRank + k] = batch.textureHash;
      }
    }

    // The backend rasterises the coverage (Canvas: an offscreen bitmap; GPU: a
    // render-target texture) and owns its lifetime. Null when the mask program
    // is still compiling.
    final ctx = backend.renderCoverage(frame, this, plan, textureByRank);
    return PlayerMask.root(ctx, seq: _maskSeq);
  }

  /// Whether this player, or any instance under it at any depth, has a part
  /// that can write a mask. The whole mask pre-pass is skipped when not.
  /// Static — the instance children are fixed at load — so it is decided once.
  bool _treeCanWriteMask() => _treeCanWriteMaskCache ??= _hasWriterParts ||
      _instances.slots.any((s) => s.child._treeCanWriteMask());
  bool? _treeCanWriteMaskCache;

  /// The mask-cap warning has been printed for this player.
  bool _warnedMaskCap = false;

  /// Numbers this player's ranks on the tree sequence from [counter] into
  /// [_maskSeq], each visible instance's sub-animation taking the numbers right
  /// after its instance part, and appends every descendant reached to [out]
  /// with what its writers need: its frame, its placement in the top-level
  /// player's space and where its animation starts on the sequence. Returns the
  /// next free number.
  ///
  /// The children's frames are fetched at the clock they will be drawn at, so
  /// the draw orders numbered here are the ones [_paintTree] then walks.
  int _numberMaskTree(DrawFrame frame, int counter, Float64List? toRoot,
      List<_MaskTreeNode> out) {
    final order = frame.drawOrder;
    if (_maskSeq.length != order.length) _maskSeq = Int32List(order.length);
    for (var rank = 0; rank < order.length; rank++) {
      final seq = counter++;
      _maskSeq[rank] = seq;
      if (_instances.isEmpty) continue;
      final part = order[rank];
      final state = _instances.slotFor(part);
      if (state == null || !state.visible) continue;
      final slot = GeometryBuilder.world2dOf(part, frame);
      if (slot == null) continue;
      final child = state.child;
      final built = child._buildChildMaskFrame(state.childFrame);
      if (built == null) continue;
      final placed = toRoot == null ? slot : _mulCol4(toRoot, slot);
      out.add(_MaskTreeNode(
        player: child,
        frame: built.frame,
        textureByRank: built.textureByRank,
        toRoot: placed,
        startSeq: seq,
        comp: MaskComposition.ofInstancePart(flagsFor(part)),
      ));
      counter = child._numberMaskTree(built.frame, counter, placed, out);
    }
    return counter;
  }

  /// Column-major 4×4 product `a · b`.
  static Float64List _mulCol4(Float64List a, Float64List b) {
    final out = Float64List(16);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[k * 4 + r] * b[c * 4 + k];
        }
        out[c * 4 + r] = v;
      }
    }
    return out;
  }

  /// Builds this player's [DrawFrame] at [sampled] plus a `drawRank → texture
  /// hash` map, for numbering it on the tree sequence and baking its writers
  /// into the top-level player's coverage. A lighter mirror of [_paintTree]'s
  /// gather — alpha is irrelevant to a coverage bit, so it is left at 1.
  ({DrawFrame frame, Map<int, int> textureByRank})? _buildChildMaskFrame(
      double sampled) {
    final fd = getFrameData(subFrameEnabled ? sampled : sampled.floorToDouble());
    final batches = fd?.drawBatches;
    if (fd == null || batches == null) return null;
    var hasMesh = false, hasShapeGeom = false;
    for (final b in batches) {
      switch (b.kind) {
        case fbs.DrawBatchKind.Mesh:
          hasMesh = true;
        case fbs.DrawBatchKind.Shape:
        case fbs.DrawBatchKind.Mask:
          hasShapeGeom = true;
        default:
          break;
      }
    }
    final frame = _geometry.buildFrame(
      frameData: fd,
      frameBytes: _frameBytes,
      world: worldMatrices(),
      local: localVertices(),
      uv: localUvs(),
      mesh: hasMesh
          ? MeshBuffers(
              x: meshVerticesX(),
              y: meshVerticesY(),
              uv: meshUvs(),
              indices: meshIndices(),
              vertexOffsets: meshVertexOffsets(),
              indexOffsets: meshIndexOffsets(),
            )
          : null,
      shape: hasShapeGeom
          ? ShapeBuffers(
              vertices: shapeVertices(),
              boxCoords: shapeVertexBoxCoords(),
              counts: shapeVertexCounts(),
            )
          : null,
    );
    if (frame == null) return null;
    final texByRank = <int, int>{};
    for (final b in batches) {
      for (var k = 0; k < b.count; k++) {
        texByRank[b.startRank + k] = b.textureHash;
      }
    }
    return (frame: frame, textureByRank: texByRank);
  }

  // --- InstanceChild: this player driven as another's instance child --------

  @override
  SsContext get instanceContext => _context;

  @override
  void instancePlay() {
    if (_disposed) return;
    // Required, not a courtesy: `ss_instance_slot_step` configures this child
    // but leaves it stopped, and an independent child's per-tick
    // `Context::update` no-ops until something starts it. `play()` also snaps to
    // the start frame the step just configured and re-arms our nested slots.
    play();
  }

  @override
  void instanceResetSlots() {
    if (_disposed) return;
    _resetSlots();
  }

  @override
  void instanceStop() {
    if (_disposed) return;
    stop();
  }

  @override
  void instanceStepSlots(double childFrame, double deltaMs, bool childLooped) {
    if (_disposed) return;
    // No `ss_runtime_update` — our animation clock belongs to the parent's slot,
    // which has already moved us to `childFrame`. Only the slot-based kinds
    // still owe a tick.
    _stepSlots(childFrame, deltaMs, childLooped);
  }

  @override
  void instanceDispose() => dispose();

  // --- Teardown ------------------------------------------------------------

  /// Releases the native context, its instance children and effect slots, this
  /// player's hold on the pack and the render backend. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // The backend owns the coverage bitmap + shader pools (and any GPU
    // resources); release them.
    _backend.dispose();
    // The slots borrow the pack's resource; they must go first. Instance
    // children own their own Context and hold on the pack, and are torn down
    // recursively from here.
    _effects.dispose();
    _instances.dispose();
    // Decoded atlases are native bitmap memory the GC cannot see, so a dropped
    // registry leaks a full texture set per load. Children share ours and have
    // already run their own dispose above with `_ownsTextures == false`.
    if (_ownsTextures) textures.dispose();
    ssRuntime.unregisterFromGc(this);
    ssRuntime.destroyContext(_context);
    _pack.close();
  }
}

/// One instance descendant reached by [SpriteStudioInternalPlayer._numberMaskTree]:
/// what collecting its writers into the top-level player's coverage needs.
class _MaskTreeNode {
  const _MaskTreeNode({
    required this.player,
    required this.frame,
    required this.textureByRank,
    required this.toRoot,
    required this.startSeq,
    required this.comp,
  });

  final SpriteStudioInternalPlayer player;

  /// Its frame at the clock it is drawn at.
  final DrawFrame frame;
  final Map<int, int> textureByRank;

  /// Its local → the top-level player's local (column-major 4×4).
  final Float64List toRoot;

  /// Its instance part's number on the tree sequence: where its pure masks
  /// start to count.
  final int startSeq;

  /// What its instance part hands down.
  final MaskComposition comp;
}
