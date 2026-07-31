# Playback & Events

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
| `stop()` | method | Stop playback |
| `seek(double frame)` | method | Jump to a frame (fractional allowed) |
| `loop` | `set int` | Loop count — `-1` (or `0`) forever, `n` plays *n* times |
| `speed` | `set double` | Playback speed multiplier (negative reverses) |
| `frameRate` | `int` | Advance rate in fps — the pack's authored rate unless you override it |
| `subFrame` | `bool` | Sub-frame interpolation (on by default) |
| `isPlaying` / `isPaused` | `bool` (read) | Current transport state |
| `isFinished` / `isLooped` | `bool` (read) | Every loop has played (sticky) / the last advance crossed a loop boundary (edge) |
| `frameNo` / `currentAnimation` | read | Current frame / active animation name |
| `startFrame` / `endFrame` / `totalFrames` | `int` (read) | The frame range being played, and its length — feed `totalFrames` to a scrubber |

!!! note "`frameRate` is not restored across `setupAnimation`"
    `loop` and `speed` are re-applied for you after a setup, but `frameRate` is not: the Brain
    re-reads the pack's authored fps there, and re-applying a host override on top would silently
    outrank what the animation was authored at. Set it again after each setup if you need it to
    persist — or use `speed`, which scales playback without touching the authored rate.

## Switching animations

`setupAnimation(name)` selects an animation and **waits on its first frame** — it does not start
playback, and it **resets loop / speed** to the runtime defaults.

!!! warning "Set `loop` / `speed` *after* `setupAnimation`"
    `setupAnimation` rewinds and resets the transport, so re-apply `loop` / `speed` afterward or the
    loop silently falls back to infinite.

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
