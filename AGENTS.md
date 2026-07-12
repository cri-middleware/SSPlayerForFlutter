# SSPlayerForFlutter — AI Agent Guide

Flutter "Body" for the SpriteStudio-SDK "Brain". This repo implements the
Player (rendering / resource / coordinate transform) that consumes the Rust
`libssruntime` runtime over `dart:ffi`. The Brain itself lives in the
`SpriteStudio-SDK/` git submodule — see its own [AGENTS.md](./SpriteStudio-SDK/AGENTS.md).

## Operating rules

* Keep changes scoped to the requested task.
* **Do not commit or push unless the user explicitly asks.**
* Before editing, read enough surrounding context to understand callers and invariants.
* Follow the existing Dart style in touched files (naming, null-safety, `dispose` discipline).
* After editing Dart, run `flutter analyze` and the tests (see [Verification](#verification)).
* Treat the flagship **SSPlayerForGodot** (`../SSPlayerForGodot`) as the reference
  implementation when a rendering/behavior detail is unclear — it is closest to
  Flutter's canvas model. Fall back to the porting guide under
  `SpriteStudio-SDK/libs/ssruntime/docs/`.

## Architecture in one paragraph

The Brain (`libssruntime`, Rust `no_std`) loads a `.ssab`, advances time, and
emits per-frame **SoA buffers** (world matrices, local vertices/UVs) plus a
FlatBuffers **`FrameData`** carrying a **DrawBatch** plan. The Body (this repo)
is a strict 4-layer downward dependency: **L4** drawing adapters
(`SpriteStudioView` = `RenderBox`; Flame/CustomPaint optional) → **L3**
`SpriteStudioPlayer` (`ChangeNotifier` + `Ticker`, transport/events) → **L2**
`SpriteStudioInternalPlayer` (Widget-agnostic: FFI Resource/Context lifecycle,
SoA→`ui.Vertices` bake, `paint`) → **L1** `SsRuntimeBindings` (`dart:ffi`) +
`SsRuntime` loader. Layers below are nearer the Brain; keep L2 Widget-free so it
is reusable headless / from Flame / flutter_gpu.

## Key files

| Path | Role |
|---|---|
| `lib/ssplayer_flutter.dart` | Public API barrel. |
| `lib/src/bindings/ssruntime_bindings.g.dart` | **L1**, ffigen-generated full C-API (do not hand-edit). |
| `lib/src/bindings/ssruntime_library.dart` | `SsRuntime` — DynamicLibrary loader (per-platform name). |
| `lib/src/internal_player.dart` | **L2** engine — FFI lifecycle, SoA getters, `paint` = `DrawBatch.kind` dispatch (`_emitNormalBatch`). |
| `lib/src/render/geometry_builder.dart` | **L2** — `GeometryBuilder` (pure SoA→`ui.Vertices` bake) + `DrawFrame` (per-frame SoA bundle). New kinds add build methods here. |
| `lib/src/render/blend.dart` | **L2** — `blendModeFor` (`BlendType`→`ui.BlendMode`); future PartColor coef table. |
| `lib/src/texture_registry.dart` | **L2** — pure texture store: hash→`ui.Image` + cached `shaderFor` (`ImageShader`). No blend/Paint logic. |
| `lib/src/texture_loader.dart` | `SsTextureLoader` — reference + embedded texture loading + per-cellmap routing (§16C). |
| `lib/src/ssab_info.dart` | `SsAnimeInfo` — enumerate animation/cellmap names from bytes. |
| `lib/src/player.dart` | **L3** `SpriteStudioPlayer`. |
| `lib/src/render/sprite_studio_view.dart` | **L4** `SpriteStudioView` / `SpriteStudioRenderBox`. |
| `lib/src/ssab/*.g.dart` | flatc-generated FlatBuffers accessors (do not hand-edit). |
| `scripts/*` | Native build + codegen toolchain (below). |
| `example/` | overall/Basic validation app. |

## Toolchain scripts

All mirror the sibling players (`../SSPlayerFor{Godot,Unity,Web,RenPy}`).
`.sh` + `.ps1` variants; SDK located via `$SSSDK`, else `./SpriteStudio-SDK`.

| Script | Does | When |
|---|---|---|
| `scripts/build-runtime.{sh,ps1}` | Builds `ssruntime`/`ssconverter` (host direct; cross via `SpriteStudio-SDK/scripts/release-*`) and places dynamic libs into `packages/ssplayer_flutter/native/libs/<platform>/[<arch>]`. macOS ships the runtime as `libssruntime.framework` (SDK-built on the universal path; wrapped locally on the host/debug path); no `macos/Frameworks/` mirror. Then copies the SDK `build.rs`-emitted plain-C headers (`<crate>.h`) into `native/include/` and regenerates the ffigen bindings (calls `generate-ffigen-code`). | After changing Rust / first setup. |
| `scripts/generate-ffigen-code.{sh,ps1}` | `dart run ffigen` → `lib/src/bindings/*.g.dart` from `native/include/*.h`. **No cbindgen** — the SDK `build.rs` emits the C header. Auto-invoked at the end of `build-runtime` / `download-sdk`; run directly only when an `ffigen*.yaml` changed. | After a native / C-API change (usually automatic). |
| `scripts/generate-fbs-code.{sh,ps1}` | `flatc --dart` → `lib/src/ssab/*.g.dart` from the SDK `.fbs`. Standalone (deliberately NOT part of `build-runtime`). | After changing a `.fbs` schema. |
| `scripts/download-sdk.{sh,ps1}` | Downloads a prebuilt SDK release (`SDK_VERSION.txt`) instead of building, then regenerates the ffigen bindings (calls `generate-ffigen-code`). | Rust-less setup (reserved; artifact name/layout may need updating). |
| `scripts/prepare-example-assets.sh` | Converts `tests/overall/overall.sspj` → `.ssab` into `example/assets/overall/`. | Refreshing example assets. |

## Hard constraints & gotchas

These were learned the hard way — respect them.

* **Never call `PartState.updateFlag`.** The flatc-generated `bit_flags` enum's
  `fromValue` throws `StateError` on any OR-combined value (i.e. almost always).
  Read the raw `uint64` from the FrameData buffer and bitwise-AND. Phase-1 Basic
  sidesteps this with the 4-corner quad; the 5-vertex center fan is only needed
  when `update_flag & (AttributeVertex | AttributePartColor)`.
* **`local_uvs` are texture-PIXEL coordinates, stride 10** (`lt,rt,lb,rb,center`),
  not normalized and not ×8 (the design doc's "×8" predates this runtime). In
  Flutter, `ImageShader` with an identity matrix samples in image pixels, so pass
  the UVs straight to `drawVertices` — no scaling. `local_vertices` is also
  stride 10. World matrix is column-major 4×4:
  `x' = m0·x + m4·y + m12`, `y' = m1·x + m5·y + m13`.
* **Texture key = `cellmap.name_hash` == `DrawBatch.texture_hash`.** Use the
  pre-baked hash; never re-implement FNV-1a on the Dart side. For runtime name→id
  use `ss_runtime_hash_string`.
* **Coordinate system = 1 (Y-Down); the Brain applies the flip once.** Do not
  double-flip in the Body. The flagship sets only `coordinate_system`, leaving
  origin/unit at defaults; positioning is the Body's job (`paint` centers on `dst`).
* **FFI pointer lifetime.** `FrameData` + SoA pointers are borrows into the
  Brain's internal buffer, valid only until the next `update` — consume within
  the frame. `Context`/`Resource` are freed by `dispose()`; a `NativeFinalizer`
  is a backstop. The borrowed `.ssab` native buffer must outlive the resource
  (borrow mode). Call `get_frame_data(frame)` BEFORE reading the SoA getters.
* **ffigen types.** ffigen maps `const unsigned char *` → `Pointer<UnsignedChar>`
  and `uintptr_t *` → `Pointer<UintPtr>`. L2 keeps ergonomic `Uint8`/`Size`
  scratch cells and `.cast()`s at the FFI boundary.
* **macOS native packaging.** A bare `.dylib` via `vendored_libraries` is NOT
  embedded for runtime `dlopen`. Ship the Brain as a versioned `libssruntime.framework`
  (`@rpath` install id) built by the SDK's shared `scripts/make-macos-framework.sh`
  (single source of truth, the framework twin of `make-macos-bundle.sh`): the SDK's
  `release-macos.sh` calls it for the universal release (with `Headers/`+`Modules/`
  and a code signature) and `build-runtime.sh` copies that in; on the fast host/debug
  path `build-runtime.sh` calls the SAME helper to wrap the cargo dylib. There is one
  physical copy, in `native/libs/macos/`. CocoaPods only *embeds* a vendored framework
  located at/below the podspec dir — a `../native/...` path is recorded but the app
  ships without it (verified: no `libssruntime` in the built `.app`) — so
  `build-runtime.sh` puts a **symlink** at `macos/Frameworks/libssruntime.framework`
  → `../../native/libs/macos/...` and the podspec vendors `Frameworks/libssruntime.framework`
  (`install_framework` resolves the symlink at embed time). (The iOS podspec vendors
  `../native/libs/ios/libssruntime.xcframework`; iOS embedding isn't verified here.)
  CocoaPods must be installed (`brew install cocoapods`).
* **Generated code is never hand-edited.** The flatc `lib/src/ssab/*.g.dart` are
  **committed** (schema-driven; regenerate with `generate-fbs-code` when a `.fbs`
  changes). The ffigen `lib/src/bindings/*.g.dart` are **gitignored** — they track
  the native C-API and are regenerated by `build-runtime` / `download-sdk` (which
  call `generate-ffigen-code`). `native/` is gitignored. The SDK `build.rs` emits
  two headers per crate: `<crate>.h` (plain C — ffigen input + framework module-map
  umbrella) and `<crate>.hpp` (C++ — Godot); both ship in the release `include/`.
* **Blend types**: only Mix/Add/Mul/Sub are honored (others → Mix), matching the
  flagship; straight (non-premultiplied) alpha. `PartColor` needs a
  `FragmentProgram` (Phase-1+), not stock `BlendMode`.

## Verification

Native libs must be built first (`scripts/build-runtime.sh`). The tests load the
host Brain via `SSRUNTIME_LIBRARY_PATH` (the framework binary on macOS).

| Check | Command (run in `packages/ssplayer_flutter/`) |
|---|---|
| Analyze | `flutter analyze lib test` |
| Unit + render tests | `SSRUNTIME_LIBRARY_PATH="$PWD/native/libs/macos/libssruntime.framework/libssruntime" flutter test` |
| Native host build (also copies C headers + regenerates ffigen) | `bash ../../scripts/build-runtime.sh` |
| ffigen bindings only | `bash ../../scripts/generate-ffigen-code.sh` |
| FlatBuffers (on `.fbs` change) | `bash ../../scripts/generate-fbs-code.sh` |
| macOS desktop run | (in `example/`) `flutter run -d macos` → expect `[ssplayer] OK` |

`example/` is analyzed as its own package (path dependency on the plugin).

## Render recipe (Phase 1 Basic)

Per frame: `update(dt)` → `get_frame_data(frameNo)` → iterate `draw_batches`;
for `kind == Normal`, gather `draw_order[start_rank .. +count]` parts, bake each
part's 4 world-transformed corners + pixel UVs + white×`alpha` vertex colors +
quad indices into one indexed `ui.Vertices`, and `drawVertices(v,
BlendMode.modulate, paint)` once per batch (`paint` = `ImageShader(texture)` +
framebuffer blend). Sub-frame sampling is ON by default. See
`SpriteStudio-SDK/libs/ssruntime/docs/30_core/30_render_loop.ja.md` and the
Flutter architecture design doc.
