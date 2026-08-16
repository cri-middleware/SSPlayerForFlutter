# 🔥 Flame Integration

The [`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame)
package adds `SpriteStudioComponent` — a `PositionComponent` that plays a SpriteStudio animation
inside a `FlameGame`. It owns an **externally-clocked** `SpriteStudioPlayer` (no `Ticker`): Flame's
game loop drives time (`update(dt)` → `advance`, `render` → paint). It is a separate package so the
core never pulls in `flame`, and it re-exports the whole `ssplayer_flutter` API.

The [live Flame demo](../demo/flame/) is `examples/flame` built for the web — the code on this
page, running.

## Add the dependency

Add `ssplayer_flame` from the same GitHub Releases bundle described in [Installation](install.md):

```yaml
dependencies:
  ssplayer_flame:
    path: vendor/SSPlayerForFlutter/packages/ssplayer_flame
```

## Add a component to your game

```dart
class RingoGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    add(
      SpriteStudioComponent.asset(
        // Sibling reference textures resolve from the key's own folder
        // (embedded packs work the same way).
        'assets/overall/Basic.ssab',
        position: Vector2(200, 200),
        anchor: Anchor.center,
        loop: -1,
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
| `loop` | `-1` | Loop count (`-1` forever, `n` plays *n* times) |
| `speed` | `1.0` | Playback speed multiplier |
| `subFrame` | `true` | Sub-frame interpolation |
| `autoStart` | `true` | Play as soon as the resource loads (set `false` to drive it yourself) |
| `onEvents` / `onComplete` / `onLoop` | `null` | Forwarded to the player's callbacks (see [Playback & Events](playback.md)) |

Standard `PositionComponent` fields (`position`, `size`, `scale`, `angle`, `anchor`, `priority`) work
as usual.

## Controlling playback

After `onLoad`, reach the full L3 transport through `component.player`:

```dart
component.player?..setupAnimation('attack')..play();
```

The clock is Flame's, so there is no `Ticker` — transport state still lives on the player.

See the runnable [`examples/flame/`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame)
app for a complete `FlameGame`.
