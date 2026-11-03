# 🎯 Part Following

Part following makes an ordinary Flutter widget (a weapon, an effect, a hit marker, a health bar)
follow a specified part every frame — its **position, rotation and scale**. The player neither
creates nor disposes that widget; it only supplies the pose, and you own the
child's lifecycle exactly as you own any other widget in your tree.

`SpriteStudioPartAnchor` reads the part's pose and wraps its child in a `Transform`.

In a `SpriteStudioAnimation`, put it in `children` and leave `player` out. The anchor finds that
widget's player, and `children` already cover the animation's exact box:

```dart
SpriteStudioAnimation.asset(
  'assets/spritestudio/Ringo/Ringo.ssab',
  children: [
    SpriteStudioPartAnchor(partName: 'apple', child: const Icon(Icons.star)),
  ],
)
```

Over a `SpriteStudioView` you build yourself, pass its player and cover the view's box:

```dart
Stack(
  fit: StackFit.expand,
  children: [
    SpriteStudioView(player: _player),
    Positioned.fill(
      child: SpriteStudioPartAnchor(
        player: _player,
        partName: partName,
        child: const Icon(Icons.star),
      ),
    ),
  ],
)
```

!!! warning "Put the anchor in the same coordinate space as the view"
    The view fits the animation into **its own box**, measured from that box's centre, and the pose the anchor reads carries the fit; the anchor applies the matching centring from **its own constraints**.
    The two agree only when the anchor covers the view's exact box.
    So make it a `Positioned.fill` sibling of the `SpriteStudioView` inside one `Stack`, and apply any nudge or scale to that `Stack` as a whole so both move together.
    Given a different box, the child lands off the part by exactly half the difference. On an
    unbounded axis the anchor has no box to centre in and falls back to `0`.

!!! warning "Mesh (skinned) parts cannot be followed directly"
    A **bone-bound mesh part** (a deforming part such as a hand or a face) has its vertices drawn by
    bone skinning, while the part's *own* transform stays at its setup node position — usually near the
    character root. So targeting such a part makes the follower snap near the root rather than onto the
    visible art.

    To follow the position of a mesh part, add a **NULL part (a bone-point / empty part)** at that spot
    in SpriteStudio and target that part's name instead. A bone (armature) or joint part works the same
    way. A *rigid* (deform-only) mesh follows correctly and needs none of this — only skinned parts
    diverge. `isPartSkinnedMesh(name)` reports whether a part is one of these so you can warn or dim it
    in a follow-target picker; it is a **hint only** and never blocks following.

## Properties

| Property | Description |
|---|---|
| **`player`** | The player whose part poses this anchor follows. Omit it in a `SpriteStudioAnimation`'s `children`, where the anchor finds that widget's |
| **`partName`** | The name of the part to follow (the `PartData` name in the `.ssab`). An unknown name — or one absent from the current animation — simply draws nothing until it resolves |
| **`child`** | The widget stuck to the part. Its **top-left origin** is pinned to the part's origin |
| **`position`** | Drive the child's position from the part. Default `true` |
| **`rotation`** | Drive the child's rotation from the part. Default `true` |
| **`scale`** | Drive the child's scale from the part. **Default `false`** — a follower is placed *at* the part, not sized by it. Only with all three on is the affine applied as-is, so the part's mirroring is reproduced exactly. The pose is skew-free either way — a follower is never sheared by the part it tracks (SpriteStudio does not propagate Skew to children) |
| **`onHidden`** | Behaviour on frames where the part is hidden. `followAlways` (default) / `hideChild` |
| **`onMirrored`** | What a flipped player does to the child, **with `scale: true`**: a mirror is a sign on the scale, so with `scale` off the child is never mirrored (it takes the mirrored angle and stays upright). `follow` (default) / `cancel` |
| **`filterQuality`** | Optional `Transform.filterQuality` — e.g. `FilterQuality.low` to smooth a rotated or scaled child. Null keeps Flutter's nearest-neighbour default |

### Behaviour on hidden frames (`SpriteStudioAnchorHidden`)

| Value | Behaviour |
|---|---|
| `followAlways` (default) | Keep following the part's pose regardless of its hide flag, so the child stays visible |
| `hideChild` | Stop drawing the child while the part is hidden |

"Hidden" here is the keyframe `hide` composed with any visibility override — the same value
[Part Overrides](part-overrides.md) writes.

### Behaviour under a flipped player (`SpriteStudioAnchorMirror`)

A player's [`flipX` / `flipY`](playback.md) reaches the anchor as well, so a character can turn around
without its followers coming off their parts. All this setting decides is whether the **child itself**
is mirrored along with them, and it decides that only when `scale` is on. With the default
`scale: false` the child is never mirrored: it follows the mirrored position and angle, upright.

| Value | Behaviour |
|---|---|
| `follow` (default) | Apply the part's pose as-is, so a flipped player mirrors the child too |
| `cancel` | Follow the mirrored **position**, but keep the child's own orientation |

Pick `follow` for anything that should turn around with the character — a weapon, an effect — and
`cancel` for anything that stops being readable when mirrored: text, icons, a health bar.

```dart
SpriteStudioPartAnchor(
  player: _player,
  partName: partName,
  scale: true,                                  // sized by the part…
  onMirrored: SpriteStudioAnchorMirror.cancel, // …and still readable
  child: const Text('Player 1'),
)
```

!!! info "`cancel` is exact, and leaves no residue"
    It undoes a ±1 diagonal this library applied itself, so the position stays exact and no stray
    rotation is left behind.

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
final partIndex = _player.findPartIndex(partName);

// The part's current-frame pose, in player-local (animation) space.
final Matrix4? pose = _player.partTransformByIndex(partIndex);
if (pose != null && !_player.isPartHiddenByIndex(partIndex)) {
  final x = pose.storage[12];
  final y = pose.storage[13];
  // ... spawn a projectile at (x, y), place your own component, etc.
}
```

| Method | Description |
|---|---|
| `findPartIndex(name)` | Part index, or `-1` if the pack has no such part |
| `partNames` | Part-name list and name↔index lookup (`PartNameTable`) |
| `partTransform(name)` | The part's transform on the frame the last tick built, as a `Matrix4?` (player-local). Null before `load()`, until an animation is selected, or for an unknown part |
| `partTransformByIndex(index)` | Index form of `partTransform` (skips the name lookup) |
| `isPartHidden(name)` | Whether the part is hidden on the frame the last tick built. `false` before `load()` or for an unknown part |
| `isPartHiddenByIndex(index)` | Index form of `isPartHidden` |
| `isPartSkinnedMesh(name)` | Whether the part is a bone-bound (skinned) mesh — a **poor follow target** (see the warning above). `false` before `load()`, for an unknown part, and for a rigid mesh |
| `isPartSkinnedMeshByIndex(index)` | Index form of `isPartSkinnedMesh` |
| `partQuad(name)` | The outline the part is drawn with on the frame the last tick built, as an `SsPartQuad?` (see [below](#a-parts-outline)). Null before `load()`, until an animation is selected, for an unknown or hidden part, and for a part that draws nothing of its own |
| `partQuadByIndex(index)` | Index form of `partQuad` |
| `hitTestPart(point, {parts})` | Index of the front-most part whose outline holds `point`, among the parts named in `parts` (every part when omitted), or `-1` |
| `hitTestPartByIndex(point, {parts})` | `hitTestPart` with `parts` given as indices |

!!! tip "One-shot reads need no anchor"
    When you only want the part's position at a single moment — a projectile spawn point, for example — rather than continuous following, calling `partTransform()` directly is simpler than mounting a `SpriteStudioPartAnchor`.

### What the matrix carries

The returned `Matrix4` holds **only the 2D affine terms** (`m0, m1, m4, m5, m12, m13`) over an
identity Z/W row, so a stray Z scale or perspective term can never leak into a `Transform`. Position,
rotation and scale all ride in those six terms — hand the matrix straight to a `Transform`
widget. The translation is at `storage[12]` / `storage[13]`.

The pose is **skew-free**. The runtime applies a part's Skew as a non-inheriting local-vertex
deform — it warps the part's own quad, not its matrix — so skew never reaches the world matrix and a
follower is never sheared by the part it tracks. This matches SpriteStudio, where Skew does not
propagate to a part's children.

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

!!! tip "With every axis followed, nothing is decomposed"
    With `position`, `rotation` and `scale` all on, the pose reaches a `Transform` widget as a whole
    `Matrix4`, so a reflection rides along without loss. With any of them off, the anchor rebuilds the
    pose from the axes it follows, taking a player flip out first so that the child is not turned
    over.

    Decompose it **yourself**, though, and the rotation you extract from a mirrored matrix is not well
    defined (a horizontal flip leaves an extra 180°): check the sign of
    `determinant()` before reading a rotation out of the matrix. The translation
    (`storage[12]` / `storage[13]`) is exact whatever the sign.

### A part's outline

`partQuad` returns an `SsPartQuad`: the four corners the part is drawn with (`leftTop`, `rightTop`,
`leftBottom`, `rightBottom`), in the same space as `partTransform`, with `bounds` (the axis-aligned box
around them) and `contains(point)`. Under a `SpriteStudioView`, a point in the view's own coordinates
lands in that space once you subtract the centre of the view's box:

```dart
// `local` is a point in the view's coordinates, `size` the view's size.
final index = _player.hitTestPart(local - size.center(Offset.zero), parts: ['button']);
```

The outline is what is drawn. A part with a cell gives its four drawn corners, skew and vertex deform
included, so a rotated part gives a rotated quad. A Mesh part gives the axis-aligned box around its
vertices, which is where it is drawn even when bones bind it. A Shape gives its size around its pivot.
Null, bone, Instance and Effect parts draw nothing of their own and have no outline, and neither does a
hidden part; a part drawn at alpha 0 still has one.

!!! note "The same reads exist on the low-level API"
    `SpriteStudioInternalPlayer`, the drawing engine beneath `SpriteStudioPlayer`, has them too, for a
    headless run or a drawing adapter of your own: see
    [How the Player Is Put Together](../development/architecture.md#driving-l2-directly).

## Timing and accuracy

The reads report **the frame the last tick built**, which is the frame the paint path draws —
fractional when sub-frame sampling is on, floored otherwise — so the pose always matches the image
on screen. No manual ordering against the draw is needed, and a read builds no frame of its own, so
it adds nothing to the paint. An override shows in the reads from the next tick, together with the
drawing: a paused `SpriteStudioPlayer` runs one zero-length tick on the next frame for it.

Unlike the part overrides, these are **pure reads and notify no listeners** (nothing changed). Drive
them from a listener on the player so you re-read right after each advance, when the frame's
transforms are final. `SpriteStudioPartAnchor` does exactly this internally, so it rebuilds on the
same notification the view repaints on and lands on the same frame.

Querying a pose before `load()` completes or before an animation is selected is **not an error**: like the overrides, these reads return
`null` / `false` rather than throwing, so a UI that runs while the pack is still loading needs no
guard.

## Notes

- **An unknown part name draws nothing, whatever `onHidden` says.** `followAlways` / `hideChild`
  only decide what happens to a part that exists and is hidden this frame.
- A part that is **absent from the current frame** reads as *not* hidden — its world transform is
  still valid.
- Part names resolve against the animation the player itself is running. **Parts inside an Instance
  part (the child animation) cannot be followed**, because the child runs as its own player. The
  Instance part itself can be followed.
- **A bone-bound (skinned) mesh part cannot be followed onto its visible art** — follow a
  NULL / bone-point part placed at that spot instead; `isPartSkinnedMesh` flags such a part without
  blocking it. See the warning near the top for why.
- If several parts share a name, the **first** one is used (SpriteStudio does not guarantee unique
  part names).
- Names are re-resolved on every read, so **switching animation or loading another `.ssab` needs no
  re-registration** — the anchor picks the part up again as soon as the name resolves.
- Following transfers the **spatial transform only, not draw order**. The child paints above the
  whole animation; it cannot be interleaved between the character's own parts.
- **Ownership is yours.** The anchor never creates or disposes the child or the player — it only
  reads a pose and applies it.

## Using it from Flame

`ssplayer_flame` has no API of its own for this, and `SpriteStudioPartAnchor` is a Widget, so it has no place
inside a Flame component tree. Read the pose from the player the component exposes and drive your own
component with it.

```dart
final player = component.player!;
final pose = player.partTransform(partName);
if (pose != null && !player.isPartHidden(partName)) {
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
