# SSPlayerForFlutter — AI Agent Guide

Flutter **Body** for the SpriteStudio-SDK **Brain**. This monorepo (a pub
workspace, Melos-released) implements the Player that renders `.ssab` animations
by driving the Rust `libssruntime` runtime over `dart:ffi`. The Brain lives in
the `SpriteStudio-SDK/` submodule — see its own [AGENTS.md](./SpriteStudio-SDK/AGENTS.md).

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

Examples: `examples/overall` (Basic validation), `examples/flame` and
`examples/part_following` (`SpriteStudioPartAnchor`).

**L2 render internals** (`ssplayer_flutter/lib/src/render/`): `geometry_builder.dart`
(SoA→geometry bake — `ui.Vertices` for Canvas and interleaved VBOs for GPU — plus `DrawFrame`,
Mesh/Shape buffers), `blend.dart`, `part_color.dart`, `part_shader.dart` (the built-in
`ss-*` integration-shader catalog + `SHDR` attribute reader), `mask.dart`/`mask_context.dart`,
`part_override.dart` (per-part color/cell/visibility), `part_anchor.dart`, `root_transform.dart`
(the player-level flip/offset), `effect.dart`/`instance.dart`;
the pluggable render backends in `backend/` (`render_backend.dart` abstraction + `canvas_backend.dart` /
`flutter_gpu_backend.dart` + the capability probe). Shaders live at the package root `ssplayer_flutter/shaders/`
(not under `lib/`): Canvas shaders `shaders/{partcolor,mask_write}.frag` plus `shaders/ss_*.frag` over the
shared `shaders/ss_shader_common.glsl` (dart:ui runtime-effect), and GPU shaders `shaders/gpu/*.{vert,frag}`
(real GLSL). Loaders sit one level up from `render/`, at `lib/src/texture_loader.dart` /
`lib/src/instance_loader.dart`; generated `lib/src/ssab/*.g.dart` (never hand-edit).

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
| `deploy-examples` | Convert the SDK's bundled test projects (`tests/overall/overall.sspj` and `tests/Ringo/Ringo.sspj`) → example assets. | Refresh example assets |
| `download-web-runtime` | Put the SDK release's wasm-bindgen `libssruntime` into `ssplayer_flutter/assets/runtime-web/`, flattened to the layout the loader's SIMD probe expects. | Web demo, web release |
| `build-release` | Per package: run the publish pub.dev will run, minus the upload, and lay the file set it would send out in `release-dist/`. Bumps nothing, tags nothing. | Before cutting versions |

Generated code (ffigen bindings + flatc accessors) is **committed** and never
hand-edited; each pkg's `native/` is gitignored. No `download-sdk` — `hook/build.dart`
downloads the pinned SDK release for Rust-less consumers.

## Traps (hard-won)

* **Never call `PartState.updateFlag`** — the flatc `bit_flags` enum throws on OR-combined bits; read the raw `uint64` and bitwise-AND.
* **The flatc write side is not in `lib/`** — `*Builder`/`*ObjectBuilder` are split into `ssplayer_flutter/test/support/*_builders.g.dart` (~2/3 of flatc's output; nothing in `lib/` ever writes a buffer). Those shims re-export their reader library, so a test that needs to synthesise a fixture imports `support/<schema>_builders.g.dart` under the usual prefix. Every schema gets one, `ssqb` included — its shim is unused until sequence playback lands, but it means adding `.ssqb` support needs no codegen change.
* **`local_uvs`/`local_vertices` are texture-PIXEL, stride 10** (`lt,rt,lb,rb,center`), not normalized/×8 — pass straight to `drawVertices`. World matrix is column-major 4×4 (`x' = m0·x + m4·y + m12`).
* **Texture key = `cellmap.name_hash` == `DrawBatch.texture_hash`** — use the pre-baked hash; never re-implement FNV-1a on the Dart side.
* **`texture_hash` spans TWO hash spaces, so the loader loads both tables** — a `DrawBatch` binds either `cellmaps()[].name_hash` (`fnv1a("common")`) or, on the frames a TextureChange (`TCHG`) fires, `external_textures()[].name_hash` (`fnv1a("common.png")`, the file name). `SsTextureLoader` loads `cellmaps()` (required — a missing one is reported) *and* `external_textures()` (silent best-effort — the converter fills it with a superset, so a miss is not a load error), each under its own hash, into the one shared `TextureRegistry`. Miss the second table and TCHG frames — and any runtime replacement of a TCHG target — draw nothing.
* **Runtime texture replacement lives in `TextureRegistry`, keyed by `texture_hash`, and is NOT the §65 Override Layer** — `SpriteStudioPlayer.setCellmapTexture(name, image?)` (ForGodot's `set_cellmap_texture`) sets/clears a per-hash override the registry returns in place of the loaded original; the draw loop already binds by hash, so it "just draws". Three things the siblings' memo does not: (1) **restore keeps the original** rather than reloading from path — Flutter holds the decoded `ui.Image`, so `image: null` is an instant, infallible fallback, and the override image is the **caller's** (borrowed, never disposed by the registry). (2) **The registry is shared across the whole instance tree**, so an override reaches every part sampling that hash — root and instance child alike — the *opposite* of ForGodot's per-player `_textures` (memo §5-1); this is a consequence of the shared-atlas design, not a bug. (3) **The GPU backend caches uploads by hash**, so `setCellmapTexture` calls `RenderBackend.invalidateTexture` (no-op on Canvas, which reads the registry every draw) and the swap carries a per-hash upload generation so an in-flight upload of the old bitmap cannot land stale. A swap retires the old `ImageShader`, disposed at the next frame's `TextureRegistry.flushRetired` (called once per top-level frame in `paint`), never on the spot — a picture recorded before the swap may still read it. To replace what a TCHG shows, target the external-texture name (`common.png`), not the cellmap (`common`). Tests: `test/texture_replace_test.dart`.
* **Coordinate system = 1 (Y-Down); the Brain flips once** — do not double-flip in the Body.
* **FFI pointer lifetime** — `FrameData`/SoA are borrows valid only until the next `update`; call `get_frame_data(frame)` *before* reading SoA getters, and keep the `.ssab` buffer alive past the resource.
* **Per-kind geometry differs**: Normal & Shape verts are **local** (apply the world matrix); **Mesh & Effect verts are world/sim-space** (don't). Effect UVs are normalized 0..1 (scale back up); Mesh is CSR-sliced, Shape fixed-stride 24.
* **Instance: the Brain owns all playback; the Body owns child player + pack resolution + drawing** — `play()` on `transitioned` is mandatory, and `childFrame` must stay raw.
* **An instance part's ALPHA crosses into its child; its COLOUR does not** — the family's rule, not a shortcut: ForGodot modulates the child with `Color(1, 1, 1, part_alpha)`, ForWGPU states it outright ("no player propagates an instance part's tint"), the SDK's PartColor part-type table (§1-2) stops at Normal / Mesh / Shape, and the Editor renders such a subtree untinted. This Body used to tint it with `wholeTintMatrix` through a `saveLayer` (Canvas) / sub-texture (GPU), which was wrong twice: the tint does not belong (an Animate import carrying `mul #262626` played at 15% brightness), and isolating the subtree to apply it broke every framebuffer blend inside — an `add` child composited against the empty layer, turning a glow into an opaque dark blob. `RenderBackend` deliberately has no group-tint hook any more; **a tint that needs isolation is the shape of the bug, not of the feature**.
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
* **Canvas Sub/Invert are multi-pass, not approximations** — no stock mode is a reverse-subtract or a dst-replace, so `blendPassesFor` rebuilds them exactly from 3 stock passes over the *same* geometry (`difference`-with-white **is** a dst inversion, and inverting twice cancels): Sub = invert → `plus` → invert; Invert = invert → `modulate` → `dstOver` black (restores the alpha `modulate` scaled down). Two hard rules: **one part per plan** (peel them out of the batched run — two overlapping parts would invert their overlap twice) and **same geometry every pass**. **Exact only over an OPAQUE backdrop, which is rarer than it sounds** — the invert pass draws saturated opaque white (`_coverageFilter`) over the part's whole footprint, so it destroys the destination's alpha, and only Invert's plan restores one. Over a transparent or translucent destination the rgb still matches but **alpha comes back as 1 across every texel the art covers, however faint**: a soft Sub shadow renders as a hard opaque silhouette of its own artwork. `examples/overall` hits this (the `InteractiveViewer` + `clipBehavior` above the view puts the animation in a fresh, transparent layer), so it is the normal case in the demo, not a corner. Measured against the GPU backend, which sets the real GL state and is right here: of the 10459 pixels a `sub` part touched, Canvas made 10020 fully opaque and flutter_gpu 692. No fix is planned — recovering the overwritten `dst.a` needs a layer, and a layer isolates the subtree, which is the bug removing the instance group tint just fixed. `SS_BACKEND=gpu` is the workaround.

## Documentation site

Built with [Zensical](https://zensical.org), the successor to MkDocs + Material for MkDocs. Zensical has no multi-locale build, so **each locale is built from its own config**: `mkdocs.yml` builds `docs/en` to `site/`, `mkdocs.ja.yml` builds `docs/ja` to `site/ja/`, and both inherit the shared settings from `mkdocs.base.yml`. Every page still exists as both `docs/en/<path>` and `docs/ja/<path>`; there is no fallback locale any more, so a page missing from one side is a nav entry pointing at nothing.

**The three-config split has one rule: a YAML sequence must be defined in exactly one of the three files.** Zensical's `INHERIT` *concatenates* parent and child sequences where MkDocs replaces them — put `nav` in the base as well as a locale config and the Japanese site renders the English navigation followed by the Japanese one. Shared sequences (`theme.palette`, `theme.features`, `plugins`, `markdown_extensions`, `extra.alternate`) live in `mkdocs.base.yml` and nowhere else; `nav` and `extra.social` live in the locale configs and never in the base.

Things that do **not** follow the "everything twice" rule, or that changed with the migration — check before duplicating:

*   **`overrides/main.html`** (`theme.custom_dir`) emits the Open Graph / Twitter Card tags the theme omits, **and repairs the page title**: Zensical never sets `page.is_homepage`, which its own `base.html` branches on, so the landing page would title itself "SpriteStudioPlayer for Flutter - SpriteStudioPlayer for Flutter". The override derives the flag from `page.url` and overrides the `htmltitle` block. **One template serves both locales** — everything is read from whichever locale config is building. Localize by adding a per-locale config override, never by branching in the template. Keep it in sync with the copies in SpriteStudio-Docs and the sibling player repos.
*   **`overrides/partials/alternate.html`** rebuilds the header language selector so switching language keeps you on the same page. `mkdocs-static-i18n` used to rewrite those links per page; nothing does once the locales are separate builds, and the stock partial would send every reader to the other locale's home page. Driven by `extra.alternate[].link` (a locale subpath, not a URL) plus `extra.site_root_prefix` in each locale config. Known gap: the `<link rel="alternate" hreflang>` tags in `<head>` still point at each locale root — they sit inside the theme's `site_meta` block, and overriding that would mean copying thirty lines Zensical may change.
*   **`site_url` is per locale** and the ja one keeps its `ja/` suffix — `page.canonical_url`, and therefore `og:url`, is built from it.
*   **Footer social icons are defined twice** — in `mkdocs.yml` and `mkdocs.ja.yml` (translated labels, same icons and links). Add or reorder an icon in both, or the two footers diverge. Keep `twitter:site` in `overrides/main.html` in sync with the X link.
*   **There is deliberately no `edit_uri`**, so no "edit this page" button renders. It is a branch name nothing validates, and it had drifted wrong in three of the five player repos. Do not reintroduce it.

`mkdocs.base.yml` sets `strict: true`, so a plain `build` fails on a broken link. `serve` validates nothing — `zensical serve --strict` is accepted and currently does nothing. Nothing builds the docs on a pull request either — `pages.yml` runs on `release: published` and dispatch — so the local build is the only gate, and **both locales have to be built**, English first because it clears `site/`, which contains `site/ja`:

```bash
scripts/prepare-docs.sh          # once: .venv + the pins in docs/requirements.txt
scripts/build-docs.sh            # the gate: English then Japanese, both --strict
```

`scripts/*.ps1` are the PowerShell twins, and both take `key=value` options and `--help` like the other scripts here (`build-docs.sh locale=ja`, `prepare-docs.sh force=yes`). They wrap nothing more than `pip install -r docs/requirements.txt` and the two `zensical build` runs, in the order that works — `zensical` straight out of `.venv` still does the same thing. Every repository in the family spells this pair the same way, and the `-docs` suffix keeps it apart from the scripts that build the code.

`scripts/build-pages.sh` is the whole published site: the pair above, then **both Web demos** — `examples/overall` at `site/demo/flutter/` and `examples/flame` at `site/demo/flame/`, with a chooser page at `site/demo/` — then, with `serve=yes`, the tree over HTTP. `pages.yml`'s build job **is** this script (`prepare=no docs=yes demo=build sdk=download base=/<repo>/ serve=no`, every option spelled out so a publish cannot change because a default did), so CI and the local build cannot drift. Only the deploy job has no local equivalent.

```bash
scripts/build-pages.sh serve=yes            # docs + both demos -> http://localhost:8000/SSPlayerForFlutter/
scripts/build-pages.sh sdk=build            # ... with the Brain compiled from the submodule
scripts/build-pages.sh demo=skip            # documentation only
```

Four things about the demo half, none of them guessable from the tree:

*   **The demos are built here, not downloaded.** `release.yml` versions packages and publishes to pub.dev; it creates no GitHub Release, so there is no asset for a `demo=download` to fetch (the sibling players' pattern does not apply). `sdk=` is the separate question of where the *Brain* comes from: `download` (the default, and what CI uses) takes the web wasm from the SpriteStudio-SDK release `packages/*/hook/build.dart` pin, and lets those hooks fetch the host libraries from the same release — **no Rust toolchain anywhere**. `sdk=build` compiles both with `build-runtime.sh` and is the way out while that release does not exist yet.
*   **`base=` is baked in.** `flutter build web --base-href` is fixed at build time, so a demo built for one path 404s on another. It defaults to `/<repo>/`; `serve=yes` therefore hangs `site/` off `.pages-preview/<repo>` and serves *that*, which is the only way to open the demo at the address it was built for.
*   **The examples' `web/` runners are git-ignored** ("generated per-clone", like `android/` and `ios/`), so the script runs `flutter create --platforms=web .` when one is missing — and puts `.metadata` back, because `flutter create` *replaces* its platform list rather than appending to it.
*   **`deploy-examples.sh` runs every time.** The `.ssab` both demos play are generated and git-ignored; a stale pack is exactly the kind of thing nobody notices in a published demo.

A second copy of the site goes up **by hand to Cloudflare Pages**, whose dashboard takes an upload rather than a git push. That host serves a project at its own root, so it needs a different build from the GitHub Pages one — `--base-href` cannot be both:

```bash
scripts/build-pages.sh base=/ zip=yes    # -> SSPlayerForFlutter-site.zip, drag that in
```

`zip=yes` packs `site/` with its contents at the archive root (a wrapping folder would become a wrapping path segment and 404 every page), and says so loudly if you pack a tree built for a subpath. **GitHub Pages stays canonical**: the absolute URLs in `README.md` / `README.ja.md` point there, and they are absolute only because GitHub and pub.dev render those files outside the site. **Every demo link inside `docs/` is relative** (`demo/`, `../demo/`, `../../demo/flame/`), which is what lets the same documentation build serve correctly from both hosts.

Building only English is the easy mistake: it leaves a stale `site/ja` behind, so a Japanese page you just broke still looks fine.

No page here uses `> [!NOTE]` callouts, but `pymdownx.quotes` keeps them working. If you start: a list inside one needs a blank `>` line before it, and `[!IMPORTANT]` renders unstyled until you copy the `docs/*/stylesheets/extra.css` the sibling player repos carry. Also **avoid `src="…"` / `href="…"` inside an inline code span** — Zensical rewrites paths there as if they were real links, corrupting the example. Use a fenced block, which it leaves alone.

## Releasing

There is **no GitHub Release and no asset** — the sibling players' `build-release` builds one archive and attaches it; here the release *is* six pub.dev publishes. `release.yml` (manual dispatch) runs `melos version --no-private`, which computes an **independent** SemVer bump per package from Conventional Commits, writes the CHANGELOGs, commits and pushes `<package>-v<version>` tags; each tag triggers `publish.yml`, which hands that package to dart-lang's reusable publish workflow (pub.dev OIDC, no stored secret). `publish_to: none` in a package's pubspec is the on/off switch for the whole chain — Melos skips it and `dart pub publish` refuses it.

The order is what makes a preflight necessary: **the tags are pushed before pub.dev ever sees a package**, and a version there is permanent. A package pub rejects at publish time has already cost a version number and a CHANGELOG commit. `scripts/build-release.sh` is that preflight and it is `release.yml`'s first job (`checks=analyze codegen=skip sdk=download`, every option spelled out), so CI and a working tree run the same thing.

```bash
scripts/build-release.sh                     # every package, analyze + tests + dry-run publish
scripts/build-release.sh checks=skip sdk=skip   # just the archives, offline
scripts/build-release.sh packages=ssruntime_dart
```

Four things about it that the tree does not show:

*   **A private package is previewed, not skipped.** With `publish_to: none` still on all six, skipping them would leave the script nothing to do, so it lifts the line for the length of the dry run (restoring it however the script exits, from a backup kept *outside* the package — pub publishes untracked files too, so a `pubspec.yaml.bak` beside the original would land in the archive). Everything that would block the publish is printed; none of it fails the run. Delete the line and that package is checked for real.
*   **`dart pub publish` treats warnings as fatal** — only `--ignore-warnings` changes that, and neither `-f` nor the reusable workflow passes it. `LICENSE.md` instead of `LICENSE`, or a missing `CHANGELOG.md`, is enough to abort a publish.
*   **The pinned SDK release has to exist.** `packages/*/hook/build.dart` download `libssruntime` / `libssconverter` from `_sdkVersion`'s release for every consumer without a Rust toolchain, which is all of them; the two hooks must also name the *same* release. `sdk=check` is what fails while the SDK has not been tagged, and that failure is correct — there is nothing to publish against.
*   **The web Brain is git-ignored build output that has to ship**, and getting it published takes two things that are easy to break separately. `assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm,ssruntime_bg.nosimd.wasm}` are what `ssruntime_dart`'s `web_runtime.dart` loads by name, and pub publishes nothing git ignores — hence `assets/runtime-web/.pubignore`, which pub reads *instead of* the `.gitignore` in that directory (the lone `!ssruntime.js` is for the repo-root `*.js` rule, which a `.pubignore` there does not replace). But pub can only pack what is on disk, and dart-lang's reusable publish workflow takes `environment` and `working-directory` and nothing else — **there is no step between its checkout and its `dart pub publish`**. So `publish.yml`'s **`ssplayer_flutter` job is hand-rolled**: that workflow's steps, verbatim, with `scripts/download-web-runtime.sh` inserted before the dry run. The other five stay on the reusable workflow. `build-release sdk=download` runs the same script, so the archive it checks is the one that job uploads — and if the fetch step ever disappears from `publish.yml`, `verify` says so rather than letting a complete-looking archive hide an empty `assets/runtime-web/` on pub.dev.

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
