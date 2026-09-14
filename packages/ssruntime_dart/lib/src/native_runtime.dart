import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'runtime_api.dart';
import 'ssab_identity.dart';
import 'ssruntime_bindings.g.dart';

/// The native (`dart:ffi`) backend of [SsRuntime].
///
/// Wraps the `@Native` libssruntime bindings: handles are `Pointer<Void>`, SoA
/// buffers are zero-copy `asTypedList` views over the Brain's native heap (valid
/// until the next [update]). Selected on any platform where `dart:ffi` exists;
/// the web build picks `web_runtime.dart` instead.
final SsRuntime ssRuntime = _NativeRuntime();

/// No-op on native: the Brain is a native asset the `@Native` bindings resolve
/// eagerly. Exposed so the public barrel offers the same symbol as the web
/// backend, where it asynchronously loads the wasm module before first use.
Future<void> loadSsRuntime([String? moduleUrl]) async {}

class _NativeContext implements SsContext {
  _NativeContext(this.ptr);
  final ffi.Pointer<ffi.Void> ptr;
}

class _NativeResource implements SsResource {
  _NativeResource(this.ptr);
  final ffi.Pointer<ffi.Void> ptr;
}

class _NativeEffectSlot implements SsEffectSlot {
  _NativeEffectSlot(this.ptr);
  final ffi.Pointer<ffi.Void> ptr;
}

class _NativeInstanceSlot implements SsInstanceSlot {
  _NativeInstanceSlot(this.ptr);
  final ffi.Pointer<ffi.Void> ptr;
}

/// A `NativeFinalizer` can only attach to a `Finalizable`. Layer 2's owner is
/// intentionally NOT `Finalizable` (so it compiles on the web), so we attach to
/// this internal token instead and tie its lifetime to the owner via an
/// `Expando`: once the owner is unreachable the token is too, and the finalizer
/// runs the Brain-side destroy.
class _GcToken implements ffi.Finalizable {}

class _NativeRuntime implements SsRuntime {
  static final ffi.NativeFinalizer _ctxFinalizer = ffi.NativeFinalizer(
      ffi.Native.addressOf<ffi.NativeFinalizerFunction>(ss_runtime_destroy));
  static final ffi.NativeFinalizer _resFinalizer = ffi.NativeFinalizer(
      ffi.Native.addressOf<ffi.NativeFinalizerFunction>(ss_resource_destroy));

  final Expando<_GcToken> _gcTokens = Expando<_GcToken>();

  // Reused scratch cells for the SoA out-parameters. Shared across every player
  // on the single UI isolate — each is written then read within one synchronous
  // getter, so there is no aliasing between calls.
  final ffi.Pointer<ffi.Pointer<ffi.Float>> _outFloat =
      calloc<ffi.Pointer<ffi.Float>>();
  final ffi.Pointer<ffi.Pointer<ffi.Uint8>> _outByte =
      calloc<ffi.Pointer<ffi.Uint8>>();
  final ffi.Pointer<ffi.Pointer<ffi.Uint32>> _outU32 =
      calloc<ffi.Pointer<ffi.Uint32>>();
  final ffi.Pointer<ffi.Pointer<ffi.Int32>> _outI32 =
      calloc<ffi.Pointer<ffi.Int32>>();
  final ffi.Pointer<ffi.Size> _outLen = calloc<ffi.Size>();

  ffi.Pointer<ffi.Void> _ctx(SsContext c) => (c as _NativeContext).ptr;
  ffi.Pointer<ffi.Void> _res(SsResource r) => (r as _NativeResource).ptr;

  // --- Resource / Context lifecycle --------------------------------------

  @override
  SsResource? createResourceCopy(Uint8List ssab) {
    // The Brain parses `.ssab` unchecked (documented UB on malformed input), so
    // reject anything without the "SSAB" file identifier here — before the bytes
    // reach native code — with a friendly error instead of a native crash.
    assertSsabIdentifier(ssab);
    // Zero-copy leaf hand-off: `ss_resource_create_copy` is marked leaf in
    // ffigen, so `ssab.address` stays valid for the whole call and the Brain
    // copies the bytes onto its own heap.
    final r = ss_resource_create_copy(ssab.address.cast(), ssab.length);
    return r == ffi.nullptr ? null : _NativeResource(r);
  }

  @override
  void destroyResource(SsResource resource) =>
      ss_resource_destroy(_res(resource));

  @override
  SsContext? createContext() {
    final c = ss_runtime_create();
    return c == ffi.nullptr ? null : _NativeContext(c);
  }

  @override
  void destroyContext(SsContext context) => ss_runtime_destroy(_ctx(context));

  @override
  bool bindResource(SsContext context, SsResource resource) =>
      ss_runtime_bind_resource(_ctx(context), _res(resource));

  @override
  void setRenderMode(SsContext context, int mode) =>
      ss_runtime_set_render_mode(_ctx(context), mode);

  @override
  void setCoordinateSystem(SsContext context, int system) =>
      ss_context_set_coordinate_system(_ctx(context), system);

  @override
  void registerForGc(Object owner,
      {required SsContext context, required SsResource resource}) {
    final token = _GcToken();
    _ctxFinalizer.attach(token, _ctx(context).cast(), detach: token);
    _resFinalizer.attach(token, _res(resource).cast(), detach: token);
    _gcTokens[owner] = token;
  }

  @override
  void unregisterFromGc(Object owner) {
    final token = _gcTokens[owner];
    if (token != null) {
      _ctxFinalizer.detach(token);
      _resFinalizer.detach(token);
      _gcTokens[owner] = null;
    }
  }

  // --- Setup / transport -------------------------------------------------

  @override
  bool setupAnimation(SsContext context, String name) {
    final cName = name.toNativeUtf8();
    try {
      return ss_runtime_setup_animation(_ctx(context), cName.cast());
    } finally {
      malloc.free(cName);
    }
  }

  @override
  String? lastErrorMessage(SsContext context) {
    final code = ss_runtime_get_last_error(_ctx(context));
    if (code == 0) return null;
    // Borrowed from the runtime and valid until the next call to this function
    // on this context, so copy it out before returning.
    final text = ss_runtime_error_message(code).cast<Utf8>().toDartString();
    return text.isEmpty ? null : text;
  }

  @override
  int hashString(String name) {
    final cName = name.toNativeUtf8();
    try {
      return ss_runtime_hash_string(cName.cast());
    } finally {
      malloc.free(cName);
    }
  }

  @override
  void play(SsContext context) => ss_runtime_play(_ctx(context));

  @override
  void playWithStartFrame(SsContext context, double frameNo) =>
      ss_runtime_play_with_start_frame(_ctx(context), frameNo);

  @override
  void pause(SsContext context) => ss_runtime_pause(_ctx(context));

  @override
  void resume(SsContext context) => ss_runtime_resume(_ctx(context));

  @override
  void stop(SsContext context) => ss_runtime_stop(_ctx(context));

  @override
  bool isPlaying(SsContext context) => ss_runtime_is_playing(_ctx(context));

  @override
  bool isPausing(SsContext context) => ss_runtime_is_pausing(_ctx(context));

  @override
  bool isFinished(SsContext context) => ss_runtime_is_finished(_ctx(context));

  @override
  bool isLooped(SsContext context) => ss_runtime_is_looped(_ctx(context));

  @override
  bool isPlayingForward(SsContext context) =>
      ss_runtime_is_playing_forward(_ctx(context));

  @override
  double frameNo(SsContext context) => ss_runtime_get_frame_no(_ctx(context));

  @override
  int startFrame(SsContext context) =>
      ss_runtime_get_start_frame(_ctx(context));

  @override
  int endFrame(SsContext context) => ss_runtime_get_end_frame(_ctx(context));

  @override
  int fps(SsContext context) => ss_runtime_get_fps(_ctx(context));

  @override
  void setLoop(SsContext context, int count) =>
      ss_runtime_set_loop(_ctx(context), count);

  @override
  void setSpeed(SsContext context, double rate) =>
      ss_runtime_set_animation_speed(_ctx(context), rate);

  @override
  void setFrameRate(SsContext context, int fps) =>
      ss_runtime_set_frame_rate(_ctx(context), fps);

  @override
  void seek(SsContext context, double frame) =>
      ss_runtime_set_frame_no(_ctx(context), frame);

  @override
  void setAnimationSection(SsContext context, int startFrame, int endFrame) =>
      ss_runtime_set_animation_section(_ctx(context), startFrame, endFrame);

  @override
  void setPlaybackDirection(SsContext context, int direction, int style) =>
      ss_runtime_set_playback_direction(_ctx(context), direction, style);

  @override
  int playbackDirection(SsContext context) =>
      ss_runtime_get_playback_direction(_ctx(context));

  @override
  int playbackStyle(SsContext context) =>
      ss_runtime_get_playback_style(_ctx(context));

  @override
  void setSkipFrames(SsContext context, bool skip) =>
      ss_runtime_set_skip_frames(_ctx(context), skip);

  @override
  bool skipFrames(SsContext context) =>
      ss_runtime_get_skip_frames(_ctx(context));

  @override
  double update(SsContext context, double deltaMs) =>
      ss_runtime_update(_ctx(context), deltaMs);

  // --- Frame data + SoA --------------------------------------------------

  @override
  Uint8List? getFrameData(SsContext context, double frameNo) {
    _outByte.value = ffi.nullptr;
    _outLen.value = 0;
    ss_runtime_get_frame_data(
        _ctx(context), frameNo, _outByte.cast(), _outLen.cast());
    final data = _outByte.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return null;
    return data.asTypedList(len);
  }

  Float32List _floats(
      SsContext context,
      void Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Pointer<ffi.Float>>, ffi.Pointer<ffi.UintPtr>)
          getter) {
    _outFloat.value = ffi.nullptr;
    _outLen.value = 0;
    getter(_ctx(context), _outFloat, _outLen.cast());
    final data = _outFloat.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return Float32List(0);
    return data.asTypedList(len);
  }

  Uint32List _u32(
      SsContext context,
      void Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Pointer<ffi.Uint32>>, ffi.Pointer<ffi.UintPtr>)
          getter) {
    _outU32.value = ffi.nullptr;
    _outLen.value = 0;
    getter(_ctx(context), _outU32, _outLen.cast());
    final data = _outU32.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return Uint32List(0);
    return data.asTypedList(len);
  }

  Int32List _i32(
      SsContext context,
      void Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Pointer<ffi.Int32>>, ffi.Pointer<ffi.UintPtr>)
          getter) {
    _outI32.value = ffi.nullptr;
    _outLen.value = 0;
    getter(_ctx(context), _outI32, _outLen.cast());
    final data = _outI32.value;
    final len = _outLen.value;
    if (data == ffi.nullptr || len == 0) return Int32List(0);
    return data.asTypedList(len);
  }

  @override
  Float32List worldMatrices(SsContext context) =>
      _floats(context, ss_runtime_get_world_matrices);

  @override
  Float32List localVertices(SsContext context) =>
      _floats(context, ss_runtime_get_local_vertices);

  @override
  Float32List localUvs(SsContext context) =>
      _floats(context, ss_runtime_get_local_uvs);

  @override
  Float32List cellMeta(SsContext context) =>
      _floats(context, ss_runtime_get_cell_meta);

  @override
  Float32List meshVerticesX(SsContext context) =>
      _floats(context, ss_runtime_get_mesh_vertices_x);

  @override
  Float32List meshVerticesY(SsContext context) =>
      _floats(context, ss_runtime_get_mesh_vertices_y);

  @override
  Float32List meshUvs(SsContext context) =>
      _floats(context, ss_runtime_get_mesh_uvs);

  @override
  Int32List meshIndices(SsContext context) =>
      _i32(context, ss_runtime_get_mesh_indices);

  @override
  Uint32List meshVertexOffsets(SsContext context) =>
      _u32(context, ss_runtime_get_mesh_vertex_offsets);

  @override
  Uint32List meshIndexOffsets(SsContext context) =>
      _u32(context, ss_runtime_get_mesh_index_offsets);

  @override
  Float32List shapeVertices(SsContext context) =>
      _floats(context, ss_runtime_get_shape_vertices);

  @override
  Float32List shapeVertexBoxCoords(SsContext context) =>
      _floats(context, ss_runtime_get_shape_vertex_box_coords);

  @override
  Int32List shapeVertexCounts(SsContext context) =>
      _i32(context, ss_runtime_get_shape_vertex_counts);

  // --- Events ------------------------------------------------------------

  @override
  int passedEventCount(SsContext context) =>
      ss_runtime_get_passed_event_count(_ctx(context));

  @override
  int passedEventIndex(SsContext context, int index) =>
      ss_runtime_get_passed_event_index(_ctx(context), index);

  // --- Part overrides ----------------------------------------------------

  @override
  int findPartIndex(SsContext context, String partName) {
    final cName = partName.toNativeUtf8();
    try {
      return ss_runtime_find_part_index(_ctx(context), cName.cast());
    } finally {
      malloc.free(cName);
    }
  }

  @override
  bool setPartVisibilityOverride(SsContext context, int part, int force,
          {required bool cascade}) =>
      ss_runtime_set_part_visibility_override(
          _ctx(context), part, force, cascade ? 1 : 0);

  @override
  bool clearPartVisibilityOverride(SsContext context, int part) =>
      ss_runtime_clear_part_visibility_override(_ctx(context), part);

  @override
  bool setPartColorOverride(SsContext context, int part, int blendOp, int rgba,
          int priorityMode) =>
      ss_runtime_set_part_color_override(
          _ctx(context), part, blendOp, rgba, priorityMode);

  @override
  bool setPartColorOverrideCorners(SsContext context, int part, int blendOp,
      Uint32List rgbaLtRtLbRb, int priorityMode) {
    if (rgbaLtRtLbRb.length != 4) {
      throw ArgumentError.value(rgbaLtRtLbRb, 'rgbaLtRtLbRb',
          'must hold exactly 4 packed corners (lt, rt, lb, rb)');
    }
    // Unlike the SoA getters this is an IN array, so it needs real native
    // storage for the duration of the call rather than a scratch out-cell.
    final buf = calloc<ffi.Uint32>(4);
    try {
      for (var i = 0; i < 4; i++) {
        buf[i] = rgbaLtRtLbRb[i];
      }
      return ss_runtime_set_part_color_override_corners(
          _ctx(context), part, blendOp, buf, priorityMode);
    } finally {
      calloc.free(buf);
    }
  }

  @override
  bool clearPartColorOverride(SsContext context, int part) =>
      ss_runtime_clear_part_color_override(_ctx(context), part);

  @override
  bool setPartCellOverride(SsContext context, int part, int cellmapNameHash,
          int cellNameHash, int priorityMode) =>
      ss_runtime_set_part_cell_override(
          _ctx(context), part, cellmapNameHash, cellNameHash, priorityMode);

  @override
  bool clearPartCellOverride(SsContext context, int part) =>
      ss_runtime_clear_part_cell_override(_ctx(context), part);

  @override
  bool clearAllPartOverrides(SsContext context) =>
      ss_runtime_clear_all_part_overrides(_ctx(context));

  // --- Effect slots ------------------------------------------------------

  @override
  SsEffectSlot? createEffectSlot(
      SsResource resource, int effectNameHash, int seed) {
    final s = ss_effect_slot_create(_res(resource), effectNameHash, seed);
    return s == ffi.nullptr ? null : _NativeEffectSlot(s);
  }

  @override
  void resetEffectSlot(SsEffectSlot slot) =>
      ss_effect_slot_reset((slot as _NativeEffectSlot).ptr);

  @override
  void destroyEffectSlot(SsEffectSlot slot) =>
      ss_effect_slot_destroy((slot as _NativeEffectSlot).ptr);

  @override
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
  }) {
    final ev = ss_runtime_get_active_effect_event(_ctx(context), slotIndex);
    final r = ss_effect_slot_step(
      (slot as _NativeEffectSlot).ptr,
      ev,
      parentFrame,
      deltaSeconds,
      fps,
      parentLooped,
      yFlip,
      vertStride,
    );
    final hasPlan =
        r.visible && r.draw_plan_buf != ffi.nullptr && r.draw_plan_len > 0;
    return SsEffectStep(
      visible: r.visible,
      // Zero-copy view over the slot's builder — valid until this slot steps
      // again, i.e. consumed within the paint that follows this update.
      drawPlan: hasPlan ? r.draw_plan_buf.asTypedList(r.draw_plan_len) : null,
    );
  }

  // --- Instance slots ----------------------------------------------------

  @override
  SsInstanceSlot? createInstanceSlot() {
    final s = ss_instance_slot_create();
    return s == ffi.nullptr ? null : _NativeInstanceSlot(s);
  }

  @override
  void resetInstanceSlot(SsInstanceSlot slot) =>
      ss_instance_slot_reset((slot as _NativeInstanceSlot).ptr);

  @override
  void destroyInstanceSlot(SsInstanceSlot slot) =>
      ss_instance_slot_destroy((slot as _NativeInstanceSlot).ptr);

  @override
  bool instanceSlotIsIndependent(SsInstanceSlot slot) =>
      ss_instance_slot_is_independent((slot as _NativeInstanceSlot).ptr);

  @override
  SsInstanceStep stepInstanceSlot(
    SsInstanceSlot slot,
    SsContext parentContext,
    int slotIndex,
    SsContext childContext, {
    required double parentFrame,
    required double deltaSeconds,
    required bool parentLooped,
  }) {
    final ev =
        ss_runtime_get_active_event_instance(_ctx(parentContext), slotIndex);
    final r = ss_instance_slot_step(
      (slot as _NativeInstanceSlot).ptr,
      ev,
      _ctx(childContext),
      parentFrame,
      deltaSeconds,
      parentLooped,
    );
    return SsInstanceStep(
      visible: r.visible,
      transitioned: r.transitioned,
      childFrameNo: r.child_frame_no,
      childLooped: r.child_looped,
    );
  }
}
