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
SpriteStudioAnimation.asset(
  'assets/overall/Basic.ssab',
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

## What you can pass it

| Parameter | Purpose |
|---|---|
| `animation` | Which animation to select. Omit it for the pack's first — an unselected pack draws an empty box, which is what a failed load looks like too. Change it and the same player switches; while `playing`, the new animation starts from its first frame. |
| `width` / `height` | The box to draw in. Omit them to take the incoming constraints. |
| `loopCount` | `-1` loops forever; `n > 0` plays *n* times. See [Playback & Events](playback.md). |
| `playing` | On by default. A state, not a start-up flag: off holds the playhead where it stands, and on carries on from there. Off from the first build leaves the first frame posed, the way a `<video>` without `autoplay` shows a poster. |
| `speedScale` | Playback rate as a multiple of the authored one. |
| `flipX` / `flipY` | Mirror the drawn animation. |
| `placeholder` | Shown until the first frame is drawable. Worth setting: until then there is nothing to draw, and an empty box looks exactly like a broken pack. |
| `onError` | Called when the load fails, instead of the error reaching the zone unhandled. |
| `onPlayerCreated` | Hands you the player for the parts of the API the parameters do not cover. Do not dispose it — the widget does. |
| `bundle` / `backend` | Which `AssetBundle` to read from, and which render backend to draw with. |

Changing `assetKey`, `bundle` or `backend` builds a new player. Every other
parameter reaches the player only when it changes, so what you set on the player
through `onPlayerCreated` stands until the matching parameter changes.

## Owning the player yourself

`SpriteStudioAnimation` builds a player because most screens do not want one.
When yours does — to swap animations from a state machine, subscribe to events,
stick a widget to a part, or drive the clock from somewhere else — build a
[`SpriteStudioPlayer`](playback.md) and hand it to `SpriteStudioView`:

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _player.loadAsset('assets/overall/Basic.ssab');
    _player
      ..setAnimation(_player.animationNames.first)
      ..loopCount = -1
      ..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

`SpriteStudioAnimation` will hand you its own player through `onPlayerCreated:`
if you only need to reach past the props occasionally — but the moment you want
to control when it is built and disposed, it is `SpriteStudioView`'s job.

!!! tip "Textures: embedded vs. reference"
    Both texture modes resolve with no extra argument: an **embedded** `.ssab` (built with
    `ssconvert -e`) carries its images, and a **reference** `.ssab` points at sibling files that
    `loadAsset` resolves from the key's own folder. See [Preparing Assets](conversion.md).

Sub-frame interpolation is **on by default**, so motion stays smooth regardless of frame rate.

## Next steps

- Control playback, switch animations, and react to events → [Playback & Events](playback.md).
- Using the [Flame](https://flame-engine.org/) game engine → [Flame Integration](flame.md).
