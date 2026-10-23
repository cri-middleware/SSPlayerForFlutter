# 📥 Installation

How to add SpriteStudio Player for Flutter to your app. The native runtime (`libssruntime`) is
delivered automatically through Dart **native assets** — there is no CocoaPods, framework, or
`DynamicLibrary` path to configure, and no Rust toolchain to install.

## Supported environment

| Item | Details |
|---|---|
| Flutter / Dart | **Flutter 3.47+ / Dart 3.13+** (native assets is default-on from 3.38; the flutter_gpu backend sets the 3.47 floor). This page is where that floor is written down — `ssplayer_flutter`'s `environment:` enforces it, so `flutter pub get` is what tells you if yours is older |
| Verified platforms | macOS · iOS · Android |
| Other platforms | Windows / Linux: the prebuilt runtime downloads as on the others, but these are not in the verified set; Web is a developer preview |
| Native toolchain | None — the Brain is downloaded prebuilt by the `ssruntime_dart` build hook |

## Add the dependency

Add `ssplayer_flutter` from [pub.dev](https://pub.dev/packages/ssplayer_flutter), and the converter as a
dev dependency:

```bash
flutter pub add ssplayer_flutter
flutter pub add --dev ssconverter_dart
```

`ssruntime_dart`, the runtime bindings underneath, comes with it.

What else to add depends on what you use:

| For | Add |
|---|---|
| [Flame Integration](flame.md) | `flutter pub add flame ssplayer_flame` |
| [Live Reload](live-reload.md) | `flutter pub add --dev ssgen_flutter` |

!!! note "The web target"
    The web runtime ships inside `ssplayer_flutter`. Call `await loadSsRuntime()` once before
    `runApp`; on the other platforms it does nothing.

!!! tip "Developing the core?"
    Building `libssruntime` from Rust source, or hacking on the Player itself, is covered separately
    in the [Build Guide](../contributing/build.md) — app users never need it.

## Verify

Import `ssplayer_flutter` in your app and confirm `flutter pub get`
resolves and the app builds. The native library is fetched and embedded on the first build; no extra
setup.

## Next steps

- **No `.ssab` file yet?** → [Preparing Assets (`.sspj` → `.ssab`)](conversion.md) to build
  one from your SpriteStudio project.
- **Already have an `.ssab`?** → [Quick Start](quickstart.md) to load and play it in a widget.
