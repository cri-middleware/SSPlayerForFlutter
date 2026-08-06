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
Mesh/Shape buffers), `blend.dart`, `part_color.dart`, `part_shader.dart` (the built-in
`ss-*` integration-shader catalog + `SHDR` attribute reader), `mask.dart`/`mask_context.dart`,
`part_override.dart` (per-part color/cell/visibility), `part_anchor.dart`, `root_transform.dart`
(the player-level flip/offset), `effect.dart`/`instance.dart`;
the pluggable render backends in `backend/` (`render_backend.dart` abstraction + `canvas_backend.dart` /
`flutter_gpu_backend.dart` + the capability probe); Canvas shaders `shaders/{partcolor,mask_write}.frag`
plus `shaders/ss_*.frag` over the shared `shaders/ss_shader_common.glsl`
(dart:ui runtime-effect) and GPU shaders `shaders/gpu/*.{vert,frag}` (real GLSL); loaders
`texture_loader.dart`/`instance_loader.dart`; generated `lib/src/ssab/*.g.dart` (never hand-edit).

**Integration shaders (`SHDR`)**: a per-part attribute, not a draw kind — the Brain
does not split batches by it, so the Body peels shader parts out of ordinary Normal
batches exactly as it peels PartColor ones. All 13 built-in `ss-*` effects ship on
both backends; every one but `ss-blur` folds the PartColor formula as its output
tail. Deliberately out of scope (matching both siblings' v1): `map0`/`map1` extra
textures, shader × mask combined (a masked part drops its shader), and shader parts
on Mesh/Shape/Effect kinds. Canvas uses **one program per effect** (a runtime effect
impellerc rejects fails *silently*, so one bad shader must not blank the rest); the
GPU backend uses **one pipeline branching on an id** (a bad shader fails the bundle
build loudly, and the parts draw individually anyway).

## Toolchain scripts (`scripts/`, `.sh`+`.ps1`; SDK via `$SSSDK` else `./SpriteStudio-SDK`)

| Script | Does | When |
|---|---|---|
| `build-runtime` | Build `ssruntime`/`ssconverter`; place bare dylibs into each binding pkg's `native/libs/…` + copy C headers to `native/include/`. Does **not** run ffigen. | After Rust / first setup |
| `generate-ffigen-code` | `dart run ffigen` → each pkg's `lib/src/*_bindings.g.dart`. Standalone; commit result. | After a C-API change |
| `generate-fbs-code` | `flatc --dart` → `lib/src/ssab/*.g.dart`, then `strip_fbs_builders.dart` splits the write side out of `lib/`. Standalone. | After a `.fbs` change |
| `deploy-examples` | Convert `tests/overall/overall.sspj` → example assets. | Refresh example assets |

Generated code (ffigen bindings + flatc accessors) is **committed** and never
hand-edited; each pkg's `native/` is gitignored. No `download-sdk` — `hook/build.dart`
downloads the pinned SDK release for Rust-less consumers.

## Traps (hard-won)

* **Never call `PartState.updateFlag`** — the flatc `bit_flags` enum throws on OR-combined bits; read the raw `uint64` and bitwise-AND.
* **The flatc write side is not in `lib/`** — `*Builder`/`*ObjectBuilder` are split into `ssplayer_flutter/test/support/*_builders.g.dart` (~2/3 of flatc's output; nothing in `lib/` ever writes a buffer). Those shims re-export their reader library, so a test that needs to synthesise a fixture imports `support/<schema>_builders.g.dart` under the usual prefix. Every schema gets one, `ssqb` included — its shim is unused until sequence playback lands, but it means adding `.ssqb` support needs no codegen change.
* **`local_uvs`/`local_vertices` are texture-PIXEL, stride 10** (`lt,rt,lb,rb,center`), not normalized/×8 — pass straight to `drawVertices`. World matrix is column-major 4×4 (`x' = m0·x + m4·y + m12`).
* **Texture key = `cellmap.name_hash` == `DrawBatch.texture_hash`** — use the pre-baked hash; never re-implement FNV-1a on the Dart side.
* **Coordinate system = 1 (Y-Down); the Brain flips once** — do not double-flip in the Body.
* **FFI pointer lifetime** — `FrameData`/SoA are borrows valid only until the next `update`; call `get_frame_data(frame)` *before* reading SoA getters, and keep the `.ssab` buffer alive past the resource.
* **Per-kind geometry differs**: Normal & Shape verts are **local** (apply the world matrix); **Mesh & Effect verts are world/sim-space** (don't). Effect UVs are normalized 0..1 (scale back up); Mesh is CSR-sliced, Shape fixed-stride 24.
* **Instance: the Brain owns all playback; the Body owns child player + pack resolution + drawing** — `play()` on `transitioned` is mandatory, and `childFrame` must stay raw.
* **Flip/offset live in `SsRootTransform`, and BOTH consumers must read it** — the backends' `beginFrame`
  (Canvas: on top of the centring translate; GPU: folded into the ortho) *and* `partWorldMatrix`. Put it in
  the geometry bake alone and every `SpriteStudioPartAnchor` detaches the moment a player flips. Keeping it
  at the root also leaves the whole tree below in player-local space, which is why the mask coverage pass
  and the runtime-effect shaders need no changes. Instance children inherit it (they never `beginFrame`).
* **A world matrix can be a reflection, and the sign is a PRODUCT** — authored negative scale (Ringo: 8 of
  69 parts) × the player's flip, so the two cancel. Never infer it from the flip settings; read
  `determinant()`. This port carries mirrors losslessly because it never decomposes (`Transform` takes the
  whole `Matrix4`) — the siblings' quaternion/`Transform2D` caveats simply do not arise. See the SDK's
  `libs/ssruntime/docs/30_core/30_render_loop.md`.
* **Mask has no C-API** — roles come from the static `.ssab` `PartData`, read once at load; ignore `FrameData.mask_indices`.
* **PartColor alpha is pre-folded by the Brain** — do not re-multiply `PartState.alpha` when a PartColor is present.
* **dart:ui shaders ≠ full GLSL** — the Canvas backend's runtime-effect shaders (`shaders/*.frag`) take no per-vertex varyings and `impellerc` rejects bitwise ops & `discard`; a bad one fails silently and falls back (grep test output for `impellerc failure`/`SkSL Error`; verifiable only in `examples/overall`). The **flutter_gpu** shaders (`shaders/gpu/`) are real GLSL — varyings, bitwise ops, UBOs — which is how the GPU backend batches the peeled PartColor/mask fan-out the Canvas path cannot.
* **A local `#include` in a Canvas `.frag` works** — the Flutter shader build passes the shader's own directory to impellerc, so `shaders/ss_*.frag` share `ss_shader_common.glsl`. It also **keeps declared-but-unused uniforms in their slots**, which is why all 13 can share one uniform block and one Dart writer even though most never read `uCellRect`. `test/part_shader_test.dart` pins the float count (48) per program — that test failing is how a rejected shader or a block edit surfaces.
* **`ss-blur` skips the PartColor fold** and **shader × mask is not combined** (a masked part drops its shader) — both deliberate, both matching the Web/Godot ports.
* **Blend table**: the ground truth is ssplayer-webgl's `applyBlend` — every SS mode is a fixed-function GL state, and **only RGB varies; alpha is premultiplied source-over for all of them** (`ONE, ONE_MINUS_SRC_ALPHA`, ADD). Break that and a Sub/Mul part *erases* what's under it instead of darkening it. The flutter_gpu backend (`blendEquationFor`) reproduces **every** row exactly — no fallbacks. Canvas maps to stock `ui.BlendMode` (`blendModeFor`), exact for Mix/Add/Screen/Exclusion (any backdrop alpha) and Mul (opaque backdrop only). Div2/Overlay2 → Mix on both, as upstream. Effect blend is a separate byte whose additive row is `(ONE, ONE, ONE, ONE)` — alpha adds too, unlike batch Add. Tests: `test/blend_pixel_test.dart` (Canvas pixels vs the GL formula), `test/gpu_blend_test.dart` (the GPU table).
* **Canvas Sub/Invert are multi-pass, not approximations** — no stock mode is a reverse-subtract or a dst-replace, so `blendPassesFor` rebuilds them exactly from 3 stock passes over the *same* geometry (`difference`-with-white **is** a dst inversion, and inverting twice cancels): Sub = invert → `plus` → invert; Invert = invert → `modulate` → `dstOver` black (restores the alpha `modulate` scaled down). Two hard rules: **one part per plan** (peel them out of the batched run — two overlapping parts would invert their overlap twice) and **same geometry every pass**. Exact over an opaque backdrop; over transparency the rgb still matches but alpha is forced to 1.

## Documentation site

Folder-based i18n (`mkdocs-static-i18n`, `docs_structure: folder`): every page exists as both `docs/en/<path>` and `docs/ja/<path>`, and `nav` is defined once in `mkdocs.yml` with Japanese labels from `nav_translations`. Three things do **not** follow that "everything twice" rule — check before duplicating:

*   **`overrides/main.html`** (`theme.custom_dir`) emits the Open Graph / Twitter Card tags Material omits. **One template serves both locales**: the i18n plugin substitutes `languages.ja.site_description` before rendering, so Japanese cards need no second copy. Localize by adding a per-locale config override, never by branching in the template. Keep it in sync with the copies in SpriteStudio-Docs and the sibling player repos.
*   **Footer social icons are defined twice** — `extra.social` and the `ja` block's `extra` override, which *replaces* the whole `social` list rather than merging into it. Add or reorder an icon in both, or Japanese readers lose it. Keep `twitter:site` in `overrides/main.html` in sync with the X link.
*   **There is deliberately no `edit_uri`**, so no "edit this page" button renders. It is a branch name nothing validates, and it had drifted wrong in three of the five player repos. Do not reintroduce it.

`mkdocs.yml` sets `strict: true`, so a plain `build` (and `serve`) fails on a broken link or nav mismatch. Nothing builds the docs on a pull request — `pages.yml` runs on `release: published` and dispatch — so the local build is the only gate: `.venv/bin/mkdocs build --strict`.

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
