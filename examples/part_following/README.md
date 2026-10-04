# part_following — attach a widget to a live part

A runnable Flutter app that demonstrates **part following**: sticking an ordinary
Flutter widget to a SpriteStudio part so it tracks that part's **position,
rotation and scale** every frame. It runs the **Ringo** character and pins a
marker to a part with `SpriteStudioPartAnchor`.

This is the Flutter take on the same feature as
[SSPlayerForUnity](https://github.com/cri-middleware/SSPlayerForUnity)'s part
tracker (`SpriteStudioPartTracker`) and
[SSPlayerForGodot](https://github.com/cri-middleware/SSPlayerForGodot)'s part
attachment (`SpriteStudioPartAttachment2D`), and a direct port of
[SSPlayerForWeb](https://github.com/cri-middleware/SSPlayerForWeb)'s
`examples/part-follow`. Each engine delivers the same capability its own
idiomatic way; Flutter's is a Widget you drop into the tree.

## Run it

From the repo root, `bash scripts/run-<platform>.sh example=part_following` does all of the
below — assets, the platform runner, a device — in one step. By hand:

```sh
# First time / after a pull: stage the Ringo assets (see "The assets" below).
bash scripts/deploy-examples.sh          # from the repo root

cd examples/part_following
flutter run -d windows          # or -d macos, -d chrome, -d <device>
```

The character loops while a star marker rides the followed part. Use the
**Follow target** picker (top-right) to point the marker at any part, the buttons
(bottom) to switch **motion** and toggle **Attach**, **Scale follow** and
**onHide: hide**.

## The teaching point — skinned mesh parts are poor follow targets

Ringo is a rig with **skinned (bone-bound) mesh** parts: its hands, legs, ears
and tail. A skinned part's vertices are drawn by bone skinning, but the part's
*own* transform stays near the character root — so following one snaps the marker
to the root instead of onto the visible art. Only skinned parts do this; a
*rigid* (deform-only) mesh, and every bone / joint / NULL part, follows correctly.

The follow-target picker mirrors the Unity and Godot inspectors:

- Skinned parts are **listed but disabled (dimmed)** so they can't be picked by
  accident — the dropdown is built from `player.partNames.names` and each entry
  is dimmed when `player.isPartSkinnedMesh(name)` is true.
- The **text box** beside it still accepts any name (including a skinned one),
  matching those editors' "type it to override" escape hatch — and a
  **non-blocking warning** appears, because `isPartSkinnedMesh` is a *hint*, not a
  gate. Type `hand_r` to see it.
- The default target, `bone_14`, is a bone in the right-hand chain — the
  recommended kind of follow target.

See the [Part Following guide](../../docs/en/guide/part-following.md) for the full
API and the caveat.

## What to read

`lib/main.dart` is the whole demo. The one rule that makes it line up: the
follower must share the **same coordinate space** as the animation. Here the
`SpriteStudioView` and the `SpriteStudioPartAnchor` are both children of one
transformed `Stack`, so any nudge or scale moves them together:

```dart
FractionalTranslation(
  translation: const Offset(0, 0.25),
  child: Stack(
    fit: StackFit.expand,
    children: [
      SpriteStudioView(player: player),
      Positioned.fill(
        child: SpriteStudioPartAnchor(
          player: player,
          partName: 'bone_14',
          child: myMarker,           // any widget; its top-left pins to the part
        ),
      ),
    ],
  ),
)
```

The read API the anchor drives (`partTransform` / `isPartHidden` /
`isPartSkinnedMesh` / `findPartIndex` / `partNames`) lives on
`SpriteStudioPlayer`, so you can also follow a part by hand — e.g. from a Flame
component — without the widget. The status readout shows the pull side directly:
`partTransform(name)` re-read each frame via a `ListenableBuilder` on the player.

## The assets

`assets/spritestudio/Ringo/` is **generated, not committed** (git-ignored). It is
the same self-contained Ringo pack the `flame` and `override_ringo` examples use,
staged by `scripts/deploy-examples.sh`, which converts the SDK's `tests/Ringo`
project with the `ssconvert` CLI (`ssconverter_dart`) — no Rust toolchain needed
(build the native libs once with `scripts/build-runtime.sh`).

## v1 limits

Tracks top-level parts only (a part nested inside an Instance part lives in a
child player and is not addressable yet), assumes the view draws unscaled, and
transfers only the spatial transform — not draw order, so the marker paints on
top rather than being interleaved between the character's own parts.
