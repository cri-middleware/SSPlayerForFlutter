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
      ss_runtime_set_coordinate_system(_ctx(context), system);

  @override
  void registerForGc(Object owner, {SsContext? context, SsResource? resource}) {
    final token = _GcToken();
    if (context != null) {
      _ctxFinalizer.attach(token, _ctx(context).cast(), detach: token);
    }
    if (resource != null) {
      _resFinalizer.attach(token, _res(resource).cast(), detach: token);
    }
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
  bool isClockPlaying(SsContext context) =>
      ss_runtime_is_clock_playing(_ctx(context));

  @override
  bool isClockPausing(SsContext context) =>
      ss_runtime_is_clock_pausing(_ctx(context));

  @override
  bool isStackInMotion(SsContext context) =>
      ss_runtime_is_stack_in_motion(_ctx(context));

  @override
  bool isFinished(SsContext context) => ss_runtime_is_finished(_ctx(context));

  @override
  bool justLooped(SsContext context) => ss_runtime_just_looped(_ctx(context));

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
  int frameRate(SsContext context) => ss_runtime_get_frame_rate(_ctx(context));

  @override
  void setLoopCount(SsContext context, int count) =>
      ss_runtime_set_loop_count(_ctx(context), count);

  @override
  void setSpeedScale(SsContext context, double rate) =>
      ss_runtime_set_speed_scale(_ctx(context), rate);

  @override
  void setFrameRate(SsContext context, int fps) =>
      ss_runtime_set_frame_rate(_ctx(context), fps);

  @override
  void seek(SsContext context, double frame) =>
      ss_runtime_set_frame_no(_ctx(context), frame);

  @override
  bool setAnimationSection(SsContext context, int startFrame, int endFrame) =>
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

  @override
  int? passedEventSourceHandle(SsContext context, int index) =>
      _handle(ss_runtime_get_passed_event_source_handle(_ctx(context), index));

  // --- Animation mixing --------------------------------------------------
  //
  // The C-API's "nothing there" values become null: NaN for a float, -1 for a
  // signed integer, `SS_RUNTIME_INVALID_HANDLE` for a handle or an enum.

  /// `SS_RUNTIME_INVALID_HANDLE`.
  static const int _invalidHandle = 0xFFFFFFFF;

  static int? _handle(int value) => value == _invalidHandle ? null : value;
  static double? _float(double value) => value.isNaN ? null : value;
  static int? _signed(int value) => value < 0 ? null : value;

  T _withName<T>(String name, T Function(ffi.Pointer<ffi.Char>) call) {
    final cName = name.toNativeUtf8();
    try {
      return call(cName.cast());
    } finally {
      malloc.free(cName);
    }
  }

  @override
  bool setTrackAnimation(SsContext context, int track, String name) =>
      _withName(name,
          (n) => ss_runtime_set_track_animation(_ctx(context), track, n));

  @override
  int trackCount(SsContext context) =>
      ss_runtime_get_track_count(_ctx(context));

  @override
  bool clearTrack(SsContext context, int track) =>
      ss_runtime_clear_track(_ctx(context), track);

  @override
  bool setTrackAlpha(SsContext context, int track, double alpha) =>
      ss_runtime_set_track_alpha(_ctx(context), track, alpha);

  @override
  double? trackAlpha(SsContext context, int track) =>
      _float(ss_runtime_get_track_alpha(_ctx(context), track));

  @override
  bool setTrackBlend(SsContext context, int track, int blend) =>
      ss_runtime_set_track_blend(_ctx(context), track, blend);

  @override
  int? trackBlend(SsContext context, int track) =>
      _handle(ss_runtime_get_track_blend(_ctx(context), track));

  @override
  bool setTrackSync(SsContext context, int track, int sync) =>
      ss_runtime_set_track_sync(_ctx(context), track, sync);

  @override
  int? trackSync(SsContext context, int track) =>
      _handle(ss_runtime_get_track_sync(_ctx(context), track));

  @override
  bool crossfade(
          SsContext context, int track, String name, double durationMs) =>
      _withName(name,
          (n) => ss_runtime_crossfade(_ctx(context), track, n, durationMs));

  @override
  bool fadeTrack(SsContext context, int track, double targetAlpha,
          double durationMs) =>
      ss_runtime_fade_track(_ctx(context), track, targetAlpha, durationMs);

  @override
  double? trackFadeProgress(SsContext context, int track) =>
      _float(ss_runtime_get_track_fade_progress(_ctx(context), track));

  @override
  bool cancelTrackFade(SsContext context, int track) =>
      ss_runtime_cancel_track_fade(_ctx(context), track);

  @override
  bool setTrackFrame(SsContext context, int track, double frame) =>
      ss_runtime_set_track_frame(_ctx(context), track, frame);

  @override
  double? trackFrame(SsContext context, int track) =>
      _float(ss_runtime_get_track_frame(_ctx(context), track));

  @override
  bool setTrackSpeed(SsContext context, int track, double speed) =>
      ss_runtime_set_track_speed(_ctx(context), track, speed);

  @override
  double? trackSpeed(SsContext context, int track) =>
      _float(ss_runtime_get_track_speed(_ctx(context), track));

  @override
  bool setTrackFrameRate(SsContext context, int track, int fps) =>
      ss_runtime_set_track_frame_rate(_ctx(context), track, fps);

  @override
  int? trackFrameRate(SsContext context, int track) =>
      _signed(ss_runtime_get_track_frame_rate(_ctx(context), track));

  @override
  bool setTrackSkipFrames(SsContext context, int track, bool skip) =>
      ss_runtime_set_track_skip_frames(_ctx(context), track, skip);

  @override
  bool? trackSkipFrames(SsContext context, int track) {
    // The C-API answers `false` for a track that does not exist, which is also
    // a real setting, so the track's existence is asked separately.
    if (track >= trackCount(context)) return null;
    return ss_runtime_get_track_skip_frames(_ctx(context), track);
  }

  @override
  bool setTrackPlaybackDirection(
          SsContext context, int track, int direction, int style) =>
      ss_runtime_set_track_playback_direction(
          _ctx(context), track, direction, style);

  @override
  int? trackPlaybackDirection(SsContext context, int track) =>
      _signed(ss_runtime_get_track_playback_direction(_ctx(context), track));

  @override
  int? trackPlaybackStyle(SsContext context, int track) =>
      _signed(ss_runtime_get_track_playback_style(_ctx(context), track));

  @override
  bool setTrackLoopCount(SsContext context, int track, int count) =>
      ss_runtime_set_track_loop_count(_ctx(context), track, count);

  @override
  int? trackLoopCount(SsContext context, int track) {
    // `0` is "no animation": a count reads back positive, or -1 for forever.
    final count = ss_runtime_get_track_loop_count(_ctx(context), track);
    return count == 0 ? null : count;
  }

  @override
  bool isTrackFinished(SsContext context, int track) =>
      ss_runtime_is_track_finished(_ctx(context), track);

  @override
  bool trackJustLooped(SsContext context, int track) =>
      ss_runtime_track_just_looped(_ctx(context), track);

  @override
  bool setTrackOutgoingEventThreshold(
          SsContext context, int track, double threshold) =>
      ss_runtime_set_track_outgoing_event_threshold(
          _ctx(context), track, threshold);

  @override
  double? trackOutgoingEventThreshold(SsContext context, int track) => _float(
      ss_runtime_get_track_outgoing_event_threshold(_ctx(context), track));

  @override
  int? trackMainSource(SsContext context, int track) =>
      _handle(ss_runtime_get_track_main_source(_ctx(context), track));

  @override
  int? addTrackSource(
          SsContext context, int track, String name, double weight) =>
      _handle(_withName(name,
          (n) => ss_runtime_add_track_source(_ctx(context), track, n, weight)));

  @override
  bool setSourceWeight(SsContext context, int source, double weight) =>
      ss_runtime_set_source_weight(_ctx(context), source, weight);

  @override
  double? sourceWeight(SsContext context, int source) =>
      _float(ss_runtime_get_source_weight(_ctx(context), source));

  @override
  bool setSourceFrame(SsContext context, int source, double frame) =>
      ss_runtime_set_source_frame(_ctx(context), source, frame);

  @override
  double? sourceFrame(SsContext context, int source) =>
      _float(ss_runtime_get_source_frame(_ctx(context), source));

  @override
  bool setSourceEventThreshold(
          SsContext context, int source, double threshold) =>
      ss_runtime_set_source_event_threshold(_ctx(context), source, threshold);

  @override
  double? sourceEventThreshold(SsContext context, int source) =>
      _float(ss_runtime_get_source_event_threshold(_ctx(context), source));

  @override
  int? sourceAnimationIndex(SsContext context, int source) =>
      _signed(ss_runtime_get_source_animation_index(_ctx(context), source));

  @override
  int? currentAnimationIndex(SsContext context) =>
      _signed(ss_runtime_get_current_animation_index(_ctx(context)));

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
  bool effectSlotIsIndependent(SsEffectSlot slot) =>
      ss_effect_slot_is_independent((slot as _NativeEffectSlot).ptr);

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
    required bool draw,
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
      draw,
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
    final ptr = (slot as _NativeInstanceSlot).ptr;
    final r = ss_instance_slot_step(
      ptr,
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
      // After the step: before it, the slot still holds last tick's speed.
      speed: ss_instance_slot_get_speed(ptr),
    );
  }
}
