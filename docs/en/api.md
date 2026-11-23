# 📖 API Reference

The class-level API reference is generated from the Dart doc comments by
[`dart doc`](https://dart.dev/tools/dart-doc). pub.dev publishes it for each package: open
**API reference** on the package's page, e.g. [`ssplayer_flutter`](https://pub.dev/packages/ssplayer_flutter).

## Generate locally

```bash
# in packages/ssplayer_flutter/ (or any package)
dart doc --output build/api
# output: build/api/index.html
```

## Key entry points

- **`SpriteStudioAnimation`** — the widget that owns its player, from an asset key. See [Quick Start](guide/quickstart.md).
- **`SpriteStudioPlayer`** — transport / events. See [Playback & Events](guide/playback.md).
- **`SpriteStudioView`** — the `RenderBox` widget over a player you own. See
  [Playback & Events](guide/playback.md#owning-the-player-yourself).
- **`SpriteStudioComponent` / `SpriteStudioButtonComponent`** (`ssplayer_flame`) — Flame adapter, and a button made
  of one. See [Flame Integration](guide/flame.md).
- **`SpriteStudioPartAnchor` / `SpriteStudioAnchorHidden` / `SpriteStudioAnchorMirror`** — stick a widget to
  a part. See [Part Following](guide/part-following.md).
- **`SsPartQuad`** — a part's outline as drawn (`SpriteStudioPlayer.partQuad` / `hitTestPart`). See
  [Part Following](guide/part-following.md#a-parts-outline).
- **`SsRootTransform`** — the player-level flip / offset / scale (`flipX` / `flipY` / `offset` / `scale`). See
  [Playback & Events](guide/playback.md).
- **`SpriteStudioStateView` / `SpriteStudioHitRegion` / `SsUiState`** (`package:ssplayer_flutter/ui.dart`) — an
  animation inside a button. See [Buttons & UI States](guide/buttons.md).
- **`SsBlendOp` / `SsOverridePriority` / `PartNameTable`** — part overrides. See
  [Part Overrides](guide/part-overrides.md).
- **Texture replacement** — `SpriteStudioPlayer.setCellmapTexture` / `cellmapTextureOverride` /
  `replaceableTextureNames`, backed by the low-level **`TextureRegistry`**. See
  [Texture Replacement](guide/textures.md).
- **`SsAnimeInfo`** — enumerate animation / cellmap / cell / external-texture names from `.ssab` bytes.
- **`SsConverter` / `ssconvert`** (`ssconverter_dart`) — see [Preparing Assets](guide/conversion.md).
