# 🧥 Texture Replacement

Runtime texture replacement swaps the bitmap a whole **cellmap** samples — from your code, at
runtime — for costume changes, colour variants, and dynamic facial expressions, without touching the
animation data. The draw loop binds textures by their cellmap hash, so a replacement shows on the
next frame the player draws, for every part that samples that texture (see Notes for the
`flutter_gpu` upload).

This is separate from [Part Overrides](part-overrides.md): those change one part's colour / cell /
visibility through the runtime; this replaces the texture *image itself* in the player's texture
registry.

## Example: changing an outfit

A replacement texture is a decoded `ui.Image`. Load one from an asset (or anywhere), then hand it to
`setCellmapTexture()`:

```dart
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;

Future<ui.Image> _loadImage(String assetKey) async {
  final data = await rootBundle.load(assetKey);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  return (await codec.getNextFrame()).image;
}

// Swap the "Clothes" cellmap for a different atlas of the SAME size and layout.
final sailor = await _loadImage('assets/sailor_uniform.png');
_player.setCellmapTexture('Clothes', sailor);

// Restore the original bitmap; the image you passed is now yours to release.
_player.setCellmapTexture('Clothes', null);
sailor.dispose();
```

With this you can build an efficient avatar / dress-up system without preparing a separate animation
for every combination — one rig, many textures.

## Discovering names

The names you can replace are read from the loaded `.ssab`:

```dart
final names = _player.replaceableTextureNames; // cellmaps + TextureChange targets
```

- **Cellmap names** carry no extension (`Clothes`). Replacing one re-skins every part that samples
  that cellmap.
- **TextureChange file names** carry an extension (`clothes.png`). Replace one of these to change what
  a part shows on the frames an authored *TextureChange* is active (see the note below).

`cellmapNames` / `cellNames(cellmap)` — the same pair a [cell override](part-overrides.md) uses — list
the cellmaps and the cells inside one.

## Methods

These are methods on `SpriteStudioPlayer`.

| Method | Description |
|---|---|
| `setCellmapTexture(name, image)` | Replace the texture the cellmap (or TextureChange file) `name` samples. `image: null` **restores** the original |
| `setCellmapTextureByHash(hash, image)` | The same, keyed by the registry hash from `cellmapTextureHash` — skips the name lookup |
| `cellmapTextureOverride(name)` | The replacement image currently set for `name` (the override only, never the original), or `null` |
| `replaceableTextureNames` | Every name a replacement can target — cellmaps, then TextureChange files |
| `cellmapTextureHash(name)` | The registry key for a cellmap name (for `...ByHash` / the low-level `TextureRegistry`) |
| `cellmapNames` / `cellNames(name)` | Enumerate cellmaps and the cells inside one |

`setCellmapTexture` returns `false` before `load()`, for an unknown name, or when restoring a name
that had no override; `true` when a replacement was set or actually cleared.

!!! note "The same calls exist on the low-level API"
    `SpriteStudioInternalPlayer`, the drawing engine beneath `SpriteStudioPlayer`, has them too, for a
    headless run or a drawing adapter of your own: see
    [How the Player Is Put Together](../development/architecture.md#driving-l2-directly).

## Notes

- **You own the replacement image.** The player *borrows* it and never disposes it — keep it alive
  while it is set, and dispose it once you clear the override (or replace it with another). Restoring
  is instant: the player keeps the original decoded image, so `null` never re-loads anything and cannot
  fail.
- **Use the same size and layout as the original atlas.** Cell rectangles and UVs stay in the
  *original* cellmap's pixel space, so a replacement of a different resolution samples a different
  region. A texture swap assumes a same-size, same-layout atlas — a re-skin, not a re-layout.
- **Applies tree-wide.** The whole animation — including parts inside instance children — shares one
  texture registry, so a replacement reaches every part that samples that texture, root or child alike.
- **Takes effect even while paused.** A swap changes pixels without changing the frame number, and
  `SpriteStudioPlayer` notifies its listeners on success. On the `flutter_gpu` backend the new image is
  uploaded to the GPU first, so the parts that sample it are not drawn until the upload lands, and the
  player repaints by itself when it does; the Canvas backend draws it at once. Restoring the original
  is immediate on both.
- **Loading another `.ssab` clears every replacement** — the texture registry is rebuilt with the new
  pack.

## TextureChange vs. runtime replacement

SpriteStudio also has an **authored** TextureChange attribute — a part swaps the texture it samples on
keyed frames, set on the timeline. That renders automatically; you write no code for it. The two meet
in one place:

- On the frames an authored TextureChange is active, the part binds the **file-name** texture
  (`clothes.png`), not the cellmap-name one (`Clothes`). To replace what such a part shows there,
  target the **TextureChange file name** (with extension) — it is listed in `replaceableTextureNames`.

## Choosing between this and a cell override

- **`setCellmapTexture()`** replaces a **whole cellmap (texture)** at once, affecting every part that
  samples it — a re-skin.
- **[`setPartCellOverride()`](part-overrides.md)** replaces the **cell a single part draws** — one
  part, a different sprite from a cellmap.

Pick whichever matches your intent; they are independent and can be combined.

## Using it from Flame

`ssplayer_flame` has no API of its own for this — call `setCellmapTexture` on the player the component exposes.

```dart
final player = component.player!;
player.setCellmapTexture('Clothes', await _loadImage('assets/sailor_uniform.png'));
```

## See also

- [Part Overrides](part-overrides.md) — per-part colour / cell / visibility
- [Preparing Assets](conversion.md) — how cellmaps and their images get into a `.ssab`
- [API Reference](../api.md) — the low-level `TextureRegistry`, if you drive drawing yourself
