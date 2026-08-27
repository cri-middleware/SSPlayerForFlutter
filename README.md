[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**Give your Flutter app editor-crafted 2D raster animation — rigged by an artist, played with a single widget, and not one line of animation code.**

▶️ **[Try the example app](./examples/overall/)** — the bundled SpriteStudio animations rendered straight onto the Flutter canvas. 🚧 Prebuilt binaries download automatically once the first SDK release is published.

A player that renders **[SpriteStudio](https://www.webtech.co.jp/spritestudio/)** animations (`.ssab`) directly in [Flutter](https://flutter.dev/). SpriteStudio is a professional 2D **raster** (sprite) animation editor — bone rigs, mesh deformation, and particle effects over hand-drawn sprite art. Your artist builds the motion visually; this player just plays the finished file, drawing it natively to the Flutter `Canvas` — no `AnimationController` to hand-write, no spritesheet to slice, no video to decode.

## ✨ Why SpriteStudio Player?

- **Bring sprites — and whole scenes — to life, with zero animation code.** Breathing and blinking, swaying hair and clothes, flashy slash and magic effects. Instead of hand-wiring `AnimationController` / `Tween` / `AnimatedBuilder` or hand-slicing a spritesheet, the motion is authored visually in a dedicated editor (SpriteStudio) and the player just plays it — bone rigs, mesh deform, and particles included. And it is not limited to a single mascot: compose entire animated **UIs, HUDs, and full scenes** in the editor and render them as one — a scope narrower vector-icon tools don't reach.
- **Raster sprite animation, drawn natively — not vector, not video.** It rigs and deforms **raster sprite art**, so hand-painted characters and game sprites animate exactly as authored — a different fit from vector animation tools, and lighter than shipping a `.gif` or `.mp4`. Playback runs on `dart:ffi` into a Rust runtime and draws through Flutter's own renderer — GPU-batched via **flutter_gpu** on Impeller, or `Canvas.drawVertices` elsewhere — not a WebView, not a video decode — scaling freely at runtime, looping seamlessly, and reacting to your app instead of merely playing back.
- **Composes with the widget tree — and with Flame.** `SpriteStudioView` is a plain `RenderBox` widget, so you position, transform, and clip it exactly like any other widget. Building a game? The separate [`ssplayer_flame`](./packages/ssplayer_flame) adapter drops the same animation into a `FlameGame` as a `PositionComponent`.
- **Smooth motion, not locked to a frame rate.** **Sub-frame interpolation** renders each frame at its exact display time, so motion follows your display's refresh rate and playback speed — smoother than a fixed-fps flipbook or a baked video.
- **A seamless edit-to-runtime loop.** Live reload watches your `SpriteStudio_Source/` during `flutter run`: save in SpriteStudio, hot-reload, and only the changed project is re-converted and appears live in your app — no manual export step.

## 📚 Documentation

For installation, the asset pipeline, and API references, see the MkDocs documentation site.

- [**Documentation site (hosted)**](https://cri-middleware.github.io/SSPlayerForFlutter/) — 🚧 live after the first release
- [**Live Web demos**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — `ssplayer_flutter` and `ssplayer_flame` running in a browser — 🚧 live after the first release
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)
- [**SpriteStudio Docs (portal)**](https://cri-middleware.github.io/SpriteStudio-Docs/) — the SDK and every official player in one place — 🚧 live after the first release

### Quick Links
- [Installation](docs/en/guide/install.md)
- [Quick Start](docs/en/guide/quickstart.md)
- [Flame Integration](docs/en/guide/flame.md)
- [Preparing Assets (`.sspj` → `.ssab`)](docs/en/guide/conversion.md)

## 📦 Packages

This monorepo will publish the following packages to pub.dev 🚧 (not yet published — see the Quick Start below).

| Purpose | Package | Kind |
|---|---|---|
| Animation playback (runtime rendering) | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter package (all platforms; depends on `ssruntime_dart`) |
| [Flame](https://flame-engine.org/) game-engine adapter | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter package (`SpriteStudioComponent`) |
| Runtime FFI bindings (Layer 1) | [`ssruntime_dart`](./packages/ssruntime_dart) | Pure Dart (renderer-agnostic core) |
| `.sspj` → `.ssab` conversion (CLI / library) | [`ssconverter_dart`](./packages/ssconverter_dart) | Pure Dart (desktop-only host tool) |
| Reconvert-only-stale host lib (powers `ssgen_flutter`) | [`ssgen_dart`](./packages/ssgen_dart) | Pure Dart (desktop host lib) |
| Live reload for the edit-to-runtime loop | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter dev tooling (on `ssgen_dart`) |

---

## 🚀 1. Quick Start

### Setup

Add the dependency. **Until the packages are on pub.dev**, download the latest bundle from
[GitHub Releases](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest), extract it
into your project (e.g. `vendor/`), and reference it with a path dependency:

```yaml
# pubspec.yaml
dependencies:
  ssplayer_flutter:
    # From the GitHub Releases bundle, extracted into your project. The packages/ layout is
    # preserved, so the transitive ssruntime_dart dependency resolves automatically.
    path: vendor/SSPlayerForFlutter/packages/ssplayer_flutter
```

> 🚧 The Releases download goes live once the first release is published. Once the packages are on
> pub.dev, this becomes a plain `ssplayer_flutter: ^x.y.z`.

The minimal code to embed a `.ssab` animation (you supply the `.ssab` — see [Convert your own](#convert-your-own-sspj)):

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // loadAsset reads the bytes and resolves sibling reference textures from the
    // key's own folder — no baseAssetDir needed (embedded packs work too).
    await _player.loadAsset('assets/spritestudio/overall/Basic.ssab');
    _player
      ..setAnimation(_player.animationNames.first)
      ..loopCount = -1
      ..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

> ⚠️ The native Brain (`libssruntime`) is required. It is bundled automatically by the
> **native assets** hook (`hook/build.dart`) of the `ssruntime_dart` dependency — no plugin or
> framework wiring. The hook **auto-downloads** the prebuilt binary from the pinned SDK release,
> so no Rust toolchain is needed (build from source only if you want to — see section 2).

### Verifying It Works

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

### Convert your own `.sspj`

Put your SpriteStudio project (`.sspj` + `.ssae` + images) under a **`SpriteStudio_Source/`** folder,
then convert it with the `ssconverter_dart` CLI (`-e` produces a self-contained embedded `.ssab`,
ideal for shipping). **No Rust toolchain** — `libssconverter` auto-downloads:

```bash
# SpriteStudio_Source/MyChar/MyChar.sspj  →  assets/spritestudio/MyChar/<pack>.ssab
#   (one .sspj yields one .ssab per animation pack)
dart run ssconverter_dart:ssconvert -e -o assets/spritestudio/MyChar/ SpriteStudio_Source/MyChar/MyChar.sspj
# then in your app:  loadAsset('assets/spritestudio/MyChar/MyChar.ssab')
```

The same `SpriteStudio_Source/` layout drives **live reload**: run `sswatch` next to `flutter run`
and a save in SpriteStudio re-converts only the changed project and pushes it into the running app
(see [Live Reload](docs/en/guide/live-reload.md)). To supply your own locally-built native library,
point `hooks.user_defines.<pkg>.lib<name>` in the app's `pubspec.yaml` at it.

## ⚙️ 2. Full Build Environment (For SDK / Player Developers)

To develop the core (Rust runtime / Player) from source. **Prerequisites**: Rust (`rustup`),
Flutter 3.47+ / Dart 3.13+ (native assets is standard — no CocoaPods / vendored framework to embed
the Brain; the flutter_gpu backend is what puts the floor at 3.47). `flatc` only when regenerating `.fbs`; cbindgen is pulled in as a build-dependency by the
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

See [AGENTS.md](./AGENTS.md) (implementation rules, gotchas, native-asset packaging) and
[ROADMAP.md](./ROADMAP.md) (upcoming work) for the full developer guide.

## 🔗 Related Repositories

- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — the Rust runtime / converter / `.fbs` schemas (the Brain)

## 📄 License

This project is licensed under the BSD-3-Clause License — see [`LICENSE.md`](./LICENSE.md).
For the bundled native runtime and other third-party components, see
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md).
