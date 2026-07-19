# SpriteStudioPlayer for Flutter

Play **OPTPiX SpriteStudio 7** raster (sprite) animations (`.ssab`) natively in Flutter — rigged by
an artist in a dedicated editor, drawn straight to the Flutter `Canvas`, with no animation code to
hand-write. Playback runs through `libssruntime` provided by
[SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK).

!!! tip "New to SpriteStudio?"
    [OPTPiX SpriteStudio 7](https://www.webtech.co.jp/spritestudio/) is a professional 2D **raster**
    animation editor: bone rigs, mesh deformation, and particle effects applied to raster sprite
    art. Your artist authors the motion visually; this player plays the finished file. It is a
    different fit from vector animation tools, and lighter than shipping a `.gif` or `.mp4`.

## Table of Contents

- **Setup**
    - [Installation](guide/install.md)
    - [Quick Start](guide/quickstart.md)
- **Workflow**
    - [Playback & Events](guide/playback.md)
    - [Flame Integration](guide/flame.md)
    - [Preparing Assets (`.sspj` → `.ssab`)](guide/conversion.md) (start here for the initial import)
    - [Live Reload](guide/live-reload.md)
- **Advanced Topics**
    - [Architecture](contributing/architecture.md)
    - [Build Guide](contributing/build.md)
    - [Native Runtime](contributing/native-runtime.md)
    - [Releasing](contributing/releasing.md)
- **Reference**
    - [Packages](packages.md)
    - [API Reference](api.md)
- [Roadmap & Limitations](contributing/roadmap.md)

## Key Features

This player is designed to bring the full expressive power of SpriteStudio 7 to Flutter with zero
animation code to write by hand.

*   **Zero animation code:** Characters, **UIs, and whole scenes** are authored in SpriteStudio 7; you just call `play()`.
*   **Full feature support:** Ships every core draw kind — Normal, PartColor, Mask, Mesh, Effect (particles), Instance, and Shape — plus bone hierarchies and mesh deformation.
*   **Native Canvas drawing:** `dart:ffi` into the Rust runtime, rendered via `Canvas.drawVertices`. Not a WebView, not a video decode.
*   **Composes with the widget tree — and [Flame](guide/flame.md):** `SpriteStudioView` is a plain `RenderBox`; the `ssplayer_flame` package adds a `SpriteStudioComponent`.
*   **Smooth sub-frame interpolation:** Playback follows the display refresh rate, not a fixed fps — buttery-smooth even in slow motion.
*   **Bring your own art, with live-reload:** Convert `.sspj` → `.ssab` from a [CLI or CI](guide/conversion.md), and **[live-reload](guide/live-reload.md)** editor edits straight into the running app.
*   **High performance & low memory:** A SIMD-optimized runtime and zero-parse binary format (`.ssab`); the native runtime is bundled automatically via native assets — no CocoaPods, no manual linking.

## Overview

The diagram below shows how data flows from authored assets to on-screen playback.

```mermaid
graph LR
    SS[" .sspj / Images<br>(Source Assets) "]

    subgraph Convert ["Conversion"]
        CLI[[" ssconvert<br>(CLI / CI) "]]
        WATCH[[" sswatch<br>(live-reload) "]]
    end

    subgraph App ["Flutter App"]
        BIN[" .ssab "]
        VIEW[[ SpriteStudioView / Player ]]
        RT(" libssruntime<br>(dart:ffi · native assets) ")
    end

    SS -- "one-shot / CI" --> CLI
    SS -- "save → push" --> WATCH
    CLI -. "generate" .-> BIN
    WATCH -. "push into running app" .-> VIEW

    BIN -- "load()" --> VIEW
    VIEW -. "drive" .-> RT
    VIEW -- "drawVertices" --> RENDER{{" Flutter Canvas "}}

    classDef generated stroke-dasharray: 5 5;
    class BIN generated;
```

## Supported Versions

- **Flutter**: 3.38 or later — **Dart**: 3.10 or later (native assets is stable and default-on there).
- **Platforms**: verified on macOS, iOS (simulator), and Android (emulator). A physical iOS device and Web are not yet confirmed — see [Roadmap & Limitations](contributing/roadmap.md).

## Samples

Sample apps live under the `examples/` folder in the repository.

- [overall](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/overall) — comprehensive validation app (`flutter run -d macos` → `[ssplayer] OK`).
- [flame](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame) — a `FlameGame` playing an animation via `ssplayer_flame`.

## Related Repositories

- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — the SDK itself, providing `libssruntime` / `libssconverter`.
- Sibling players for other engines: [Godot](https://github.com/cri-middleware/SSPlayerForGodot), [Unity](https://github.com/cri-middleware/SSPlayerForUnity), [Web](https://github.com/cri-middleware/SSPlayerForWeb), [Ren'Py](https://github.com/cri-middleware/SSPlayerForRenPy).

## License

See [LICENSE.md](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/LICENSE.md).

For third-party library licenses (such as FlatBuffers and SpriteStudio-SDK dependencies), see [THIRD_PARTY_NOTICES.md](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/THIRD_PARTY_NOTICES.md).
