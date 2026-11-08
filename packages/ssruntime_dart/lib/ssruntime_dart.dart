/// The SpriteStudio-SDK runtime (**Brain** = `libssruntime`) as a Dart API:
/// [SsRuntime] and its `ssRuntime` singleton, backed by `dart:ffi` (a native code
/// asset that `hook/build.dart` bundles) or by wasm on the web.
///
/// This is **Layer 1** — the renderer-agnostic core beneath
/// [`ssplayer_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter),
/// also usable from Flame / `flutter_gpu` / headless Dart. No Flutter dependency.
///
/// Loading `.ssab`, advancing time, and reading back per-frame SoA buffers +
/// the `FrameData` `DrawBatch` plan (see `package:ssruntime_dart/framedata.dart`)
/// all go through it.
library;

// Layer-1 runtime abstraction (platform-agnostic) + the compile-time-selected
// backend singleton `ssRuntime`: native `dart:ffi` where it exists, otherwise the
// web `dart:js_interop` backend. Layer 2 talks only to this, so it carries no
// `dart:ffi` and compiles for the web.
export 'src/runtime_api.dart';
export 'src/native_runtime.dart'
    if (dart.library.js_interop) 'src/web_runtime.dart';

// Pure-Dart `.ssab` header identify check (`file_identifier "SSAB"`). `dart:ffi`-
// free, so it re-exports safely on the web. Callers loading untrusted bytes can
// pre-check with `hasSsabIdentifier`; `createResourceCopy` enforces it.
export 'src/ssab_identity.dart';

// The raw Layer-1 C-API (`@ffi.Native` functions + runtime structs) is
// intentionally NOT re-exported here: it is `dart:ffi`-only, and this barrel must
// stay `dart:ffi`-free so Layer 2 compiles for the web. All callers go through
// `ssRuntime` ([SsRuntime]); the native backend (`src/native_runtime.dart`) is
// the sole importer of the raw bindings.
