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

- ☐ **Label / index playback** — play a *named label* range, or play by animation
  index. Labels already ride in the `.ssab` FlatBuffers payload, so no SDK change
  is needed; add `play_range` / `play_by_index` on L3 over the existing
  `setAnimationSection`, which already covers the frame-number form.
- ☐ **Flip / offset on the Flame adapter** — `SpriteStudioPlayer` has `flipX` / `flipY` / `offset`;
  `SpriteStudioComponent` does not surface them, since a Flame `PositionComponent` already offers
  `flipHorizontally()` and a `scale`. Worth revisiting if the two turn out to compose badly (a
  component flip also mirrors the component's children, which is exactly what the player-level one
  avoids).
- ☐ **Reverse-playback audio — decide where the gate lives.** SpriteStudio has no
  reverse audio, so a sound key crossed while the effective direction is backward
  (a reverse direction, or a ping-pong return leg) is not meant to sound. The
  Brain reports those keys regardless of direction — `collect_events` has no
  direction test — and `isPlayingForward` now exposes the heading, so a host *can*
  gate. What is undecided is whether this Player should do more than expose it.
  The siblings that own an audio backend (ForGodot / ForUnity / ForRen'Py /
  ForWeb) gate **their own playback** and still fire the notification either way;
  this Player has no backend, so it has nothing of its own to gate, and
  suppressing `onAudio` would diverge from every sibling — the notification is an
  observation channel in all of them. So the choice is (a) leave it to the host,
  as [Playback & Events](docs/en/guide/playback.md) documents today, or (b) also
  ship the gate in `examples/overall`'s `_playAudio`, so the path people copy is
  the correct one. (c) — an opt-in audio backend on the Player — is a much larger
  item and is not on the table yet. Settle (a) vs (b) first.
- ☐ **`Nines` / `Text` kinds + `BoxFit` / alignment** — the remaining Phase-2 draw
  kinds, plus fitting the animation's design bounds into the destination box.
  Unimplemented on both render backends.

## UI integration (widget-side)

Behaving like a Flutter widget, not merely painting inside one. `Nines` / `Text` /
`BoxFit` above is the drawing half of this; these are the parts of a widget the
view does not implement yet. The vocabulary is shared with the sibling Players:
`fit` / `align` for placement, a part rect read-out for hit areas, and a UI-state
map.

- ☐ **Intrinsic sizing** — `SpriteStudioRenderBox` has no intrinsic dimensions and
  `computeDryLayout` constrains `width ?? infinity`, so the view collapses or
  overflows wherever the constraints are unbounded (a `Row`, a `ListView`, an
  `IntrinsicHeight`) and a caller must hand it explicit numbers. Report the
  animation's content box through `computeMinIntrinsicWidth` and friends, from the
  same measurement `BoxFit` needs, so `Row` / `Wrap` / `FittedBox` can size it.
- ☐ **Per-part hit testing** — `hitTestSelf` is not overridden, so the box is
  transparent to pointers and a `GestureDetector` around it answers for the whole
  rectangle. Add `partRectOf(part)` (built from the `PartState` fields the runtime
  already delivers every frame — `size_x` / `size_y`, `anchor`, `pivot` — and the
  part transform), then `hitTestPart(Offset)`, and answer `hitTestSelf` from it so
  an irregular button stops eating taps around its artwork.
- ☐ **UI state binding** — a widget that drives the player from
  `WidgetStatesController` (`hovered` / `pressed` / `disabled` / `focused`), each
  state mapped to an animation or a label, so a player drops into an `InkWell` or a
  `ButtonStyleButton` and reacts like the rest of the button does.
- ☐ **Semantics** — the view contributes no `SemanticsNode`, so a player used as a
  control is invisible to screen readers and to widget tests that look up by label.
  Take a `semanticsLabel` and mark a decorative player as excluded.
- ☐ **Carry the fit into `SpriteStudioPartAnchor`** — the anchor documents that it
  assumes the view draws unscaled. It has to apply the same fit transform the day
  `BoxFit` lands, or every follower comes off its part on a fitted view.

## SDK-integration features (⛔ blocked on the SDK)

- ⛔ **Dynamic instance animation swap** — replace the animation mounted on an
  Instance part at runtime. Waits on the SDK **Instance Lifecycle API**.
- ⛔ **Sequence (`.ssqb`) playback** — run SpriteStudio-authored playlists. Waits
  on the SDK **State machine implementation**.
- ⛔ **Replicate / crowd rendering** — draw many instances of one animation cheaply
  from a single evaluated `FrameData`. Waits on the SDK **Instance Lifecycle API**
  (shared evaluation context).
- ⛔ **Stretch a `Nines` part to the layout box** — the runtime evaluates a
  Nines part's size from its keyframes and hands over finished vertices, and the
  Override Layer covers colour / cell / visibility only, so nothing can resize
  one from the host: an authored window frame cannot follow the box Flutter
  gives it. Waits on the SDK **Per-part size override** (Phase 3) — the Override
  Layer extended with `size_x` / `size_y`.

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

- ✖ **PartColor struct direct-read (`ByteData`)** — *measured, not worth it.* The
  idea was to read the packed `PartAttributePartColor` struct straight from the
  `FrameData` bytes (as the Unity / RenPy / Web siblings do), dropping the
  throwaway wrappers plus the `PartColor` + 4 `PartColorCorner` PODs per tinted
  part per frame. The gating micro-benchmark says no: on `PartsColor.ssab`
  (17 parts, 16 tinted) the **whole** per-frame extraction is **0.97 µs** —
  ~60 ns per tinted part, i.e. 0.006 % of a 60 fps budget, and still under 0.2 %
  extrapolated to 500 tinted parts. (`scaleAlpha` 58 ns/call,
  `wholeTintMatrix` 33 ns/call, both instance-chain only.) Making a public
  immutable value type mutable and slot-pooling it through every render path is
  not a trade worth that. Reopen only if a real profile contradicts the number.
- ☐ **Instance child `Resource` sharing** — one Instance part = one `Resource`
  today; the parsed `.ssab` should be shareable across children of the same pack
  (each child's `Context` stays separate for its own clock). A Body-local dedup is
  possible before the SDK shared-resource registry lands.
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
