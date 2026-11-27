# 🛠️ Build Guide

For developing the core (the Rust runtime or the Player itself). **App users and customizers do not
need this** — the native libraries are auto-downloaded (see
[Native Runtime](native-runtime.md)).

## Prerequisites

| Tool | When |
|---|---|
| Rust (`rustup`) | Building the native libs from source |
| Flutter / Dart | Always. The floor is on [Installation](../guide/install.md); `flutter pub get` fails if yours is older |
| `wasm-pack` + `wasm32-unknown-unknown` target | Only to **build** the web runtime (`cargo install wasm-pack`; `rustup target add wasm32-unknown-unknown`) |
| `flatc` | Only when regenerating a `.fbs` schema |
| libclang | Only when regenerating the ffigen bindings (ffigen loads it) |
| `rustup target add` per cross target; for Android also `cargo install cargo-ndk` and an NDK | Only for a cross-build; the `Install targets and tools` step of `ci.yml` lists the targets |
| cbindgen | Never install manually — it is a build-dependency of the SDK's `build.rs` |

Clone with submodules — the SDK (the Brain's source, see
[How the Player Is Put Together](architecture.md)) is a git submodule:

```bash
git submodule update --init --recursive
```

## Running from a checkout

A checkout needs no Rust. When a binding package's `native/libs/` has no library for the target, its
build hook downloads it from the SDK release the packages pin ([Native Runtime](native-runtime.md)),
and the example assets are converted with that prebuilt `libssconverter`.

```bash
# Run the overall example; its assets and platform runner are generated if missing
scripts/run-macos.sh                  # expect [ssplayer] OK + on-screen animation
```

`run-linux.sh`, `run-ios.sh`, `run-android.sh` and `run-web.sh` do the same for their target, and
take `example=<name>`, `--gpu` and `--watch` (the last two for `overall` only) and any `flutter run`
argument — the header of
`scripts/run-example.sh` lists them. Windows uses the `.ps1` variant of each script
(`run-windows.ps1` for the run). The web target has no build hook, so get its runtime first
([Web](#web-developer-preview)).

## Build from source

Only when you change the Brain itself. `build-runtime` builds the native libraries from the submodule
into each binding package's `native/libs/`, and the build hooks take them instead of the download.

```bash
# Build the native libs + copy the C headers into each binding package's native/include/
scripts/build-runtime.sh              # e.g. build-runtime.sh platform=macos build=release
```

Android, iOS and a universal macOS build (`arch=universal`) are
delegated to `SpriteStudio-SDK/scripts/release-*`; `build-runtime` builds the host target and the web
wasm itself.

## Web (developer preview)

The web target has **no `dart:ffi` and no native assets**, so the Brain cannot ship as a dylib.
Instead it is built as the SDK's wasm-bindgen `web` build (a `.wasm` + JS glue) and bundled as a plain
Flutter **asset**, then driven from Dart over `dart:js_interop`.

**Setup — get the wasm runtime.** Download the pinned release (needs neither Rust nor `wasm-pack`)
or build it (needs `wasm-pack` and the `wasm32-unknown-unknown` target):

```bash
scripts/download-web-runtime.sh              # the pinned release, no Rust
scripts/build-runtime.sh platform=web        # or: build it; debug unless you add build=release
# → packages/ssplayer_flutter/assets/runtime-web/
#     {ssruntime.js, ssruntime_bg.wasm, ssruntime_bg.nosimd.wasm}
```

Two wasm binaries are built from the same source: `ssruntime_bg.wasm` (SIMD, the fast path) and
`ssruntime_bg.nosimd.wasm` (fallback for WASM engines without stable SIMD, e.g. the NW.js in RPG
Maker MZ). They share **one** wasm-bindgen JS glue (`ssruntime.js`); `loadSsRuntime` picks the right
binary at runtime via a `WebAssembly.validate` SIMD probe.

Like the native dylibs, the wasm is **git-ignored** — each developer builds or downloads it once,
and a `git clean` removes it.

**Run:**

```bash
scripts/run-web.sh             # default CanvasKit renderer
scripts/run-web.sh --wasm      # Skwasm renderer (WebAssembly build mode)
```

!!! warning "Developer preview"
    For the web **runtime backend**, the runtime API is the seam: a conditional export picks its
    `dart:ffi` backend or its `dart:js_interop` backend, so Layer 2 compiles without `dart:ffi`.
    `flutter build web` / `flutter run -d chrome` build and render — every render kind
    (Normal / Shape / Mesh / Effect / Instance), the shader paths (PartColor / mask), framebuffer
    blend, and the timeline event callbacks (UserData / Signal / Audio) are verified on CanvasKit.
    On the web every frame goes through the **Canvas (`drawVertices`) backend** — `flutter_gpu` is
    not available there — with the SIMD / nosimd wasm auto-selected at load. The native-assets build hooks
    no-op cleanly on web (nothing to configure).

!!! note "First macOS runner"
    `scripts/run-macos.sh` generates `examples/overall/macos/` when it is missing. To make it by hand,
    run `bash examples/overall/scripts/setup-macos.sh`: besides `flutter create` it adds the entitlements
    the example needs (drag-and-drop, and a debug-only sandbox-off for the live-reload push), which a
    bare `flutter create --platforms=macos .` leaves out.

## Code generation (committed; regenerate on change)

Generated code is **committed** so a normal checkout, and an app depending on the packages, builds
without ffigen or flatc. Regenerate and commit after the corresponding change:

- **ffigen bindings** (`lib/src/*_bindings.g.dart`) — after a C-API change, run
  `scripts/build-runtime.sh` first (it copies the SDK's headers into each binding package's
  `native/include/`, which ffigen reads), then `scripts/generate-ffigen-code.sh`, and commit. The
  generator is **standalone** — `build-runtime` does *not* run it — and a stale header regenerates
  the old API without an error.
- **FlatBuffers** (`lib/src/ssab/*.g.dart` asset format; `ssruntime_dart` runtime fbs) — after a
  `.fbs` change, run `scripts/generate-fbs-code.sh`. flatc always emits a serializer next to every
  reader, and the script moves those `*Builder` / `*ObjectBuilder` classes out of `lib/` (nothing
  there writes a buffer — the `.ssab` assets come from the SpriteStudio tooling and the runtime fbs
  come back over dart:ffi) into the tests' support code, where they synthesise fixtures. That is ~2/3 of flatc's output kept out of the published packages.

## Verify

```bash
# in packages/ssplayer_flutter/
flutter analyze lib test
flutter test          # the Brain comes in through ssruntime_dart's build hook (native assets) — no env vars, no framework
```

The tests that play an animation read the packs `scripts/deploy-examples.sh` writes (the `run-*`
scripts write them too) and report skipped without them, so a green run shows less than it looks.

Every other package and example runs its own suite in its own directory; the table says which runner.

| Check | Where |
|---|---|
| Analyze + unit/render tests | `packages/ssplayer_flutter/` |
| L1 bindings smoke | `packages/ssruntime_dart/` (`dart test`) |
| Converter smoke + CLI | `packages/ssconverter_dart/` (`dart test`) |
| Flame adapter | `packages/ssplayer_flame/` (`flutter test`) |
| Incremental reconversion | `packages/ssgen_dart/` (`dart test`) |
| Live reload | `packages/ssgen_flutter/` (the watcher, `flutter test`); the in-app end is in `packages/ssplayer_flutter/` |
| Example apps | `examples/overall/`, `examples/flame/`, `examples/part_following/` (`flutter test`) |
| macOS embedding | `examples/overall/` → `flutter build macos` → `ssruntime.framework` under `*.app/Contents/Frameworks/` |

## Using a changed Player

Keep the app's dependencies as a released app has them, and override every package of this
repository the app reaches — the ones it imports, and `ssruntime_dart` under them — to the checkout:

```yaml
dependencies:
  ssplayer_flutter: ^7.0.0-beta.1
  ssplayer_flame: ^7.0.0-beta.1          # only if the app uses Flame

dependency_overrides:
  ssplayer_flutter:
    path: <checkout>/packages/ssplayer_flutter
  ssplayer_flame:
    path: <checkout>/packages/ssplayer_flame
  ssruntime_dart:
    path: <checkout>/packages/ssruntime_dart
```

Inside the repository the packages find each other through the pub workspace; from outside, each one
names the others by version, so a `path:` dependency on `ssplayer_flutter` alone still asks pub for
`ssruntime_dart` (and `ssplayer_flame` for `ssplayer_flutter`) by version, so pub takes the released
ones from pub.dev and the app runs your change on top of them unnoticed. The native library then
comes from the checkout's `packages/ssruntime_dart/native/libs/` when `build-runtime` has filled it,
and otherwise from the pinned SDK release ([Native Runtime](native-runtime.md)). To run a patched
runtime under the released Player instead, point the app at your own dylib
([Bring your own build](native-runtime.md#bring-your-own-build)).

## Checking against the real host

What the suites above do not show, and how to look at it:

- **`flutter test`'s end-to-end renders do not run the shader paths.** Under `flutter test`,
  `ui.FragmentProgram.fromAsset` finds only package-local keys, and the Canvas backend asks for
  `packages/…` ones, so the program fails once and stays failed: peeled PartColor, the mask coverage
  pass and the `ss_*` effects are not drawn. A green `player.paint` → `toImage` test covers the batch
  geometry only; the helpers' unit tests cover the rest, and an app run shows it.
- **A change to `ui.Image` or `ui.ImageShader` lifetimes also runs the `dart:io`-free tests under
  `flutter test --platform chrome <file>`** (the header of each says so and gives the command).
  CanvasKit's `ImageShader.dispose` disposes its image too, where native and Skwasm only borrow it, and
  neither the VM tests nor CI go through CanvasKit.
- **`flutter test --enable-impeller` fails the end-to-end blend test's `Sub` case, and that is the
  engine.** flutter_tester's Impeller, which has no framebuffer fetch, draws an advanced blend over an
  earlier draw with a seam along its bounds' diagonal; three `drawRect` calls in plain `dart:ui`
  reproduce it, and the macOS app draws it cleanly. CI does not pass `--enable-impeller`.
- **Check a `.frag` with `impellerc` from Flutter's cache** rather than by reading it: a runtime
  effect fails silently. `--reflection-json` gives each uniform's `location`, which is the order of
  the Dart side's `setFloat` calls; `--sksl --json` shows the Web path. A local `#include` works, and a
  uniform declared and never used still keeps its slot.
- **Look at the GPU backend after `flutter clean`.** An incremental build has hidden a bug that only
  a clean build showed. The integration test in `examples/overall` compares it with Canvas on a
  device, and its header says what it assumes. Quote the GPU path's memory as RSS, not
  allocation: pages never written to are not resident.
- **Find a flickering frame headless.** Drive a `SpriteStudioInternalPlayer` directly — `load`, then
  `updateMs`, `frameNo` and `getFrameData` in the order the player paints with — record the part's world
  bounding box from `meshVertexOffsets()` / `meshVerticesX()` / `meshVerticesY()` each tick, and look
  for the tick that jumps away from its neighbours.
- **Live reload without a device.** Run
  `dart run ssgen_flutter:sswatch --run -d chrome --device --web-browser-flag=--headless=new` in
  `examples/overall` (the only example with `ssgen_flutter` and a `SpriteStudio_Source/`). Make its runner with `flutter create --platforms=<every platform it already has>`, because
  the command replaces the list in `.metadata` (restore `.metadata` afterwards). Stand in for a save by
  appending a newline to the `.sspj`: `touch` does not reach the watcher. To press `r` / `R` / `q`,
  pipe them through `script`, which gives `flutter run` the terminal it waits for.

The four layers and what each owns are on [How the Player Is Put Together](architecture.md); how
the native library is resolved and packaged is on [Native Runtime](native-runtime.md).
