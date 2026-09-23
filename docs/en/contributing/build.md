# 🛠️ Build Guide

For developing the core (the Rust runtime or the Player itself). **App users and customizers do not
need this** — the native libraries are auto-downloaded (see
[Native Runtime](native-runtime.md)).

## Prerequisites

| Tool | When |
|---|---|
| Rust (`rustup`) | Building the native libs from source |
| Flutter / Dart | Always. The floor is on [Installation](../guide/install.md); `flutter pub get` fails if yours is older |
| `wasm-pack` + `wasm32-unknown-unknown` target | Only for the **web** target (`cargo install wasm-pack`; `rustup target add wasm32-unknown-unknown`) |
| `flatc` | Only when regenerating a `.fbs` schema |
| cbindgen | Never install manually — it is a build-dependency of the SDK's `build.rs` |

Clone with submodules — the SDK (the Brain's source) is a git submodule:

```bash
git submodule update --init --recursive
```

## Build from source

```bash
# Build the native libs + copy the C headers into each binding package's native/include/
scripts/build-runtime.sh              # e.g. build-runtime.sh platform=macos build=release

# Generate example assets, then run
scripts/deploy-examples.sh
cd examples/overall && flutter run    # expect [ssplayer] OK + on-screen animation
```

Windows uses the `.ps1` variant of each script. Cross-builds for android / ios are delegated to
`SpriteStudio-SDK/scripts/release-*`; `build-runtime` itself builds the host target directly.

## Web (developer preview)

The web target has **no `dart:ffi` and no native assets**, so the Brain cannot ship as a dylib.
Instead it is built as the SDK's wasm-bindgen `web` build (a `.wasm` + JS glue) and bundled as a plain
Flutter **asset**, then driven from Dart over `dart:js_interop`.

**Setup — build the wasm runtime** (needs `wasm-pack` + the `wasm32-unknown-unknown` target):

```bash
scripts/build-runtime.sh platform=web        # + build=release (default) | debug
# → packages/ssplayer_flutter/assets/runtime-web/
#     {ssruntime.js, ssruntime_bg.wasm, ssruntime_bg.nosimd.wasm}
```

Two wasm binaries are built from the same source: `ssruntime_bg.wasm` (SIMD, the fast path) and
`ssruntime_bg.nosimd.wasm` (fallback for WASM engines without stable SIMD, e.g. the NW.js in RPG
Maker MZ). They share **one** wasm-bindgen JS glue (`ssruntime.js`); `loadSsRuntime` picks the right
binary at runtime via a `WebAssembly.validate` SIMD probe.

Like the native dylibs, the built wasm is **git-ignored** — every developer (re)builds it with the
line above; a `git clean` removes it.

**Run:**

```bash
cd examples/overall
flutter run -d chrome          # default CanvasKit renderer
flutter run -d chrome --wasm   # Skwasm renderer (WebAssembly build mode)
```

!!! warning "🚧 Developer preview"
    The web **runtime backend** is wired: `lib/src/runtime_api.dart` is the seam, with a `dart:ffi`
    backend (`native_runtime.dart`) and a `dart:js_interop` backend (`web_runtime.dart`) selected by
    conditional export, so Layer 2 (`internal_player.dart` etc.) compiles without `dart:ffi`.
    `flutter build web` / `flutter run -d chrome` now build and render — every render kind
    (Normal / Shape / Mesh / Effect / Instance), the shader paths (PartColor / mask), framebuffer
    blend, and the timeline event callbacks (UserData / Signal / Audio) are verified on CanvasKit.
    Web stays a **debug-grade `drawVertices` path** (mobile / desktop are the ones headed for
    `flutter_gpu`), with the SIMD / nosimd wasm auto-selected at load. The native-assets build hooks
    no-op cleanly on web (nothing to configure).

!!! note "First macOS runner"
    If `examples/overall/macos/` is missing, generate it once:
    `cd examples/overall && flutter create --platforms=macos .`

## Code generation (committed; regenerate on change)

Generated code is **committed** so a normal checkout / pub.dev consumer builds without ffigen or
flatc. Regenerate and commit after the corresponding change:

- **ffigen bindings** (`lib/src/*_bindings.g.dart`) — after a C-API change, run
  `scripts/generate-ffigen-code.sh` and commit. This is **standalone** — `build-runtime` does *not*
  run it.
- **FlatBuffers** (`lib/src/ssab/*.g.dart` asset format; `ssruntime_dart` runtime fbs) — after a
  `.fbs` change, run `scripts/generate-fbs-code.sh`. flatc always emits a serializer next to every
  reader, and `scripts/strip_fbs_builders.dart` moves those
  `*Builder` / `*ObjectBuilder` classes out of `lib/` (nothing there writes a buffer — the `.ssab`
  assets come from the SpriteStudio tooling and the runtime fbs come back over dart:ffi) into
  `packages/ssplayer_flutter/test/support/*_builders.g.dart`, which the tests use to synthesise
  fixtures. That is ~2/3 of flatc's output kept out of the published packages.

## Verify

```bash
# in packages/ssplayer_flutter/
flutter analyze lib test
flutter test          # native assets bundles the Brain via hook/build.dart — no env vars, no framework
```

`ssruntime_dart` and `ssconverter_dart` each run `dart test` in their own package.

| Check | Where |
|---|---|
| Analyze + unit/render tests | `packages/ssplayer_flutter/` |
| L1 bindings smoke | `packages/ssruntime_dart/` (`dart test`) |
| Converter smoke + CLI | `packages/ssconverter_dart/` (`dart test`) |
| macOS embedding | `examples/overall/` → `flutter build macos` → `ssruntime.framework` under `*.app/Contents/Frameworks/` |

The four layers and what each owns are on [Architecture](architecture.md); how the native library is
resolved and packaged is on [Native Runtime](native-runtime.md).
