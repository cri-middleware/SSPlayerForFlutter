# SpriteStudio Player for Flutter — Player Roadmap

The **Flutter Player** roadmap. It tracks Flutter-specific work for capabilities
the Rust runtime/converter exposes (`SpriteStudio-SDK/ROADMAP.md`). This file is
**forward-looking only**.

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
  direction test — and `isPlayingForward` exposes the heading, so a host *can*
  gate. What is undecided is whether this Player should do more than expose it.
  The siblings that own an audio backend (ForGodot / ForUnity / ForRen'Py /
  ForWeb) gate **their own playback** and still fire the notification either way;
  this Player has no backend, so it has nothing of its own to gate, and
  suppressing `onAudio` would diverge from every sibling — the notification is an
  observation channel in all of them. So the choice is (a) leave it to the host,
  as [Playback & Events](docs/en/guide/playback.md) documents, or (b) also
  ship the gate in `examples/overall`'s `_playAudio`, so the path people copy is
  the correct one. (c) — an opt-in audio backend on the Player — is a much larger
  item and is not on the table. Settle (a) vs (b) first.
- 🕒 **`Nines` / `Text` kinds** — not drawn on either render backend.

## UI integration (widget-side)

Behaving like a Flutter widget, not merely painting inside one. The view sizes
from the authored canvas, fits it into its box and answers hits over the whole
box, as an `Image` does; these are the parts of a widget it does not implement
yet. The vocabulary is shared with the sibling Players: a part rect read-out for
hit areas, and a UI-state map.

- ☐ **Per-part hit testing** — the view answers a hit anywhere in its box, so an
  irregular button takes taps around its artwork too. Add `partRectOf(part)`
  (built from the `PartState` fields the runtime already delivers every frame —
  `size_x` / `size_y`, `anchor`, `pivot` — and the part transform), then
  `hitTestPart(Offset)`, and answer `hitTestSelf` from it.
- ☐ **UI state binding** — a widget that drives the player from
  `WidgetStatesController` (`hovered` / `pressed` / `disabled` / `focused`), each
  state mapped to an animation or a label, so a player drops into an `InkWell` or a
  `ButtonStyleButton` and reacts like the rest of the button does.

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

- ☐ **Canvas and flutter_gpu draw different colours in three packs** — measured by
  `examples/overall/integration_test/gpu_backend_test.dart` on macOS, where the two
  agree on coverage everywhere. Which backend matches SpriteStudio is established for
  none of them; the reference Player (ForWgpu) or the Editor decides it, and the
  losing side is the fix.
  A **four-corner PartColor gradient** (`PartsColor`, rgbMeanDiff 6.1; a one-colour
  tint matches): the GPU interpolates it per triangle, Canvas bilinearly per
  fragment. The **gradient inside a Shape** (`Shape`, 6.7), and a few of its edge
  pixels. **`Mul`, `Sub`, `Mulalpha` and `Invert`** (`BlendMode`, 11.7), each over
  the pack's own opaque backdrop, where `Mix`, `Add`, `Screen` and `Exclusion` match —
  [Limitations](docs/en/limitations.md) says both backends reproduce all eight there,
  which this contradicts.

- 🕒 **Physical iOS device + `armeabi-v7a` runtime check** — verified on the iOS
  simulator and Android emulator; a code-signed `iphoneos` slice and the 32-bit
  ARM ABI at runtime are still unconfirmed.
- 🕒 **Live reload on Windows / Linux desktop and on physical devices** — confirmed
  on macOS, the Android emulator, the iOS simulator and the web (debug). The push
  is the same code on every target, and `--device` only picks the payload, so what
  these lack is a run on the target, not push logic: `sswatch --run -d macos
  --device` exercises the whole byte path with nothing attached, which tells a
  broken push from an unconnected target.

## Backlog (small / optional)

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
