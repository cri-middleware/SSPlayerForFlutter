[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**Give your Flutter app editor-crafted 2D raster animation — rigged by an artist, played with a single widget, and not one line of animation code.**

▶️ **[Try the live demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/)** — SpriteStudio animations played by Flutter in your browser, with nothing to install.

A player that renders **[SpriteStudio](https://www.webtech.co.jp/spritestudio/)** animations (`.ssab`) directly in [Flutter](https://flutter.dev/). SpriteStudio is a professional 2D **raster** (sprite) animation editor — bone rigs, mesh deformation, and particle effects over hand-drawn sprite art. Your artist builds the motion visually; this player just plays the finished file, drawing it natively to the Flutter `Canvas` — no `AnimationController` to hand-write, no spritesheet to slice, no video to decode.

## ✨ Why use SpriteStudio with Flutter?

- **Bring your sprites — and whole screens — to life.** Breathing and blinking, swaying hair and clothes, flashy slash and magic effects, even an animated HUD or splash screen: the motion is built visually in a dedicated editor (SpriteStudio) and `SpriteStudioView` just plays it. Bone rigs, mesh deformation and particles are all handled for you, so there is no animation code to write.
- **Hand-drawn art, drawn natively.** It animates the sprite art you already have, so painted characters move exactly as drawn — a different fit from vector tools like Lottie. Unlike a `.gif` or an `.mp4`, it scales freely, loops seamlessly and reacts to your app, and Flutter's own renderer draws it — no WebView, no video decoding.
- **A widget like any other — and a Flame component.** Position, size, transform and clip it like any other widget. Making a game? [`ssplayer_flame`](./packages/ssplayer_flame) drops the same animation into a `FlameGame`.
- **Smooth motion, not locked to a frame rate.** **Sub-frame interpolation** renders each frame at the exact display time, so motion follows your display's refresh rate and playback speed instead of the authored fps.
- **A seamless edit-to-runtime loop.** Live reload watches `SpriteStudio_Source/` while the app runs: save in SpriteStudio and only the changed project is re-converted and pushed into the running app — no manual export step.

## 📚 Documentation

For installation, the asset pipeline, and API references, see the MkDocs documentation site.

- [**Documentation site (hosted)**](https://cri-middleware.github.io/SSPlayerForFlutter/)
- [**Live Web demos**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — `ssplayer_flutter` and `ssplayer_flame` running in a browser
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)
- [**For AI assistants**](https://cri-middleware.github.io/SSPlayerForFlutter/llms.txt) — these docs as Markdown: `llms.txt` indexes the pages and `llms-full.txt` holds all of them in one file; `ssplayer_flutter` and `ssplayer_flame` carry the same pages in their `doc/` folder and as an Agent Skill in `skills/` ([installing the skill](https://cri-middleware.github.io/SpriteStudio-Docs/overview/ai-assistants/))
- [**SpriteStudio Docs (portal)**](https://cri-middleware.github.io/SpriteStudio-Docs/) — the SDK and every official player in one place

### Quick Links
- [Installation](docs/en/guide/install.md)
- [Quick Start](docs/en/guide/quickstart.md)
- [Flame Integration](docs/en/guide/flame.md)
- [Preparing Assets (`.sspj` → `.ssab`)](docs/en/guide/conversion.md)
- [Limitations & Scope](docs/en/limitations.md)

---

## 🚀 1. Quick Start

**Using it in your app?** Read on — add the dependency, convert your `.sspj`, play.
Everything after that (events, per-part overrides, live reload) is the same path
further in, on the [documentation site](docs/en/index.md).
**Working on the Player, or the Rust runtime under it?** [Section 2](#%EF%B8%8F-2-full-build-environment-for-sdk--player-developers).

You need **Flutter 3.47+ / Dart 3.13+**, and a project made in **SpriteStudio 7.5 or later**.

1. **Install** the player, and the converter as a dev dependency:

   ```bash
   flutter pub add ssplayer_flutter
   flutter pub add --dev ssconverter_dart
   ```

   The native runtime comes prebuilt with the package on the first build — no Rust toolchain and no
   platform setup.

2. **Convert**: Put your SpriteStudio project — the whole folder — under `SpriteStudio_Source/` in
   your app, convert it into `assets/spritestudio/`, and list that folder in `pubspec.yaml`:

   ```bash
   dart run ssconverter_dart:ssconvert -o assets/spritestudio/Ringo/ SpriteStudio_Source/Ringo/Ringo.sspj
   ```

   ```yaml
   flutter:
     assets:
       - assets/spritestudio/Ringo/
   ```

   ```
   my_app/
   ├── SpriteStudio_Source/
   │   └── Ringo/                 ← your SpriteStudio project, the whole folder
   │       ├── Ringo.sspj
   │       ├── Ringo.png
   │       └── …
   ├── assets/spritestudio/
   │   └── Ringo/                 ← written by ssconvert
   │       ├── Ringo.ssab
   │       └── Ringo.png
   ├── lib/main.dart
   └── pubspec.yaml               ← lists assets/spritestudio/Ringo/
   ```

3. **Play** it — one widget, anywhere in your tree:

   ```dart
   SpriteStudioAnimation.asset(
     'assets/spritestudio/Ringo/Ringo.ssab',
     animation: 'wait1',
     width: 400,
     height: 400,
   )
   ```

   It loads the pack and its textures, loops the animation, and is disposed with the widget.

To see a save in SpriteStudio in the running app without converting by hand, use
[Live Reload](docs/en/guide/live-reload.md) — it watches the same `SpriteStudio_Source/`.

No `.sspj` of your own yet? SpriteStudio's [official sample data](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/) works as-is — the page is in Japanese, the downloads are not. [Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) is a good character to start with.

**Read next:** [Quick Start guide](docs/en/guide/quickstart.md) · [Playback & Events](docs/en/guide/playback.md) ·
[Limitations & Scope](docs/en/limitations.md)

## ⚙️ 2. Full Build Environment (For SDK / Player Developers)

### See it running from a checkout

Run the bundled example to confirm the player works. **No Rust toolchain required** — each package's
`hook/build.dart` downloads the prebuilt native libraries (`libssruntime` / `libssconverter`) from
the pinned SDK release and bundles them.

**macOS / Linux:**
```bash
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive
scripts/deploy-examples.sh          # generate example .ssab (libssconverter auto-downloads; no Rust)
cd examples/overall && flutter run  # libssruntime auto-downloads
```

**Windows:**
```powershell
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive
scripts\deploy-examples.ps1
cd examples\overall; flutter run
```

### Building the core yourself

To develop the core (Rust runtime / Player) from source. **Prerequisites**: Rust (`rustup`),
a Flutter/Dart SDK at or above the floor on [Installation](docs/en/guide/install.md) (native assets is
standard — no CocoaPods / vendored framework to embed the native runtime). `flatc` only when regenerating `.fbs`; cbindgen is pulled in as a build-dependency by the
SDK's `build.rs`, so no separate install.

**macOS / Linux:**
```bash
git submodule update --init --recursive
scripts/build-runtime.sh             # e.g. build-runtime.sh platform=macos build=release
#   After a C-API change, regenerate bindings and commit: scripts/generate-ffigen-code.sh
scripts/deploy-examples.sh
cd examples/overall && flutter run
```

**Windows:**
```powershell
git submodule update --init --recursive
scripts\build-runtime.ps1
scripts\deploy-examples.ps1
cd examples\overall; flutter run
```

See [CONTRIBUTING.md](./CONTRIBUTING.md) for building and testing from a checkout,
[Native Runtime](./docs/en/contributing/native-runtime.md) for how the native library is packaged, and
[ROADMAP.md](./ROADMAP.md) for upcoming work.

## 📦 Packages

What this monorepo releases — you need only the first row to play an animation; the rest are what it is built on and the tooling around it.

| Purpose | Package | Kind |
|---|---|---|
| Animation playback (runtime rendering) | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter package (all platforms; depends on `ssruntime_dart`) |
| [Flame](https://flame-engine.org/) game-engine adapter | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter package (`SpriteStudioComponent`) |
| Runtime bindings over `dart:ffi` | [`ssruntime_dart`](./packages/ssruntime_dart) | Pure Dart (renderer-agnostic core) |
| `.sspj` → `.ssab` conversion (CLI / library) | [`ssconverter_dart`](./packages/ssconverter_dart) | Pure Dart (desktop-only host tool) |
| Reconverts only what changed (powers `ssgen_flutter`) | [`ssgen_dart`](./packages/ssgen_dart) | Pure Dart (desktop host lib) |
| Live reload for the edit-to-runtime loop | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter dev tooling (on `ssgen_dart`) |

## 🎬 Samples

Runnable apps under [`examples/`](./examples/). `scripts/run-<platform>.*` starts one in a single
step: it converts the SDK's test projects into the `.ssab` the example loads, generates the platform
runner, and picks a device (launching an emulator if none is running).

```bash
scripts/run-macos.sh                   # overall; also run-linux / run-ios / run-android / run-web
scripts/run-android.sh example=flame   # another example
scripts\run-windows.ps1                # Windows (run-android.ps1 / run-web.ps1 there too)
```

- [overall](./examples/overall) — The one to open. Plays `tests/overall`, with a dropdown to switch between its animations.
- [flame](./examples/flame) — The [`ssplayer_flame`](./packages/ssplayer_flame) adapter: one `SpriteStudioComponent` in a `FlameGame` playing Ringo, tap to toggle play/pause.
- [part_following](./examples/part_following) — Pins an ordinary Flutter widget to a part with `SpriteStudioPartAnchor`, so it tracks that part's position, rotation and scale every frame.

## 🔗 Related Repositories

- [SpriteStudio Docs](https://cri-middleware.github.io/SpriteStudio-Docs/) — the portal for the SDK and every official player
- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — the Rust runtime / converter / `.fbs` schemas this player drives
- [SSConverterGUI](https://github.com/cri-middleware/SSConverterGUI) — desktop GUI for converting `.sspj` without a player

## 📄 License

This project is licensed under the BSD-3-Clause License — see [`LICENSE.md`](./LICENSE.md).
For the bundled native runtime and other third-party components, see
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md).
