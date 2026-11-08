# SpriteStudio Player for Flutter — Roadmap

This file lists unfinished work only. Technical constraints live in
[Limitations](docs/en/limitations.md); work on the SDK side lives in the
[SDK ROADMAP](https://github.com/cri-middleware/SpriteStudio-SDK/blob/HEAD/ROADMAP.md).

## Playback & rendering

- [ ] **Texture mapping of a vertex-deformed part on Canvas** — a Normal part with a PartColor, an
  integration shader, a mask test or a Sub / Invert blend draws through one fragment program per part,
  which recovers its texture coordinates from three corners. A deformed part keeps its outline but
  maps its texture as if undeformed, by up to its deformation near the fourth corner. `flutter_gpu`
  draws the real vertices. Drawing the part's four triangles apart would fix it.
- [ ] **Fall back to Canvas when `flutter_gpu` cannot draw** — under `SpriteStudioBackend.auto`, a
  shader bundle or pipeline that fails to build leaves the view empty rather than falling back to
  Canvas.
- [ ] **The first frame of a start** — playback started by `play` or `resume` on a player with a
  `vsync` begins one display frame late.
- [ ] **A wrong file handed to `load`** — bytes that are not a `.ssab` (a `.png`, a `.sspj`) fail with an
  `IndexError` rather than the documented `FormatException`, and the error does not name the asset.
- [ ] **`flutter_gpu` resolution with several windows** — the offscreen target follows the device pixel
  ratio of the app's first window.
- [ ] **Flip / offset on the Flame adapter** — `SpriteStudioPlayer` has `flipX` / `flipY` / `offset`;
  `SpriteStudioComponent` does not surface them, since a Flame `PositionComponent` already offers
  `flipHorizontally()` and a `scale`. Worth revisiting if the two turn out to compose badly (a
  component flip also mirrors the component's children, which is exactly what the player-level one
  avoids).
- [ ] **`Nines` / `Text` kinds** — not drawn on either render backend.

## UI integration

- [ ] **Selected state** — `SpriteStudioStateView` reads disabled, pressed, hovered and focused from the
  button's `WidgetStatesController`, but not `WidgetState.selected`, which `IconButton` (`isSelected`) and
  `SegmentedButton` set, so a selected button shows as it would unselected. The SDK porting guide's
  [UI integration page](https://github.com/cri-middleware/SpriteStudio-SDK/blob/HEAD/libs/ssruntime/docs/50_features/80_ui_integration.md)
  recommends the selected state where the host has one: a flag beside the state that plays the `selected_`
  labels, falling back through them before the plain ones, with `pressed` right after `selected_pressed`.
  `resolveUiSection` and `SsUiStateDriver.show` would take it.

## Live reload

- [ ] **Push what a failed reconvert did convert** — when one project of several fails to convert,
  those converted before it are not pushed, and count as up to date on the next save.
- [ ] **Say why a push reloaded nothing** — `sswatch` reports that no player reloaded but not why:
  usually the macOS app sandbox or a pack name no player holds. The desktop push also matches on the
  pack's name alone, so same-named packs of two projects would both reload from one directory.
- [ ] **What `reload` repeats** — it fires `onAnimationStarted` again and reports the landing frame's
  events again.

## Distribution & verification

- [ ] **Leave the web runtime out of native apps** — `assets/runtime-web/` is a plain Flutter asset, so
  a mobile or desktop app built against the published package carries the wasm binaries and their glue
  too.
- [ ] **A console warning from `loadSsRuntime`** — the web runtime logs "using deprecated parameters for
  the initialization function" on every start. Two calls before the first completes also instantiate it
  twice.
- [ ] **`user_defines` per ABI** — `hooks.user_defines.ssruntime_dart.libssruntime` names one library,
  which goes to every ABI of a multi-ABI Android build. [Native Runtime](docs/en/development/native-runtime.md)
  should say so, or the option should take one per target.
- [ ] **`build-runtime` when a slice is missing** — the Android and iOS builds skip a library the SDK
  script did not produce and still succeed, and the app then takes the downloaded runtime unnoticed.
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

- [ ] **Release effects without `dispose`** — a player that is never disposed, as across a hot restart,
  has its runtime released by the garbage collector, but not its effects, which keep the pack's parse.
  Development only.
- [ ] **Small documentation gaps** — `SsCornerColors`' field names are not on
  [Part Overrides](docs/en/guide/part-overrides.md), the `ssplayer_flame` README sets an `anchor` that
  has no effect without a `size`, and the `ssruntime_dart` README asks to keep `.ssab` bytes alive, which
  copy mode does not need.
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
