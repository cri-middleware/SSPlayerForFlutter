import 'dart:typed_data';

/// Layer 1 runtime abstraction — the surface the drawing engine (Layer 2) needs
/// from the Brain, independent of transport.
///
/// Two backends implement it:
///   * **native** — `dart:ffi` `@Native` bindings over the libssruntime native
///     asset (`native_runtime.dart`). Handles are `Pointer<Void>`; SoA buffers
///     are zero-copy `asTypedList` views over the native heap.
///   * **web** — `dart:js_interop` over the SDK's wasm-bindgen `web` build
///     (`web_runtime.dart`). Handles are the wasm-bindgen JS objects; SoA buffers
///     are **copied** out of the wasm `memory.buffer`, because a view over it
///     survives only until the next wasm allocation grows the heap and detaches
///     it — a stricter rule than the lifetime below, so the backend pays a
///     per-frame copy to honour the same contract native does.
///
/// The `ssRuntime` singleton resolves to the right backend at compile time via
/// a conditional export in `ssruntime_dart.dart`. Layer 2 talks only to this
/// API, so `internal_player.dart` / `render/effect.dart` /
/// `render/instance.dart` carry no `dart:ffi` and compile for the web.
///
/// **Handle & event types are opaque.** [SsContext] / [SsResource] / slot handles
/// and the two `*EventInfo` tokens are produced by a backend and only ever handed
/// back to the same backend — Layer 2 never inspects their fields (verified: it
/// passes each active-event straight into the matching `step`). This lets each
/// backend carry its native representation (an FFI struct / a JS object) with no
/// per-call re-marshalling.
///
/// **Lifetime.** [getFrameData] and every SoA getter return a buffer that is
/// valid only until the next [update] — read it within the current frame. Call
/// [getFrameData] before the SoA getters. On native the buffer aliases the
/// Brain's own memory (zero-copy); on web it is a copy, because the shared wasm
/// heap cannot promise a view that long. Either way, treat it as read-only and
/// do not keep it past the frame.
abstract interface class SsRuntime {
  // The compile-time-selected backend is exposed via a conditional export in
  // `ssruntime_dart.dart` (native FFI vs web js_interop). It is kept OFF this
  // interface so this file stays backend-free and analyzes on every platform.

  // --- Resource / Context lifecycle --------------------------------------

  /// The `.ssab` schema version this runtime reads, for a report on a pack
  /// [createResourceCopy] rejected. Null on the web, whose rejection names it.
  int? get ssabSchemaVersion;

  /// Copies `ssab` onto the Brain's heap (copy mode — the only mode that works
  /// on web, where Body and Brain memory spaces differ). Returns null when the
  /// Brain rejects the pack; on the web, whose runtime gives its reason, throws a
  /// [StateError] carrying it instead.
  ///
  /// Throws a [FormatException] when `ssab` lacks the `"SSAB"` FlatBuffers file
  /// identifier (`hasSsabIdentifier`): the Brain parses `.ssab` unchecked and is
  /// undefined behaviour on malformed input, so a non-`.ssab`/truncated buffer is
  /// rejected here rather than crashing native code. This is an identify check,
  /// not full validation — a well-formed header does not make an untrusted pack
  /// safe.
  SsResource? createResourceCopy(Uint8List ssab);

  /// Releases this handle on [resource]. A context or effect slot bound to it
  /// keeps its own share, so this is safe while they live.
  void destroyResource(SsResource resource);

  /// Creates an empty context, or null when the Brain could not. Bind a
  /// resource ([bindResource]) and set up an animation ([setupAnimation])
  /// before playing; release it with [destroyContext].
  SsContext? createContext();

  /// Releases [context] and its share of the bound resource.
  void destroyContext(SsContext context);

  /// Binds [resource] to [context], which takes its own share of it; one
  /// resource can be bound to several contexts. Drops the context's tracks and
  /// overrides, so [setupAnimation] comes next.
  bool bindResource(SsContext context, SsResource resource);

  /// `mode`: 0 = Direct (the default), which pre-bakes the world matrices;
  /// 1 = SceneGraph, which skips them, along with the world-space mesh
  /// vertices. Any other value is Direct.
  void setRenderMode(SsContext context, int mode);

  /// `system`: 0 = Y-up (the default); 1 = Y-down, which flips Y coordinates
  /// and rotation in the Brain, so the renderer does not flip again. Any other
  /// value is Y-up.
  void setCoordinateSystem(SsContext context, int system);

  /// Registers `owner` so the Brain-side [context] and/or [resource] are
  /// reclaimed when `owner` is GC'd even if `dispose` was skipped (a backstop,
  /// never the primary path). Native uses a `NativeFinalizer`; web a `dart:core`
  /// `Finalizer`. [unregisterFromGc] detaches on explicit dispose.
  void registerForGc(Object owner, {SsContext? context, SsResource? resource});

  /// Detaches what [registerForGc] attached to [owner]; call it from an
  /// explicit dispose.
  void unregisterFromGc(Object owner);

  // --- Setup / transport -------------------------------------------------

  /// Selects the animation [name] of the bound resource and moves to its first
  /// frame without starting it; [play] does. Drops every track but 0, the
  /// section and the loop count, and keeps the speed, the frame rate, the frame
  /// skip and the direction. Returns false when no resource is bound or the
  /// pack has no such animation, and [lastErrorMessage] says which.
  bool setupAnimation(SsContext context, String name);

  /// Why the last call on [context] that tracks a reason failed, or null when
  /// the last such call succeeded.
  ///
  /// The Brain's own wording, not a code: a Player reports it, it does not
  /// branch on it. (Branching would mean hard-coding the integers from
  /// `SSRuntimeError::as_code`, which the C ABI publishes as a compatibility
  /// surface but exports no constants for.)
  ///
  /// The two backends reach it differently and mean the same thing. Native asks
  /// the context, which records a reason on every fallible call. The wasm face
  /// has no such accessor — it throws instead — so the web backend keeps what it
  /// caught. Either way this is the reason for the *last* failure, so read it
  /// straight after the call that returned `false`.
  String? lastErrorMessage(SsContext context);

  /// Canonical name→id hash (FNV-1a in the Brain — never re-implement in Dart).
  int hashString(String name);

  /// Starts track 0 from the start of its range (the end when playing
  /// backward) with its loop count re-armed, and starts the clock the other
  /// tracks and fades run on.
  void play(SsContext context);

  /// [play] from `frameNo` rather than the head of the section. Re-arms the
  /// loop count exactly as [play] does — it is a head-out, not a resume.
  void playWithStartFrame(SsContext context, double frameNo);

  /// Holds playback in place. Idempotent, and ignored while nothing is playing.
  void pause(SsContext context);

  /// Lifts a [pause], carrying on from the same frame. Idempotent, and a no-op
  /// on a stopped animation — `play` heads out, so it cannot serve as a resume.
  void resume(SsContext context);

  /// Stops every track and fade where they stand. Nothing rewinds; [play]
  /// starts them again.
  void stop(SsContext context);

  /// `true` while the clock runs and track 0 has not finished. A paused
  /// character is still playing.
  bool isPlaying(SsContext context);

  /// `true` while a [pause] holds a playing character. Once track 0 has
  /// finished this reads `false`; [isClockPausing] still reads the hold.
  bool isPausing(SsContext context);

  /// The character's clock, which every track and every fade runs on: `true`
  /// from [play] until [stop] or the next successful [setupAnimation]. Unlike
  /// [isPlaying], which is track 0's, it stays `true` after track 0 finishes,
  /// while an overlay or a fade still has somewhere to go.
  bool isClockPlaying(SsContext context);

  /// Whether a [pause] holds the clock, track 0 finished or not. Implies
  /// [isClockPlaying].
  bool isClockPausing(SsContext context);

  /// Whether the track stack would move the pose on a running clock for a
  /// reason other than track 0's own animation stepping: a fade on any track,
  /// or another source still playing, at a speed and weight above zero, on a
  /// track that is heard. It does not read the clock: combine it with
  /// [isClockPlaying] and [isClockPausing].
  bool isStackInMotion(SsContext context);

  /// `true` once the configured loops have completed, until the next [play] or
  /// [setupAnimation]. Always `false` under an infinite loop count, and never
  /// raised by [stop]. It is a state, not a pulse: to notify once, take its
  /// rising edge.
  bool isFinished(SsContext context);

  /// `true` for the single [update] that took playback back to the start of
  /// its cycle. Never raised on the last cycle of a finite loop count, which
  /// finishes instead.
  bool justLooped(SsContext context);

  /// Which way the playhead is **actually** travelling this frame, which is not
  /// the heading [setPlaybackDirection] configured: under ping-pong the return
  /// leg runs backward while the configured heading still reads forward. A
  /// speed of `0` or below is a stop rather than a reversal, and does not flip
  /// it either.
  ///
  /// `true` before anything has played — forward is the resting state, so a
  /// host gating audio on it is not silenced on its first frame.
  bool isPlayingForward(SsContext context);

  /// The playhead of track 0's main animation, with its fraction: what
  /// [update] last returned, or where a [seek] put it.
  double frameNo(SsContext context);

  /// The first frame of the playback range: the section's
  /// ([setAnimationSection]) when one is set, otherwise the animation's.
  int startFrame(SsContext context);

  /// The last frame of the playback range: the section's
  /// ([setAnimationSection]) when one is set, otherwise the animation's.
  int endFrame(SsContext context);

  /// The rate track 0's animation plays at, in frames per second: the
  /// [setFrameRate] override when one is set, otherwise the authored rate.
  int frameRate(SsContext context);

  /// `count > 0` plays that many cycles and then finishes; `0` or a negative
  /// count loops forever. [setupAnimation] resets it to looping forever, so set
  /// it after.
  void setLoopCount(SsContext context, int count);

  /// Playback speed as a multiple of the frame rate. `0` stops the playhead
  /// while [isPlaying] stays `true`, and a negative rate clamps to `0`; the
  /// direction is [setPlaybackDirection]'s. It survives [setupAnimation].
  void setSpeedScale(SsContext context, double rate);

  /// Plays at [fps] frames per second instead of the authored rate; `0` or a
  /// negative rate clears the override. It survives [setupAnimation].
  void setFrameRate(SsContext context, int fps);

  /// Moves track 0 to [frame], clamped to the playback range. The events of
  /// the frames in between do not fire.
  void seek(SsContext context, double frame);

  /// Restricts playback to `[startFrame, endFrame]` of the current animation.
  /// Returns false when the Brain refuses it — both ends inside the animation
  /// and the end before the start — and [lastErrorMessage] says why; the
  /// section and the playhead stay as they were.
  bool setAnimationSection(SsContext context, int startFrame, int endFrame);

  /// `direction`: 0 = forward, 1 = backward. `style`: 0 = normal, 1 = ping-pong.
  void setPlaybackDirection(SsContext context, int direction, int style);

  /// The heading [setPlaybackDirection] stored: 0 = forward, 1 = backward.
  /// [isPlayingForward] is the way the playhead actually travels.
  int playbackDirection(SsContext context);

  /// The style [setPlaybackDirection] stored: 0 = normal, 1 = ping-pong.
  int playbackStyle(SsContext context);

  /// Whether a long tick advances by elapsed time (true, dropping frames) or by
  /// exactly one frame (false).
  void setSkipFrames(SsContext context, bool skip);

  /// What [setSkipFrames] stored.
  bool skipFrames(SsContext context);

  /// Advances internal time by [deltaMs]; returns the new (sub-frame) frame.
  double update(SsContext context, double deltaMs);

  // --- Frame data + SoA (views valid until the next [update]) ------------

  /// The FlatBuffers `FrameData` bytes for [frameNo], or null when the frame has
  /// none. Call before the SoA getters.
  Uint8List? getFrameData(SsContext context, double frameNo);

  /// Per-part world matrices: 16 floats per part at `partIndex * 16`, with the
  /// translation at `[12]` and `[13]`. The SceneGraph render mode does not
  /// compute them.
  Float32List worldMatrices(SsContext context);

  /// Per-part local quads: `lt, rt, lb, rb, center` as `(x, y)`, 10 floats at
  /// `partIndex * 10`, with the coordinate system's flip, the pivot, the image
  /// flip and the vertex deformation applied, so they only need multiplying by
  /// [worldMatrices]. Zeros for a part with no cell.
  Float32List localVertices(SsContext context);

  /// Per-part UVs matching [localVertices]: `lt, rt, lb, rb, center` as
  /// `(u, v)`, 10 floats at `partIndex * 10`, in the cellmap's texture pixels.
  /// Divide by the texture size to normalize.
  Float32List localUvs(SsContext context);

  /// Per-part resolved cells: `pivotX, pivotY, width, height, rectLeft,
  /// rectTop`, 6 floats at `partIndex * 6`, with the rectangle in the
  /// cellmap's texture pixels. Zeros for a part with no cell.
  Float32List cellMeta(SsContext context);

  /// The world-space X of every mesh vertex, concatenated across parts: part
  /// `p` owns `[offsets[p], offsets[p + 1])` of [meshVertexOffsets]. The
  /// SceneGraph render mode leaves it empty.
  Float32List meshVerticesX(SsContext context);

  /// The world-space Y companion of [meshVerticesX], sliced the same way.
  Float32List meshVerticesY(SsContext context);

  /// Mesh UVs as interleaved `(u, v)` in the cellmap's texture pixels,
  /// concatenated across parts and sliced by [meshVertexOffsets]. Static:
  /// resolved once from each mesh part's frame-0 cell.
  Float32List meshUvs(SsContext context);

  /// Mesh triangle indices, part-local and 0-based, concatenated across parts:
  /// part `p` owns `[offsets[p], offsets[p + 1])` of [meshIndexOffsets].
  /// Static.
  Int32List meshIndices(SsContext context);

  /// Prefix sums, one longer than the part count, slicing [meshVerticesX],
  /// [meshVerticesY] and [meshUvs] per part. A part that is not a mesh has an
  /// empty range.
  Uint32List meshVertexOffsets(SsContext context);

  /// Prefix sums, one longer than the part count, slicing [meshIndices] per
  /// part.
  Uint32List meshIndexOffsets(SsContext context);

  /// Per-part shape outlines: 12 `(x, y)` vertices, 24 floats at
  /// `partIndex * 24`, in local space after the pivot, so they only need
  /// multiplying by [worldMatrices]. Only the first [shapeVertexCounts] of a
  /// part are valid. Empty when the pack has no shape part.
  Float32List shapeVertices(SsContext context);

  /// Where each [shapeVertices] vertex sits in the shape's pre-pivot bounding
  /// box, from `(0, 0)` at the top-left corner to `(1, 1)` at the bottom-right,
  /// laid out like [shapeVertices]: for interpolating the four part-color
  /// corners.
  Float32List shapeVertexBoxCoords(SsContext context);

  /// How many of a part's [shapeVertices] are valid, at `partIndex`; zero for
  /// a part that is not a shape.
  Int32List shapeVertexCounts(SsContext context);

  // --- Events ------------------------------------------------------------

  /// How many events the last [update] passed. They stay until the next
  /// [update], [setupAnimation] or [bindResource].
  int passedEventCount(SsContext context);

  /// Passed event [index], as an index into the `events()` of the animation of
  /// the source that fired it ([passedEventSourceHandle]); `-1` out of range.
  int passedEventIndex(SsContext context, int index);

  /// The source that fired passed event [index], or null when there is none.
  /// The event's index addresses the `events()` of **that source's**
  /// animation ([sourceAnimationIndex]), which after a crossfade on track 0 is
  /// not the animation `setupAnimation` chose.
  int? passedEventSourceHandle(SsContext context, int index);

  // --- Animation mixing (the track stack) --------------------------------
  //
  // Thin pass-throughs to the Brain's tracks and sources. The two backends
  // report "nothing there" in their own ways — native with NaN, -1 or
  // `SS_RUNTIME_INVALID_HANDLE`, the wasm face with `undefined` — and both
  // become null here. A setter returns false when the Brain refused it, and
  // [lastErrorMessage] says why. Durations are milliseconds, as [update] takes.

  /// Puts the animation [name] on [track], replacing what it played and
  /// cancelling its fade. Tracks grow on demand. Refused for an unknown [name]
  /// or before [setupAnimation].
  bool setTrackAnimation(SsContext context, int track, String name);

  /// How many tracks exist, silent ones included; at least 1.
  int trackCount(SsContext context);

  /// Silences [track]: its sources are released and its fade cancelled. Track 0
  /// cannot be cleared; fade it to alpha 0 instead.
  bool clearTrack(SsContext context, int track);

  /// The strength of [track]: `0` contributes nothing, `1` all of it, and
  /// values above `1` extrapolate. Refused for NaN or a track that does not
  /// exist.
  bool setTrackAlpha(SsContext context, int track, double alpha);

  /// The strength of [track] as it stands, which a [fadeTrack] moves; null for
  /// a track that does not exist.
  double? trackAlpha(SsContext context, int track);

  /// `blend`: 0 = mix, 1 = additive.
  bool setTrackBlend(SsContext context, int track, int blend);

  /// What [setTrackBlend] stored; null for a track that does not exist.
  int? trackBlend(SsContext context, int track);

  /// `sync`: 0 = free, 1 = start at track 0's phase.
  bool setTrackSync(SsContext context, int track, int sync);

  /// What [setTrackSync] stored; null for a track that does not exist.
  int? trackSync(SsContext context, int track);

  /// Fades [track] to the animation [name] over [durationMs], creating the
  /// track when it does not exist yet. Refused for a duration that is not
  /// positive, for an unknown [name], or before [setupAnimation].
  bool crossfade(SsContext context, int track, String name, double durationMs);

  /// Drives the alpha of [track] to [targetAlpha] over [durationMs]. Refused
  /// for a duration that is not positive, NaN, or a track that does not exist.
  bool fadeTrack(
      SsContext context, int track, double targetAlpha, double durationMs);

  /// `[0, 1]` while the track fades, null otherwise.
  double? trackFadeProgress(SsContext context, int track);

  /// Cancels the fade on [track], leaving its alpha and weights where they
  /// stand.
  bool cancelTrackFade(SsContext context, int track);

  /// Seeks the animation on [track], which is how an axis authored as an
  /// animation is driven. Refused when the track has no animation.
  bool setTrackFrame(SsContext context, int track, double frame);

  /// The playhead on [track]; null when it has no animation.
  double? trackFrame(SsContext context, int track);

  /// The speed of [track] as a multiple of each animation's frame rate, kept
  /// across a crossfade or a new animation. Track 0's is [setSpeedScale].
  bool setTrackSpeed(SsContext context, int track, double speed);

  /// What [setTrackSpeed] stored (a negative speed reads back as `0`); null
  /// for a track that does not exist.
  double? trackSpeed(SsContext context, int track);

  /// The rate in frames per second [track] plays its animations at; `0` or a
  /// negative rate clears it. The track keeps it, as it does its speed.
  bool setTrackFrameRate(SsContext context, int track, int fps);

  /// The override, or the authored rate; `0` for a track with neither.
  int? trackFrameRate(SsContext context, int track);

  /// [setSkipFrames] for [track]. The track keeps it, as it does its speed.
  bool setTrackSkipFrames(SsContext context, int track, bool skip);

  /// What [setTrackSkipFrames] stored; null for a track that does not exist.
  bool? trackSkipFrames(SsContext context, int track);

  /// Same values as [setPlaybackDirection].
  bool setTrackPlaybackDirection(
      SsContext context, int track, int direction, int style);

  /// 0 = forward, 1 = backward; null for a track that does not exist.
  int? trackPlaybackDirection(SsContext context, int track);

  /// 0 = normal, 1 = ping-pong; null for a track that does not exist.
  int? trackPlaybackStyle(SsContext context, int track);

  /// How many times the animation on [track] plays before it holds its last
  /// frame; `0` or a negative count loops forever. It belongs to the
  /// animation: laying another one on the track loops forever again.
  bool setTrackLoopCount(SsContext context, int track, int count);

  /// `-1` for a track that loops forever, null for one with no animation.
  int? trackLoopCount(SsContext context, int track);

  /// `true` once the animation on [track] has played its loop count out and
  /// holds its last frame, as [isFinished] is for track 0. `false` for a track
  /// with no animation.
  bool isTrackFinished(SsContext context, int track);

  /// `true` for the [update] in which the animation on [track] wrapped back to
  /// its start, as [justLooped] is for track 0.
  bool trackJustLooped(SsContext context, int track);

  /// How far into a crossfade on [track] the outgoing side keeps firing
  /// events: while its share of the track, `1 - t`, is at least [threshold].
  /// The default, infinity, silences it from the moment the fade begins.
  bool setTrackOutgoingEventThreshold(
      SsContext context, int track, double threshold);

  /// What [setTrackOutgoingEventThreshold] stored; null for a track that does
  /// not exist.
  double? trackOutgoingEventThreshold(SsContext context, int track);

  /// The handle of the source carrying the animation on [track], to give it a
  /// weight once the track holds several ([addTrackSource]); null when the
  /// track has no animation.
  int? trackMainSource(SsContext context, int track);

  /// The new source's handle, or null when the Brain refused it.
  int? addTrackSource(SsContext context, int track, String name, double weight);

  /// The proportion of [source] within its track; [setTrackAlpha] is the
  /// strength of the track as a whole. Refused for an invalid or released
  /// handle.
  bool setSourceWeight(SsContext context, int source, double weight);

  /// What [setSourceWeight] stored; null for an invalid or released handle.
  double? sourceWeight(SsContext context, int source);

  /// Seeks one [source]. Refused for an invalid or released handle.
  bool setSourceFrame(SsContext context, int source, double frame);

  /// The playhead of [source]; null for an invalid or released handle.
  double? sourceFrame(SsContext context, int source);

  /// [source] fires events once its weight reaches [threshold]. The default,
  /// infinity, keeps every source silent but track 0's main one, which always
  /// fires. Refused for an invalid or released handle.
  bool setSourceEventThreshold(SsContext context, int source, double threshold);

  /// What [setSourceEventThreshold] stored; null for an invalid or released
  /// handle.
  double? sourceEventThreshold(SsContext context, int source);

  /// Index into the pack's `animations()` of what [source] plays.
  int? sourceAnimationIndex(SsContext context, int source);

  /// Index into the pack's `animations()` of what track 0's main source plays,
  /// or null before anything is set up.
  int? currentAnimationIndex(SsContext context);

  // --- Part overrides (Override Layer) -----------------------------------

  //
  // Per-part overrides are applied by the Brain at the seam *after* the
  // keyframe mix and *before* `FrameData` is composed, so they beat both the
  // keyframes and the blend. The Brain owns the whole table and its lifecycle
  // ([setupAnimation] clears all but the `Permanent` ones, a new [bindResource]
  // clears everything) — **never re-apply them per frame**.
  //
  // Parts are addressed by index only; the Body resolves names once. `false`
  // means the call was rejected (bad index / out-of-range enum / unresolvable
  // cell), NOT "the override had no visible effect": a part whose type the
  // attribute does not apply to still returns `true` and is ignored at the
  // seam.

  /// Resolves a part name to its index in the current primary animation, or -1
  /// when unknown / before `setupAnimation`. The Body keeps its own pack-level
  /// name→index map (part indices are stable within one `.ssab`); this is the
  /// Brain's own view of the same space.
  int findPartIndex(SsContext context, String partName);

  /// `force`: 0 = revert to the animation, 1 = force-hide, 2 = force-visible
  /// (reserved by the Brain — currently always fails). With [cascade] the
  /// force-hide propagates to the part's descendants. No priority mode: a
  /// visibility override always wins and is cleared on `setupAnimation`.
  bool setPartVisibilityOverride(SsContext context, int part, int force,
      {required bool cascade});

  /// Clears the visibility override on [part], reverting to the animation.
  bool clearPartVisibilityOverride(SsContext context, int part);

  /// [rgba] is packed `0xRRGGBBAA` in the same 8-bit sRGB space as the authored
  /// PartColor — the Brain pre-multiplies alpha itself, so do not fold the
  /// part's alpha in here. `blendOp`: 0=Mix 1=Mul 2=Add 3=Sub (≥4 is rejected).
  /// `priorityMode`: 0=OverwriteOnNextKeyframe 1=HoldUntilNextAnimation
  /// 2=Permanent. Normal parts only.
  bool setPartColorOverride(
      SsContext context, int part, int blendOp, int rgba, int priorityMode);

  /// Four-corner form of [setPartColorOverride]. [rgbaLtRtLbRb] must hold
  /// exactly 4 packed values in the Brain's corner order `lt, rt, lb, rb`.
  bool setPartColorOverrideCorners(SsContext context, int part, int blendOp,
      Uint32List rgbaLtRtLbRb, int priorityMode);

  /// Clears the color override on [part].
  bool clearPartColorOverride(SsContext context, int part);

  /// Makes the part draw a different cell, named by the FNV-1a [hashString] of
  /// its cellmap (without `.ssce`) and cell name. Resolution happens once, here
  /// — an unresolvable cell fails immediately rather than per frame. `(0, 0)`
  /// reverts to the animation. Normal + Mask parts only.
  ///
  /// A swap to a cell on another texture changes `DrawBatch.texture_hash` and
  /// so the batch split; the Body just re-reads `draw_batches` as usual.
  bool setPartCellOverride(SsContext context, int part, int cellmapNameHash,
      int cellNameHash, int priorityMode);

  /// Clears the cell override on [part].
  bool clearPartCellOverride(SsContext context, int part);

  /// Clears every per-part override on [context] (all parts, all attributes).
  bool clearAllPartOverrides(SsContext context);

  // --- Effect slots ------------------------------------------------------

  /// Creates a slot for [effectNameHash] against [resource], or null on bad
  /// effect data (the caller caches the null and does not retry).
  SsEffectSlot? createEffectSlot(
      SsResource resource, int effectNameHash, int seed);

  /// Returns [slot] to its just-created playback state, keeping its resource
  /// and emitter caches. Call it on an explicit head-out ([play], a replay) so
  /// the effect fires again from scratch instead of taking its first key for
  /// the one it last started.
  void resetEffectSlot(SsEffectSlot slot);

  /// Releases [slot] and its share of the resource.
  void destroyEffectSlot(SsEffectSlot slot);

  /// Whether [slot] runs on its own time rather than the parent's frame, as the
  /// last `EventEffect` it saw says. Such a slot needs ticking even while the
  /// parent's frame stands still.
  bool effectSlotIsIndependent(SsEffectSlot slot);

  /// Fetches the active `EventEffect` for [slotIndex] (== part index) against
  /// [context] and steps [slot] one frame. The active-event fetch is fused in so
  /// the backend's by-value event/result structs never cross this boundary.
  ///
  /// [draw] is whether the part is in this frame's `draw_order`. With false the
  /// slot keeps time and builds no plan, and the next step with true returns the
  /// plan it would have had anyway.
  SsEffectStep stepEffectSlot(
    SsEffectSlot slot,
    SsContext context,
    int slotIndex, {
    required double parentFrame,
    required double deltaSeconds,
    required double fps,
    required bool parentLooped,
    required bool yFlip,
    required int vertStride,
    required bool draw,
  });

  // --- Instance slots ----------------------------------------------------

  /// Creates an instance slot, or null when the Brain could not. It binds no
  /// resource: each [stepInstanceSlot] runs against the child context it is
  /// handed.
  SsInstanceSlot? createInstanceSlot();

  /// Forgets the key [slot] last started. Call it on an explicit head-out
  /// ([play], a replay) so the instance child starts again from scratch
  /// instead of the first key being taken for the one it last started.
  void resetInstanceSlot(SsInstanceSlot slot);

  /// Releases [slot].
  void destroyInstanceSlot(SsInstanceSlot slot);

  /// Whether the current key of [slot] plays the child on its own time rather
  /// than the parent's frame.
  bool instanceSlotIsIndependent(SsInstanceSlot slot);

  /// Fetches the active `EventInstance` for [slotIndex] (== part index) against
  /// [parentContext] and steps [slot] one tick against [childContext]. Fused for
  /// the same reason as [stepEffectSlot]. Both backends track the child's
  /// previous frame internally, so it is not an argument.
  SsInstanceStep stepInstanceSlot(
    SsInstanceSlot slot,
    SsContext parentContext,
    int slotIndex,
    SsContext childContext, {
    required double parentFrame,
    required double deltaSeconds,
    required bool parentLooped,
  });
}

// --- Opaque handles (a backend subclasses these with its representation) ----

/// A bound animation context (one clock). Opaque; produced and consumed by one
/// backend.
abstract class SsContext {}

/// A parsed `.ssab` resource (Arc-refcounted in the Brain). Opaque.
abstract class SsResource {}

/// A live particle-effect slot. Opaque.
abstract class SsEffectSlot {}

/// A live instance slot. Opaque.
abstract class SsInstanceSlot {}

// --- Value results (plain Dart PODs, populated by either backend) -----------

/// One `ss_effect_slot_step` result. [drawPlan] is a zero-copy view over the
/// slot's builder (valid until the slot steps again) or null when invisible.
class SsEffectStep {
  /// A step result; the backends build these.
  const SsEffectStep({required this.visible, required this.drawPlan});

  /// Whether the effect draws this frame.
  final bool visible;

  /// The `EffectDrawPlan` FlatBuffer, read with
  /// `package:ssruntime_dart/effect_draw_plan.dart`, or null when there is
  /// nothing to draw.
  final Uint8List? drawPlan;
}

/// One `ss_instance_slot_step` result. See `render/instance.dart` for the
/// `transitioned`/`childFrameNo` handshake.
class SsInstanceStep {
  /// A step result; the backends build these.
  const SsInstanceStep({
    required this.visible,
    required this.transitioned,
    required this.childFrameNo,
    required this.childLooped,
    required this.speed,
  });

  /// Whether the instance part draws its child this tick.
  final bool visible;

  /// `true` on a new instance key: the slot has set the child up for it
  /// without starting it, so the caller plays the child on this tick.
  final bool transitioned;

  /// The frame to draw the child at. On a [transitioned] tick it is already
  /// where `play` puts the child, and for a synced child it follows the
  /// parent, which reading the frame back after `play` would lose.
  final double childFrameNo;

  /// Whether an independent child wrapped back to the start of its cycle this
  /// tick: the `parentLooped` to hand the child's own slots.
  final bool childLooped;

  /// The speed the slot ran the child at this tick (`ss_instance_slot_get_speed`,
  /// read after the step). Scale the delta handed to the child's own slots by
  /// its absolute value: the event's `speed` reads 1 while the slot ignores the
  /// implicit key, which would leave the child's independent grandchildren and
  /// effects running slower than the child.
  final double speed;
}
