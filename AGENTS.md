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
SoA→`ui.Vertices` bake, `paint`) → **L1** ffigen `@Native` C-API bindings
(`dart:ffi`), which live in the sibling **`ssruntime_dart`** binding package
(a plain Dart, non-Flutter package — top-level bindings + the
`framedata`/`effect_draw_plan` FlatBuffers; `ssplayer_flutter` depends on it). The native `libssruntime` is delivered via
**native assets** (`ssruntime_dart/hook/build.dart` bundles the prebuilt dylib as
a code asset; the `@Native` bindings resolve it by asset id) — there is no
`DynamicLibrary` loader, no `SSRUNTIME_LIBRARY_PATH`, and (on Flutter) no
CocoaPods framework. Layers below are nearer the Brain; keep L2 Widget-free so it
is reusable headless / from Flame / flutter_gpu.
The host `.sspj`→`.ssab` converter is a third binding package,
**`ssconverter_dart`** — ffigen `@Native` bindings to the host `libssconverter`
dylib behind a `ssconvert` CLI + `SsConverter` lib (desktop only); the conversion
itself runs in Rust, mirroring how `ssruntime_dart` binds `libssruntime`.

## Key files

| Path | Role |
|---|---|
Paths are under `packages/ssplayer_flutter/` unless noted; **L1** now lives in the
sibling `../ssruntime_dart/` package.

| `lib/ssplayer_flutter.dart` | Public API barrel (L2–L4; import L1 from `ssruntime_dart` directly). |
| `../ssruntime_dart/` | **L1** binding package (plain Dart, non-Flutter): ffigen `@Native` top-level C-API bindings (`lib/src/ssruntime_bindings.g.dart`; native lib bundled by `hook/build.dart`) + runtime FlatBuffers `lib/src/fbs/{framedata,effect_draw_plan}.g.dart` (imported as `package:ssruntime_dart/framedata.dart`). |
| `../ssconverter_dart/` | Host `.sspj`→`.ssab` converter — ffigen `@Native` bindings to the host `libssconverter` dylib (`lib/src/ssconverter_bindings.g.dart`; dylib bundled by `hook/build.dart`) behind the `ssconvert` CLI + `SsConverter` lib (desktop only). |
| `lib/src/internal_player.dart` | **L2** engine — FFI lifecycle, SoA getters, `paint` = `DrawBatch.kind` dispatch (`_emitNormalBatch`). |
| `lib/src/render/geometry_builder.dart` | **L2** — `GeometryBuilder` (pure SoA→`ui.Vertices` bake) + `DrawFrame` (per-frame SoA bundle). New kinds add build methods here. |
| `lib/src/render/blend.dart` | **L2** — `blendModeFor` (`BlendType`→`ui.BlendMode`); future PartColor coef table. |
| `lib/src/render/part_color.dart` | **L2** — PartColor (§10) reader (`PartColor.read`) + `PartColor.identity` passthrough. |
| `lib/src/render/mask.dart` | **L2** — Mask (§9) pure logic: `MaskPartFlags` (ssab PartData roles), `MaskPlan` (writer collection, scope, coverage bbox/UV), `MaskBits`. |
| `shaders/partcolor.frag` | PartColor blend + mask replay — the shader every *peeled* part uses. |
| `shaders/mask_write.frag` | Writes one mask writer's bit into the coverage bitmap. |
| `lib/src/texture_registry.dart` | **L2** — pure texture store: hash→`ui.Image` + cached `shaderFor` (`ImageShader`). No blend/Paint logic. |
| `lib/src/texture_loader.dart` | `SsTextureLoader` — reference + embedded texture loading + per-cellmap routing (§16C). |
| `lib/src/ssab_info.dart` | `SsAnimeInfo` — enumerate animation/cellmap names from bytes. |
| `lib/src/player.dart` | **L3** `SpriteStudioPlayer`. |
| `lib/src/render/sprite_studio_view.dart` | **L4** `SpriteStudioView` / `SpriteStudioRenderBox`. |
| `lib/src/ssab/*.g.dart` | flatc-generated `.ssab`/`.ssqb` **asset-format** accessors (do not hand-edit; runtime `framedata`/`effect` FlatBuffers live in `ssruntime_dart`). |
| `scripts/*` | Native build + codegen toolchain (below). |
| `example/` | overall/Basic validation app. |

## Toolchain scripts

All mirror the sibling players (`../SSPlayerFor{Godot,Unity,Web,RenPy}`).
`.sh` + `.ps1` variants; SDK located via `$SSSDK`, else `./SpriteStudio-SDK`.

| Script | Does | When |
|---|---|---|
| `scripts/build-runtime.{sh,ps1}` | Builds `ssruntime`/`ssconverter` (host direct; cross via `SpriteStudio-SDK/scripts/release-*`) and places the **bare** dynamic libs into each binding package's `native/libs/<platform>/[<arch>]` — `libssruntime` → `ssruntime_dart`, the host `libssconverter` → `ssconverter_dart`. No framework wrapping / `macos/Frameworks/` symlink on the Flutter side: each package's `hook/build.dart` bundles the dylib as a **native-assets code asset** (Flutter re-wraps it into `ssruntime.framework` inside the `.app` automatically). Then copies the SDK `build.rs`-emitted plain-C headers (`<crate>.h`) into each package's `native/include/` — but does **not** regenerate the ffigen bindings (they are committed; that is a separate manual step). | After changing Rust / first setup. |
| `scripts/generate-ffigen-code.{sh,ps1}` | `dart run ffigen` → each package's `lib/src/*_bindings.g.dart` (`@Native` top-level bindings) from `native/include/*.h`. **No cbindgen** — the SDK `build.rs` emits the C header. **Standalone** — NOT invoked by `build-runtime`; run it yourself after a C-API change and commit the result. | After a native / C-API change (then commit). |
| `scripts/generate-fbs-code.{sh,ps1}` | `flatc --dart` → `lib/src/ssab/*.g.dart` from the SDK `.fbs`. Standalone (deliberately NOT part of `build-runtime`). | After changing a `.fbs` schema. |
| `scripts/prepare-example-assets.sh` | Converts `tests/overall/overall.sspj` → `.ssab` into `example/assets/overall/`. | Refreshing example assets. |

> There is **no** `download-sdk` script: a Rust-less consumer gets the prebuilt
> `libssruntime` from `ssruntime_dart/hook/build.dart`'s download branch (see the
> Native-packaging gotcha), not a separate setup step.

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
* **Native packaging = native assets (no CocoaPods framework on Flutter).** The
  Brain reaches the app through Dart's **build hooks**: `ssruntime_dart/hook/build.dart`
  emits a `CodeAsset(package: 'ssruntime_dart', name: 'ssruntime', file: <bare dylib
  from native/libs/<platform>/<arch>>, linkMode: DynamicLoadingBundled())`, and the
  generated `@Native` bindings carry a matching `@ffi.DefaultAsset('package:ssruntime_dart/ssruntime')`.
  `build.dart` resolves that `file` in priority order: (1) a consumer override
  `hooks.user_defines.ssruntime_dart.libssruntime` (bring-your-own dylib), (2) the
  package's local `native/libs/…` (source checkout / `build-runtime.sh`), else
  (3) a **download** of the pinned SDK release asset (`_sdkVersion` in `build.dart`)
  cached under `outputDirectoryShared` — so a pub.dev consumer with no Rust
  toolchain gets the Brain automatically (this replaced the old `download-sdk`).
  `dart`/`flutter test` and `flutter build` run the hook automatically (native assets
  is stable & default-on since Flutter 3.38 / Dart 3.10). On macOS, Flutter re-wraps
  the bundled dylib into `Contents/Frameworks/ssruntime.framework` and records the
  mapping in `flutter_assets/NativeAssetsManifest.json` (`package:ssruntime_dart/ssruntime`
  → `ssruntime.framework/ssruntime`) — verified: the runtime *is* embedded, dlopen-resolved
  at runtime, no `@rpath` link-time dependency on the main binary. So there is **no**
  vendored podspec, `macos/Frameworks/` symlink, or `SSRUNTIME_LIBRARY_PATH`; the
  example's `macos/` needs no CocoaPods plugin integration (`pod install` re-syncs
  cleanly with zero plugin pods). `ssconverter_dart` bundles the host `libssconverter`
  the same way. NB: the SDK still builds the versioned `libssruntime.framework` via
  `scripts/make-macos-framework.sh` for the universal release + the other players
  (Godot/Unity/RenPy consume it directly) — only Flutter's *consumption* moved to
  native assets. **iOS/Android** go through the same `ssruntime_dart/hook/build.dart`
  (only that runtime hook; `ssconverter_dart` is a desktop-only host tool). Android
  resolves one bare `.so` per NDK ABI (`native/libs/android/{arm64-v8a,armeabi-v7a,x86_64}/`);
  iOS uses **bare per-slice dylibs, NOT an xcframework** — the hook is invoked once
  per `code.iOS.targetSdk`, so it picks
  `native/libs/ios/{iphoneos,iphonesimulator}/<arch>/libssruntime.dylib` (device-arm64,
  sim-arm64 and sim-x86_64 are distinct Mach-O targets that can't share a slice —
  that is what an xcframework separates). `build-runtime.sh` places these; Flutter's
  embedding wraps+signs the chosen slice like on macOS. **Verified 2026-07-13**:
  the example renders on an iOS **simulator** (iphonesimulator/arm64) and an Android
  **emulator** (APK bundles all three ABIs under `lib/<abi>/`; ran on x86_64/arm64) —
  `[ssplayer] OK` + on-screen animation on both. Still unconfirmed: a physical iOS
  device (iphoneos slice, code-signed) and the armeabi-v7a ABI at runtime.
* **Generated code is never hand-edited.** The flatc FlatBuffers accessors are
  **committed** — asset format in `ssplayer_flutter/lib/src/ssab/`, runtime output
  in `ssruntime_dart/lib/src/fbs/` (schema-driven; regenerate with
  `generate-fbs-code`, which routes each `.fbs` to its owning package). The ffigen
  bindings (each binding package's `lib/src/*_bindings.g.dart`) are **also
  committed** (like the flatc accessors) so a normal checkout / pub.dev consumer
  builds without ffigen — they track the native C-API and are regenerated by the
  **standalone** `generate-ffigen-code` (globbing `packages/*/ffigen*.yaml`),
  NOT by `build-runtime`; run it after a C-API change and commit. Each package's
  `native/` (prebuilt libs + copied C headers) is gitignored. The SDK
  `build.rs` emits two headers per crate: `<crate>.h` (plain C — ffigen input +
  framework module-map umbrella) and `<crate>.hpp` (C++ — Godot); both ship in the
  release `include/`.
* **Blend types**: only Mix/Add/Mul/Sub are honored (others → Mix), matching the
  flagship; straight (non-premultiplied) alpha. `PartColor` needs a
  `FragmentProgram` (Phase-1+), not stock `BlendMode`.
* **Flutter's fragment-shader dialect is NOT full GLSL.** `impellerc` rejects
  **integer bitwise operators** (`<<`, `>>`, `&`, `|`, `~`) and **`discard`** —
  runtime effects are SkSL *shaders*, which return a colour. Port bit twiddling
  to float arithmetic (`bitAt(set, 2^i) = floor(mod(set/p, 2.0))`; an 8-bit
  `~x` is `255.0 - x`; a 24-bit set is exact in a float32 mantissa) and replace
  `discard` with `fragColor = vec4(0.0)` — a zero premultiplied fragment is a
  no-op under every blend mode we emit. Shaders also get **no per-vertex
  varyings**, which is why `drawVertices` can't feed them: a shaded part is
  peeled onto its own `drawPath` and its UVs are rebuilt from a CPU affine
  (`buildPartColorQuad`). **`flutter test` compiles the shaders** (impellerc runs
  in the asset build), so a dialect error shows up there — but the tests still
  pass, because the programs merely fail to load and the code falls back. Grep
  the test output for `impellerc failure` / `SkSL Error`; fragment programs never
  *execute* headless, so shader output can only be verified in `example/`.
* **Mask (§9) has no C-API — it is a data contract.** The roles come from the
  **static `.ssab` `PartData`** (`mask_write` / `draw_as_mask` /
  `visible_inside_mask` / `mask_influence`), read once at load
  (`MaskPartFlags.readAll`), NOT from `FrameData` and NOT from any SoA buffer;
  only `mask` / `priority` / `hide` are per-frame. `mask_influence` is
  **deliberately overloaded** (writer → OP invert/increment; target → opt-in) —
  never normalise it away. Ignore `FrameData.mask_indices`: the runtime omits
  clipping writers from it and *includes* hidden masks, so walk `draw_order` +
  `PartData` instead (the flagship does the same).

## Verification

Native libs must be built first (`scripts/build-runtime.sh`). The tests pick up
the Brain automatically via **native assets** — `dart`/`flutter test` runs the
binding package's `hook/build.dart`, which bundles the prebuilt dylib; there is
no `SSRUNTIME_LIBRARY_PATH` / `DynamicLibrary.open` and no framework to point at.

| Check | Command (run in `packages/ssplayer_flutter/`) |
|---|---|
| Analyze | `flutter analyze lib test` |
| Unit + render tests | `flutter test` |
| L1 bindings smoke (in `../ssruntime_dart/`) | `dart test` |
| Converter smoke + CLI (in `../ssconverter_dart/`) | `dart test` / `dart run ssconverter_dart:ssconvert -o <out> <sspj>` |
| Native host build (also copies C headers) | `bash ../../scripts/build-runtime.sh` |
| ffigen bindings only | `bash ../../scripts/generate-ffigen-code.sh` |
| FlatBuffers (on `.fbs` change) | `bash ../../scripts/generate-fbs-code.sh` |
| macOS desktop run | (in `example/`) `flutter run -d macos` → expect `[ssplayer] OK` |
| macOS embedding check | (in `example/`) `flutter build macos` → `ssruntime.framework` under `*.app/Contents/Frameworks/` |

`example/` is analyzed as its own package (path dependency on the `ssplayer_flutter`
package; no longer a Flutter plugin — native assets replace the plugin/podspec).

## Render recipe (Phase 1 Basic)

Per frame: `update(dt)` → `get_frame_data(frameNo)` → iterate `draw_batches`;
for `kind == Normal`, gather `draw_order[start_rank .. +count]` parts, bake each
part's 4 world-transformed corners + pixel UVs + white×`alpha` vertex colors +
quad indices into one indexed `ui.Vertices`, and `drawVertices(v,
BlendMode.modulate, paint)` once per batch (`paint` = `ImageShader(texture)` +
framebuffer blend). Sub-frame sampling is ON by default. See
`SpriteStudio-SDK/libs/ssruntime/docs/30_core/30_render_loop.ja.md` and the
Flutter architecture design doc.
