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
///     are typed-array views over the wasm `memory.buffer` (recreated per read,
///     since `memory.grow` detaches the backing `ArrayBuffer`).
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
/// **Lifetime.** [getFrameData] and every SoA getter return a view that aliases
/// the Brain's internal buffer and is valid only until the next [update] — read
/// it within the current frame. Call [getFrameData] before the SoA getters.
abstract interface class SsRuntime {
  // The compile-time-selected backend is exposed via a conditional export in
  // `ssruntime_dart.dart` (native FFI vs web js_interop), added together with the
  // two backend implementations. It is kept OFF this interface so this file stays
  // backend-free and analyzes on every platform.

  // --- Resource / Context lifecycle --------------------------------------

  /// Copies `ssab` onto the Brain's heap (copy mode — the only mode that works
  /// on web, where Body and Brain memory spaces differ). Returns null on a bad
  /// pack.
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
  void pause(SsContext context);
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
