# Part Following

Part following makes an ordinary Flutter widget (a weapon, an effect, a hit marker, a health bar)
follow a specified part every frame — its **position, rotation and scale**. The player neither
creates nor disposes that widget; it only supplies the pose (constraint style), and you own the
child's lifecycle exactly as you own any other widget in your tree.

`SpriteStudioPartAnchor` reads the part's pose and wraps its child in a `Transform`.

```dart
Stack(
  fit: StackFit.expand,
  children: [
    SpriteStudioView(player: _player),
    Positioned.fill(
      child: SpriteStudioPartAnchor(
        player: _player,
        partName: 'FrontHand',
        child: const Icon(Icons.star),
      ),
    ),
  ],
)
```

!!! warning "Put the anchor in the same coordinate space as the view"
    The view centres the animation's world origin inside **its own box**, and the anchor applies the matching centring from **its own constraints**.
    The two agree only when the anchor covers the view's exact box.
    So make it a `Positioned.fill` sibling of the `SpriteStudioView` inside one `Stack`, and apply any nudge or scale to that `Stack` as a whole so both move together.
    Given a different box, the child lands off the part by exactly half the difference. On an
    unbounded axis the anchor has no box to centre in and falls back to `0`.

## Properties

| Property | Description |
|---|---|
| **`player`** | The player whose part poses this anchor follows (required) |
| **`partName`** | The name of the part to follow (the `PartData` name in the `.ssab`). An unknown name — or one absent from the current animation — simply draws nothing until it resolves |
| **`child`** | The widget stuck to the part. Its **top-left origin** is pinned to the part's origin |
| **`onHidden`** | Behaviour on frames where the part is hidden. `hideChild` (default) / `followAlways` |
| **`filterQuality`** | Optional `Transform.filterQuality` — e.g. `FilterQuality.low` to smooth a rotated or scaled child. Null keeps Flutter's nearest-neighbour default |

### Behaviour on hidden frames (`SpriteStudioAnchorHidden`)

| Value | Behaviour |
|---|---|
| `hideChild` (default) | Stop drawing the child while the part is hidden (ForUnity's `Deactivate`, ForGodot's `HIDE_TARGET`) |
| `followAlways` | Keep following the part's pose regardless of its hide flag, so the child stays visible (ForUnity's `FollowAlways`, ForGodot's `FOLLOW_ALWAYS`) |

"Hidden" here is the keyframe `hide` composed with any visibility override — the same value
[Part Overrides](part-overrides.md) writes.

!!! tip "Choosing the anchor point"
    The child's top-left is what lands on the part. To attach a different point of it, wrap the child.
    `FractionalTranslation(translation: Offset(-0.5, -0.5), child: ...)` centres the child on the part instead.

## Reading a pose without the widget

The anchor is a thin wrapper over a read API on `SpriteStudioPlayer`, so you can follow a part by
hand — from a Flame component, a `CustomPainter`, or your own layout code.

```dart
// Resolve the name once; part indices are stable within one .ssab.
final hand = _player.partIndexOf('FrontHand');

// The part's current-frame pose, in player-local (animation) space.
final Matrix4? pose = _player.partTransformOf(hand);
if (pose != null && !_player.isPartHiddenOf(hand)) {
  final x = pose.storage[12];
  final y = pose.storage[13];
  // ... spawn a projectile at (x, y), place your own component, etc.
}
```

| Method | Description |
|---|---|
| `partIndexOf(name)` | Part index, or `-1` if the pack has no such part |
| `partNames` | Part-name list and name↔index lookup (`PartNameTable`) |
| `partTransform(name)` | The part's transform for the current frame as a `Matrix4?` (player-local). Null before `load()` or for an unknown part |
| `partTransformOf(index)` | Index form of `partTransform` (skips the name lookup) |
| `isPartHidden(name)` | Whether the part is hidden on the current frame. `false` before `load()` or for an unknown part |
| `isPartHiddenOf(index)` | Index form of `isPartHidden` |

!!! tip "One-shot reads need no anchor"
    When you only want the part's position at a single moment — a projectile spawn point, for example — rather than continuous following, calling `partTransform()` directly is simpler than mounting a `SpriteStudioPartAnchor`.

### What the matrix carries

The returned `Matrix4` holds **only the 2D affine terms** (`m0, m1, m4, m5, m12, m13`) over an
identity Z/W row, so a stray Z scale or perspective term can never leak into a `Transform`. Position,
rotation, scale and skew all ride in those six terms — hand the matrix straight to a `Transform`
widget. The translation is at `storage[12]` / `storage[13]`.

The Y-Down flip is **already applied by the runtime**, so never flip again on your side.

!!! note "The same reads exist on the low-level API"
    The drawing engine beneath `SpriteStudioPlayer` (L3) exposes the same two reads, addressed by index only and under different names —
    `SpriteStudioInternalPlayer.partWorldMatrix(index)` and `partHidden(index)` (L2).
    Reach for those when driving the player headless or from your own drawing adapter (see [Architecture](../contributing/architecture.md) for the layering).

## Timing and accuracy

The reads re-sample **the same frame the paint path draws** — fractional when sub-frame sampling is
on, floored otherwise — so the pose always matches the image on screen within one frame. No manual
ordering against the draw is needed.

Unlike the part overrides, these are **pure reads and notify no listeners** (nothing changed). Drive
them from a listener on the player so you re-read right after each advance, when the frame's
transforms are final. `SpriteStudioPartAnchor` does exactly this internally, so it rebuilds on the
same notification the view repaints on and lands on the same frame.

Querying a pose before `load()` completes is **not an error**: like the overrides, these reads return
`null` / `false` rather than throwing, so a UI that runs while the pack is still loading needs no
guard.

## Notes

- **An unknown part name draws nothing, whatever `onHidden` says.** `hideChild` / `followAlways`
  only decide what happens to a part that exists and is hidden this frame.
- A part that is **absent from the current frame** reads as *not* hidden — its world transform is
  still valid — matching the sibling players' followers.
- Part names resolve against the animation the player itself is running. **Parts inside an Instance
  part (the child animation) cannot be followed**, because the child runs as its own player. The
  Instance part itself can be followed.
- If several parts share a name, the **first** one is used (SpriteStudio 7 does not guarantee unique
  part names).
- Names are re-resolved on every read, so **switching animation or loading another `.ssab` needs no
  re-registration** — the anchor picks the part up again as soon as the name resolves.
- Following transfers the **spatial transform only, not draw order**. The child paints above the
  whole animation; it cannot be interleaved between the character's own parts.
- The anchor assumes the view **draws unscaled**. Scale/`BoxFit` placement is not implemented on the
  view yet; when it lands, the anchor will need the same fit applied.
- **Ownership is yours.** The anchor never creates or disposes the child or the player — it only
  reads a pose and applies it.

## Using it from Flame

`ssplayer_flame` adds no API of its own, and `SpriteStudioPartAnchor` is a Widget, so it has no place
inside a Flame component tree. Read the pose from the player the component exposes and drive your own
component with it.

```dart
final player = component.player!;
final pose = player.partTransform('FrontHand');
if (pose != null && !player.isPartHidden('FrontHand')) {
  marker.position = Vector2(pose.storage[12], pose.storage[13]);
}
```

The pose is in **player-local (animation) space**, so map it into your component's own space the same
way you positioned the `SpriteStudioComponent` itself.

## See also

- [Part Overrides](part-overrides.md) — write the other direction: force a part's colour / cell /
  visibility
- [Playback & Events](playback.md) — transport and event callbacks
- [Limitations & Scope](../limitations.md) — the current following constraints in one place
