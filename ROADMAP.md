# SpriteStudio Player for Flutter — Roadmap

This file lists unfinished work only. Technical constraints live in
[Limitations](docs/en/limitations.md); work on the SDK side lives in the
[SDK ROADMAP](https://github.com/cri-middleware/SpriteStudio-SDK/blob/HEAD/ROADMAP.md).

## Playback & rendering

- [ ] **Flip / offset on the Flame adapter** — `SpriteStudioPlayer` has `flipX` / `flipY` / `offset`;
  `SpriteStudioComponent` does not surface them, since a Flame `PositionComponent` already offers
  `flipHorizontally()` and a `scale`. Worth revisiting if the two turn out to compose badly (a
  component flip also mirrors the component's children, which is exactly what the player-level one
  avoids).
- [ ] **`Nines` / `Text` kinds** — not drawn on either render backend.

## UI integration

Behaving like a Flutter widget, not merely painting inside one. The view sizes
from the authored canvas, fits it into its box and answers hits over the whole
box, as an `Image` does; this section is the rest of what a widget does. The
vocabulary is shared with the sibling Players: a part rect read-out for hit
areas, and a UI-state map.

- [ ] **Per-part hit testing** — the view answers a hit anywhere in its box, so an
  irregular button takes taps around its artwork too. The player reads each part's
  outline (`partQuad`, `hitTestPart`); what is left is a separate opt-in widget that
  narrows hits to the parts the host names, so a player that only plays pays nothing.
- [ ] **UI state binding** — a widget that drives the player from
  `WidgetStatesController` (`hovered` / `pressed` / `disabled` / `focused`), each
  state mapped to an animation or a label, so a player drops into an `InkWell` or a
  `ButtonStyleButton` and reacts like the rest of the button does.

## Distribution & verification

- [ ] **Physical iOS device and `armeabi-v7a` runtime check** — verified on the iOS
  simulator and Android emulator; a code-signed `iphoneos` slice and the 32-bit
  ARM ABI have no runtime check. Blocked on: a physical iOS device and a 32-bit
  ARM Android device.
- [ ] **Windows and Linux desktop apps** — CI builds the example for both and runs the test suites
  on Linux, but neither desktop app has been run. Blocked on: a Windows machine and a Linux
  machine.
- [ ] **Confirm the three borrowed blend states** — `Mulalpha` and `Mul2` draw with `Mul`'s
  state and `Screen2` with `Screen`'s, on both backends (`render/blend.dart`,
  `flutter_gpu_backend.dart`), as SpriteStudio Player for Web and for wgpu do; none of the three has
  been checked against a reference render.
- [ ] **Live reload on Windows / Linux desktop and on physical devices** — verified on
  macOS, the Android emulator, the iOS simulator and the web (debug); the push is the
  same code on every target, so what is missing is a run on each, not push logic.
  Blocked on: a Windows machine, a Linux machine and physical devices.

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

- [ ] **Batch the Canvas `Sub` / `Invert` reconstruction** — with no stock
  `ui.BlendMode` for them, the Canvas backend rebuilds those modes from four or three
  passes over one part's geometry, and each such part leaves its batched run because
  the inversion passes must cover every pixel exactly once. Overlapping parts could
  still batch if the emitter proved their quads disjoint, which is only worth it for a
  pack that leans on those modes heavily.
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
