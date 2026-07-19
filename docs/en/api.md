# API Reference

The class-level API reference is generated from the Dart doc comments by
[`dart doc`](https://dart.dev/tools/dart-doc). Once the packages are on pub.dev, each renders its API
automatically at `pub.dev/documentation/<package>`.

!!! note "🚧 Before the first release"
    Hosted API links go live with the pub.dev publish. Until then, generate them locally.

## Generate locally

```bash
# in packages/ssplayer_flutter/ (or any package)
dart doc
# output: doc/api/index.html
```

## Key entry points

- **`SpriteStudioPlayer`** (L3) — transport / events. See [Playback & Events](guide/playback.md).
- **`SpriteStudioView`** (L4) — the `RenderBox` widget. See [Quick Start](guide/quickstart.md).
- **`SpriteStudioComponent`** (`ssplayer_flame`) — Flame adapter. See [Flame Integration](guide/flame.md).
- **`SsAnimeInfo`** — enumerate animation / cellmap names from `.ssab` bytes.
- **`SsConverter` / `ssconvert`** (`ssconverter_dart`) — see [CLI Conversion](customize/conversion.md).
