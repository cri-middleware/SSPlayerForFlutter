# ⚡ Quick Start

The shortest path from an `.ssab` file to a playing animation in a widget.

!!! note "This page assumes you already have an `.ssab`"
    If you only have a SpriteStudio project (`.sspj`), first build an `.ssab` with
    [Preparing Assets (`.sspj` → `.ssab`)](conversion.md).

## 1. Add the asset

Put your `.ssab` (and, for the reference-texture form, its sibling PNG / WebP files) under your app's
assets and declare the folder in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/overall/
```

## 2. Load and play

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // loadAsset reads the bytes from the asset bundle and resolves sibling
    // reference textures from the key's own folder (embedded packs too).
    await _player.loadAsset('assets/overall/Basic.ssab');
    _player
      ..setAnimation(_player.getAnimations().first)
      ..loop = -1
      ..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

## What each step does

| Step | Purpose |
|---|---|
| `SpriteStudioPlayer(vsync: this)` | Creates the player with its own `Ticker`. Omit `vsync` to drive the clock yourself (see [Playback & Events](playback.md)). |
| `loadAsset('assets/overall/Basic.ssab')` | Reads the bytes from the asset bundle, hands them to the native runtime, and resolves sibling reference textures from the key's own folder. |
| `getAnimations()` / `setAnimation` | Lists the animations inside the loaded `.ssab` and selects one. |
| `loop = -1` | Loops forever (`n > 0` plays *n* times; see [Playback & Events](playback.md)). |
| `play()` | Starts the transport. |
| `SpriteStudioView(player:, width:, height:)` | A plain `RenderBox` widget — position, transform, and clip it like any widget. |

!!! tip "Textures: embedded vs. reference"
    Both texture modes resolve with no extra argument: an **embedded** `.ssab` (built with
    `ssconvert -e`) carries its images, and a **reference** `.ssab` points at sibling files that
    `loadAsset` resolves from the key's own folder. See [Preparing Assets](conversion.md).

Sub-frame interpolation is **on by default**, so motion stays smooth regardless of frame rate.

## Next steps

- Control playback, switch animations, and react to events → [Playback & Events](playback.md).
- Using the [Flame](https://flame-engine.org/) game engine → [Flame Integration](flame.md).
