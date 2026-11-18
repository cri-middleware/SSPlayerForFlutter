// The js_interop shapes below mirror the wasm-bindgen `web` API 1:1, so their
// external members keep the JS methods' snake_case names on purpose.
// ignore_for_file: non_constant_identifier_names

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'runtime_api.dart';
import 'ssab_identity.dart';

/// Web (`dart:js_interop`) backend of [SsRuntime].
///
/// Drives the SDK's wasm-bindgen `web` build (`ssruntime.js` + `ssruntime_bg.wasm`,
/// bundled as a Flutter asset by `ssplayer_flutter`). Handles are the wasm-bindgen
/// JS objects; SoA buffers live in the wasm `memory.buffer`.
///
/// **Every buffer this backend returns is a copy**, unlike the native backend's
/// zero-copy `asTypedList` views. It has to be: there is one shared
/// `memory.buffer` behind all of them, and *any* wasm allocation can
/// `memory.grow`, which detaches it and turns every outstanding view into a
/// `TypeError` on next read. A view is only safe until the very next call into
/// the Brain — not until the next `update`, which is all [SsRuntime]'s lifetime
/// contract requires — and Layer 2 legitimately holds buffers across calls: an
/// effect's draw plan is cached during `updateMs` and read back during paint,
/// and a parent's frame data stays live across an instance child's whole paint,
/// which re-enters the Brain. Copying on the way out makes the documented
/// contract true here, at the cost of a per-frame memcpy that native does not
/// pay. See [_f32] and friends.
///
/// The wasm module loads asynchronously but [SsRuntime] is synchronous, so the
/// app must `await loadSsRuntime(url)` once before creating a player on the web.
final SsRuntime ssRuntime = _WebRuntime();

// --- Module loading --------------------------------------------------------

/// Default asset path of the wasm-bindgen module, as Flutter serves a package
/// asset. Resolved against [Uri.base] so it is an absolute URL (a bare
/// `assets/…` specifier is rejected by `import()`) and honours the app's base
/// href. Callers may override the whole URL.
const _defaultModulePath =
    'assets/packages/ssplayer_flutter/assets/runtime-web/ssruntime.js';

JSObject? _module;
JSObject? _memory; // the WebAssembly.Memory (its .buffer detaches on grow)

/// Dynamically imports and initialises the wasm-bindgen module. Idempotent.
/// Must complete before any [SsRuntime] call on the web.
Future<void> loadSsRuntime([String? moduleUrl]) async {
  if (_module != null) return;
  final jsUrl = moduleUrl ?? Uri.base.resolve(_defaultModulePath).toString();
  // Prefer the SIMD build; fall back to the nosimd binary on WASM engines
  // without stable SIMD (e.g. the NW.js bundled with RPG Maker MZ). The two
  // builds share one wasm-bindgen JS glue — only the `_bg.wasm` differs — so we
  // pick the wasm URL here and hand it to init, resolved against the JS module
  // URL so a caller-supplied `moduleUrl` keeps its sibling wasm.
  final wasmName =
      _wasmSupportsSimd() ? 'ssruntime_bg.wasm' : 'ssruntime_bg.nosimd.wasm';
  final wasmUrl = Uri.parse(jsUrl).resolve(wasmName).toString();
  final mod = (await importModule(jsUrl.toJS).toDart);
  // wasm-bindgen `--target web`: the default export is the init function. Passing
  // the wasm URL makes it `fetch` that binary; it resolves to the InitOutput
  // (which carries the `memory`). callAsFunction's first arg is `thisArg`.
  final init = mod.getProperty('default'.toJS) as JSFunction;
  final out =
      (await (init.callAsFunction(null, wasmUrl.toJS) as JSPromise).toDart)
          as JSObject;
  _memory = out.getProperty('memory'.toJS) as JSObject;
  _module = mod;
}

/// Whether this WASM engine supports the SIMD (`simd128`) proposal. Validates a
/// tiny module that uses `i8x16.splat` — the standard probe from
/// GoogleChromeLabs/wasm-feature-detect. Returns false (→ nosimd binary) if SIMD
/// is unsupported or `WebAssembly.validate` is somehow unavailable.
bool _wasmSupportsSimd() {
  try {
    final wasm = globalContext.getProperty('WebAssembly'.toJS) as JSObject;
    final probe = Uint8List.fromList(const [
      0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, //
      3, 2, 1, 0, 10, 10, 1, 8, 0, 65, 0, 253, 15, 253, 98, 11,
    ]).toJS;
    return (wasm.callMethod('validate'.toJS, probe) as JSBoolean).toDart;
  } catch (_) {
    return false;
  }
}

JSObject get _mod => _module ??
    (throw StateError(
        'ssruntime_dart: call `await loadSsRuntime()` before using the web '
        'runtime.'));

JSFunction _class(String name) => _mod.getProperty(name.toJS) as JSFunction;

// --- Typed-array views over wasm memory (fresh each call; grow detaches) -----

@JS('Float32Array')
extension type _F32View._(JSFloat32Array _) implements JSFloat32Array {
  external _F32View(JSArrayBuffer buffer, int byteOffset, int length);
}

@JS('Uint32Array')
extension type _U32View._(JSUint32Array _) implements JSUint32Array {
  external _U32View(JSArrayBuffer buffer, int byteOffset, int length);
}

@JS('Int32Array')
extension type _I32View._(JSInt32Array _) implements JSInt32Array {
  external _I32View(JSArrayBuffer buffer, int byteOffset, int length);
}

@JS('Uint8Array')
extension type _U8View._(JSUint8Array _) implements JSUint8Array {
  external _U8View(JSArrayBuffer buffer, int byteOffset, int length);
}

JSArrayBuffer get _buffer => _memory!.getProperty('buffer'.toJS) as JSArrayBuffer;

// Each reads through a fresh view and returns a COPY. `toDart` does not copy on
// either web compiler — it casts on dart2js and wraps on dart2wasm, so the
// result still reads through to `memory.buffer` and detaches when the wasm heap
// grows. `fromList` is what actually detaches the caller from that hazard; see
// the class doc for why holding a live view is not an option here.
Float32List _f32(int ptr, int len) => len == 0
    ? Float32List(0)
    : Float32List.fromList(_F32View(_buffer, ptr, len).toDart);
Uint32List _u32(int ptr, int len) => len == 0
    ? Uint32List(0)
    : Uint32List.fromList(_U32View(_buffer, ptr, len).toDart);
Int32List _i32(int ptr, int len) => len == 0
    ? Int32List(0)
    : Int32List.fromList(_I32View(_buffer, ptr, len).toDart);
Uint8List _u8(int ptr, int len) =>
    len == 0 ? Uint8List(0) : Uint8List.fromList(_U8View(_buffer, ptr, len).toDart);

// --- js_interop shapes of the wasm-bindgen classes -------------------------

extension type _JsCtx(JSObject _) implements JSObject {
  external bool bind_resource(JSObject resource);
  external void set_render_mode(int mode);
  external void set_coordinate_system(int system);
  external void setup_animation(String name); // Result → throws on error
  external void play();
  external void play_with_start_frame(double frameNo);
  external void pause();
  external void resume();
  external void stop();
  external bool is_playing();
  external bool is_pausing();
  external bool is_clock_playing();
  external bool is_clock_pausing();
  external bool is_stack_in_motion();
  external bool is_finished();
  external bool just_looped();
  external bool is_playing_forward();
  external double get_frame_no();
  external int get_start_frame();
  external int get_end_frame();
  external int get_frame_rate();
  external void set_loop_count(int loops);
  external void set_speed_scale(double rate);
  external void set_frame_rate(int fps);
  external void set_frame_no(double frame);
  external void set_animation_section(int startFrame, int endFrame); // Result → throws on error
  // wasm-bindgen marshals WebPlaybackDirection / WebPlaybackStyle as their
  // numeric discriminants, so these cross as plain ints.
  external void set_playback_direction(int direction, int style);
  external int get_playback_direction();
  external int get_playback_style();
  external void set_skip_frames(bool skip);
  external bool get_skip_frames();
  external double update(double delta);
  external int prepare_frame_data(double frameNo);
  external int get_frame_data_buf();
  external int get_frame_data_len();
  external int get_world_matrices_buf();
  external int get_world_matrices_len();
  external int get_local_vertices_buf();
  external int get_local_vertices_len();
  external int get_local_uvs_buf();
  external int get_local_uvs_len();
  external int get_cell_meta_buf();
  external int get_cell_meta_len();
  external int get_mesh_vertices_x_buf();
  external int get_mesh_vertices_x_len();
  external int get_mesh_vertices_y_buf();
  external int get_mesh_vertices_y_len();
  external int get_mesh_uvs_buf();
  external int get_mesh_uvs_len();
  external int get_mesh_indices_buf();
  external int get_mesh_indices_len();
  external int get_mesh_vertex_offsets_buf();
  external int get_mesh_vertex_offsets_len();
  external int get_mesh_index_offsets_buf();
  external int get_mesh_index_offsets_len();
  external int get_shape_vertices_buf();
  external int get_shape_vertices_len();
  external int get_shape_vertex_box_coords_buf();
  external int get_shape_vertex_box_coords_len();
  external int get_shape_vertex_counts_buf();
  external int get_shape_vertex_counts_len();
  external int get_passed_event_count();
  external int get_passed_event_index(int index);
  external int get_passed_event_source_handle(int index);
  // Animation mixing (web/mod.rs). A Rust `Option` arrives as `undefined` and a
  // `Result` error as a throw; the callers below map both to the C-API's shape.
  external void set_track_animation(int track, String name);
  external int get_track_count();
  external void clear_track(int track);
  external void set_track_alpha(int track, double alpha);
  external double? get_track_alpha(int track);
  external void set_track_blend(int track, int blend);
  external int? get_track_blend(int track);
  external void set_track_sync(int track, int sync);
  external int? get_track_sync(int track);
  external void crossfade(int track, String name, double durationMs);
  external void fade_track(int track, double targetAlpha, double durationMs);
  external double? get_track_fade_progress(int track);
  external void cancel_track_fade(int track);
  external void set_track_frame(int track, double frame);
  external double? get_track_frame(int track);
  external void set_track_speed(int track, double speed);
  external double? get_track_speed(int track);
  external void set_track_frame_rate(int track, int fps);
  external int? get_track_frame_rate(int track);
  external void set_track_skip_frames(int track, bool skip);
  external bool? get_track_skip_frames(int track);
  external void set_track_playback_direction(int track, int direction, int style);
  external int? get_track_playback_direction(int track);
  external int? get_track_playback_style(int track);
  external void set_track_loop_count(int track, int count);
  external int? get_track_loop_count(int track);
  external bool is_track_finished(int track);
  external bool track_just_looped(int track);
  external void set_track_outgoing_event_threshold(int track, double threshold);
  external double? get_track_outgoing_event_threshold(int track);
  external int? get_track_main_source(int track);
  external int add_track_source(int track, String name, double weight);
  external void set_source_weight(int handle, double weight);
  external double? get_source_weight(int handle);
  external void set_source_frame(int handle, double frame);
  external double? get_source_frame(int handle);
  external void set_source_event_threshold(int handle, double threshold);
  external double? get_source_event_threshold(int handle);
  external int? get_source_animation_index(int handle);
  external int? get_current_animation_index();
  // Both return the event **owned** (a plain Rust value → a fresh wasm-heap
  // allocation behind a JS wrapper), while the `step` that consumes it takes it
  // by reference. See [_JsOwned]: the caller must free it.
  external _JsOwned get_active_effect_event(int slotIndex);
  external _JsOwned get_active_event_instance(int slotIndex);
  // Override layer. Every setter but
  // `clear_all_part_overrides` returns a Rust `Result`, which wasm-bindgen
  // surfaces as a THROW rather than a false — the callers below translate.
  external int find_part_index(String partName);
  external void set_part_visibility_override(int part, int force, bool cascade);
  external void clear_part_visibility_override(int part);
  external void set_part_color_override(
      int part, int blendOp, int rgba, int priorityMode);
  external void set_part_color_override_corners(
      int part, int blendOp, JSUint32Array rgbaLtRtLbRb, int priorityMode);
  external void clear_part_color_override(int part);
  external void set_part_cell_override(
      int part, int cellmapNameHash, int cellNameHash, int priorityMode);
  external void clear_part_cell_override(int part);
  external void clear_all_part_overrides();
  external void free();
}

extension type _JsRes(JSObject _) implements JSObject {
  external void free();
}

/// A wasm-bindgen wrapper the Rust side handed over **owned**, so its wasm-heap
/// allocation is the Dart caller's to release.
///
/// Only the JS FinalizationRegistry would otherwise reclaim it, and JS GC does
/// not see wasm-heap pressure — at 60 fps × every effect and instance slot that
/// is thousands of live structs per second, which is also exactly the
/// `memory.grow` churn that detaches the typed-array views above.
extension type _JsOwned(JSObject _) implements JSObject {
  external void free();
}

extension type _JsEffect(JSObject _) implements JSObject {
  external bool step(JSObject ev, double parentFrame, double deltaSeconds,
      double fps, bool parentLooped, bool yFlip, int vertStride, bool draw);
  external int get_draw_plan_buf();
  external int get_draw_plan_len();
  external bool is_independent();
  external void reset();
  external void free();
}

extension type _JsInstance(JSObject _) implements JSObject {
  // web/mod.rs SSRuntimeInstanceSlot::step — (ev, child_ctx, parent_frame,
  // delta_seconds, parent_looped); NO previous_child_frame (the slot tracks it
  // internally, same as the native C-API).
  external bool step(JSObject ev, JSObject childCtx, double parentFrame,
      double deltaSeconds, bool parentLooped);
  external bool transitioned();
  external double child_frame_no();
  external bool child_looped();
  external double get_speed();
  external bool is_independent();
  external void reset();
  external void free();
}

// --- Opaque handle wrappers ------------------------------------------------

class _WebContext implements SsContext {
  _WebContext(this.js);
  final _JsCtx js;

  /// What the wasm face threw on the last call that tracks a reason.
  ///
  /// The native side records this inside the Brain and hands it back through
  /// `ss_runtime_get_last_error`; the wasm face throws instead, so the reason
  /// only exists for as long as the `catch` that sees it. Kept here so the two
  /// backends can answer `lastErrorMessage` the same way.
  String? lastError;
}

class _WebResource implements SsResource {
  _WebResource(this.js);
  final _JsRes js;
}

class _WebEffectSlot implements SsEffectSlot {
  _WebEffectSlot(this.js);
  final _JsEffect js;
}

class _WebInstanceSlot implements SsInstanceSlot {
  _WebInstanceSlot(this.js);
  final _JsInstance js;
}

class _WebRuntime implements SsRuntime {
  // GC backstop: no NativeFinalizer on the web. wasm-bindgen objects hold wasm
  // memory that only `free()` releases; explicit dispose is the real path, so a
  // dart:core Finalizer is a best-effort backstop that frees on collection.
  final Finalizer<JSObject> _finalizer = Finalizer<JSObject>((js) {
    try {
      js.callMethod('free'.toJS);
    } catch (_) {}
  });

  _JsCtx _ctx(SsContext c) => (c as _WebContext).js;
  _JsRes _res(SsResource r) => (r as _WebResource).js;

  /// What the wasm face threw, in the Brain's words: a JS `Error` stringifies
  /// with its class in front.
  static String _reason(Object error) {
    final text = error.toString();
    return text.startsWith('Error: ') ? text.substring('Error: '.length) : text;
  }

  @override
  int? get ssabSchemaVersion => null;

  @override
  SsResource? createResourceCopy(Uint8List ssab) {
    // Reject a non-.ssab / truncated buffer with a friendly error before it
    // reaches the wasm module (which parses unchecked). See native_runtime.dart.
    assertSsabIdentifier(ssab);
    final resourceClass = _class('SSRuntimeResource');
    try {
      // `new SSRuntimeResource(data)` copies the bytes into wasm memory (Result
      // → throws on a bad pack, with the versions when they are what differs).
      final js = resourceClass.callAsConstructor<JSObject>(ssab.toJS) as _JsRes;
      return _WebResource(js);
    } catch (e) {
      throw StateError(_reason(e));
    }
  }

  @override
  void destroyResource(SsResource resource) => _res(resource).free();

  @override
  SsContext? createContext() {
    final js = _class('SSRuntimeContext').callAsConstructor<JSObject>() as _JsCtx;
    return _WebContext(js);
  }

  @override
  void destroyContext(SsContext context) => _ctx(context).free();

  @override
  bool bindResource(SsContext context, SsResource resource) =>
      _ctx(context).bind_resource(_res(resource));

  @override
  void setRenderMode(SsContext context, int mode) =>
      _ctx(context).set_render_mode(mode);

  @override
  void setCoordinateSystem(SsContext context, int system) =>
      _ctx(context).set_coordinate_system(system);

  @override
  void registerForGc(Object owner, {SsContext? context, SsResource? resource}) {
    if (context != null) _finalizer.attach(owner, _ctx(context), detach: owner);
    if (resource != null) _finalizer.attach(owner, _res(resource), detach: owner);
  }

  @override
  void unregisterFromGc(Object owner) => _finalizer.detach(owner);

  @override
  bool setupAnimation(SsContext context, String name) {
    final ctx = context as _WebContext;
    try {
      ctx.js.setup_animation(name);
      ctx.lastError = null;
      return true;
    } catch (e) {
      // The wasm face formats the Brain's error with `Display`, so what arrives
      // is the wording a user should see.
      ctx.lastError = _reason(e);
      return false;
    }
  }

  @override
  String? lastErrorMessage(SsContext context) =>
      (context as _WebContext).lastError;

  @override
  int hashString(String name) =>
      (_mod.callMethod('ss_runtime_hash_string'.toJS, name.toJS) as JSNumber)
          .toDartInt;

  @override
  void play(SsContext context) => _ctx(context).play();

  @override
  void playWithStartFrame(SsContext context, double frameNo) =>
      _ctx(context).play_with_start_frame(frameNo);

  @override
  void pause(SsContext context) => _ctx(context).pause();

  @override
  void resume(SsContext context) => _ctx(context).resume();

  @override
  void stop(SsContext context) => _ctx(context).stop();

  @override
  bool isPlaying(SsContext context) => _ctx(context).is_playing();

  @override
  bool isPausing(SsContext context) => _ctx(context).is_pausing();

  @override
  bool isClockPlaying(SsContext context) => _ctx(context).is_clock_playing();

  @override
  bool isClockPausing(SsContext context) => _ctx(context).is_clock_pausing();

  @override
  bool isStackInMotion(SsContext context) => _ctx(context).is_stack_in_motion();

  @override
  bool isFinished(SsContext context) => _ctx(context).is_finished();

  @override
  bool justLooped(SsContext context) => _ctx(context).just_looped();

  @override
  bool isPlayingForward(SsContext context) =>
      _ctx(context).is_playing_forward();

  @override
  double frameNo(SsContext context) => _ctx(context).get_frame_no();

  @override
  int startFrame(SsContext context) => _ctx(context).get_start_frame();

  @override
  int endFrame(SsContext context) => _ctx(context).get_end_frame();

  @override
  int frameRate(SsContext context) => _ctx(context).get_frame_rate();

  @override
  void setLoopCount(SsContext context, int count) => _ctx(context).set_loop_count(count);

  @override
  void setSpeedScale(SsContext context, double rate) =>
      _ctx(context).set_speed_scale(rate);

  @override
  void setFrameRate(SsContext context, int fps) =>
      _ctx(context).set_frame_rate(fps);

  @override
  void seek(SsContext context, double frame) =>
      _ctx(context).set_frame_no(frame);

  @override
  bool setAnimationSection(SsContext context, int startFrame, int endFrame) =>
      _tracked(context,
          () => _ctx(context).set_animation_section(startFrame, endFrame));

  @override
  void setPlaybackDirection(SsContext context, int direction, int style) =>
      _ctx(context).set_playback_direction(direction, style);

  @override
  int playbackDirection(SsContext context) =>
      _ctx(context).get_playback_direction();

  @override
  int playbackStyle(SsContext context) => _ctx(context).get_playback_style();

  @override
  void setSkipFrames(SsContext context, bool skip) =>
      _ctx(context).set_skip_frames(skip);

  @override
  bool skipFrames(SsContext context) => _ctx(context).get_skip_frames();

  @override
  double update(SsContext context, double deltaMs) =>
      _ctx(context).update(deltaMs);

  @override
  Uint8List? getFrameData(SsContext context, double frameNo) {
    final c = _ctx(context);
    // The web API returns a Result that THROWS when no animation/frame is set
    // (e.g. a paint that races ahead of the async .ssab load); the native C-API
    // returns null there. Mirror native so the Body's null path handles it.
    try {
      // One evaluation: `prepare_frame_data` builds the frame and returns its
      // length; the pointer is then a pure read.
      final len = c.prepare_frame_data(frameNo);
      if (len == 0) return null;
      return _u8(c.get_frame_data_buf(), len);
    } catch (_) {
      return null;
    }
  }

  @override
  Float32List worldMatrices(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_world_matrices_buf(), c.get_world_matrices_len());
  }

  @override
  Float32List localVertices(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_local_vertices_buf(), c.get_local_vertices_len());
  }

  @override
  Float32List localUvs(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_local_uvs_buf(), c.get_local_uvs_len());
  }

  @override
  Float32List cellMeta(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_cell_meta_buf(), c.get_cell_meta_len());
  }

  @override
  Float32List meshVerticesX(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_mesh_vertices_x_buf(), c.get_mesh_vertices_x_len());
  }

  @override
  Float32List meshVerticesY(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_mesh_vertices_y_buf(), c.get_mesh_vertices_y_len());
  }

  @override
  Float32List meshUvs(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_mesh_uvs_buf(), c.get_mesh_uvs_len());
  }

  @override
  Int32List meshIndices(SsContext context) {
    final c = _ctx(context);
    return _i32(c.get_mesh_indices_buf(), c.get_mesh_indices_len());
  }

  @override
  Uint32List meshVertexOffsets(SsContext context) {
    final c = _ctx(context);
    return _u32(c.get_mesh_vertex_offsets_buf(), c.get_mesh_vertex_offsets_len());
  }

  @override
  Uint32List meshIndexOffsets(SsContext context) {
    final c = _ctx(context);
    return _u32(c.get_mesh_index_offsets_buf(), c.get_mesh_index_offsets_len());
  }

  @override
  Float32List shapeVertices(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_shape_vertices_buf(), c.get_shape_vertices_len());
  }

  @override
  Float32List shapeVertexBoxCoords(SsContext context) {
    final c = _ctx(context);
    return _f32(c.get_shape_vertex_box_coords_buf(),
        c.get_shape_vertex_box_coords_len());
  }

  @override
  Int32List shapeVertexCounts(SsContext context) {
    final c = _ctx(context);
    return _i32(c.get_shape_vertex_counts_buf(), c.get_shape_vertex_counts_len());
  }

  @override
  int passedEventCount(SsContext context) =>
      _ctx(context).get_passed_event_count();

  @override
  int passedEventIndex(SsContext context, int index) =>
      _ctx(context).get_passed_event_index(index);

  @override
  int? passedEventSourceHandle(SsContext context, int index) {
    final handle = _ctx(context).get_passed_event_source_handle(index);
    // The wasm face answers u32::MAX for an index with no event, as C does.
    return handle == 0xFFFFFFFF ? null : handle;
  }

  // --- Animation mixing --------------------------------------------------
  //
  // Every setter goes through [_tracked], which keeps what the wasm face threw
  // so [lastErrorMessage] answers for these as the native side does.

  static bool _tracked(SsContext context, void Function() call) {
    final ctx = context as _WebContext;
    try {
      call();
      ctx.lastError = null;
      return true;
    } catch (e) {
      ctx.lastError = _reason(e);
      return false;
    }
  }

  @override
  bool setTrackAnimation(SsContext context, int track, String name) =>
      _tracked(context, () => _ctx(context).set_track_animation(track, name));

  @override
  int trackCount(SsContext context) => _ctx(context).get_track_count();

  @override
  bool clearTrack(SsContext context, int track) =>
      _tracked(context, () => _ctx(context).clear_track(track));

  @override
  bool setTrackAlpha(SsContext context, int track, double alpha) =>
      _tracked(context, () => _ctx(context).set_track_alpha(track, alpha));

  @override
  double? trackAlpha(SsContext context, int track) =>
      _ctx(context).get_track_alpha(track);

  @override
  bool setTrackBlend(SsContext context, int track, int blend) =>
      _tracked(context, () => _ctx(context).set_track_blend(track, blend));

  @override
  int? trackBlend(SsContext context, int track) =>
      _ctx(context).get_track_blend(track);

  @override
  bool setTrackSync(SsContext context, int track, int sync) =>
      _tracked(context, () => _ctx(context).set_track_sync(track, sync));

  @override
  int? trackSync(SsContext context, int track) =>
      _ctx(context).get_track_sync(track);

  @override
  bool crossfade(
          SsContext context, int track, String name, double durationMs) =>
      _tracked(
          context, () => _ctx(context).crossfade(track, name, durationMs));

  @override
  bool fadeTrack(SsContext context, int track, double targetAlpha,
          double durationMs) =>
      _tracked(context,
          () => _ctx(context).fade_track(track, targetAlpha, durationMs));

  @override
  double? trackFadeProgress(SsContext context, int track) =>
      _ctx(context).get_track_fade_progress(track);

  @override
  bool cancelTrackFade(SsContext context, int track) =>
      _tracked(context, () => _ctx(context).cancel_track_fade(track));

  @override
  bool setTrackFrame(SsContext context, int track, double frame) =>
      _tracked(context, () => _ctx(context).set_track_frame(track, frame));

  @override
  double? trackFrame(SsContext context, int track) =>
      _ctx(context).get_track_frame(track);

  @override
  bool setTrackSpeed(SsContext context, int track, double speed) =>
      _tracked(context, () => _ctx(context).set_track_speed(track, speed));

  @override
  double? trackSpeed(SsContext context, int track) =>
      _ctx(context).get_track_speed(track);

  @override
  bool setTrackFrameRate(SsContext context, int track, int fps) =>
      _tracked(context, () => _ctx(context).set_track_frame_rate(track, fps));

  @override
  int? trackFrameRate(SsContext context, int track) =>
      _ctx(context).get_track_frame_rate(track);

  @override
  bool setTrackSkipFrames(SsContext context, int track, bool skip) =>
      _tracked(context, () => _ctx(context).set_track_skip_frames(track, skip));

  @override
  bool? trackSkipFrames(SsContext context, int track) =>
      _ctx(context).get_track_skip_frames(track);

  @override
  bool setTrackPlaybackDirection(
          SsContext context, int track, int direction, int style) =>
      _tracked(
          context,
          () => _ctx(context)
              .set_track_playback_direction(track, direction, style));

  @override
  int? trackPlaybackDirection(SsContext context, int track) =>
      _ctx(context).get_track_playback_direction(track);

  @override
  int? trackPlaybackStyle(SsContext context, int track) =>
      _ctx(context).get_track_playback_style(track);

  @override
  bool setTrackLoopCount(SsContext context, int track, int count) =>
      _tracked(
          context, () => _ctx(context).set_track_loop_count(track, count));

  @override
  int? trackLoopCount(SsContext context, int track) =>
      _ctx(context).get_track_loop_count(track);

  @override
  bool isTrackFinished(SsContext context, int track) =>
      _ctx(context).is_track_finished(track);

  @override
  bool trackJustLooped(SsContext context, int track) =>
      _ctx(context).track_just_looped(track);

  @override
  bool setTrackOutgoingEventThreshold(
          SsContext context, int track, double threshold) =>
      _tracked(
          context,
          () => _ctx(context)
              .set_track_outgoing_event_threshold(track, threshold));

  @override
  double? trackOutgoingEventThreshold(SsContext context, int track) =>
      _ctx(context).get_track_outgoing_event_threshold(track);

  @override
  int? trackMainSource(SsContext context, int track) =>
      _ctx(context).get_track_main_source(track);

  @override
  int? addTrackSource(
      SsContext context, int track, String name, double weight) {
    int? handle;
    _tracked(context,
        () => handle = _ctx(context).add_track_source(track, name, weight));
    return handle;
  }

  @override
  bool setSourceWeight(SsContext context, int source, double weight) =>
      _tracked(
          context, () => _ctx(context).set_source_weight(source, weight));

  @override
  double? sourceWeight(SsContext context, int source) =>
      _ctx(context).get_source_weight(source);

  @override
  bool setSourceFrame(SsContext context, int source, double frame) =>
      _tracked(context, () => _ctx(context).set_source_frame(source, frame));

  @override
  double? sourceFrame(SsContext context, int source) =>
      _ctx(context).get_source_frame(source);

  @override
  bool setSourceEventThreshold(
          SsContext context, int source, double threshold) =>
      _tracked(context,
          () => _ctx(context).set_source_event_threshold(source, threshold));

  @override
  double? sourceEventThreshold(SsContext context, int source) =>
      _ctx(context).get_source_event_threshold(source);

  @override
  int? sourceAnimationIndex(SsContext context, int source) =>
      _ctx(context).get_source_animation_index(source);

  @override
  int? currentAnimationIndex(SsContext context) =>
      _ctx(context).get_current_animation_index();

  // --- Part overrides ----------------------------------------------------
  //
  // The wasm bindings signal rejection by throwing (a Rust `Result<(), JsValue>`
  // becomes a JS exception), while the C-API — and therefore [SsRuntime] —
  // returns false and keeps the reason. [_tracked] does that translation so both
  // backends present the same contract to Layer 2.

  @override
  int findPartIndex(SsContext context, String partName) =>
      _ctx(context).find_part_index(partName);

  @override
  bool setPartVisibilityOverride(SsContext context, int part, int force,
          {required bool cascade}) =>
      _tracked(context,
          () => _ctx(context).set_part_visibility_override(part, force, cascade));

  @override
  bool clearPartVisibilityOverride(SsContext context, int part) =>
      _tracked(context, () => _ctx(context).clear_part_visibility_override(part));

  @override
  bool setPartColorOverride(SsContext context, int part, int blendOp, int rgba,
          int priorityMode) =>
      _tracked(context, () => _ctx(context)
          .set_part_color_override(part, blendOp, rgba, priorityMode));

  @override
  bool setPartColorOverrideCorners(SsContext context, int part, int blendOp,
      Uint32List rgbaLtRtLbRb, int priorityMode) {
    if (rgbaLtRtLbRb.length != 4) {
      throw ArgumentError.value(rgbaLtRtLbRb, 'rgbaLtRtLbRb',
          'must hold exactly 4 packed corners (lt, rt, lb, rb)');
    }
    return _tracked(context, () => _ctx(context).set_part_color_override_corners(
        part, blendOp, rgbaLtRtLbRb.toJS, priorityMode));
  }

  @override
  bool clearPartColorOverride(SsContext context, int part) =>
      _tracked(context, () => _ctx(context).clear_part_color_override(part));

  @override
  bool setPartCellOverride(SsContext context, int part, int cellmapNameHash,
          int cellNameHash, int priorityMode) =>
      _tracked(context, () => _ctx(context).set_part_cell_override(
          part, cellmapNameHash, cellNameHash, priorityMode));

  @override
  bool clearPartCellOverride(SsContext context, int part) =>
      _tracked(context, () => _ctx(context).clear_part_cell_override(part));

  @override
  bool clearAllPartOverrides(SsContext context) =>
      _tracked(context, () => _ctx(context).clear_all_part_overrides());

  @override
  SsEffectSlot? createEffectSlot(
      SsResource resource, int effectNameHash, int seed) {
    try {
      final create = _class('SSRuntimeEffectSlot').getProperty('create'.toJS)
          as JSFunction;
      final js = create.callAsFunction(null, _res(resource),
          effectNameHash.toJS, seed.toJS) as _JsEffect?;
      return js == null ? null : _WebEffectSlot(js);
    } catch (_) {
      return null;
    }
  }

  @override
  void resetEffectSlot(SsEffectSlot slot) =>
      (slot as _WebEffectSlot).js.reset();

  @override
  void destroyEffectSlot(SsEffectSlot slot) =>
      (slot as _WebEffectSlot).js.free();

  @override
  bool effectSlotIsIndependent(SsEffectSlot slot) =>
      (slot as _WebEffectSlot).js.is_independent();

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
    final s = (slot as _WebEffectSlot).js;
    // `step` borrows the event; the allocation is ours to release (see
    // [_JsOwned]). The draw plan below lives on the slot, not the event.
    final ev = _ctx(context).get_active_effect_event(slotIndex);
    final bool visible;
    try {
      visible = s.step(ev, parentFrame, deltaSeconds, fps, parentLooped, yFlip,
          vertStride, draw);
    } finally {
      ev.free();
    }
    final len = visible ? s.get_draw_plan_len() : 0;
    return SsEffectStep(
      visible: visible,
      drawPlan: len > 0 ? _u8(s.get_draw_plan_buf(), len) : null,
    );
  }

  @override
  SsInstanceSlot? createInstanceSlot() {
    final create =
        _class('SSRuntimeInstanceSlot').getProperty('create'.toJS) as JSFunction;
    final js = create.callAsFunction() as _JsInstance;
    return _WebInstanceSlot(js);
  }

  @override
  void resetInstanceSlot(SsInstanceSlot slot) =>
      (slot as _WebInstanceSlot).js.reset();

  @override
  void destroyInstanceSlot(SsInstanceSlot slot) =>
      (slot as _WebInstanceSlot).js.free();

  @override
  bool instanceSlotIsIndependent(SsInstanceSlot slot) =>
      (slot as _WebInstanceSlot).js.is_independent();

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
    final s = (slot as _WebInstanceSlot).js;
    // Owned event, borrowed by `step` — see [stepEffectSlot].
    final ev = _ctx(parentContext).get_active_event_instance(slotIndex);
    final bool visible;
    try {
      visible = s.step(
          ev, _ctx(childContext), parentFrame, deltaSeconds, parentLooped);
    } finally {
      ev.free();
    }
    return SsInstanceStep(
      visible: visible,
      transitioned: s.transitioned(),
      childFrameNo: s.child_frame_no(),
      childLooped: s.child_looped(),
      // After the step: before it, the slot still holds last tick's speed.
      speed: s.get_speed(),
    );
  }
}
