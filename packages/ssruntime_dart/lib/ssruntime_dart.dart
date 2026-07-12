/// Pure-Dart `dart:ffi` bindings + loader for the SpriteStudio-SDK runtime
/// (**Brain** = `libssruntime`).
///
/// Loads a `.ssab`, advances time, and emits per-frame SoA buffers + a
/// `DrawBatch` plan through the raw C-API. This is **Layer 1** — the
/// renderer-agnostic core beneath [`ssplayer_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter),
/// also usable from Flame / `flutter_gpu` / headless Dart. No Flutter dependency.
library ssruntime_dart;

export 'src/ssruntime_library.dart' show SsRuntime;
export 'src/ssruntime_bindings.g.dart'
    show SsRuntimeBindings, SS_RUNTIME_INVALID_HANDLE;
