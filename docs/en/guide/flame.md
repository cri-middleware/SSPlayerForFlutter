# 🔥 Flame Integration

The [`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame)
package adds `SpriteStudioComponent` — a `PositionComponent` that plays a SpriteStudio animation
inside a `FlameGame`. It owns an **externally-clocked** `SpriteStudioPlayer` (no `Ticker`): Flame's
game loop drives time (`update(dt)` → `advance`, `render` → paint). It is a separate package so the
core never pulls in `flame`, and it re-exports the whole `ssplayer_flutter` API.

The [live Flame demo](../demo/flame/) is `examples/flame` built for the web — the code on this
page, running.

## Add the dependency

```bash
flutter pub add flame ssplayer_flame
```

`ssplayer_flutter` and `ssruntime_dart` come with `ssplayer_flame`; the rest of the setup is on
[Installation](install.md).

## Add a component to your game

```dart
class RingoGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    add(
      SpriteStudioComponent.asset(
        // Sibling reference textures resolve from the key's own folder
        // (embedded packs work the same way).
        'assets/spritestudio/Ringo/Ringo.ssab',
        animation: 'wait1',
        position: Vector2(200, 200),
        anchor: Anchor.center,
        loopCount: -1,
      ),
    );
  }
}
```

`SpriteStudioComponent.asset(path, …)` loads the `.ssab` from the asset bundle in `onLoad` and
resolves sibling reference textures from the key's own folder. To play bytes you already hold, use the
default constructor `SpriteStudioComponent(ssab: myBytes)`.

## Key constructor options

| Option | Default | Description |
|---|---|---|
| `animation` | first in pack | Animation to select on load |
| `loopCount` | `-1` | Loop count (`-1` forever, `n` plays *n* times) |
| `speed` | `1.0` | Playback speed multiplier |
| `subFrame` | `true` | Sub-frame interpolation |
| `autoStart` | `true` | Play as soon as the resource loads (set `false` to drive it yourself) |
| `onEvents` / `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | `null` | Forwarded to the player's callbacks (see [Playback & Events](playback.md)) |

Standard `PositionComponent` fields (`position`, `size`, `scale`, `angle`, `anchor`, `priority`) work
as usual.

## A button

`SpriteStudioButtonComponent` is a `SpriteStudioComponent` that is a button: one animation shows its
states by the rule the Flutter widgets follow — labels named after the states, their fallbacks, and
`clips` to use other animations or labels (see [Buttons & UI States](buttons.md)).

```dart
add(
  SpriteStudioButtonComponent.asset(
    'assets/ui/start.ssab',
    hitParts: const ['face'],
    onReleased: startGame,
    size: Vector2(240, 120),
    position: Vector2(200, 300),
    anchor: Anchor.center,
  ),
);
```

| State | Set by |
|---|---|
| `hover` | a mouse over the button |
| `pressed` | a tap held on it |
| `disabled` | `isDisabled` |
| `focused` | `isFocused`. Flame has no focus of its own, so a menu driven by a gamepad or the keyboard marks the button it has selected |

| Option | Default | Description |
|---|---|---|
| `onPressed` / `onReleased` / `onCancelled` | `null` | A tap going down, coming up, and cancelled, as on Flame's `ButtonComponent`. A disabled button fires none |
| `hitParts` | `null` | The parts a pointer counts on, by their outlines as drawn, within the box. Null is the whole box |
| `hitOnArtwork` | `false` | With no `hitParts`, count a pointer on any part rather than on the whole box |
| `clips` | none | Per-state replacements for the labels |
| `isDisabled` / `isFocused` / `reducedMotion` | `false` | Also properties, to change at any time. Flame reads no platform setting, so `reducedMotion` is the game's own choice |

The animation is drawn about the middle of the box, so give the button a `size` that holds its artwork.
The button takes its player's playback over, which is why it has no `loopCount`, `speed` or `autoStart`.
[`examples/flame/lib/button_check.dart`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/examples/flame/lib/button_check.dart)
runs three of them, one for each way of taking a pointer.

## Controlling playback

After `onLoad`, reach the full L3 transport through `component.player`:

```dart
component.player?..setAnimation('attack')..play();
```

The clock is Flame's, so there is no `Ticker` — transport state still lives on the player.

See the runnable [`examples/flame/`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame)
app for a complete `FlameGame`.
