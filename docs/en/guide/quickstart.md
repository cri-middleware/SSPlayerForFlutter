# ⚡ Quick Start

The shortest path from a SpriteStudio project to a playing animation in a widget.

## 1. Convert the project

Put your SpriteStudio project — the whole folder — under `SpriteStudio_Source/` in your app, and
convert it into `assets/spritestudio/` with `ssconvert`, from the `ssconverter_dart` dev dependency
[Installation](install.md) adds:

```bash
dart run ssconverter_dart:ssconvert -o assets/spritestudio/Ringo/ SpriteStudio_Source/Ringo/Ringo.sspj
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
└── pubspec.yaml
```

The other ways to convert are on [Preparing Assets (`.sspj` → `.ssab`)](conversion.md).

!!! tip "No SpriteStudio data of your own yet?"
    The [official sample data](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/) works as-is — that page is
    Japanese only, but the downloads themselves are language-neutral.
    [Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) is a good character sample.

## 2. Add the asset

Declare the folder `ssconvert` wrote in `pubspec.yaml`:
```yaml
flutter:
  assets:
    - assets/spritestudio/Ringo/
```

## 3. Load and play

```dart
SpriteStudioAnimation.asset(
  'assets/spritestudio/Ringo/Ringo.ssab',
  width: 400,
  height: 400,
)
```

That is the whole thing. The widget builds a player, reads the bytes from the
asset bundle (resolving sibling reference textures from the key's own folder —
embedded packs too), selects the pack's first animation, starts it looping, and
disposes it with the widget. Pass `animation:` to choose a different one,
`playing: false` to leave the first frame posed, `placeholder:` for what to show
until the first frame is drawable, and `onError:` to hear about a load that
failed.

On the web, call `await loadSsRuntime()` once before `runApp`; on the other platforms it does
nothing:

```dart
Future<void> main() async {
  await loadSsRuntime();
  runApp(const MyApp());
}
```

## What you can pass it

| Parameter | Purpose |
|---|---|
| `animation` | Which animation to select. Omit it for the pack's first — an unselected pack draws an empty box, which is what a failed load looks like too. Change it and the same player switches; while `playing`, the new animation starts from its first frame. |
| `width` / `height` | The box to draw in. Omit them and it takes the animation's authored canvas as its size, shrunk to the constraints with its aspect kept — the way `Image` sizes from its picture. |
| `loopCount` | `-1` loops forever; `n > 0` plays *n* times. See [Playback & Events](playback.md). |
| `playing` | On by default. A state, not a start-up flag: off holds the playhead where it stands, and on carries on from there. Off from the first build leaves the first frame posed, the way a `<video>` without `autoplay` shows a poster. |

Every parameter, and how a change reaches the player, is on [Playback & Events](playback.md#widget-parameters).

!!! tip "Textures: embedded vs. reference"
    Both texture modes resolve with no extra argument: an **embedded** `.ssab` (built with
    `ssconvert -e`) carries its images, and a **reference** `.ssab` points at sibling files that
    `loadAsset` resolves from the key's own folder. See [Preparing Assets](conversion.md).

Sub-frame interpolation is **on by default**, so motion stays smooth regardless of frame rate.

## Next steps

- Control playback, switch animations, and react to events → [Playback & Events](playback.md).
- Using the [Flame](https://flame-engine.org/) game engine → [Flame Integration](flame.md).
