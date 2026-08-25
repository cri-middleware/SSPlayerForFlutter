# 🎯 Part Following

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
| **`onHidden`** | Behaviour on frames where the part is hidden. `followAlways` (default) / `hideChild` |
| **`onMirrored`** | What a flipped player does to the child. `follow` (default) / `cancel` |
| **`filterQuality`** | Optional `Transform.filterQuality` — e.g. `FilterQuality.low` to smooth a rotated or scaled child. Null keeps Flutter's nearest-neighbour default |

### Behaviour on hidden frames (`SpriteStudioAnchorHidden`)

| Value | Behaviour |
|---|---|
| `followAlways` (default) | Keep following the part's pose regardless of its hide flag, so the child stays visible (ForUnity's `FollowAlways`, ForGodot's `FOLLOW_ALWAYS`, ForWeb's `onHide: 'follow'`) |
| `hideChild` | Stop drawing the child while the part is hidden (ForUnity's `Deactivate`, ForGodot's `HIDE_TARGET`, ForWeb's `onHide: 'hide'`) |

"Hidden" here is the keyframe `hide` composed with any visibility override — the same value
[Part Overrides](part-overrides.md) writes.

### Behaviour under a flipped player (`SpriteStudioAnchorMirror`)

A player's [`flipX` / `flipY`](playback.md) reaches the anchor as well, so a character can turn around
without its followers coming off their parts. All this setting decides is whether the **child itself**
is mirrored along with them.

| Value | Behaviour |
|---|---|
| `follow` (default) | Apply the part's pose as-is, so a flipped player mirrors the child too |
| `cancel` | Follow the mirrored **position**, but keep the child's own orientation |

Pick `follow` for anything that should turn around with the character — a weapon, an effect — and
`cancel` for anything that stops being readable when mirrored: text, icons, a health bar.

```dart
SpriteStudioPartAnchor(
  player: _player,
  partName: 'Head',
  onMirrored: SpriteStudioAnchorMirror.cancel, // the name plate stays readable
  child: const Text('Ringo'),
)
```

!!! info "`cancel` is exact, and leaves no residue"
    It undoes a ±1 diagonal this library applied itself, so the position stays exact and no stray
    rotation is left behind. ForUnity and ForGodot carry the pose as rotation + scale, where the
    equivalent setting (`Drive Scale` / `update_scale` off) leaves an extra 180° on a horizontal flip;
    that does not happen here.

    Either way, mirroring the **artist** authored on the part (a negative scale on it or an ancestor)
    always reaches the child — that one is part of the animation. `cancel` only takes back the
    player's own `flipX` / `flipY`.

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

The player's [`flipX` / `flipY` / `offset`](playback.md) are applied too: this is the pose **as drawn**,
which is why a follower stays on its part across a flip.

### The matrix can be a reflection

The returned matrix is sometimes a **reflection** — a matrix whose determinant is negative. Two things
cause that, and they **compose**:

- A negative scale the artist authored on the part or an ancestor — ordinary in real data
- The player's [`flipX` / `flipY`](playback.md)

Two mirrorings **cancel**, returning the determinant to positive. So neither "I flipped, therefore it is
mirrored" nor "I did not flip, therefore it is not" holds. When you need the sign, read it off the
matrix you are actually holding, with `determinant()`.

!!! tip "This port never decomposes, so it stays exact"
    The pose reaches a `Transform` widget as a whole `Matrix4`, so a reflection rides along without
    loss. ForUnity and ForGodot decompose into a `Quaternion` / `Transform2D` and inherit the caveats
    that come with it (`Matrix4x4.rotation` is undefined on a mirrored matrix; a horizontal flip leaves
    an extra 180° in the extracted rotation) — none of which applies here.

    Decompose it **yourself**, though, and you take those caveats on: check the sign of
    `determinant()` before reading a rotation out of the matrix. The translation
    (`storage[12]` / `storage[13]`) is exact whatever the sign.

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

- **An unknown part name draws nothing, whatever `onHidden` says.** `followAlways` / `hideChild`
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
