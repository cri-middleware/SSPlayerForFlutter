# Native Runtime

The Rust runtime (`libssruntime`, the "Brain") reaches your app through Dart **native assets**: the
[`ssruntime_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssruntime_dart)
build hook (`hook/build.dart`) bundles the dylib as a code asset, and the `@Native` bindings resolve
it by asset id. There is no CocoaPods plugin, vendored framework, or `DynamicLibrary` path — for most
apps this is entirely automatic and you never need this page.

## How the library is resolved

`hook/build.dart` selects the native library in priority order:

1. **Consumer override** — `hooks.user_defines.ssruntime_dart.libssruntime` in your app's
   `pubspec.yaml`. Highest priority; bring your own dylib.
2. **Local checkout** — `native/libs/<platform>/[<arch>]`, populated by `scripts/build-runtime.*`
   (source builds).
3. **Download** — the pinned SDK release asset, cached locally. This is the zero-setup path for
   consumers with no Rust toolchain.

`ssconverter_dart` bundles the host `libssconverter` the same way (desktop only).

## Bring your own build

To point at a locally-built dylib — for a patched runtime, a debug build, or an unreleased slice —
add an override to your **app's** `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    ssruntime_dart:
      libssruntime: /abs/path/to/libssruntime.dylib
```

Rebuild; the hook picks your file over the download. This is per-app, not a repo-wide change.

## Platform packaging

The same hook serves every target — it is invoked per platform/arch and picks the matching bare
library:

| Platform | What the hook resolves |
|---|---|
| macOS | one dylib; Flutter re-wraps it into `ssruntime.framework` inside the `.app` |
| iOS | bare per-slice dylibs (device `iphoneos` / simulator `iphonesimulator`), **not** an xcframework |
| Android | one bare `.so` per NDK ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`) |
| Windows / Linux | one dylib/`.so` (build from source) |

No `pod install` plugin integration and no manual slice juggling — Flutter embeds and signs the
chosen library automatically.

## Using the runtime from plain Dart (headless)

`ssruntime_dart` is a **pure Dart** package (no Flutter dependency), so the Layer-1 FFI bindings can
be used headless — for command-line tooling, tests, or a non-Flutter renderer (e.g. `flutter_gpu` or
your own canvas). The Flutter drawing stack (Layers 2–4: SoA → `ui.Vertices` bake, `paint`, widgets)
lives in `ssplayer_flutter`; the runtime and its FlatBuffers frame data do not depend on it.

See [Architecture](architecture.md) for how the layers stack up.
