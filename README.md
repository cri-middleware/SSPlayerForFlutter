[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**Give your Flutter app editor-crafted 2D raster animation — rigged by an artist, played with a single widget, and not one line of animation code.**

▶️ **[Try the live demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/)** — SpriteStudio animations played by Flutter in your browser, with nothing to install.

A player that renders **[SpriteStudio](https://www.webtech.co.jp/spritestudio/)** animations (`.ssab`) directly in [Flutter](https://flutter.dev/). SpriteStudio is a professional 2D **raster** (sprite) animation editor — bone rigs, mesh deformation, and particle effects over hand-drawn sprite art. Your artist builds the motion visually; this player just plays the finished file, drawing it natively to the Flutter `Canvas` — no `AnimationController` to hand-write, no spritesheet to slice, no video to decode.

## ✨ Why use SpriteStudio with Flutter?

- **Bring your sprites — and whole screens — to life.** Breathing and blinking, swaying hair and clothes, flashy slash and magic effects, even an animated HUD or splash screen: the motion is built visually in a dedicated editor (SpriteStudio) and `SpriteStudioAnimation` just plays it. Bone rigs, mesh deformation and particles are all handled for you, so there is no animation code to write.
- **Raster art, drawn natively — not vector, not video.** It animates **raster** (bitmap/PNG) sprite art, so painted illustrations and rich textures move exactly as drawn — a different fit from vector animation tools. Unlike a `.gif` or an `.mp4`, it scales freely, loops seamlessly and reacts to your app, and Flutter's own renderer draws it — no WebView, no video decoding.
- **A widget like any other — and a Flame component.** Position, size, transform and clip it like any other widget. Keys the artist placed on the timeline — user data, signals, audio cues — arrive as callbacks, and per-part overrides recolour, hide or swap a part at runtime. Making a game? [`ssplayer_flame`](./packages/ssplayer_flame) drops the same animation into a `FlameGame`.
- **Smooth motion — between frames and between animations.** **Sub-frame interpolation** renders each frame at the exact display time, so motion follows your display's refresh rate and playback speed instead of the authored fps. Set `transition` and a change of `animation` crossfades instead of cutting, and further tracks lay a blink or an aim over what is playing.
- **A seamless edit-to-runtime loop.** Live reload watches `SpriteStudio_Source/` while the app runs: save in SpriteStudio and only the changed project is re-converted and pushed into the running app — no manual export step.

## 📚 Documentation

For installation, the asset pipeline, and API references, see the MkDocs documentation site.

- [**Documentation site (hosted)**](https://cri-middleware.github.io/SSPlayerForFlutter/)
- [**Live Web demos**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — `ssplayer_flutter` and `ssplayer_flame` running in a browser
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)
- [**For AI assistants**](https://cri-middleware.github.io/SSPlayerForFlutter/llms.txt) — these docs as Markdown: `llms.txt` indexes the pages and `llms-full.txt` holds all of them in one file; `ssplayer_flutter` and `ssplayer_flame` carry the same pages in their `doc/` folder and as an Agent Skill in `skills/` ([installing the skill](https://cri-middleware.github.io/SpriteStudio-Docs/ai/))
- [**SpriteStudio Docs (portal)**](https://cri-middleware.github.io/SpriteStudio-Docs/) — the SDK and every official player in one place

### Quick Links
- [Installation](docs/en/guide/install.md)
- [Quick Start](docs/en/guide/quickstart.md)
- [Flame Integration](docs/en/guide/flame.md)
- [Preparing Assets (`.sspj` → `.ssab`)](docs/en/guide/conversion.md)
- [Limitations & Scope](docs/en/limitations.md)

---

## 🚀 Quick Start

**Using it in your app?** Read on — add the dependency, convert your `.sspj`, play.
Everything after that (events, per-part overrides, live reload) is the same path
further in, on the [documentation site](docs/en/index.md).
**Working on the Player, or the Rust runtime under it?** [CONTRIBUTING.md](./CONTRIBUTING.md), the [Build Guide](./docs/en/development/build.md) — which also covers using a changed player in an app and checking what the suites miss — and [How the Player Is Put Together](./docs/en/development/architecture.md) for the layers and why.

You need **Flutter 3.47+ / Dart 3.13+**, and a project made in **SpriteStudio 7.6 or later**.

1. **Install** the player, and the converter as a dev dependency:

   ```bash
   flutter pub add ssplayer_flutter
   flutter pub add --dev ssconverter_dart
   ```

   The first build downloads the prebuilt native runtime from the SpriteStudio-SDK release and
   verifies its checksum — no Rust toolchain and no platform setup.

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
   │       ├── Ringo.png
   │       └── …
   ├── lib/main.dart
   └── pubspec.yaml               ← lists assets/spritestudio/Ringo/
   ```

3. **Play** it — one widget, anywhere in your tree:

   ```dart
   import 'package:ssplayer_flutter/ssplayer_flutter.dart';

   SpriteStudioAnimation.asset(
     'assets/spritestudio/Ringo/Ringo.ssab',
     animation: 'wait1',
     width: 400,
     height: 400,
   )
   ```

   It loads the pack and its textures, loops the animation, and is disposed with the widget.

   On the web, call `await loadSsRuntime()` once before `runApp`; on the other platforms it does nothing:

   ```dart
   Future<void> main() async {
     await loadSsRuntime();
     runApp(const MyApp());
   }
   ```

To see a save in SpriteStudio in the running app without converting by hand, use
[Live Reload](docs/en/guide/live-reload.md) — it watches the same `SpriteStudio_Source/`.

No `.sspj` of your own yet? SpriteStudio's [official sample data](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/) works as-is — the page is in Japanese, the downloads are not. [Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) is a good character to start with.

**Read next:** [Quick Start guide](docs/en/guide/quickstart.md) · [Playback & Events](docs/en/guide/playback.md) ·
[Limitations & Scope](docs/en/limitations.md)

## 📦 Packages

What you install directly — you need only the first row to play an animation. For the internal binding and diff-reconversion packages (`ssruntime_dart`, `ssgen_dart`), see [Packages](docs/en/packages.md) and [How the Player Is Put Together](docs/en/development/architecture.md).

| Purpose | Package | Kind |
|---|---|---|
| Animation playback (runtime rendering) | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter package (all platforms) |
| [Flame](https://flame-engine.org/) game-engine adapter | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter package (`SpriteStudioComponent`) |
| `.sspj` → `.ssab` conversion (CLI / library) | [`ssconverter_dart`](./packages/ssconverter_dart) | Pure Dart (desktop-only host tool) |
| Live reload for the edit-to-runtime loop | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter dev tooling |

## 🎬 Samples

Runnable apps under [`examples/`](./examples/). `scripts/run-<platform>.*` starts one in a single
step: it converts the SDK's test projects into the `.ssab` the example loads, generates the platform
runner, and picks a device (launching an emulator if none is running). Clone with
`git clone --recurse-submodules`: the test projects come from the `SpriteStudio-SDK` submodule
(`git submodule update --init --recursive` after a plain clone). `run-web` also needs the web
runtime once: `scripts/download-web-runtime.sh`.

```bash
scripts/run-macos.sh                   # overall; also run-linux / run-ios / run-android / run-web
scripts/run-android.sh example=flame   # another example
scripts\run-windows.ps1                # Windows (run-android.ps1 / run-web.ps1 there too)
```

- [overall](./examples/overall) — The one to open. Plays the SDK's `tests/overall` project plus Ringo, Doll and ParticleEffect, with dropdowns to switch project, pack and animation.
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
