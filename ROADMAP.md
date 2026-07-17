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
- ☐ **Mesh PartColor / mask-target** and **Instance-part own PartColor** — the
  remaining cross-cutting gaps in the kind matrix
  ([`docs/architecture.ja.md` §11-A](./docs/architecture.ja.md)). Mesh
  PartColor/mask-target is bounded by the same no-varyings shader constraint as the
  fan-out item above; Instance-part PartColor is unimplemented in the Godot flagship
  too (only α propagates today). (Instance-*child* mask inheritance §3-2-2 already
  ships — see the matrix.)

## ☐/⛔ SDK-integration features

- ☐ **Per-part runtime overrides (color / cell / visibility)** — the SDK
  **Override Layer API** (Phase 2) is **shipped** (`[x]` in `SpriteStudio-SDK/ROADMAP.md`),
  so this is now Player-side work: wrap the override FFI in L2 (via a
  part-index resolver) and expose `setPartColor` / `setPartCell` / `setPartVisible`
  on L3, matching the Unity/Web sibling surface.
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

- 🕒 **`flutter_gpu` renderer backend** — a lower-level Body path (the Flutter
  analogue of the SDK's own `ssplayer-wgpu`, Phase 3) that could give shaded parts
  per-vertex data and so unblock the peeled-fan-out item above. Deferred until
  `flutter_gpu` stabilises and the fan-out cost is shown to matter in a real title.
- 🕒 **Physical iOS device + `armeabi-v7a` runtime verification** — the example is
  verified on the iOS simulator and Android emulator; a code-signed `iphoneos`
  slice and the 32-bit ARM ABI at runtime are still unconfirmed (see the
  native-packaging notes in `CLAUDE.md`).

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
