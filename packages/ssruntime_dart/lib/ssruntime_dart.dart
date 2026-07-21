/// Pure-Dart `dart:ffi` bindings for the SpriteStudio-SDK runtime
/// (**Brain** = `libssruntime`), delivered via **native assets**.
///
/// The C-API is exposed as top-level `@Native` functions that resolve the
/// `libssruntime` **code asset** bundled by `hook/build.dart` — no
/// `DynamicLibrary`, no loader, and no Rust toolchain on the consumer side.
/// This is **Layer 1** — the renderer-agnostic core beneath
/// [`ssplayer_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter),
/// also usable from Flame / `flutter_gpu` / headless Dart. No Flutter dependency.
///
/// Loading `.ssab`, advancing time, and reading back per-frame SoA buffers +
/// the `FrameData` `DrawBatch` plan (see `package:ssruntime_dart/framedata.dart`)
/// all go through these functions.
library;

// Layer-1 runtime abstraction (platform-agnostic) + the compile-time-selected
// backend singleton `ssRuntime`: native `dart:ffi` where it exists, otherwise the
// web `dart:js_interop` backend. Layer 2 talks only to this, so it carries no
// `dart:ffi` and compiles for the web.
export 'src/runtime_api.dart';
export 'src/native_runtime.dart'
    if (dart.library.js_interop) 'src/web_runtime.dart';

// The raw Layer-1 C-API (`@ffi.Native` functions + runtime structs) is
// intentionally NOT re-exported here: it is `dart:ffi`-only, and this barrel must
// stay `dart:ffi`-free so Layer 2 compiles for the web. All callers go through
// `ssRuntime` ([SsRuntime]); the native backend (`src/native_runtime.dart`) is
// the sole importer of the raw bindings.
