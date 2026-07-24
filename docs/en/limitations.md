# Limitations & Scope

Constraints and platform caveats to be aware of when shipping with the current SpriteStudio Player
for Flutter. For what *is* supported, see the [Key Features](index.md#key-features) and the workflow
guides.

!!! note
    This is a living document. Items are added as they are confirmed; wording and coverage may change
    as the player evolves.

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
- **Blend modes.** On the Canvas backend, `Sub` / `Invert` approximate to `difference` and `Div2` /
  `Overlay2` fall back to `srcOver` — Flutter's fixed blend enum can't express reverse-subtract /
  dst-replace. The `flutter_gpu` backend maps more modes exactly (e.g. reverse-subtract, Screen,
  Multiply); only `Exclusion` / `Invert` / Multiply-over-transparency fall back to `srcOver` there.

## Playback Feature Constraints

These come from the shared `libssruntime` and therefore apply on every platform and backend.

!!! warning
    - **`independent = true` parts (Instance / Effect) do not reverse or seek correctly.** An
      `independent = true` child runs on its own real-time clock, detached from the parent timeline.
      Parent **reverse playback** and **seeking** break it; only **forward** playback (including
      forward frame-skips) is correct.
    - **Seeking does not fire the events it skips over.** Jumping the playhead directly does **not**
      emit the `UserData` / `Signal` / `Audio` events on the frames passed over — only the destination
      frame's events fire. To receive every intermediate event, advance step by step instead of jumping.
    - **No reverse audio.** Sounds fire only while the animation advances forward in time. When the
      effective direction is backward (reverse, ping-pong return, or negative speed), audio events are
      skipped.
    - **Animation blending is same-`.ssab` only.** Cross-`.ssab` blending is not supported, and every
      blended animation must assign the **same cell to the same part**; mismatched cells cause size /
      pivot mismatches that break the pose.
