# SpriteStudio Player for Flutter — Roadmap

This file lists unfinished work only. Technical constraints live in
[Limitations](docs/en/limitations.md); work on the SDK side lives in the
[SDK ROADMAP](https://github.com/cri-middleware/SpriteStudio-SDK/blob/HEAD/ROADMAP.md).

## Playback & rendering

- [ ] **Label playback** — set the playback section by a start and an end label, each
  with an offset. Labels already ride in the `.ssab` FlatBuffers payload, so no SDK
  change is needed; add `setAnimationSectionByLabel` on L3 beside the existing
  `setAnimationSection`, which already covers the frame-number form, under the stem
  the SDK's API conventions register.
- [ ] **Flip / offset on the Flame adapter** — `SpriteStudioPlayer` has `flipX` / `flipY` / `offset`;
  `SpriteStudioComponent` does not surface them, since a Flame `PositionComponent` already offers
  `flipHorizontally()` and a `scale`. Worth revisiting if the two turn out to compose badly (a
  component flip also mirrors the component's children, which is exactly what the player-level one
  avoids).
- [ ] **Reverse-playback audio** — decide where the gate lives. SpriteStudio has no
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
- [ ] **`Nines` / `Text` kinds** — not drawn on either render backend.

## UI integration

Behaving like a Flutter widget, not merely painting inside one. The view sizes
from the authored canvas, fits it into its box and answers hits over the whole
box, as an `Image` does; this section is the rest of what a widget does. The
vocabulary is shared with the sibling Players: a part rect read-out for hit
areas, and a UI-state map.

- [ ] **Per-part hit testing** — the view answers a hit anywhere in its box, so an
  irregular button takes taps around its artwork too. Add `partRectOf(part)`
  (built from the `PartState` fields the runtime already delivers every frame —
  `size_x` / `size_y`, `anchor`, `pivot` — and the part transform), then
  `hitTestPart(Offset)`, and answer `hitTestSelf` from it.
- [ ] **UI state binding** — a widget that drives the player from
  `WidgetStatesController` (`hovered` / `pressed` / `disabled` / `focused`), each
  state mapped to an animation or a label, so a player drops into an `InkWell` or a
  `ButtonStyleButton` and reacts like the rest of the button does.

## Distribution & verification

- [ ] **Canvas and flutter_gpu draw different colours in three packs** — measured by
  `examples/overall/integration_test/gpu_backend_test.dart` on macOS, where the two
  agree on coverage everywhere. Which backend matches SpriteStudio is established for
  none of them; the reference Player (ForWgpu) or the Editor decides it, and the
  losing side is the fix.
  A **four-corner PartColor gradient** (`PartsColor`, rgbMeanDiff 6.1; a one-colour
  tint matches): the GPU interpolates it per triangle, Canvas bilinearly per
  fragment. The **gradient inside a Shape** (`Shape`, 6.7), and a few of its edge
  pixels. **`Mul` and `Mulalpha`** (`BlendMode`, 3.5, which the test's 6.0 gate
  lets through), each over the pack's own opaque backdrop, where the other six modes
  match — [Limitations](docs/en/limitations.md) says both backends reproduce all
  eight there, which this contradicts.
- [ ] **Physical iOS device and `armeabi-v7a` runtime check** — verified on the iOS
  simulator and Android emulator; a code-signed `iphoneos` slice and the 32-bit
  ARM ABI have no runtime check. Blocked on: a physical iOS device and a 32-bit
  ARM Android device.
- [ ] **Live reload on Windows / Linux desktop and on physical devices** — verified
  on macOS, the Android emulator, the iOS simulator and the web (debug). The push
  is the same code on every target, and `--device` only picks the payload, so what
  is missing is a run on the target, not push logic. Blocked on: a Windows
  machine, a Linux machine and physical devices.

## Needs SDK

- [ ] **Dynamic instance animation swap** — replace the animation mounted on an
  Instance part at runtime. Waits for: Instance Lifecycle API.
- [ ] **Sequence (`.ssqb`) playback** — run SpriteStudio-authored playlists.
  Waits for: State machine implementation.
- [ ] **Replicate / crowd rendering** — draw many instances of one animation cheaply
  from a single evaluated `FrameData` (shared evaluation context). Waits for:
  Instance Lifecycle API.
- [ ] **Stretch a `Nines` part to the layout box** — the runtime evaluates a
  Nines part's size from its keyframes and hands over finished vertices, and the
  Override Layer covers colour / cell / visibility only, so nothing can resize
  one from the host: an authored window frame cannot follow the box Flutter
  gives it. Needs the `Nines` kind above, which neither render backend draws.
  Waits for: Per-part size override (the Override Layer extended with `size_x` /
  `size_y`).

## Backlog

- [ ] **Batch the Canvas `Sub` / `Invert` reconstruction** — those two modes have no
  stock `ui.BlendMode`, so the Canvas backend rebuilds them from four or three
  passes over one part's geometry (`blendPassesFor`), which also forces each such
  part out of its batched run: the inversion passes must cover every pixel exactly
  once. Two overlapping parts could still batch if the emitter proved their quads
  disjoint. Bounded cost — 4 draws per Sub part, 3 per Invert part — so it is only
  worth doing for a pack that leans on those modes heavily.
- [ ] **Reuse the GPU mask coverage texture** — `FlutterGpuBackend.renderCoverage`
  creates the coverage texture for every frame that writes a mask, and leaves the
  last one to the GC. A ring of them, as `TargetRing` keeps the offscreen targets,
  would stop that; only packs with masks pay it.
- [ ] **Keep a Mesh run's static UVs and indices** — every frame, the Mesh bake
  copies each vertex's UV and rebases each index, though both stay the same while
  the run's parts do; only the positions and the alpha change. Mesh takes about a
  quarter of a Ringo frame on Canvas, but `ui.Vertices.raw` takes every array each
  time, so only the Dart-side copy can go: about half of the Mesh bake, by
  estimate, not measured.
- [ ] **One `.ssab` buffer per pack in L3** — `SpriteStudioPlayer` keeps the bytes
  it loaded (`SsAnimeInfo`), 140 KB for each Ringo player, though L2's `SsabPack`
  already holds one buffer for every player of the pack. Reading the pack's buffer
  instead needs L3 to reach it, which means a public getter on
  `SpriteStudioInternalPlayer`.
