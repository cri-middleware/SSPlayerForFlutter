# Roadmap & Limitations

The rendering features shipped so far — the five draw kinds (**Normal, Mesh, Effect, Instance,
Shape**) plus **PartColor** and **Mask** — and the Flame adapter cover the core feature set. This page summarizes what remains and what to be aware
of when shipping; the live, detailed roadmap is
[`ROADMAP.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/ROADMAP.md).

## Roadmap highlights

Work is tracked as ☐ **Ready** (Player-only, can start now), ⛔ **Blocked on SDK** (needs a runtime
phase first), or 🕒 **Deferred**.

- ☐ **Label / frame-range / index playback** — play a named label range or by index.
- ☐ **`Nines` / `Text` kinds + `BoxFit` / alignment** — the remaining draw kinds and fitting the
  design bounds into the destination box.
- ☐ **Per-part runtime overrides** (color / cell / visibility) — the SDK Override Layer API is
  shipped; the Player-side surface (`setPartColor` / `setPartCell` / `setPartVisible`) is pending.
- ⛔ **Dynamic instance swap · Sequence (`.ssqb`) playback · crowd rendering** — blocked on SDK Phase 3.
- 🕒 **`flutter_gpu` backend** — a lower-level path that could unblock peeled-shader draw-call fan-out.

## Performance

The batching is already **correct** — one `Canvas.drawVertices` per Normal / Mesh / Shape batch,
matching the Brain's plan, and adjacent batches can't merge without breaking z-order. The levers are
(a) per-frame allocation to *build* each batch and (b) the draw-call count of *peeled* shader parts.
Allocation hygiene (zero-copy vertex views, reused scratch buffers, dense per-part lookup, effect
command merging) has already shipped. The remaining big lever — peeled PartColor / mask draw-call
fan-out — is **structurally bounded by Flutter's shader model** (fragment shaders take no per-vertex
varyings, so `drawVertices` can't feed a shader), which is why the `flutter_gpu` backlog item exists.
See [`ROADMAP.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/ROADMAP.md#performance).

## Known limitations

### Rendering

- **Shape / `Arrow`** is broken upstream: the runtime emits a bare 7-point polygon with no center
  vertex, while every Player fans it, so part of the arrow paints outside itself. The fix belongs in
  the SDK (give `Arrow` a center + closing vertex). See
  [`docs/architecture.ja.md` §11-A](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/docs/architecture.ja.md).
- **Blend modes** — `Sub` and `Invert` approximate to `difference` (Flutter's fixed blend enum can't
  express reverse-subtract / dst-replace); `Div2` / `Overlay2` fall back to `srcOver`.

### Playback (from the shared `libssruntime`, so common to every Player)

- **`independent = true` parts (Instance / Effect) do not reverse or seek correctly** — they run on
  their own real-time clock; only forward playback is correct.
- **Seeking does not fire the events it skips over** — only the destination frame's events fire.
- **No reverse audio** — audio events fire only while time advances forward.
- **Animation blending is same-`.ssab` only**, and every blended animation must assign the same cell
  to the same part.

### Platforms

Verified on macOS, iOS (simulator), and Android (emulator). A physical iOS device (signed `iphoneos`
slice) and the `armeabi-v7a` ABI at runtime are not yet confirmed; Web is planned.
