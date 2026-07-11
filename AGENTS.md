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
| `lib/src/internal_player.dart` | **L2** engine — lifecycle, SoA, `paint`, `_bakeNormalBatch`. |
| `lib/src/texture_registry.dart` | **L2** — hash→`ui.Image`, `paintForBatch` (blend mapping). |
| `lib/src/texture_loader.dart` | `SsTextureLoader` — reference + embedded texture loading (§16C). |
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
| `scripts/build-runtime.{sh,ps1}` | Builds `ssruntime`/`ssconverter` (host direct; cross via `SpriteStudio-SDK/scripts/release-*`) and places dynamic libs into `packages/ssplayer_flutter/native/libs/<platform>/[<arch>]`. macOS also emits `libssruntime.framework` and mirrors it to `macos/Frameworks/`. | After changing Rust / first setup. |
| `scripts/generate-runtime-code.{sh,ps1}` | `cbindgen --lang c` → `native/include/*.h`; `flatc --dart` → `lib/src/ssab/*.g.dart`; `dart run ffigen` → `lib/src/bindings/ssruntime_bindings.g.dart`. | After changing `.fbs` / C-API / regenerating bindings. |
| `scripts/download-sdk.{sh,ps1}` | Downloads a prebuilt SDK release (`SDK_VERSION.txt`) instead of building. | Rust-less setup (reserved; artifact name may need updating). |
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
* **macOS/iOS native packaging.** A bare `.dylib` via `vendored_libraries` is NOT
  embedded for runtime `dlopen`. Ship the Brain as a versioned `.framework`
  (`@rpath` install id) via `vendored_frameworks`, and it must live at/below the
  podspec dir (`macos/Frameworks/`, gitignored) — CocoaPods won't glob `../`.
  CocoaPods must be installed (`brew install cocoapods`).
* **Generated code is committed but never hand-edited.** Regenerate
  `lib/src/ssab/*.g.dart` and `lib/src/bindings/ssruntime_bindings.g.dart` via
  `generate-runtime-code.sh`. `native/` and `macos/Frameworks/` are gitignored.
* **Blend types**: only Mix/Add/Mul/Sub are honored (others → Mix), matching the
  flagship; straight (non-premultiplied) alpha. `PartColor` needs a
  `FragmentProgram` (Phase-1+), not stock `BlendMode`.

## Verification

Native libs must be built first (`scripts/build-runtime.sh`). The tests load the
host dylib via `SSRUNTIME_LIBRARY_PATH`.

| Check | Command (run in `packages/ssplayer_flutter/`) |
|---|---|
| Analyze | `flutter analyze lib test` |
| Unit + render tests | `SSRUNTIME_LIBRARY_PATH="$PWD/native/libs/macos/libssruntime.dylib" flutter test` |
| Native host build | `bash ../../scripts/build-runtime.sh` |
| Codegen | `bash ../../scripts/generate-runtime-code.sh` |
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
