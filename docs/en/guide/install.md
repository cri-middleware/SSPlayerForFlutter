# Installation

How to add SpriteStudioPlayer for Flutter to your app. The native runtime (`libssruntime`) is
delivered automatically through Dart **native assets** — there is no CocoaPods, framework, or
`DynamicLibrary` path to configure, and no Rust toolchain to install.

## Supported environment

| Item | Details |
|---|---|
| Flutter / Dart | **Flutter 3.38+ / Dart 3.10+** (native assets is stable and default-on) |
| Verified platforms | macOS · iOS · Android |
| Other platforms | Windows / Linux build from source; Web is on the roadmap |
| Native toolchain | None — the Brain is downloaded prebuilt by the `ssruntime_dart` build hook |

## Install from a GitHub Releases bundle (recommended)

Until the packages are on pub.dev, install from the release bundle:

1. Download the latest bundle from
   [**GitHub Releases**](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest).
2. Extract it into your project (e.g. into a `vendor/` folder).
3. Reference it with a `path:` dependency in your app's `pubspec.yaml`:

```yaml
dependencies:
  ssplayer_flutter:
    # The extracted bundle keeps the packages/ layout, so the transitive
    # ssruntime_dart dependency resolves automatically.
    path: vendor/SSPlayerForFlutter/packages/ssplayer_flutter
```

4. Run `flutter pub get`.

!!! note "🚧 Before the first release"
    The Releases download goes live once the first release is published. Once the packages are on
    pub.dev this becomes a plain `ssplayer_flutter: ^x.y.z` — no `vendor/` step.

Building a game with [Flame](https://flame-engine.org/)? Also add `ssplayer_flame` from the same
bundle (see [Flame Integration](flame.md)).

!!! tip "Developing the core?"
    Building `libssruntime` from Rust source, or hacking on the Player itself, is covered separately
    in the [Build Guide](../contributing/build.md) — app users never need it.

## Verify

Run the bundled example, or import `ssplayer_flutter` in your app and confirm `flutter pub get`
resolves and the app builds. The native library is fetched and embedded on the first build; no extra
setup.

## Next steps

- **No `.ssab` file yet?** → [CLI Conversion (`.sspj` → `.ssab`)](../customize/conversion.md) to build
  one from your SpriteStudio project.
- **Already have an `.ssab`?** → [Quick Start](quickstart.md) to load and play it in a widget.
