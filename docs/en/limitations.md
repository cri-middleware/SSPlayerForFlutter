# ⚠️ Limitations & Scope

Constraints and platform caveats to be aware of when shipping with the current SpriteStudio Player
for Flutter. For what *is* supported, see the [Key Features](index.md#key-features) and the workflow
guides.

!!! note
    This is a living document. Items are added as they are confirmed; wording and coverage may change
    as the player evolves.

## Not Yet Implemented

!!! warning
    - **Text parts** — not drawn on either backend. The runtime reserves the part's slot in the
      draw plan but supplies no glyphs (glyph layout and rasterization are the player's job), and
      the player has no Flutter text pass yet.
    - **9-slice parts** — not drawn on either backend. The runtime builds the whole grid into its
      dedicated `Nines` buffers, but the player does not read them yet, so the part renders as
      nothing rather than as a stretched cell.

Both part types still occupy their place in the draw order, so an animation that uses them plays
with those parts missing rather than failing. They are also skipped as mask writers: a text or
9-slice part authored as a mask contributes no coverage. If you ship one, replace it with an
ordinary part at authoring time.

## Platforms

Verified on **macOS**, **iOS (simulator)**, **Android (emulator)**, and **Web (developer preview)**.
Not yet confirmed: a **physical iOS device** (signed `iphoneos` slice) and the 32-bit **`armeabi-v7a`**
ABI at runtime.

The native runtime (`libssruntime`) is delivered per target by the **native assets** build hook — no
CocoaPods, no manual linking. On the **Web** there is no `dart:ffi`: the Brain ships as the SDK's
wasm-bindgen build driven over `dart:js_interop`, bundled as a Flutter asset, and always renders
through the Canvas backend.

## Rendering

- **Two render backends.** `flutter_gpu` (Impeller) is used where available and the dart:ui **Canvas**
  (`Canvas.drawVertices`) otherwise; the default `auto` probes and falls back safely. Web is always
  Canvas.
- **Blend modes.** SpriteStudio realises every blend as a fixed-function GPU blend state, so how
  closely a mode can be reproduced depends on the backend:

    | SpriteStudio mode | `flutter_gpu` | Canvas |
    |---|---|---|
    | `Mix`, `Add` | exact | exact |
    | `Screen`, `Screen2`, `Exclusion` | exact | exact |
    | `Mul`, `Mulalpha`, `Mul2` | exact over opaque content | exact over opaque content |
    | `Sub`, `Invert` | exact | exact over opaque content (3 draws) |
    | `Div2`, `Overlay2` | renders as `Mix` | renders as `Mix` |

    `flutter_gpu` sets the reference blend state directly, so every mode is reproduced as-is. On the
    Canvas backend, `Sub` and `Invert` have no single `ui.BlendMode` — Flutter's fixed enum has no
    reverse-subtract and no destination-replace — so the player reconstructs them exactly from three
    stock passes over the same geometry. The reconstruction costs two extra draws per part and prevents
    those parts from batching, which matters only if an animation uses `Sub` / `Invert` on many parts
    at once.

    `Div2` / `Overlay2` matching `Mix` is intentional: they have no GPU blend mapping in the reference
    players either.

- **Blends read an opaque backdrop.** The modes that sample the destination (`Mul`, `Sub`, `Screen`,
  `Exclusion`, `Invert`) match the editor where the pixels underneath are opaque — the case
  SpriteStudio itself assumes, since it renders onto an opaque target. Over transparency they differ,
  and the two backends differ from each other: the Canvas backend blends against whatever your app
  already painted behind the widget, while `flutter_gpu` blends inside its own offscreen and so sees
  only the animation's own pixels. Give a blend-heavy animation an opaque background layer if you need
  the two to agree.

## Part Following

Sticking a widget to a part (see [Part Following](guide/part-following.md)) is currently limited to
the following scope.

- **Top-level parts only.** A part inside an Instance part lives in the child animation's own player
  and cannot be followed; the Instance part itself can.
- **Skinned mesh parts cannot be followed onto their art.** A bone-bound mesh part is drawn by bone
  skinning, but its own transform stays at the setup node (usually the character root), so a follower
  snaps there rather than onto the visible art. Target a NULL / bone-point part at that spot instead
  (`isPartSkinnedMesh` flags such a part, without blocking it). A rigid, deform-only mesh follows
  correctly. Shared by every official player — the same `libssruntime` behaviour.
- **Transform only, not draw order.** The following widget paints above the whole animation — it
  cannot be interleaved between the character's own parts.
- The anchor must cover the **same box as the view** (a `Positioned.fill` sibling in one `Stack`),
  since both derive their centring from their own constraints.

## Playback Feature Constraints

These come from the shared `libssruntime` and therefore apply on every platform and backend — and
to every official player, so the full explanations and the rest of the shared constraints
(embedded mode, unvalidated `.ssab` input, and so on) live in the portal:
**[Shared Limitations](https://cri-middleware.github.io/SpriteStudio-Docs/sdk/limitations/)**.

!!! warning
    - **`independent = true` parts (Instance / Effect) do not reverse or seek correctly.** Only
      forward playback (including forward frame-skips) is correct.
    - **Seeking does not fire the events it skips over.** Only the destination frame's
      `UserData` / `Signal` / `Audio` events fire.
    - **No reverse audio.** A sound key crossed while the effective direction is backward (a reverse
      direction, or a ping-pong return leg) is not meant to sound. This player **reports** audio
      rather than playing it, so it does not drop those keys — `onAudio` still fires and the gate is
      yours: read `isPlayingForward` and return early. (A negative speed is not one of those cases:
      speed is a multiplier, and a negative one stops the playhead rather than turning it around, as
      does `0`.) See [Playback & Events](guide/playback.md#example-play-an-audio-trigger).
    - **Animation blending is same-`.ssab` only**, and every blended animation must assign the
      same cell to the same part.
