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
| `subFrame` | `bool` | Sub-frame interpolation (on by default) |
| `isPlaying` / `isPaused` | `bool` (read) | Current transport state |
| `frameNo` / `currentAnimation` | read | Current frame / active animation name |

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
| `onEvents` | `void Function(List<int> passedEventIndices)` | A frame carrying user-data / signal events is passed; you receive the event indices |
| `onComplete` | `VoidCallback` | Every configured loop has played. **Never** fires while `loop` is infinite, and not on `stop()` |
| `onLoop` | `VoidCallback` | Playback crosses a loop boundary (the final cycle fires `onComplete` instead) |

### Example: play a sound on a user-data event

```dart
_player.onEvents = (indices) {
  // Indices identify the user-data / signal keys authored in SpriteStudio for this frame.
  if (indices.contains(footstepEventIndex)) _audio.play();
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

## Overriding individual parts

To give one part a different colour / cell — or hide it — in a way that beats the keyframes, see
[Part Overrides](part-overrides.md).

## Live updates during development

To hot-swap a re-exported `.ssab` without losing transport state, see
[Live Reload](live-reload.md).
