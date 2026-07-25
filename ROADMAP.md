# SpriteStudioPlayer for Flutter — Player Roadmap

The **Flutter Player** roadmap. It tracks Flutter-specific work for capabilities
the Rust runtime/converter exposes (`SpriteStudio-SDK/ROADMAP.md`). This file is
**forward-looking only** — already-shipped features (the draw kinds Normal /
PartColor / Mask / Mesh / Effect / Instance / Shape, the built-in `ss-*`
integration shaders, both render backends **Canvas** and **flutter_gpu**, events,
per-part overrides, the Flame adapter, live-reload, and the Web render target)
are not repeated here.

Legend: ☐ **Ready** (Player-only, can start now) · ⛔ **Blocked on SDK** (needs an
`SpriteStudio-SDK/ROADMAP.md` phase first) · 🕒 **Deferred**.

## Player features (no SDK dependency)

- ☐ **Label / frame-range / index playback** — play a named label range, a start
  offset, or by animation index. Labels already ride in the `.ssab` FlatBuffers
  payload, so no SDK change is needed; add `play_range` / `play_by_index` on L3.
- ☐ **`Nines` / `Text` kinds + `BoxFit` / alignment** — the remaining Phase-2 draw
  kinds, plus fitting the animation's design bounds into the destination box.
  Unimplemented on both render backends.

## SDK-integration features (⛔ blocked on SDK Phase 3)

- ⛔ **Dynamic instance animation swap** — replace the animation mounted on an
  Instance part at runtime. Waits on the SDK **Instance Lifecycle API**.
- ⛔ **Sequence (`.ssqb`) playback** — run SpriteStudio-authored playlists. Waits
  on the SDK **State machine implementation**.
- ⛔ **Replicate / crowd rendering** — draw many instances of one animation cheaply
  from a single evaluated `FrameData`. Waits on the SDK **Instance Lifecycle API**
  (shared evaluation context).

## Distribution & verification

- 🕒 **Web wasm distribution for pub.dev** — the Web target renders every kind, but
  ships the Brain as a git-ignored, build-on-demand wasm pair
  (`assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm}`), so a Rust-less pub.dev
  consumer can't obtain it. **Must be settled before `ssplayer_flutter`'s
  `publish_to: none` is lifted.** Leaning: commit the small (~330 KB; ~660 KB with
  the nosimd variant), target-independent wasm as the already-declared asset;
  alternative is a runtime CDN fetch via the existing `loadSsRuntime([url])` seam.
  Open concern: the committed blob must be rebuilt + re-committed on every SDK pin
  bump (`_sdkVersion`) — consider a CI check that it equals a fresh build.
- 🕒 **Physical iOS device + `armeabi-v7a` runtime check** — verified on the iOS
  simulator and Android emulator; a code-signed `iphoneos` slice and the 32-bit
  ARM ABI at runtime are still unconfirmed.

## Backlog (small / optional)

- ☐ **PartColor struct direct-read (`ByteData`)** — read the packed
  `PartAttributePartColor` struct straight from the `FrameData` bytes (as the
  Unity / RenPy / Web siblings do), dropping ~9 throwaway FlatBuffers wrappers per
  tinted part per frame. Residual win is small (the dominant per-frame churn is
  already reclaimed); gate on a micro-benchmark and a **mandatory** layout-
  equivalence test against the generated accessors.
- ☐ **Instance child `Resource` sharing** — one Instance part = one `Resource`
  today; the parsed `.ssab` should be shareable across children of the same pack
  (each child's `Context` stays separate for its own clock). A Body-local dedup is
  possible before the SDK shared-resource registry lands.
- ☐ **Quad mask-writer anti-aliasing** (low priority) — turn AA off on the
  `drawPath` quad mask-writer, matching the Shape/Mesh writers; coverage is a
  number, not a picture, so an AA'd edge can decode as another writer's bits.
  Impact is bounded to a 1px edge.
- ☐ **Batch the Canvas `Sub` / `Invert` reconstruction** — those two modes have no
  stock `ui.BlendMode`, so the Canvas backend rebuilds them from three passes over
  one part's geometry (`blendPassesFor`), which also forces each such part out of
  its batched run: the inversion passes must cover every pixel exactly once. Two
  overlapping parts could still batch if the emitter proved their quads disjoint.
  Bounded cost — 3 draws per Sub/Invert part — so it is only worth doing for a pack
  that leans on those modes heavily.
- 🕒 **`Mul` over transparency** — SpriteStudio's Mul row (`DST_COLOR`,
  `1-SRC_ALPHA`) assumes an opaque target; over transparency the two backends
  diverge from each other by one `Cs·(1-αb)` term, and the Canvas Sub / Invert
  reconstruction likewise forces alpha to 1 over transparency. Exactness there
  would need a framebuffer-read shader. Deliberately skipped: give a blend-heavy
  pack an opaque background layer instead. See [Limitations](docs/en/limitations.md).
