# 📥 Installation

How to add SpriteStudio Player for Flutter to your app. The native runtime (`libssruntime`) is
delivered automatically through Dart **native assets** — there is no CocoaPods, framework, or
`DynamicLibrary` path to configure, and no Rust toolchain to install.

## Supported environment

| Item | Details |
|---|---|
| Flutter / Dart | **Flutter 3.47+ / Dart 3.13+** (native assets is default-on from 3.38; the flutter_gpu backend sets the 3.47 floor). This page is where that floor is written down — `ssplayer_flutter`'s `environment:` enforces it, so `flutter pub get` is what tells you if yours is older |
| Verified platforms | macOS · iOS · Android |
| Other platforms | Windows / Linux build from source; Web is a developer preview |
| Native toolchain | None — the Brain is downloaded prebuilt by the `ssruntime_dart` build hook |

## Installation methods

There are two ways to add the packages. Until the first pub.dev release, use the **GitHub Releases
bundle** (Method 1).

### Method 1 — GitHub Releases bundle (recommended, available now)

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

Building a game with [Flame](https://flame-engine.org/)? Also add `ssplayer_flame` from the same
bundle (see [Flame Integration](flame.md)).

### Method 2 — From pub.dev

Once the packages are published, installation becomes a single hosted dependency — no `vendor/` step:

```yaml
dependencies:
  ssplayer_flutter: ^x.y.z
```

!!! warning "🚧 Under construction"
    The packages are not on pub.dev yet, so this method is not available. Use **Method 1** for now —
    this section will be filled in with the real version once the first release is published.

!!! tip "Developing the core?"
    Building `libssruntime` from Rust source, or hacking on the Player itself, is covered separately
    in the [Build Guide](../contributing/build.md) — app users never need it.

## Verify

Run the bundled example, or import `ssplayer_flutter` in your app and confirm `flutter pub get`
resolves and the app builds. The native library is fetched and embedded on the first build; no extra
setup.

## Next steps

- **No `.ssab` file yet?** → [Preparing Assets (`.sspj` → `.ssab`)](conversion.md) to build
  one from your SpriteStudio project.
- **Already have an `.ssab`?** → [Quick Start](quickstart.md) to load and play it in a widget.
