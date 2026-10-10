# ssruntime_dart

Pure-Dart `dart:ffi` bindings for the SpriteStudio-SDK runtime (the **Brain**,
`libssruntime`): load a `.ssab`, advance time, and read back the per-frame SoA
buffers and the FlatBuffers `DrawBatch` plan.

**Layer 1 — no Flutter dependency, no renderer.** This package computes what to
draw and says nothing about how. [`ssplayer_flutter`](../ssplayer_flutter) is
the Flutter renderer built on it; a Flame game, a `flutter_gpu` backend or a
headless Dart tool sit on it just as well.

The C-API is exposed as top-level `@Native` functions that resolve the
`libssruntime` **code asset** bundled by `hook/build.dart` — no
`DynamicLibrary`, no loader path, and no Rust toolchain on the consumer side.
The hook prefers a locally built `native/`, and otherwise downloads the pinned
SpriteStudio-SDK release and verifies it against that release's `SHA256SUMS`.

## Install

Take it as a git dependency on a release tag, `ssruntime_dart-v<version>` on
[Releases](https://github.com/cri-middleware/SSPlayerForFlutter/releases?q=ssruntime_dart&expanded=true):

```yaml
dependencies:
  ssruntime_dart:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssruntime_dart-v7.0.0-beta.1
      path: packages/ssruntime_dart
```

Needs **Dart 3.10+** (native assets stable). Most apps get this package
transitively through `ssplayer_flutter` and never name it.

## Use

```dart
import 'package:ssruntime_dart/ssruntime_dart.dart';

// On the web the Brain is a wasm module fetched at runtime; a no-op on native.
await loadSsRuntime();

final resource = ssRuntime.createResourceCopy(bytes);   // checks the "SSAB" identifier only
```

`package:ssruntime_dart/framedata.dart` and `effect_draw_plan.dart` carry the
generated FlatBuffers accessors for the plan the Brain emits.

### Notes

* **`ssRuntime` is the whole API surface.** The raw `dart:ffi` bindings are
  deliberately not re-exported: this barrel has to stay `dart:ffi`-free so a
  layer above it can compile for the web, where the backend is `dart:js_interop`
  over the SDK's wasm build.
* **Every buffer is a borrow, valid only until the next `update`.** Read the
  frame data before advancing, and keep the `.ssab` bytes alive as long as the
  resource that was built from them.
* **Never re-implement FNV-1a for texture keys.** The pack carries the hashes
  the draw plan refers to; use them.
* **Generated code is committed and never hand-edited** — regenerate the
  bindings with `scripts/generate-ffigen-code.*` after a C-API change.

## More

* [Documentation](https://cri-middleware.github.io/SSPlayerForFlutter/)
* [Live Web demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — what this runtime draws, one layer up
* [Architecture](https://cri-middleware.github.io/SSPlayerForFlutter/contributing/architecture/) — where Layer 1 sits
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter)
