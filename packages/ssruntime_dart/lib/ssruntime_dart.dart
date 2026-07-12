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

// The Layer-1 C-API: top-level `@ffi.Native(assetId: 'package:ssruntime_dart/
// ssruntime')` functions (`ss_runtime_*`, `ss_resource_*`, `ss_context_*`),
// `SS_RUNTIME_INVALID_HANDLE`, and the runtime structs.
export 'src/ssruntime_bindings.g.dart';
