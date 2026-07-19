# Quick Start

The shortest path from an `.ssab` file to a playing animation in a widget.

!!! note "This page assumes you already have an `.ssab`"
    If you only have a SpriteStudio project (`.sspj`), first build an `.ssab` with
    [CLI Conversion (`.sspj` → `.ssab`)](../customize/conversion.md).

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

## What each step does

| Step | Purpose |
|---|---|
| `SpriteStudioPlayer(vsync: this)` | Creates the player with its own `Ticker`. Omit `vsync` to drive the clock yourself (see [Playback & Events](playback.md)). |
| `SsAnimeInfo(bytes).animationNames` | Lists the animations inside the `.ssab` so you can pick one. |
| `load(bytes, animationName:, baseAssetDir:)` | Hands the bytes to the native runtime, selects the animation, and resolves textures. |
| `loop = -1` | Loops forever (`n > 0` plays *n* times; see [Playback & Events](playback.md)). |
| `play()` | Starts the transport. |
| `SpriteStudioView(player:, width:, height:)` | A plain `RenderBox` widget — position, transform, and clip it like any widget. |

!!! tip "Textures: embedded vs. reference"
    An **embedded** `.ssab` (built with `ssconvert -e`) carries its textures, so `baseAssetDir` is
    optional. A **reference** `.ssab` points at sibling image files — pass `baseAssetDir` so they
    resolve. See [CLI Conversion](../customize/conversion.md).

Sub-frame interpolation is **on by default**, so motion stays smooth regardless of frame rate.

## Next steps

- Control playback, switch animations, and react to events → [Playback & Events](playback.md).
- Using the [Flame](https://flame-engine.org/) game engine → [Flame Integration](flame.md).
