# ▶️ Playback & Events

`SpriteStudioPlayer` exposes an intuitive transport plus event callbacks, so it drops straight into
your app logic. This page covers controlling playback, switching animations, and reacting to events.

## Playback control

```dart
_player.setupAnimation('attack'); // select an animation (waits on the first frame)
_player.play();                    // start from the beginning
```

| Member | Kind | Description |
|---|---|---|
| `play()` | method | Start the set-up animation from the beginning |
| `pause()` / `resume()` | method | Pause (holds the current frame) / resume |
| `togglePlayPause()` | method | Pause if playing, resume if paused |
| `stop()` | method | Stop playback. The playhead **stays where it stands** — nothing rewinds, so the frame it stopped on keeps drawing. `play()` is what returns to the head |
| `seek(double frame)` | method | Jump to a frame (fractional allowed). Independent instances / effects do not follow |
| `loop` | `set int` | Loop count — `-1` (or `0`) forever, `n` plays *n* times |
| `speed` | `set double` | Playback speed multiplier (negative reverses) |
| `frameRate` | `int` | Advance rate in fps — the pack's authored rate unless you override it |
| `setPlaybackDirection(dir, style)` | method | Direction (`SsPlaybackDirection.forward` / `.backward`) and end-of-range behaviour (`SsPlaybackStyle.normal` / `.pingPong`) |
| `playbackDirection` / `playbackStyle` | read | What the two above are currently set to |
| `setAnimationSection(start, end)` | method | Restrict playback to a frame range of the **current** animation |
| `skipFrames` | `bool` | ON (default) keeps playback on the wall clock by dropping frames; OFF advances exactly one frame per tick |
| `subFrame` | `bool` | Sub-frame interpolation (on by default) |
| `isPlaying` / `isPaused` | `bool` (read) | Current transport state |
| `isFinished` / `isLooped` | `bool` (read) | Every loop has played (sticky) / the last advance crossed a loop boundary (edge) |
| `frameNo` / `currentAnimation` | read | Current frame / active animation name |
| `startFrame` / `endFrame` / `totalFrames` | `int` (read) | The frame range being played, and its length — feed `totalFrames` to a scrubber |

### What survives `setupAnimation`

Setting up an animation resets the Brain's whole transport. The player puts back the settings that are
**your** decision, and lets the ones that describe **the animation** reset:

| Re-applied for you | Left to reset |
|---|---|
| `loop`, `speed`, `skipFrames`, `playbackDirection` / `playbackStyle`, `subFrame` | `frameRate`, the animation section |

`frameRate` is authored in the pack, and a section is a range of frame numbers that means nothing in a
different animation — re-applying either would silently outrank the animation you just selected. Set them
again after each setup if you need them, and note that a section set *before* `setupAnimation` is wiped by
it. To scale playback without touching the authored rate, use `speed` rather than `frameRate`.

### Playing backwards, and round trips

```dart
_player.setPlaybackDirection(SsPlaybackDirection.backward, SsPlaybackStyle.pingPong);
```

With `pingPong` one loop is a **full round trip**, so `loop = 1` plays there and back once. `speed` also
accepts a negative multiplier, but `playbackDirection` is the one that survives a setup.

### Playing part of an animation

```dart
_player.setupAnimation('attack');
_player.setAnimationSection(10, 24);   // after setup — setup would wipe it
_player..loop = -1..play();            // loops within 10..24
```

`startFrame` / `endFrame` / `totalFrames` report the sectioned range, so a scrubber bound to them follows
along.

## Flip and offset

Mirror or shift **what the player draws**, leaving the widget tree alone.

| Property | Type | Description |
|---|---|---|
| `flipX` | `bool` | Mirror the drawn animation horizontally, in the manner of Flutter's own `Transform.flip(flipX: …)` |
| `flipY` | `bool` | Mirror it vertically |
| `offset` | `Offset` | Shift it by this many logical pixels. Applied **after** the flip, so the offset is not itself mirrored |
| `rootTransform` | `SsRootTransform` | All three as one value — assign it to change several at once and repaint once |

```dart
// Face the way we are walking.
_player.flipX = velocity.dx < 0;
```

They apply to the whole tree including instance children, survive `reload()`, and notify listeners, so
the view repaints on its own.

!!! question "Why not just wrap the view in `Transform.flip`?"
    Because that mirrors the **whole** wrapped subtree, which becomes a problem as soon as
    [part tracking](part-following.md) is in play.

    | Approach | Result |
    |---|---|
    | Wrap the whole `Stack` in `Transform.flip` | The anchored widgets — icons, text — come out mirrored too |
    | Wrap only the `SpriteStudioView` | The anchors are left behind at the unflipped positions |
    | **`player.flipX`** | The animation mirrors, the anchors travel with it, and their own children can stay upright |

    Without part tracking, wrapping in `Transform.flip` is perfectly sufficient.

    See [Part Tracking](part-following.md) for what a flipped player does to a follower.

!!! note "Not on the Flame adapter"
    `SpriteStudioComponent` is a Flame `PositionComponent` and already has `flipHorizontally()` and
    friends, so the player-level flip is not exposed there.

## Switching animations

`setupAnimation(name)` selects an animation and **waits on its first frame** — it does not start
playback.

It resets the Brain's transport, but `SpriteStudioPlayer` remembers the `loop` / `speed` you set and
**re-applies them for you**, so you do not have to set them again on every switch (see
"What survives `setupAnimation`" above).

```dart
_player.setupAnimation('walk');
_player..loop = 3..speed = 1.5..play();
```

Use `getAnimations()` (or `SsAnimeInfo(bytes).animationNames`) to discover the available names.

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
| `onComplete` | `VoidCallback` | Every configured loop has played. **Never** fires while `loop` is infinite, and not on `stop()` |
| `onLoop` | `VoidCallback` | Playback crosses a loop boundary (the final cycle fires `onComplete` instead) |
| `onEvents` | `void Function(List<int> passedEventIndices)` | Low-level escape hatch: the raw event indices passed this frame, before decoding |

Prefer the decoded `onUserData` / `onSignal` / `onAudio` callbacks — `onEvents` hands you indices into
the current animation's event table and leaves the decoding to you. The decode is skipped entirely
when none of the three decoded callbacks is set, so registering only `onEvents` costs nothing extra.

### Example: react to a user-data marker

```dart
_player.onUserData = (userData) {
  // Only the fields authored in SpriteStudio are non-null.
  if (userData.string == 'footstep') _audio.play();
};
```

### Example: play an audio trigger

SpriteStudio audio is trigger-only: the player hands you the sound to play and stays out of your
audio stack. Resolve the hash to a pack-relative path and feed it to whatever you use.

```dart
_player.onAudio = (audio) {
  final path = _player.soundFilePath(audio.soundNameHash); // e.g. "sound/foo.mp3"
  if (path != null) _audio.play(path, times: audio.loopNum);
};
```

### Example: chain animations

```dart
_player.onComplete = () {
  if (_player.currentAnimation == 'attack') {
    _player.setupAnimation('idle');
    _player..loop = -1..play();
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
