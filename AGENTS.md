# SSPlayerForFlutter — AI Agent Guide

Flutter **Body** for the SpriteStudio-SDK **Brain**. This monorepo (a pub
workspace, Melos-released) implements the Player that renders `.ssab` animations
by driving the Rust `libssruntime` runtime over `dart:ffi`. The Brain lives in
the `SpriteStudio-SDK/` submodule — see its own [AGENTS.md](./SpriteStudio-SDK/AGENTS.md).
`CLAUDE.md` is a symlink to this file.

## Operating rules

* Keep changes scoped to the request; read callers/invariants before editing.
* **Do not commit or push unless the user explicitly asks.**
* Follow the existing Dart style (naming, null-safety, `dispose` discipline).
* After editing Dart, run `flutter analyze` + tests (see [Verification](#verification)).
* Fix stale docs in the same turn you notice them (architecture/roadmap drift easily).
* When a rendering/behavior detail is unclear, the flagship **SSPlayerForGodot**
  (github.com/cri-middleware/SSPlayerForGodot) is the closest reference; then the submodule `SpriteStudio-SDK/libs/ssruntime/docs/`.

## Architecture

The Brain loads a `.ssab`, advances time, and emits per-frame **SoA buffers**
(world matrices, local vertices/UVs) + a FlatBuffers **`FrameData`** carrying a
**DrawBatch** plan. The Body is a strict 4-layer downward dependency (lower =
nearer the Brain; keep **L2 Widget-free** so it stays reusable headless / Flame / flutter_gpu):

* **L4** drawing adapters — `SpriteStudioView` (`RenderBox`); Flame's `SpriteStudioComponent` (in `ssplayer_flame`).
* **L3** `SpriteStudioPlayer` — `ChangeNotifier`; a `Ticker` in vsync mode **or** externally clocked via `advance` (how Flame drives it); transport/events; `reload` is the live-reload primitive.
* **L2** `SpriteStudioInternalPlayer` — Widget-agnostic FFI lifecycle, SoA→geometry bake, and a `paint` that walks the `DrawBatch` plan and delegates each batch to a pluggable **`RenderBackend`** — `CanvasBackend` (`Canvas.drawVertices`) or `FlutterGpuBackend` (flutter_gpu/Impeller), chosen per `SpriteStudioBackend` (`auto` = flutter_gpu where the capability probe passes, else `canvas`).
* **L1** ffigen `@Native` C-API bindings — in the `ssruntime_dart` package.

Native `libssruntime` ships via **native assets** (`hook/build.dart` bundles the
prebuilt dylib as a `CodeAsset`; `@Native` resolves it by asset id) — no
`DynamicLibrary` loader, no `SSRUNTIME_LIBRARY_PATH`, no CocoaPods framework. On
**Web** (a developer preview) there is no `dart:ffi`: L1 becomes a `dart:js_interop`
backend over the SDK's wasm-bindgen build, bundled as a Flutter asset under
`assets/runtime-web/` and drawn through the Canvas backend (flutter_gpu is native-only).

## Packages (`packages/`)

| Package | Role |
|---|---|
| `ssplayer_flutter` | Core Player (L2–L4). Public API barrel `lib/ssplayer_flutter.dart`. |
| `ssplayer_flame`   | **L4** Flame adapter, separate so the core never pulls in `flame`; re-exports the core API. |
| `ssruntime_dart`   | **L1** `libssruntime` bindings + runtime FlatBuffers (`framedata`/`effect_draw_plan`). Plain Dart. |
| `ssconverter_dart` | Host `.sspj`→`.ssab` converter — `libssconverter` bindings + `ssconvert` CLI (desktop). |
| `ssgen_dart`       | Host lib: reconvert only the *stale* `.sspj` in a dir (mtime-diff over `ssconverter_dart`). Desktop. |
| `ssgen_flutter`    | Dev-only live-reload: `SsLiveReload` mixin + `SsDevChannel` (VM Service) + the `sswatch` host runner that pushes fresh packs into the running app. |

Examples: `examples/overall` (Basic validation) and `examples/flame`.

**L2 render internals** (`ssplayer_flutter/lib/src/render/`): `geometry_builder.dart`
(SoA→geometry bake — `ui.Vertices` for Canvas and interleaved VBOs for GPU — plus `DrawFrame`,
Mesh/Shape buffers), `blend.dart`, `part_color.dart`, `mask.dart`/`mask_context.dart`,
`part_override.dart` (per-part color/cell/visibility), `part_anchor.dart`, `effect.dart`/`instance.dart`;
the pluggable render backends in `backend/` (`render_backend.dart` abstraction + `canvas_backend.dart` /
`flutter_gpu_backend.dart` + the capability probe); Canvas shaders `shaders/{partcolor,mask_write}.frag`
(dart:ui runtime-effect) and GPU shaders `shaders/gpu/*.{vert,frag}` (real GLSL); loaders
`texture_loader.dart`/`instance_loader.dart`; generated `lib/src/ssab/*.g.dart` (never hand-edit).

## Toolchain scripts (`scripts/`, `.sh`+`.ps1`; SDK via `$SSSDK` else `./SpriteStudio-SDK`)

| Script | Does | When |
|---|---|---|
| `build-runtime` | Build `ssruntime`/`ssconverter`; place bare dylibs into each binding pkg's `native/libs/…` + copy C headers to `native/include/`. Does **not** run ffigen. | After Rust / first setup |
| `generate-ffigen-code` | `dart run ffigen` → each pkg's `lib/src/*_bindings.g.dart`. Standalone; commit result. | After a C-API change |
| `generate-fbs-code` | `flatc --dart` → `lib/src/ssab/*.g.dart`. Standalone. | After a `.fbs` change |
| `deploy-examples` | Convert `tests/overall/overall.sspj` → example assets. | Refresh example assets |

Generated code (ffigen bindings + flatc accessors) is **committed** and never
hand-edited; each pkg's `native/` is gitignored. No `download-sdk` — `hook/build.dart`
downloads the pinned SDK release for Rust-less consumers.

## Traps (hard-won)

* **Never call `PartState.updateFlag`** — the flatc `bit_flags` enum throws on OR-combined bits; read the raw `uint64` and bitwise-AND.
* **`local_uvs`/`local_vertices` are texture-PIXEL, stride 10** (`lt,rt,lb,rb,center`), not normalized/×8 — pass straight to `drawVertices`. World matrix is column-major 4×4 (`x' = m0·x + m4·y + m12`).
* **Texture key = `cellmap.name_hash` == `DrawBatch.texture_hash`** — use the pre-baked hash; never re-implement FNV-1a on the Dart side.
* **Coordinate system = 1 (Y-Down); the Brain flips once** — do not double-flip in the Body.
* **FFI pointer lifetime** — `FrameData`/SoA are borrows valid only until the next `update`; call `get_frame_data(frame)` *before* reading SoA getters, and keep the `.ssab` buffer alive past the resource.
* **Per-kind geometry differs**: Normal & Shape verts are **local** (apply the world matrix); **Mesh & Effect verts are world/sim-space** (don't). Effect UVs are normalized 0..1 (scale back up); Mesh is CSR-sliced, Shape fixed-stride 24.
* **Instance: the Brain owns all playback; the Body owns child player + pack resolution + drawing** — `play()` on `transitioned` is mandatory, and `childFrame` must stay raw.
* **Mask has no C-API** — roles come from the static `.ssab` `PartData`, read once at load; ignore `FrameData.mask_indices`.
* **PartColor alpha is pre-folded by the Brain** — do not re-multiply `PartState.alpha` when a PartColor is present.
* **dart:ui shaders ≠ full GLSL** — the Canvas backend's runtime-effect shaders (`shaders/*.frag`) take no per-vertex varyings and `impellerc` rejects bitwise ops & `discard`; a bad one fails silently and falls back (grep test output for `impellerc failure`/`SkSL Error`; verifiable only in `examples/overall`). The **flutter_gpu** shaders (`shaders/gpu/`) are real GLSL — varyings, bitwise ops, UBOs — which is how the GPU backend batches the peeled PartColor/mask fan-out the Canvas path cannot.
* **Blend table** (`render/blend.dart`, Canvas) is ported from ssplayer-webgl; Sub/Invert approximate to `difference`, Div2/Overlay2 → `srcOver`. The flutter_gpu backend maps blends via fixed-function pipeline equations (more modes exact), falling back to `srcOver` only for Exclusion/Invert/Multiply-over-transparency.

## Verification

Build the native libs first (`bash ../../scripts/build-runtime.sh`). Tests pick up
the Brain automatically via native assets — no `SSRUNTIME_LIBRARY_PATH`/`DynamicLibrary.open`.

| Check | Command (in `packages/ssplayer_flutter/` unless noted) |
|---|---|
| Analyze | `flutter analyze lib test` |
| Unit + render tests | `flutter test` |
| L1 bindings smoke | `dart test` (in `../ssruntime_dart/`) |
| Converter smoke + CLI | `dart test` (in `../ssconverter_dart/`) |
| macOS run / embedding | (in `examples/overall/`) `flutter run -d macos` → `[ssplayer] OK`; `flutter build macos` → `ssruntime.framework` under `*.app/Contents/Frameworks/` |
| GPU backend parity (on-device) | (in `examples/overall/`) `flutter test integration_test/gpu_backend_test.dart -d macos` — needs a real Impeller device; renders each pack on Canvas + flutter_gpu and pixel-compares |
| Web (developer preview) | `bash ../../scripts/build-runtime.sh platform=web` (needs `wasm-pack`), then (in `examples/overall/`) `flutter run -d chrome` |

## Render recipe (Normal kind)

Per frame: `update(dt)` → `get_frame_data(frameNo)` → for each `kind == Normal` batch,
gather `draw_order[start_rank .. +count]`, bake 4 world-transformed corners + pixel UVs
+ white×`alpha` colors + quad indices into one indexed `ui.Vertices`, then
`drawVertices(v, BlendMode.modulate, paint)` (`paint` = `ImageShader(texture)` + framebuffer
blend) on the Canvas backend; the flutter_gpu backend bakes the same corners/UVs/colors into an
interleaved VBO, draws through its sprite pipeline into an offscreen target, then composites it
back. Sub-frame sampling ON by default.
