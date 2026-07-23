# SpriteStudioPlayer for Flutter — Player Roadmap

This is the **Flutter Player** roadmap for SSPlayerForFlutter. It tracks the
Flutter-specific implementation tasks for capabilities exposed by the **Rust
runtime/converter** (`SpriteStudio-SDK/ROADMAP.md`). The draw kinds already
shipped (Normal / PartColor / Mask / Mesh / Effect / Instance / Shape) and the
code-verified kind × cross-cutting consistency matrix live in
[`docs/architecture.ja.md` §11-A](./docs/architecture.ja.md); this file tracks
forward-looking work only.

Most items selectively bring worthwhile capabilities from the legacy SS6 players
into this SS7-based Flutter player — reimagined for SS7 and Flutter's
immediate-mode canvas, not ported verbatim.

## Design principle — Flutter-native, 4-layer

The Body is a strict 4-layer downward dependency: **L4** drawing adapters
(`SpriteStudioView`) → **L3** `SpriteStudioPlayer` (transport / events) → **L2**
`SpriteStudioInternalPlayer` (FFI lifecycle, SoA→`ui.Vertices` bake, `paint`) →
**L1** ffigen `@Native` bindings (`ssruntime_dart`). Keep L2 Widget-free so it
stays reusable headless / from Flame / flutter_gpu.

- **Immediate-mode canvas:** the Brain emits a `DrawBatch` plan; the Body executes
  it as `Canvas.drawVertices` per batch. There is no retained scene graph —
  everything is rebuilt per frame, so **per-frame allocation and draw-call count
  are the levers** (see [Performance](#performance)).
- **Native assets, not plugins:** the runtime reaches the app through Dart build
  hooks (`ssruntime_dart/hook/build.dart`), never CocoaPods.
- **Naming and style:** follow Dart conventions and the existing null-safety /
  `dispose` discipline in touched files.

## Status legend

- ☐ **Ready** — Player-only, no SDK dependency; can start now
- ⛔ **Blocked on SDK** — needs an `SpriteStudio-SDK/ROADMAP.md` phase first (phase noted)
- 🕒 **Deferred ("あとで")** — intentionally postponed; detailed here so it can be picked up later

---

## Performance

The batching itself is **correct**: the Body honours the Brain's `DrawBatch`
grouping — one `Canvas.drawVertices` per Normal/Mesh/Shape batch — and adjacent
batches cannot be merged further without breaking z-order. So the levers are
(a) the per-frame allocation/copy done to *build* each batch and (b) the
draw-call count of *peeled* shader parts.

### ✅ Done — branch `perf/render-allocation-hygiene`

| Optimization | What | Commit |
|---|---|---|
| Vertex-bake copies | `GeometryBuilder` returns zero-copy typed-list views instead of `sublist` (which copied the whole buffer again on top of the copy `ui.Vertices.raw` already makes). Saves 4 array copies/batch for Normal, 4 for Mesh, 3 for Shape. | `9f1edb2` |
| Scratch reuse | Bake into grow-only scratch buffers reused across bakes, so a steady-state frame does no per-batch vertex allocation. The returned `MeshGeometry` aliases the scratch and must be consumed before the next bake (documented; every call site already does). | `9f1edb2` |
| `DrawFrame.partByIndex` | Per-frame `HashMap<int, PartState>` → dense `List<PartState?>` indexed by part index (no hashing, one contiguous alloc, bounds-checked `partOf`). | `9f1edb2` |
| Effect command merge | Consecutive same-cellmap+blend `EffectDrawCommand`s merge into one `drawVertices` (`buildEffectGroup` rebases per-command indices; each group capped to the 16-bit vertex limit; draw order preserved). | `460fcbb` |
| Batch paint reuse | One `ui.Paint` reused across the Normal/Mesh batch draws — `Canvas.drawVertices` snapshots the paint's state at the call, so a single mutable instance is safe. | `460fcbb` |
| Single-pass SoA select | Decide `hasMesh` / `hasShapeGeom` in one pass over the batch plan instead of two `batches.any` scans. | `460fcbb` |
| `parts_color` fetched once | `PartColor.read` no longer re-fetches `frameData.partsColor` per part; the lazy `_FbGenericList` backing-cache churn drops from O(pcParts × total) to O(total) (cached on `DrawFrame.partsColor`). | `2c5e2dd` |

### ☐ Backlog

- ☐ **PartColor struct direct-read (`ByteData`)** — the Unity (`MemoryMarshal.Cast`),
  RenPy and Web siblings all read the packed `PartAttributePartColor` struct
  directly to avoid per-access FlatBuffers wrapper objects. The Dart analogue
  navigates the `FrameData` bytes by wire format (root `derefObject(0)` → vtable
  slot 8 → vector → element base `dataStart + idx*36`) and reads fields straight
  from `ByteData`: `blendType` u8 `@+0`; corners `lt@+4 / rt@+12 / lb@+20 / rb@+28`;
  each corner = `U8Rect` (`A,R,G,B` u8 `@+0..3`) + `rate` f32 `@+4`. **Feasibility
  verified**: `BufferContext.buffer` is public and the offsets/stride are confirmed
  against `flat_buffers 25.9.23` + the generated readers.
  - **Effect**: removes ~9 throwaway wrappers per PartColored part per frame
    (1 struct + 4 corner + 4 `U8Rect`). But the shipped "*`parts_color` fetched
    once*" item already reclaimed the **dominant** O(pcParts × total) backing-cache
    churn, so the residual win here is **small-to-modest**. PartColor's real
    bottleneck is the peeled draw-call fan-out below, which this does NOT touch.
  - **Guardrails before starting**: (1) micro-benchmark the extraction (wrapper
    path vs direct-read) for a hard µs number; (2) an **equivalence test is
    mandatory** — build a struct via the `ObjectBuilder`, assert direct-read ==
    the generated accessor for every field, so it fails loudly if flatc ever
    changes the layout. The vtable slot (8) and 36-byte stride become hardcoded
    constants — the same coupling the generated code already has, accepted
    consciously.
- 🕒 **Peeled PartColor / mask draw-call fan-out** — the biggest lever, but
  **structurally blocked by Flutter's shader model**. Each peeled part is its own
  `drawPath` + `FragmentShader` (~40 `setFloat` uniforms + 2 `setImageSampler`).
  Flutter fragment shaders take **no per-vertex varyings**, so `drawVertices`
  cannot feed a shader and one-part-one-draw is unavoidable. Reducing it needs a
  different path — folding the PartColor compositing formula to per-vertex colours
  on the CPU, or a `flutter_gpu` backend (see the wgpu item below for the
  ecosystem parallel).
- ☐ **Instance child `Resource` sharing** — currently one instance part = one
  `Resource`. The `Context` must stay per-child (its own clock), but the
  `Resource` (the parsed `.ssab`) should be shareable across children of the same
  pack. Related to the SDK Phase 3 **shared resource registry** (below), but a
  Body-local dedup is possible sooner. See the Instance row in
  [`docs/architecture.ja.md` §8](./docs/architecture.ja.md).
- ☐ **Quad mask-writer anti-aliasing** (low priority) — coverage is a *number*, not
  a picture, so an AA'd writer edge can decode as another writer's bits. Shape/Mesh
  writers already draw with `isAntiAlias = false`; the existing quad-writer path
  (`drawPath` + shader) still uses Paint's default AA and should be turned off for
  the same reason. Real-world impact is bounded to a 1px edge. See
  [`docs/architecture.ja.md` §11-A](./docs/architecture.ja.md) "既知の不整合".

---

## ☐ Player-only features (no SDK dependency)

- ☑ **UserData / Signal / Audio events** — decode the timeline events the Brain
  reports (`ss_runtime_get_passed_event_*`) into plain Dart and dispatch them
  per-event on L3 as `onUserData` / `onSignal` / `onAudio` (design §6C, matching
  the Godot/Unity `user_data` / `signal` / `audio` callbacks). The raw
  `onEvents(indices)` escape hatch stays. Decode lives in
  `SsAnimeInfo.decodePassedEvents`, keyed by the current animation (the indices
  are relative to *its* `events()`). Audio is trigger-only — the player hands you
  the sound to play and never produces sound itself. Frame-skip and sub-frame are
  the Brain's job: `update` enumerates every integer frame crossed (skip is
  default-on) and collects each frame's events, so a large step delivers all
  skipped-frame events in one poll and sub-frame sampling never double-fires — the
  Body just polls the batch once and dispatches each. Not yet covered: events on
  Instance *children* (only the root context is polled) and the `set_frame_no`
  seek gap (§18). Tests: `test/event_test.dart` (pure decode incl. the Signal
  param union), `test/event_e2e_test.dart` (real `UserData.ssab` / `Signal.ssab` /
  `Sound.ssab`), `test/event_frameskip_test.dart` (frame-skip batching + sub-frame
  single-fire). Demoed in `examples/overall` (the `UserData` / `Signal` / `Sound`
  packs show the latest event).
- ☐ **Label / frame-range / index playback** — play a named label range, a
  start-offset, or by animation index. Labels already ship in the `.ssab`
  FlatBuffers payload, so no SDK change is needed; add `play_range` / `play_by_index`
  on L3.
- ☑ **Flame renderer adapter** — shipped as the `ssplayer_flame` package: a
  `SpriteStudioComponent` (L4 sibling to `SpriteStudioView`) drives an
  externally-clocked `SpriteStudioPlayer` from Flame's game loop and draws the
  same L2 batches. Kept a separate package so the core player never pulls in
  Flame. Demo: `examples/flame`.
- ☐ **`Nines` / `Text` kinds + BoxFit / alignment** — the remaining Phase-2 draw
  kinds and fitting the animation's design bounds into the destination box. Shape
  and the other kinds already ship; see the kind matrix in
  [`docs/architecture.ja.md` §11-A](./docs/architecture.ja.md).
- ☑ **Mesh PartColor / mask-target** and **Instance-part own PartColor** — the last
  cross-cutting gaps in the kind matrix
  ([`docs/architecture.ja.md` §11-A](./docs/architecture.ja.md)), now closed on
  **both** backends. The no-varyings constraint turned out not to bind: a
  *whole-only* tint (§10's Mesh rule) is one affine on rgb, so Canvas applies it
  as a `ui.ColorFilter.matrix` on the draw's own paint (no shader, no peel) and
  flutter_gpu reuses the existing PartColor pipeline unchanged — the mesh bake
  tags every vertex `st=(0,0)`, which resolves the four-corner mix to `lt`. Mesh
  mask targets gate via `BlendMode.dstIn` over a layer (Canvas) / the pipeline's
  `v_local` mask replay (GPU). Instance-part PartColor — outside the SDK spec's
  part-type table, and unimplemented in the Godot flagship, but real data since
  the runtime emits `part_color` for any part carrying the attribute — applies as
  a **group tint** over the child subtree (`saveLayer` + `ColorFilter` / an
  offscreen pass + the new `colormatrix` pipeline), deliberately asymmetric with
  α, which keeps folding per-part.
  - **Caveat — no asset exercises the tint.** Not one pack in `examples/overall`,
    nor the SDK's own `allAttributeV7/partsColor.ssae`, puts a PartColor on a Mesh
    or Instance part (all Normal), and the Override Layer is Normal-only, so it
    cannot be synthesised at runtime either. The whole-tint formula is unit-tested
    against the shader's own maths, and the **Canvas** mesh-mask path is covered
    by the parity suite (`Mask.ssab` has masked mesh parts) — but note that suite
    runs Canvas-vs-Canvas (see the flutter_gpu item below: Impeller is not enabled,
    so the GPU half never executes). The *tint itself* has never been seen on
    screen on either backend. **Author a `.sspj` with a PartColored mesh + instance
    part** — and validate on a real Impeller+FlutterGPU target — to close this out.

## ☐/⛔ SDK-integration features

- ☑ **Per-part runtime overrides (color / cell / visibility)** — shipped
  (`dad4d22`): the SDK **Override Layer API** (§65) wrapped in L2 behind a
  part-name → index resolver and exposed on L3 as
  `setPartColorOverride` / `setPartCellOverride` / `setPartVisibilityOverride`
  (plus `…ByName`, a four-corner colour form, and the matching `clear…`),
  matching the Unity/Web sibling surface. **Normal parts only** — the Brain
  ignores the override for other part types at its own seam, which is why an
  override cannot stand in for authored Mesh/Instance PartColor data (see the
  caveat below).
- ⛔ **Dynamic instance animation swap** — replace the animation mounted on an
  Instance part at runtime. Blocked on the SDK Phase 3 **Instance Lifecycle API
  (dynamic instance swap + shared resource registry)**.
- ⛔ **Sequence (`.ssqb`) playback** — run SpriteStudio-authored playlists. Blocked
  on the SDK Phase 3 **State machine implementation** (which folds Sequence
  playback into the state graph).
- ⛔ **Replicate / crowd rendering** — draw many instances of one animation cheaply
  by sharing a single evaluated `FrameData`. Blocked on the SDK Phase 3 **Instance
  Lifecycle API (Animation Instancing — shared evaluation context)**.

## 🕒 Deferred ("あとで")

- ⚠️ **`flutter_gpu` renderer backend — code shipped, NOT actually validated.**
  A second `RenderBackend` behind `SpriteStudioBackend` (default `auto`:
  flutter_gpu where Impeller is available, Canvas otherwise / always on Web). The
  code renders every kind — Normal, Mesh, Shape, Effect, PartColor, Mask,
  Instance — into an offscreen Impeller render target and composites it back with
  `canvas.drawImage`.
  - **Correction (2026-07-23):** the previous "byte-for-byte identical, verified
    on Metal/Vulkan, `rgbMeanDiff=0.00`" claim was **wrong**, and the parity
    suite is not trustworthy: (1) `gpu_backend_test.dart` runs `flutter test -d
    macos` **without** `--enable-impeller --enable-flutter-gpu`, so
    `isFlutterGpuAvailable()` is false and it **falls back to Canvas** — it has
    only ever compared Canvas-vs-Canvas; and (2) even with both flags on, its
    `pic.toImage()` capture of the GPU render target is unreliable (a pack that
    renders correctly on-device — e.g. Mask — reads 0 opaque px there), so its
    per-pack numbers are noise.
  - **On-device isolation (the only source of truth) found and FIXED one real
    bug:** mask-target Shapes rendered white because ShapeMask's `[pos.xy, rgba]`
    (6-float) vertex layout put the `vec4` colour at byte offset 8, which Impeller
    misreads (it 16-byte-aligns a vertex `vec4`). Fixed with an 8-float `[pos.xy,
    local.xy, rgba]` layout (colour at offset 16), mirroring the working sprite
    pipeline (`buildShapeColorInterleaved` + `shaders/gpu/shapemask.vert`). Mask
    and Shape now match Canvas on-device (macOS/Metal). No other vertex bake has a
    `vec4` at a non-16-aligned offset, so this is the whole class.
  - **Known-broken — peeled PartColor tint on GPU (NOT fixed).** A Normal (or
    Mesh/Instance) part with a *real* PartColor tint (`rate > 0`) renders as its
    raw texture on the GPU backend — the tint is dropped. Root cause: the batched
    PartColor pipeline reads each part's data from a UBO array indexed by a
    per-vertex `a_part` (`pc.data[part*9 + k]`), and **Impeller/Metal miscompiles
    `uniformArray[dynamicIndex + constant]`** — it returns 0 for rate/coef/mask
    (verified on macOS: `pc.data[base]` reads right, `pc.data[base + 4]` reads 0).
    Mask.ssab hid this because its masked parts use *passthrough* PartColor (white
    corners, rate 0), which looks the same whether the tint applies or not; only
    a genuinely tinted part (Shape.ssab's "Normal" part, Mul blend) exposes it.
    - Attempted fixes that did NOT work: a local-array copy with an incrementing
      index (compiler folds it back); one-draw-per-part with literal `data[0..8]`
      indexing (then a *small* UBO gets mis-bound and reads 0; oversizing it back
      to `data[360]` still read 0 in that path, cause not isolated). Reverted to
      the committed batched form.
    - **Recommended fix (not yet done) — do what Godot/Web already do.** The
      sibling players batch peeled PartColor parts with **per-vertex attributes**,
      not a UBO: ssplayer-webgl's `PartsColorProgram` carries `aColor` (the corner
      colour) + `aVarg` (rate + Mix/Mul/AddSub selectors) per vertex and the
      hardware interpolates the 4-corner gradient for free; Godot uses the same
      `CUSTOM0 = (rate, blend_idx, pma, 0)`. No UBO, no dynamic index — which is
      why raw WebGL (as low-level as flutter_gpu) has none of these bugs.
    - **Why this backend didn't do that:** it was ported from the *Canvas*
      backend, which reconstructs the bilinear gradient in the fragment from
      **uniforms** because **dart:ui runtime-effect shaders cannot take custom
      per-vertex varyings** — a hard dart:ui limitation. flutter_gpu is NOT
      dart:ui: its shaders are real GLSL with varyings (the sprite pipeline
      already uses a per-vertex `a_color`), so it should have used the
      Godot/Web per-vertex-attribute design from the start and never needed a UBO.
      The doc's "Flutter can't do custom varyings" note applies to Canvas only.
    - So the fix is: move colour / rate / blend-selectors (and the mask
      bits/uv/off) into per-vertex attributes, drop the `PartColorInfo` UBO
      entirely. Proven by the siblings, simpler than the current fragment
      reconstruction, and it sidesteps every Impeller UBO bug hit here.
    - **Cold-start handoff for this rewrite:**
      [`docs/flutter-gpu-partcolor-cold-start.ja.md`](./docs/flutter-gpu-partcolor-cold-start.ja.md)
      — the concrete file/function/shader change list, the traps already hit,
      and the on-device build/verify recipe (both `--enable-*` flags + the
      SDK-release-404 lib workaround). Read it before starting.
  - **Still experimental (unverified on-device):** Effect / Instance-tint /
    BlendMode / Basic. Canvas remains the default and the reference.
  - Design intent (as built): peeled PartColor/mask fan-out collapses into batched
    draws via per-vertex attributes + a UBO array (the UBO array being exactly
    what's broken above); per-batch blend maps the fixed-function-expressible SS
    modes; masked instance-child inheritance (§3-2-2) rides the peel path via each
    `MaskDraw`'s coverage handle.
  - Next step: (a) the flat-attribute rewrite above to make PartColor tint work on
    GPU; (b) fix `gpu_backend_test` to require both flags and fail (not silently
    pass on Canvas) when GPU is unavailable, with a trustworthy GPU capture.
  - **Remaining (edge cases, on top of the above):** a framebuffer-read shader for
    Exclusion / Invert / Multiply-over-transparency, and `Nines`/`Text`
    (unimplemented in both backends). See `docs/architecture.ja.md` §19.
- 🕒 **Physical iOS device + `armeabi-v7a` runtime verification** — the example is
  verified on the iOS simulator and Android emulator; a code-signed `iphoneos`
  slice and the 32-bit ARM ABI at runtime are still unconfirmed (see the
  native-packaging notes in `CLAUDE.md`).
- 🕒 **Web wasm distribution for pub.dev** — the web target ships the Brain as the
  SDK's wasm-bindgen build, bundled as a Flutter **asset**
  (`ssplayer_flutter/assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm}`, loaded
  over `dart:js_interop`; there is no `dart:ffi` / native-asset on web). It is
  currently **git-ignored and built on demand** (`scripts/build-runtime.sh
  platform=web`), so a pub.dev consumer with no Rust toolchain cannot obtain it —
  **this must be settled before `ssplayer_flutter`'s `publish_to: none` is
  lifted.**
  - **Leaning A — commit the built wasm** and ship it as the (already-declared)
    asset, alongside its `THIRD-PARTY-LICENSES.ssruntime.md`. Unlike the native
    dylibs — an OS×arch matrix (multi-MB) that the build hook git-ignores and
    *downloads* per target — the wasm is one small, target-independent pair
    (~330 KB; ~660 KB with the nosimd variant), so committing is simpler and gives
    the same "consumer needs no Rust" guarantee with no runtime fetch and offline
    support.
  - **Open concern (why deferred):** a committed binary must be rebuilt +
    re-committed on every SDK pin bump (`_sdkVersion` in
    `ssruntime_dart/hook/build.dart`) and kept in lockstep with ssruntime's
    release cadence — weigh the binary-in-git churn, and consider a CI check that
    the committed wasm equals a fresh build of the pinned SDK (mirroring the hook's
    SHA256 verify).
  - **Alternative B — runtime fetch** from a CORS + `application/wasm` CDN. The
    `loadSsRuntime([moduleUrl])` seam already accepts a URL, so this is migratable
    later; it wins only when the blob grows large or must update out-of-band (it is
    exactly how Flutter itself ships CanvasKit). Caveats: CORS, wasm MIME /
    streaming compile, an always-up host, CSP allow-listing, no offline.
  - **The native build-hook path cannot be reused here:** hooks don't run for web
    builds (`config.buildCodeAssets` is false, so `hook/build.dart` early-returns)
    and the upstream wasm `CodeAsset` (dart-lang/native#156) is still open — when
    it lands, a true hook-parity path opens.

## Upstream (not a Player task)

- **Shape `Arrow` renders with area outside the arrow filled** — an upstream SDK
  geometry bug (`Arrow` is emitted as a bare 7-point polygon with no center, while
  every Player fans it). The fix belongs in the runtime (give `Arrow` a center +
  closing vertex, count 7→9); it is on the **SpriteStudio-SDK Backlog** and repairs
  all five Players at once. See [`docs/architecture.ja.md` §11-A](./docs/architecture.ja.md)
  "既知の不整合" and the SDK roadmap.
- **Mask rendering is a Player responsibility, not an SDK deliverable** (per the
  SDK roadmap's "Items not on the roadmap by design"). Already implemented here
  via the coverage-bitmap hybrid — no roadmap item.
