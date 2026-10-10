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

## Add the dependency

Add the packages as git dependencies on a release tag. A release tags each package it releases
`<package>-v<version>`: pick the version from the package's
[**Releases**](https://github.com/cri-middleware/SSPlayerForFlutter/releases?q=ssplayer_flutter&expanded=true)
and use its tag as the `ref`.

```yaml
dependencies:
  ssplayer_flutter:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssplayer_flutter-v7.0.0-beta.1
      path: packages/ssplayer_flutter

dependency_overrides:
  ssruntime_dart:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssplayer_flutter-v7.0.0-beta.1
      path: packages/ssruntime_dart
```

Then run `flutter pub get`.

The packages name one another by version, so every package of this repository that yours pull in
goes under `dependency_overrides` the same way. Take them all from **one tag**: a tag holds every
package as the release checked them together.

| You depend on | Also under `dependency_overrides` |
|---|---|
| `ssplayer_flutter` | `ssruntime_dart` |
| `ssplayer_flame` — [Flame Integration](flame.md) | `ssplayer_flutter`, `ssruntime_dart` |
| `ssconverter_dart` (dev) — the `ssconvert` CLI, [Preparing Assets](conversion.md) | — |
| `ssgen_flutter` (dev) — [Live Reload](live-reload.md) | `ssplayer_flutter`, `ssgen_dart`, `ssconverter_dart`, `ssruntime_dart` |

!!! note "The web target"
    The web runtime (`packages/ssplayer_flutter/assets/runtime-web/`) is build output, not part of
    the repository, so a git dependency carries none and `loadSsRuntime()` has nothing to load. To
    build for the web, clone the tag, run `scripts/download-web-runtime.sh` (`.ps1` on Windows) in
    it once, and depend on its packages by `path:` — the `dependency_overrides` by `path:` too.

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
