# 🏗️ Architecture

SpriteStudio Player for Flutter is the **Body** for the SpriteStudio-SDK **Brain**. The Brain
(`libssruntime`, Rust `no_std`) loads a `.ssab`, advances time, and emits per-frame **SoA buffers**
(world matrices, local vertices / UVs) plus a FlatBuffers **`FrameData`** carrying a **`DrawBatch`**
plan. The Body consumes them over `dart:ffi` and executes the plan through a pluggable render backend
— `Canvas.drawVertices` or `flutter_gpu` (Impeller). There is no retained scene
graph: everything is rebuilt each frame.

## The 4 layers

```mermaid
flowchart TD
    L4["L4 · Drawing adapters<br/>SpriteStudioView (RenderBox) · SpriteStudioComponent (Flame)"]
    L3["L3 · SpriteStudioPlayer<br/>ChangeNotifier · transport · events · Ticker / advance"]
    L2["L2 · SpriteStudioInternalPlayer<br/>Widget-agnostic · FFI lifecycle · SoA → geometry bake · paint"]
    L1["L1 · ffigen @Native bindings<br/>(ssruntime_dart package)"]
    Brain["Brain · libssruntime (Rust)"]
    L4 --> L3 --> L2 --> L1 --> Brain
```

It is a **strict downward dependency**; layers below are nearer the Brain. Each layer has one job:

| Layer | Responsibility | Lives in |
|---|---|---|
| **L4** | Drawing adapters — `SpriteStudioView` (a `RenderBox`) and the Flame `SpriteStudioComponent` | `ssplayer_flutter`, `ssplayer_flame` |
| **L3** | `SpriteStudioPlayer` — transport / events; a `Ticker` in vsync mode, or externally clocked via `advance` | `ssplayer_flutter` |
| **L2** | `SpriteStudioInternalPlayer` — FFI Resource/Context lifecycle, SoA → geometry bake (`ui.Vertices` for Canvas / interleaved VBO for GPU), `paint` = `DrawBatch.kind` dispatch | `ssplayer_flutter` |
| **L1** | ffigen `@Native` C-API bindings + runtime FlatBuffers | `ssruntime_dart` |

**L2 is kept Widget-free** so it is reusable headless / from Flame / by either render backend
(`Canvas` or `flutter_gpu`).

## Where things live

- **L1** — `ssruntime_dart` (pure Dart, non-Flutter): `@Native` C-API bindings
  (`lib/src/ssruntime_bindings.g.dart`, native lib bundled by `hook/build.dart`) + runtime
  FlatBuffers (`framedata` / `effect_draw_plan`).
- **L2–L4** — `ssplayer_flutter` (the public API barrel; import L1 from `ssruntime_dart` directly).
- **Flame L4** — `ssplayer_flame` (a separate package so the core never pulls in `flame`).
- **Converter** — `ssconverter_dart` (host `.sspj` → `.ssab`, desktop-only).

See [Packages](../packages.md) for the full list and their roles.

## Rendering model

The Brain emits a `DrawBatch` plan; `paint` dispatches on `DrawBatch.kind`
(`Normal / Mesh / Effect / Instance / Shape`) and delegates each batch to the active **render
backend**. The `Canvas` backend bakes each batch into one indexed `ui.Vertices` (`Canvas.drawVertices`);
the `flutter_gpu` (Impeller) backend bakes an interleaved VBO and draws through its own pipeline into
an offscreen target. Parts that need a pass of their own — PartColor, integration shaders, and the
multi-pass Sub / Invert blends — are peeled out of their batch and drawn individually on `Canvas`,
whereas the `flutter_gpu` backend batches them. The backend is chosen per `SpriteStudioBackend`
(`auto` picks flutter_gpu where the capability probe passes, else Canvas). Because everything is rebuilt per frame, the performance
levers are **per-frame allocation** and **draw-call count** — not the batch grouping, which already
matches the Brain's plan.

## Further reading

How the native library is resolved and packaged is on [Native Runtime](native-runtime.md), and how to
build and test from a checkout on the [Build Guide](build.md).
