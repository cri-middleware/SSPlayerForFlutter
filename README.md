[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**Give your Flutter app editor-crafted 2D raster animation — rigged by an artist, played with a single widget, and not one line of animation code.**

▶️ **[Try the example app](./examples/overall/)** — the bundled SpriteStudio animations rendered straight onto the Flutter canvas. 🚧 Prebuilt binaries download automatically once the first SDK release is published.

A player that renders **[OPTPiX SpriteStudio 7](https://www.webtech.co.jp/spritestudio/)** animations (`.ssab`) directly in [Flutter](https://flutter.dev/). SpriteStudio 7 is a professional 2D **raster** (sprite) animation editor — bone rigs, mesh deformation, and particle effects over hand-drawn sprite art. Your artist builds the motion visually; this player just plays the finished file, drawing it natively to the Flutter `Canvas` — no `AnimationController` to hand-write, no spritesheet to slice, no video to decode.

## ✨ Why SpriteStudio Player?

- **Bring sprites — and whole scenes — to life, with zero animation code.** Breathing and blinking, swaying hair and clothes, flashy slash and magic effects. Instead of hand-wiring `AnimationController` / `Tween` / `AnimatedBuilder` or hand-slicing a spritesheet, the motion is authored visually in a dedicated editor (SpriteStudio 7) and the player just plays it — bone rigs, mesh deform, and particles included. And it is not limited to a single mascot: compose entire animated **UIs, HUDs, and full scenes** in the editor and render them as one — a scope narrower vector-icon tools don't reach.
- **Raster sprite animation, drawn natively — not vector, not video.** It rigs and deforms **raster sprite art**, so hand-painted characters and game sprites animate exactly as authored — a different fit from vector animation tools, and lighter than shipping a `.gif` or `.mp4`. Playback runs on `dart:ffi` into a Rust runtime and draws through `Canvas.drawVertices` — not a WebView, not a video decode — scaling freely at runtime, looping seamlessly, and reacting to your app instead of merely playing back.
- **Composes with the widget tree — and with Flame.** `SpriteStudioView` is a plain `RenderBox` widget, so you position, transform, and clip it exactly like any other widget. Building a game? The separate [`ssplayer_flame`](./packages/ssplayer_flame) adapter drops the same animation into a `FlameGame` as a `PositionComponent`.
- **Smooth motion, not locked to a frame rate.** **Sub-frame interpolation** renders each frame at its exact display time, so motion follows your display's refresh rate and playback speed — smoother than a fixed-fps flipbook or a baked video.
- **A seamless edit-to-runtime loop.** Live reload watches your `.sspj` during `flutter run`: save in SpriteStudio 7, hot-reload, and only the changed project is re-converted and appears live in your app — no manual export step.
## 📚 Documentation

For installation, the asset pipeline, and API references, see the MkDocs documentation site.

- [**Documentation site (hosted)**](https://cri-middleware.github.io/SSPlayerForFlutter/) — 🚧 live after the first release
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)

### Quick Links
- [Installation](docs/en/guide/install.md)
- [Quick Start](docs/en/guide/quickstart.md)
- [Flame Integration](docs/en/guide/flame.md)
- [CLI Conversion (`.sspj` → `.ssab`)](docs/en/customize/conversion.md)

## 📦 Packages

This monorepo publishes the following packages to pub.dev.

| Purpose | Package | Kind |
|---|---|---|
| Animation playback (runtime rendering) | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter package (all platforms; depends on `ssruntime_dart`) |
| [Flame](https://flame-engine.org/) game-engine adapter | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter package (`SpriteStudioComponent`) |
| Runtime FFI bindings (Layer 1) | [`ssruntime_dart`](./packages/ssruntime_dart) | Pure Dart (renderer-agnostic core) |
| `.sspj` → `.ssab` conversion (CLI / library) | [`ssconverter_dart`](./packages/ssconverter_dart) | Pure Dart (desktop-only host tool) |
| Live reload for the edit-to-runtime loop | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter dev tooling |

---

## 🚀 1. Quick Start (For Users)

The minimal code to embed a `.ssab` animation in your app. (You supply the `.ssab` — build one from a `.sspj` with `ssconvert`, see [section 2](#-2-run-from-source--convert-your-own-for-customizers).)

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

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bytes = (await rootBundle.load('assets/overall/Basic.ssab'))
        .buffer.asUint8List();
    final animName = SsAnimeInfo(bytes).animationNames.first;
    // For reference textures (sibling PNGs), pass baseAssetDir; embedded assets resolve automatically.
    await _player.load(bytes, animationName: animName, baseAssetDir: 'assets/overall');
    _player..loop = -1..play();
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
> so no Rust toolchain is needed (build from source only if you want to — `scripts/build-runtime.*`).

## 🛠 2. Run from Source & Convert Your Own (For Customizers)

Launch the example, and convert your own `.sspj`. **No Rust toolchain required** — each package's
`hook/build.dart` downloads the prebuilt native libraries (`libssruntime` / `libssconverter`) from
the pinned SDK release and bundles them.

```bash
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive

# Generate example assets (.ssab) with the Dart ssconvert (libssconverter auto-downloads; no Rust)
scripts/deploy-examples.sh

# Run the example (libssruntime auto-downloads)
cd examples/overall && flutter run
```

Windows uses the `.ps1` variant of each script. To supply your own locally-built dylib, point
`hooks.user_defines.<pkg>.lib<name>` in the app's `pubspec.yaml` at it.

### Convert your own `.sspj`

Use the `ssconverter_dart` CLI (`-e` produces a self-contained embedded `.ssab`, ideal for shipping):

```bash
dart run ssconverter_dart:ssconvert    -o out/     path/to/project.sspj  # reference-texture form
dart run ssconverter_dart:ssconvert -e -o out_emb/ path/to/project.sspj  # embedded (for distribution)
```

## ⚙️ 3. Full Build Environment (For SDK / Player Developers)

To develop the core (Rust runtime / Player).

**Prerequisites**: Rust (`rustup`), Flutter 3.38+ / Dart 3.10+ (native assets is standard — no CocoaPods /
vendored framework to embed the Brain). `flatc` only when regenerating `.fbs`; cbindgen is pulled in as a
build-dependency by the SDK's `build.rs`, so no separate install.

```bash
git submodule update --init --recursive

# Build the native libs from source (copies C headers too; ffigen is a separate step)
scripts/build-runtime.sh             # e.g. build-runtime.sh platform=macos build=release
#   After a C-API change, regenerate bindings and commit: scripts/generate-ffigen-code.sh

# Generate assets, then run the example
scripts/deploy-examples.sh
cd examples/overall && flutter run
```

See [AGENTS.md](./AGENTS.md) (implementation rules, gotchas, native-asset packaging),
[docs/architecture.ja.md](./docs/architecture.ja.md) (design, repository layout, kind × cross-cutting
feature matrix), and [ROADMAP.md](./ROADMAP.md) (upcoming work) for the full developer guide.

## 🔗 Related Repositories

- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — the Rust runtime / converter / `.fbs` schemas (the Brain)
- Sibling players: [Godot](https://github.com/cri-middleware/SSPlayerForGodot) ·
  [Unity](https://github.com/cri-middleware/SSPlayerForUnity) ·
  [Web](https://github.com/cri-middleware/SSPlayerForWeb) ·
  [Ren'Py](https://github.com/cri-middleware/SSPlayerForRenPy)

## 📄 License

This project follows the license of `SpriteStudio-SDK`
([`SpriteStudio-SDK/LICENSE.md`](./SpriteStudio-SDK/LICENSE.md)). For the bundled native runtime and
other third-party components, see the `THIRD-PARTY-LICENSES.*.md` notices under each package's
`native/libs/`.
