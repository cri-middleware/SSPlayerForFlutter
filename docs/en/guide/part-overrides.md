# 🎨 Part Overrides

Per-part runtime overrides let your code say "make this part this colour / this cell / hidden **now**".
An override takes priority over the keyframes (by default for the rest of the current animation; see
[Priority modes](#priority-modes-ssoverridepriority)) and over any animation blending.

```dart
// Tint a part with multiply (Normal parts only)
_player.setPartColorOverride(partName, Colors.red, blendOp: SsBlendOp.mul);

// Draw a different cell (the cellmap name carries no ".ssce" extension)
_player.setPartCellOverride(partName, cellmap, cellName);

// Force-hide a part, cascading to its descendants
_player.setPartVisibilityOverride(partName, true, cascade: true);

// Clear
_player.clearPartColorOverride(partName);
_player.clearAllPartOverrides();
```

!!! warning "Select an animation first"
    The runtime holds overrides in a table sized to the part count, and that table is only allocated
    when you call **`setAnimation()`** (or `load(animationName: ...)`). Before that, every call is
    rejected and returns `false`.

    What makes this easy to miss: **part-name resolution already works** beforehand, because names are
    read from the `.ssab`. If `findPartIndex()` returns a valid index but `set` keeps failing, this is
    almost certainly why.

    Note also that `setAnimation()` **clears** every override that is not `Permanent` — so always
    apply overrides *after* selecting the animation, never before. Selecting the animation that is
    already selected does nothing, so it clears nothing (`clearAllPartOverrides()` does), and a
    `crossfade` or `setTrackAnimation` on track 0 clears nothing either.

## Methods

These are methods on `SpriteStudioPlayer`.

| Method | Description |
|---|---|
| `findPartIndex(name)` | Part index, or `-1` if the pack has no such part |
| `partNames` | Part-name list and name↔index lookup (`PartNameTable`) |
| `setPartColorOverride(part, color, blendOp:, priority:)` | Colour override (single value) |
| `setPartColorOverrideCorners(part, corners, blendOp:, priority:)` | Four distinct corners (a gradient), as an `SsCornerColors` record |
| `setPartCellOverride(part, cellmapName, cellName, priority:)` | Draw a different cell |
| `setPartVisibilityOverride(part, hide, cascade:)` | Force-hide (`hide: false` reverts to the animation) |
| `clearPartColorOverride` / `clearPartCellOverride` / `clearPartVisibilityOverride` | Clear one override on one part |
| `clearAllPartOverrides()` | Clear every override on this player |
| `...ByIndex(...)` | The by-**index** form of each method above (suffixed `ByIndex`) |

Each method takes a **part name**; the `ByIndex`-suffixed form takes a **part index**, which is the optimisation for a caller that cached one from `findPartIndex`, not the default. Both return
`false` when the part is unknown or the runtime rejected the call.

!!! tip "Working with part indices"
    Part indices are stable within one pack (the same `.ssab`), so if you override frequently, resolve
    the name once with `findPartIndex()` and reuse the index.

An override shows from the player's next tick: `SpriteStudioPlayer` notifies its listeners when a set
or clear succeeds, and a paused one runs one zero-length tick on the next frame.

!!! note "The same calls exist on the low-level API"
    `SpriteStudioInternalPlayer`, the drawing engine beneath `SpriteStudioPlayer`, has them too, for a
    headless run or a drawing adapter of your own: see
    [How the Player Is Put Together](../development/architecture.md#driving-l2-directly).

The cellmap / cell names a cell override accepts can be enumerated from the player:

```dart
final cellmap = _player.cellmapNames.first;   // e.g. the pack's first cellmap
final cells   = _player.cellNames(cellmap);   // every cell name in that cellmap
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
none — it is a plain force-hide flag, and `setAnimation` to another animation always clears it.

| Priority mode | Behaviour |
|---|---|
| `overwriteOnNextKeyframe` | Applies until the animation data updates that attribute |
| `holdUntilNextAnimation` (default) | Wins for the current animation; cleared when `setAnimation` switches to another (a crossfade on track 0 keeps it) |
| `permanent` | Applies for as long as the same `.ssab` is loaded (survives animation changes) |

## No need to re-apply

The runtime owns the override table and its whole lifecycle. **Do not re-apply overrides every
frame.** Set one once and it keeps being applied on every subsequent frame (until its priority mode
says otherwise), including across the animation's own loops.

```dart
// ✅ set it once
_player.setPartColorOverride(partName, Colors.red, blendOp: SsBlendOp.mul);

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
    implementations setting one while stopped may not update the screen. An override shows from the
    next tick, and a paused `SpriteStudioPlayer` runs one zero-length tick on the next frame for it,
    so the drawing and the part reads change together. No extra step is needed.

## Using it from Flame

`ssplayer_flame` has no API of its own for this — call the methods above on the player the component
exposes.

```dart
final player = component.player!;
player.setPartColorOverride(partName, Colors.red, blendOp: SsBlendOp.mul);
```

## See also

- [Texture Replacement](textures.md) — swap a **whole cellmap (texture)** at runtime (skins /
  costumes): it re-skins **every part** that samples that texture, where a cell override here works on
  **one part at a time**, replacing the cell it draws. Pick whichever matches your intent.
- [Part Following](part-following.md) — read the other direction: follow a part's live pose with a
  widget
- [Playback & Events](playback.md) — transport and event callbacks
