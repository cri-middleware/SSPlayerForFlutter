# Part Overrides

Per-part runtime overrides let your code say "make this part this colour / this cell / hidden **now**".
An override wins over both the keyframes and any animation blending, so it never fights the animation.

```dart
// Tint a part with multiply (Normal parts only)
_player.setPartColorOverrideByName('body', SsBlendOp.mul, Colors.red);

// Draw a different cell (the cellmap name carries no ".ssce" extension)
_player.setPartCellOverrideByName('body', 'Ringo', 'effect3');

// Force-hide a part, cascading to its descendants
_player.setPartVisibilityOverrideByName('body', true, cascade: true);

// Clear
_player.clearPartColorOverrideByName('body');
_player.clearAllPartOverrides();
```

!!! warning "Select an animation first"
    The runtime holds overrides in a table sized to the part count, and that table is only allocated
    when you call **`setupAnimation()`** (or `load(animationName: ...)`). Before that, every call is
    rejected and returns `false`.

    What makes this easy to miss: **part-name resolution already works** beforehand, because names are
    read from the `.ssab`. If `partIndexOf()` returns a valid index but `set` keeps failing, this is
    almost certainly why.

    Note also that `setupAnimation()` **clears** every override that is not `Permanent` — so always
    apply overrides *after* selecting the animation, never before.

## Methods

These are methods on `SpriteStudioPlayer`.

| Method | Description |
|---|---|
| `partIndexOf(name)` | Part index, or `-1` if the pack has no such part |
| `partNames` | Part-name list and name↔index lookup (`PartNameTable`) |
| `setPartColorOverride(part, blendOp, color, priority:)` | Colour override (single value) |
| `setPartColorOverrideCorners(part, blendOp, leftTop:, rightTop:, leftBottom:, rightBottom:, priority:)` | Four distinct corners (a gradient) |
| `setPartCellOverride(part, cellmapName, cellName, priority:)` | Draw a different cell |
| `setPartVisibilityOverride(part, hide, cascade:)` | Force-hide (`hide: false` reverts to the animation) |
| `clearPartColorOverride` / `clearPartCellOverride` / `clearPartVisibilityOverride` | Clear one override on one part |
| `clearAllPartOverrides()` | Clear every override on this player |
| `...ByName(...)` | The by-name form of each method above (suffixed `ByName`) |

Each method takes a **part index**; the `ByName`-suffixed form takes a **part name**. Both return
`false` when the part is unknown or the runtime rejected the call.

!!! tip "Working with part indices"
    Part indices are stable within one pack (the same `.ssab`), so if you override frequently, resolve
    the name once with `partIndexOf()` and reuse the index.

!!! note "The same calls exist on the low-level API"
    Every method listed here is available not only on `SpriteStudioPlayer` (L3) but also — under the
    same names and signatures — on the drawing engine beneath it, `SpriteStudioInternalPlayer` (L2).
    Reach for that one when driving the player headless or from your own drawing adapter (see
    [Architecture](../contributing/architecture.md) for the layering).

    The only difference is **repaint notification**: `SpriteStudioPlayer` notifies its listeners when
    a set or clear succeeds, while `SpriteStudioInternalPlayer` does not, so repainting is the
    caller's responsibility there.

The cellmap / cell names a cell override accepts can be enumerated from the player:

```dart
final cellmap = _player.getCellmaps().first;   // → "Ringo"
final cells   = _player.getCells(cellmap);     // → ["eye2", "tail", "apple", "effect3", ...]
```

## Blend operations (`SsBlendOp`)

The `blendOp` of `setPartColorOverride()` is the same set of four the authored Part Color uses.

| Value | Blend operation |
|---|---|
| `SsBlendOp.mix` | Mix (default) |
| `SsBlendOp.mul` | Mul |
| `SsBlendOp.add` | Add |
| `SsBlendOp.sub` | Sub |

## Priority modes (`SsOverridePriority`)

Colour and cell overrides can conflict with the animation, so they take a `priority`. Visibility has
none — it is a plain force-hide flag, and setting up an animation always clears it.

| Priority mode | Behaviour |
|---|---|
| `overwriteOnNextKeyframe` | Applies until the animation data updates that attribute |
| `holdUntilNextAnimation` (default) | Wins for the current animation; cleared when a new one is set up |
| `permanent` | Applies for as long as the same `.ssab` is loaded (survives animation changes) |

## No need to re-apply

The runtime owns the override table and its whole lifecycle. **Do not re-apply overrides every
frame.** Set one once and it keeps being applied on every subsequent frame, including across the
animation's own loops.

```dart
// ✅ set it once
_player.setPartColorOverrideByName('body', SsBlendOp.mul, Colors.red);

// ❌ no per-frame re-application is required
```

## Notes

- **Colour** applies to Normal parts; **cell** applies to Normal and mask parts. Other part types
  silently ignore the override (the call itself still returns `true`).
- Consequently, **`false` means "rejected", not "had no visible effect".** Never use the return value
  to decide whether an override is visible.
- Colours are read in the same 8-bit sRGB space as the authored Part Color, and the runtime
  pre-multiplies alpha itself. Do not convert the colour or fold the part's own alpha in.
- The four-corner order is **left-top, right-top, left-bottom, right-bottom**.
- A cell override is resolved when it is set, so an unknown cellmap / cell name fails immediately
  (returns `false`). The cellmap name carries no `.ssce` extension.
- Passing two empty strings clears a cell override and reverts the part to the animation.
- Loading another `.ssab` clears every override, since part identity is lost.
- Overrides do not reach parts **inside** an instance part (a child animation runs as its own player).
  Force-hiding the instance part itself does stop its children from being drawn.
- `cascade` propagates only override-driven hiding. A keyframe `hide` is per-part and does *not*
  cascade to descendants; that asymmetry is deliberate.

!!! note "Takes effect even while paused"
    An override changes what is drawn without changing the frame number, so in other player
    implementations setting one while stopped may not update the screen. `SpriteStudioPlayer`
    notifies its listeners whenever a set or clear succeeds, so a paused player repaints immediately.
    No extra step is needed.

## Using it from Flame

`ssplayer_flame` adds no API of its own — call the methods above on the player the component
exposes.

```dart
final player = component.player!;
player.setPartColorOverrideByName('body', SsBlendOp.mul, Colors.red);
```

## See also

- [Part Following](part-following.md) — read the other direction: follow a part's live pose with a
  widget
- [Playback & Events](playback.md) — transport and event callbacks
- To swap a **whole cellmap (texture)** at once, use texture replacement instead. This feature works
  on **one part at a time**, replacing the cell it draws.
