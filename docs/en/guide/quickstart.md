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
    - assets/spritestudio/Ringo/
```

## 2. Load and play

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

## What you can pass it

| Parameter | Purpose |
|---|---|
| `animation` | Which animation to select. Omit it for the pack's first — an unselected pack draws an empty box, which is what a failed load looks like too. Change it and the same player switches; while `playing`, the new animation starts from its first frame. |
| `transition` | How long a change of `animation` crossfades for; `Duration.zero` (the default) switches at once. See [Motion Blending](motion-blending.md#crossfade). |
| `width` / `height` | The box to draw in. Omit them and it takes the animation's authored canvas as its size, shrunk to the constraints with its aspect kept — the way `Image` sizes from its picture. |
| `fit` / `alignment` | How the canvas is fitted into the box, and which point of it lands where: `BoxFit.contain` (the default), `cover` or `none`, and an `Alignment`. `none` draws at 1:1 with the origin at the box centre. |
| `frame` | A box to fit instead of the authored canvas, in player-local pixels — for an animation that runs off its canvas. |
| `loopCount` | `-1` loops forever; `n > 0` plays *n* times. See [Playback & Events](playback.md). |
| `playing` | On by default. A state, not a start-up flag: off holds the playhead where it stands, and on carries on from there. Off from the first build leaves the first frame posed, the way a `<video>` without `autoplay` shows a poster. |
| `speedScale` | Playback rate as a multiple of the authored one. |
| `flipX` / `flipY` | Mirror the drawn animation. |
| `offset` / `scale` | Shift the drawn animation after the fit, and multiply the fit's scale. |
| `placeholder` | Shown until the first frame is drawable. Worth setting: until then there is nothing to draw, and an empty box looks exactly like a broken pack. |
| `onLoaded` | Called with the player once the first frame can be drawn — the pack loaded, the animation selected and, while `playing`, started. `onError`'s counterpart, and where to make the calls the parameters do not cover: part overrides, tracks and texture replacement all need the pack. |
| `onError` | Called when the load fails, instead of the error reaching the zone unhandled. |
| `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | Playback started / every loop has played / a loop boundary was crossed. The start the widget issues after the load counts, and comes before `onLoaded`. |
| `onUserData` / `onSignal` / `onAudio` | A user-data, signal or audio key was crossed. Playing the sound is the app's job. See [Playback & Events](playback.md). |
| `children` | Widgets laid over the animation, each covering its box. A `SpriteStudioPartAnchor` here follows a part with no `player`, and any widget reaches the player through `SpriteStudioAnimation.playerOf(context)`. See [Part Following](part-following.md). |
| `onPlayerCreated` | Hands you the player as soon as it exists, before the pack loads, for settings that can go on ahead of it. Do not dispose it — the widget does. |
| `bundle` / `backend` | Which `AssetBundle` to read from, and which render backend to draw with: `SpriteStudioBackend.auto` (the default) and `.gpu` draw with flutter_gpu where the run has it (Impeller, with `--enable-flutter-gpu`) and with Canvas otherwise; `.canvas` forces Canvas. See [Limitations & Scope](../limitations.md#rendering). |

Changing `assetKey`, `bundle` or `backend` builds a new player. Every other
parameter reaches the player only when it changes, so what you set on the player
through `onPlayerCreated` stands until the matching parameter changes. Each event
parameter takes one callback, and supplying one replaces what `onPlayerCreated`
put on the player for that event.

That is enough to drive the animation from your own state. A one-shot that hands
back to a loop is two parameters and a callback:

```dart
SpriteStudioAnimation.asset(
  'assets/hero/Hero.ssab',
  animation: _attacking ? 'attack' : 'idle',
  loopCount: _attacking ? 1 : -1,
  onAnimationFinished: () => setState(() => _attacking = false),
)
```

## Owning the player yourself

`SpriteStudioAnimation` builds a player because most screens do not want one.
When yours does — to drive the clock from somewhere else — build a
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
    await _player.loadAsset('assets/spritestudio/Ringo/Ringo.ssab');
    if (!mounted) return;
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

`SpriteStudioAnimation` will hand you its own player through `onLoaded:`
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
