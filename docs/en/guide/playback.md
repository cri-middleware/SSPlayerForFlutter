# ▶️ Playback & Events

`SpriteStudioPlayer` exposes an intuitive transport plus event callbacks, so it drops straight into
your app logic. This page covers the `SpriteStudioAnimation` widget's parameters, controlling playback, switching animations, and reacting to events.

The snippets use `_player`, a `SpriteStudioPlayer`: one you own
([below](#owning-the-player-yourself)), or the one `SpriteStudioAnimation` hands you
through `onLoaded`.

## Widget parameters

| Parameter | Purpose |
|---|---|
| `animation` | Which animation to select. Omit it for the pack's first — an unselected pack draws an empty box, which is what a failed load looks like too. Change it and the same player switches; while `playing`, the new animation starts from its first frame. |
| `transition` | How long a change of `animation` crossfades for; `Duration.zero` (the default) switches at once. See [Motion Blending](motion-blending.md#crossfade). |
| `width` / `height` | The box to draw in. Omit them and it takes the animation's authored canvas as its size, shrunk to the constraints with its aspect kept — the way `Image` sizes from its picture. |
| `fit` / `alignment` | How the canvas is fitted into the box, and which point of it lands where: `BoxFit.contain` (the default), `cover` or `none`, and an `Alignment`. `none` draws at 1:1 with the origin at the box centre. |
| `frame` | A box to fit instead of the authored canvas, in player-local pixels — for an animation that runs off its canvas. |
| `loopCount` | `-1` loops forever; `n > 0` plays *n* times. See [Playback control](#playback-control). |
| `playing` | On by default. A state, not a start-up flag: off holds the playhead where it stands, and on carries on from there. Off from the first build leaves the first frame posed, the way a `<video>` without `autoplay` shows a poster. |
| `speedScale` | Playback rate as a multiple of the authored one. |
| `flipX` / `flipY` | Mirror the drawn animation. |
| `offset` / `scale` | Shift the drawn animation after the fit, and multiply the fit's scale. |
| `placeholder` | Shown until the first frame is drawable. Worth setting: until then there is nothing to draw, and an empty box looks exactly like a broken pack. |
| `onLoaded` | Called with the player once the first frame can be drawn — the pack loaded, the animation selected and, while `playing`, started. `onError`'s counterpart, and where to make the calls the parameters do not cover: part overrides, tracks and texture replacement all need the pack. |
| `onError` | Called when the load fails, instead of the error reaching the zone unhandled. |
| `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | Playback started / every loop has played / a loop boundary was crossed. The start the widget issues after the load counts, and comes before `onLoaded`. |
| `onUserData` / `onSignal` / `onAudio` | A user-data, signal or audio key was crossed. Playing the sound is the app's job. See [Events](#events). |
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
[`SpriteStudioPlayer`](#playback-control) and hand it to `SpriteStudioView`:

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

## Playback control

```dart
_player.setAnimation('attack'); // select an animation (waits on the first frame)
_player.play();                    // start from the beginning
```

| Member | Kind | Description |
|---|---|---|
| `play()` | method | Start the set-up animation from the beginning |
| `pause()` / `resume()` | method | Pause (holds the current frame; independent instances and effects keep running) / lift the hold and carry on in place. Both are idempotent, and `resume()` is a **no-op on a stopped or finished animation** — starting one is `play()`'s job, and it rewinds |
| `togglePlayPause()` | method | One tap for a play/pause button: pause while advancing, resume while held, and `play()` from the head when stopped or finished |
| `stop()` | method | Stop playback. The playhead **stays where it stands** — nothing rewinds, so the frame it stopped on keeps drawing. `play()` is what returns to the head |
| `seek(double frame)` | method | Jump to a frame (fractional allowed). Independent instances / effects do not follow |
| `loopCount` | `int` | Loop count — `-1` (or `0`) forever, `n` plays *n* times |
| `speedScale` | `double` | Playback speed multiplier. `0` and negatives **stop** the playhead rather than reversing it — reversing is `setPlaybackDirection`'s business |
| `frameRate` | `int` | Advance rate in fps — the pack's authored rate unless you override it |
| `setPlaybackDirection(dir, style)` | method | Direction (`SsPlaybackDirection.forward` / `.backward`) and end-of-range behaviour (`SsPlaybackStyle.normal` / `.pingPong`) |
| `playbackDirection` / `playbackStyle` | read | What the two above are currently set to |
| `setAnimationSection(start, end)` | method | Restrict playback to a frame range of the **current** animation. An end before the start returns `false` and changes nothing |
| `setAnimationSectionByLabel(start, end, {startOffset, endOffset})` | method | The same, with the ends named by labels of the current animation |
| `frameSkipEnabled` | `bool` | ON (default) keeps playback on the wall clock by dropping frames; OFF advances exactly one frame per tick |
| `subFrameEnabled` | `bool` | Sub-frame interpolation (on by default) |
| `isPlaying` / `isPausing` | `bool` (read) | `isPlaying` is true from `play()` until the animation stops or finishes, **a pause included**; `isPausing` is true only while held. "Advancing now" is `isPlaying && !isPausing` |
| `isFinished` / `justLooped` | `bool` (read) | Every loop has played (sticky) / the last advance crossed a loop boundary (edge) |
| `isPlayingForward` | `bool` (read) | Which way the playhead is **actually** travelling — not `playbackDirection`, which is only the configured heading. A ping-pong return leg reads `false` while that still reads `forward`. **Gate audio on it** |
| `frameNo` / `currentAnimation` | read | Current frame / the animation track 0 plays — after a [crossfade](motion-blending.md), the incoming one from the call on |
| `startFrame` / `endFrame` / `totalFrames` | `int` (read) | The frame range being played, and its length — feed `totalFrames` to a scrubber |

### What survives `setAnimation`

Setting up an animation resets two things in the runtime: the section and the loop count. The speed, the
frame-rate override, the frame skip and the direction and style survive there, and the player puts the
loop count back, so the settings that are **your** decision stay and only the one that describes
**the animation** resets:

| Kept | Reset |
|---|---|
| `loopCount`, `speedScale`, `frameSkipEnabled`, `frameRate`, `playbackDirection` / `playbackStyle`, `subFrameEnabled` | the animation section |

A section is a range of frame numbers, and means nothing against a different animation — carrying one over
would silently outrank the animation you just selected. Set it again after each setup if you need it, and
note that a section set *before* `setAnimation` is wiped by it.

A `frameRate` override
outlives a transition too — hand it `0` to clear it and go back to whatever each animation was authored at.
To scale playback without replacing the authored rate, use `speedScale` rather than `frameRate`.

### Playing backwards, and round trips

```dart
_player.setPlaybackDirection(SsPlaybackDirection.backward, SsPlaybackStyle.pingPong);
```

With `pingPong` one loop is a **full round trip**, so `loopCount = 1` plays there and back once.
`speedScale` also accepts a negative multiplier, but that stops the playhead rather than turning it
around — `playbackDirection` is the one that reverses, and it survives a setup.

### Playing part of an animation

```dart
_player.setAnimation('attack');
_player.setAnimationSection(10, 24);   // after setup — setup would wipe it
_player..loopCount = -1..play();            // loops within 10..24
```

`startFrame` / `endFrame` / `totalFrames` report the sectioned range, so a scrubber bound to them follows
along.

An end outside the animation (`-1`, say) is the animation's edge on that side. With both ends inside it, an end
before the start is refused: `setAnimationSection` returns `false`, says so once in the log, and leaves the
section and the playhead as they were.

The ends can be labels instead, each with an offset in frames:

```dart
_player.setAnimation('attack');
_player.setAnimationSectionByLabel('windup', 'hit', endOffset: -1); // up to the frame before `hit`
```

`_start` and `_end` name the animation's first and last frame, as they do in SpriteStudio. A label the
animation does not have, or labels and offsets that land on a section `setAnimationSection` refuses, return
`false`, say so once in the log, and leave the section as it was.

## Flip, offset and scale

Mirror, shift or scale **what the player draws**, leaving the widget tree alone.

| Property | Type | Description |
|---|---|---|
| `flipX` | `bool` | Mirror the drawn animation horizontally, in the manner of Flutter's own `Transform.flip(flipX: …)` |
| `flipY` | `bool` | Mirror it vertically |
| `offset` | `Offset` | Shift it by this many logical pixels. Applied **after** the flip, so the offset is not itself mirrored |
| `scale` | `double` | Scale the drawn animation about its origin. Under a fitted view it multiplies the fit's scale rather than replacing it |
| `rootTransform` | `SsRootTransform` | All four as one value — assign it to change several at once and repaint once |

```dart
// Face the way we are walking.
_player.flipX = velocity.dx < 0;
```

They apply to the whole tree including instance children, survive `reload()`, and notify listeners, so
the view repaints on its own.

> [!QUESTION] Why not just wrap the view in `Transform.flip`?
> Because that mirrors the **whole** wrapped subtree, which becomes a problem as soon as
> [part following](part-following.md) is in play.
>
> | Approach | Result |
> |---|---|
> | Wrap the whole `Stack` in `Transform.flip` | The anchored widgets — icons, text — come out mirrored too |
> | Wrap only the `SpriteStudioView` | The anchors are left behind at the unflipped positions |
> | **`player.flipX`** | The animation mirrors, the anchors travel with it, and their own children can stay upright |
>
> Without part following, wrapping in `Transform.flip` is perfectly sufficient.
>
> See [Part Following](part-following.md) for what a flipped player does to a follower.

> [!NOTE] On the Flame adapter
> `SpriteStudioComponent` is a Flame `PositionComponent` and already has `flipHorizontally()` and
> friends, so it takes no flip parameter of its own.

## Switching animations

`setAnimation(name)` selects an animation and **waits on its first frame** — it does not start
playback.

It resets the runtime's transport, but `SpriteStudioPlayer` remembers the `loopCount` / `speedScale` you set and
**re-applies them for you**, so you do not have to set them again on every switch (see
"What survives `setAnimation`" above).

```dart
_player.setAnimation('walk');
_player..loopCount = 3..speedScale = 1.5..play();
```

Selecting the animation that is already selected does nothing — the playhead, the section and the
part overrides stay — so a state machine may assert its current clip every frame; to restart it, call
`play()`. `setAnimation` returns `false`, and logs once, when the pack has no animation of that name.

Use `animationNames` (or `SsAnimeInfo(bytes).animationNames`) to discover the available names.

To fade from one animation to the next instead of cutting, or to lay one over another, see
[Motion Blending](motion-blending.md). Note that `setAnimation` folds that stack back to track 0 alone.

## Driving the clock

- **vsync mode** — construct with `SpriteStudioPlayer(vsync: this)` and the player runs its own
  `Ticker`. This is the widget path ([Quick Start](quickstart.md)).
- **Externally clocked** — omit `vsync` and call `advance(delta)` yourself each tick. This is how the
  [Flame](flame.md) adapter drives it.

## Events

Assign callbacks on the player. They fire as playback progresses:

| Callback | Signature | Fires when |
|---|---|---|
| `onUserData` | `void Function(SsUserData)` | A **User Data** marker authored on the timeline is crossed. Once per marker |
| `onSignal` | `void Function(SsSignal)` | An active **Signal** keyframe is crossed. Inactive signals are not surfaced |
| `onAudio` | `void Function(SsAudioEvent)` | An **Audio** trigger is crossed. The player never produces sound itself — see below |
| `onAnimationStarted` | `VoidCallback` | Playback **starts** — a `play()`, including one an autoplay wrapper or a host state machine issued. A `resume()` does not fire it: lifting a pause carries on, it does not start |
| `onAnimationFinished` | `VoidCallback` | Every configured loop has played. **Never** fires while `loopCount` is infinite, and not on `stop()` |
| `onAnimationLooped` | `VoidCallback` | Playback crosses a loop boundary (the final cycle fires `onAnimationFinished` instead) |
| `onEvents` | `void Function(List<int> passedEventIndices)` | Low-level escape hatch: the raw event indices passed this frame, before decoding |

Prefer the decoded `onUserData` / `onSignal` / `onAudio` callbacks — `onEvents` hands you indices and
leaves the decoding to you. Each index addresses the event table of **the animation that fired it**,
which after a [crossfade](motion-blending.md) on track 0 is no longer the one `setAnimation` chose; the
decoded callbacks look each one up in the right table. The decode is skipped entirely when none of the
three decoded callbacks is set, so registering only `onEvents` costs nothing extra.

All three decoded events carry `partIndex`, `partName`, `frameNo` and `source`. `frameNo` is the frame
the key is **authored** on, which is not necessarily the frame it was noticed on — one `advance` can step
across several frames and fires every key in between, so `frameNo` is not the player's current frame.
`source` is the handle of the [source](motion-blending.md#sources) that fired it. By default only track
0's animation fires, so it is `trackMainSource(0)` unless you let an overlay or the outgoing side of a
crossfade fire too.

### Example: react to a user-data marker

```dart
_player.onUserData = (userData) {
  // Only the fields authored in SpriteStudio (integer, rect, point, string) are non-null.
  if (userData.string == 'footstep') _audio.play();
};
```

### Example: react to a signal

```dart
_player.onSignal = (signal) {
  if (signal.commandId != 'spawn') return;
  for (final p in signal.params) {           // in authored order
    if (p.paramId == 'count' && p.value is int) _spawn(p.value as int);
  }
};
```

### Example: play an audio trigger

SpriteStudio audio is trigger-only: the player hands you the sound to play and stays out of your
audio stack. Resolve the hash to a pack-relative path and feed it to whatever you use.

**Gate it on `isPlayingForward`.** SpriteStudio has no reverse audio, so a key crossed on a backward
leg is not meant to sound. The players that own an audio backend apply that test themselves; this one
reports rather than plays, so `onAudio` fires either way and the test is yours.

```dart
_player.onAudio = (audio) {
  if (!_player.isPlayingForward) return; // no reverse audio
  final path = _player.soundFilePath(audio.soundNameHash); // e.g. "sound/foo.mp3"
  if (path != null) _audio.play(path, times: audio.loopNum);
};
```

`isPlayingForward` is the *instantaneous* heading, which is why it and not `playbackDirection` is the
right test: under `SsPlaybackStyle.pingPong` the return leg runs backward while `playbackDirection`
still reads `forward`. It is `true` before anything has played, so the gate does not silence the first
frame.

**Nor for where a seek landed.** A `seek` makes the next update report the audio keys of the frame
it landed on: at once while playing, and on the first tick after `resume()` for a seek made while
paused. The playhead crossed none of them, so to keep a seek silent, skip the keys on the landing
frame that the first update after it reports. The first frame after `play()` is meant to sound.

### Example: chain animations

```dart
_player.onAnimationFinished = () {
  if (_player.currentAnimation == 'attack') {
    _player.setAnimation('idle');
    _player..loopCount = -1..play();
  }
};
```

## Attaching a widget to a part

To make a widget follow a named part's position, rotation and scale every frame — or just to read a
part's pose once — see [Part Following](part-following.md).

## Overriding individual parts

To give one part a different colour / cell — or hide it — in a way that beats the keyframes, see
[Part Overrides](part-overrides.md).

## Live updates during development

To hot-swap a re-exported `.ssab` without losing transport state, see
[Live Reload](live-reload.md).
