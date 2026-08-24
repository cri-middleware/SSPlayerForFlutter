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
/// [SsRuntime.instance] resolves to the right backend at compile time via a
/// conditional export in `ssruntime_dart.dart`. Layer 2 talks only to this API,
/// so `internal_player.dart` / `render/effect.dart` / `render/instance.dart`
/// carry no `dart:ffi` and compile for the web.
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
  // `ssruntime_dart.dart` (native FFI vs web js_interop), added together with the
  // two backend implementations. It is kept OFF this interface so this file stays
  // backend-free and analyzes on every platform.

  // --- Resource / Context lifecycle --------------------------------------

  /// Copies `ssab` onto the Brain's heap (copy mode — the only mode that works
  /// on web, where Body and Brain memory spaces differ). Returns null when the
  /// Brain rejects the pack.
  ///
  /// Throws a [FormatException] when `ssab` lacks the `"SSAB"` FlatBuffers file
  /// identifier (`hasSsabIdentifier`): the Brain parses `.ssab` unchecked and is
  /// undefined behaviour on malformed input, so a non-`.ssab`/truncated buffer is
  /// rejected here rather than crashing native code. This is an identify check,
  /// not full validation — a well-formed header does not make an untrusted pack
  /// safe.
  SsResource? createResourceCopy(Uint8List ssab);
  void destroyResource(SsResource resource);

  SsContext? createContext();
  void destroyContext(SsContext context);
  bool bindResource(SsContext context, SsResource resource);

  /// Direct render mode (0) fills the SoA this Body reads; Y-Down coord (1) so
  /// the Brain flips once and the Body does not flip again.
  void setRenderMode(SsContext context, int mode);
  void setCoordinateSystem(SsContext context, int system);

  /// Registers `owner` so the Brain-side [context]/[resource] are reclaimed when
  /// `owner` is GC'd even if `dispose` was skipped (a backstop, never the primary
  /// path). Native uses a `NativeFinalizer`; web a `dart:core` `Finalizer`.
  /// [unregisterFromGc] detaches on explicit dispose.
  void registerForGc(Object owner,
      {required SsContext context, required SsResource resource});
  void unregisterFromGc(Object owner);

  // --- Setup / transport -------------------------------------------------

  bool setupAnimation(SsContext context, String name);

  /// Canonical name→id hash (FNV-1a in the Brain — never re-implement in Dart).
  int hashString(String name);

  void play(SsContext context);

  /// Holds playback in place. Idempotent, and ignored while nothing is playing.
  void pause(SsContext context);

  /// Lifts a [pause], carrying on from the same frame. Idempotent, and a no-op
  /// on a stopped animation — `play` heads out, so it cannot serve as a resume.
  void resume(SsContext context);
  void stop(SsContext context);

  bool isPlaying(SsContext context);
  bool isPausing(SsContext context);
  bool isFinished(SsContext context);
  bool isLooped(SsContext context);

  double frameNo(SsContext context);
  int startFrame(SsContext context);
  int endFrame(SsContext context);
  int fps(SsContext context);

  void setLoop(SsContext context, int count);
  void setSpeed(SsContext context, double rate);
  void setFrameRate(SsContext context, int fps);
  void seek(SsContext context, double frame);

  /// Restricts playback to `[startFrame, endFrame]` of the current animation.
  void setAnimationSection(SsContext context, int startFrame, int endFrame);

  /// `direction`: 0 = forward, 1 = backward. `style`: 0 = normal, 1 = ping-pong.
  void setPlaybackDirection(SsContext context, int direction, int style);
  int playbackDirection(SsContext context);
  int playbackStyle(SsContext context);

  /// Whether a long tick advances by elapsed time (true, dropping frames) or by
  /// exactly one frame (false).
  void setSkipFrames(SsContext context, bool skip);
  bool skipFrames(SsContext context);

  /// Advances internal time by [deltaMs]; returns the new (sub-frame) frame.
  double update(SsContext context, double deltaMs);

  // --- Frame data + SoA (views valid until the next [update]) ------------

  /// The FlatBuffers `FrameData` bytes for [frameNo], or null when the frame has
  /// none. Call before the SoA getters.
  Uint8List? getFrameData(SsContext context, double frameNo);

  Float32List worldMatrices(SsContext context);
  Float32List localVertices(SsContext context);
  Float32List localUvs(SsContext context);
  Float32List cellMeta(SsContext context);

  Float32List meshVerticesX(SsContext context);
  Float32List meshVerticesY(SsContext context);
  Float32List meshUvs(SsContext context);
  Int32List meshIndices(SsContext context);
  Uint32List meshVertexOffsets(SsContext context);
  Uint32List meshIndexOffsets(SsContext context);

  Float32List shapeVertices(SsContext context);
  Float32List shapeVertexBoxCoords(SsContext context);
  Int32List shapeVertexCounts(SsContext context);

  // --- Events ------------------------------------------------------------

  int passedEventCount(SsContext context);
  int passedEventIndex(SsContext context, int index);

  // --- Part overrides (§65 Override Layer) -------------------------------

  /// Per-part overrides are applied by the Brain at the seam *after* the
  /// keyframe mix and *before* `FrameData` is composed, so they beat both the
  /// keyframes and the blend. The Brain owns the whole table and its lifecycle
  /// (`setupAnimation` clears all but [Permanent], a new [bindResource] clears
  /// everything) — **never re-apply them per frame**.
  ///
  /// Parts are addressed by index only; the Body resolves names once. `false`
  /// means the call was rejected (bad index / out-of-range enum / unresolvable
  /// cell), NOT "the override had no visible effect": a part whose type the
  /// attribute does not apply to still returns `true` and is ignored at the
  /// seam.

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
  bool clearPartCellOverride(SsContext context, int part);

  /// Clears every per-part override on [context] (all parts, all attributes).
  bool clearAllPartOverrides(SsContext context);

  // --- Effect slots (§8) -------------------------------------------------

  /// Creates a slot for [effectNameHash] against [resource], or null on bad
  /// effect data (the caller caches the null and does not retry).
  SsEffectSlot? createEffectSlot(
      SsResource resource, int effectNameHash, int seed);
  void resetEffectSlot(SsEffectSlot slot);
  void destroyEffectSlot(SsEffectSlot slot);

  /// Fetches the active `EventEffect` for [slotIndex] (== part index) against
  /// [context] and steps [slot] one frame. The active-event fetch is fused in so
  /// the backend's by-value event/result structs never cross this boundary.
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
  });

  // --- Instance slots (§8) -----------------------------------------------

  SsInstanceSlot? createInstanceSlot();
  void resetInstanceSlot(SsInstanceSlot slot);
  void destroyInstanceSlot(SsInstanceSlot slot);
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

/// A live particle-effect slot (§8). Opaque.
abstract class SsEffectSlot {}

/// A live instance slot (§8). Opaque.
abstract class SsInstanceSlot {}

// --- Value results (plain Dart PODs, populated by either backend) -----------

/// One `ss_effect_slot_step` result. [drawPlan] is a zero-copy view over the
/// slot's builder (valid until the slot steps again) or null when invisible.
class SsEffectStep {
  const SsEffectStep({required this.visible, required this.drawPlan});
  final bool visible;
  final Uint8List? drawPlan;
}

/// One `ss_instance_slot_step` result. See `render/instance.dart` for the
/// `transitioned`/`childFrameNo` handshake.
class SsInstanceStep {
  const SsInstanceStep({
    required this.visible,
    required this.transitioned,
    required this.childFrameNo,
    required this.childLooped,
  });
  final bool visible;
  final bool transitioned;
  final double childFrameNo;
  final bool childLooped;
}
