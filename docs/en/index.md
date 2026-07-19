# SpriteStudioPlayer for Flutter

Play **OPTPiX SpriteStudio 7** raster (sprite) animations (`.ssab`) natively in Flutter — rigged by
an artist in a dedicated editor, drawn straight to the Flutter `Canvas`, with no animation code to
hand-write.

!!! tip "New to SpriteStudio?"
    [OPTPiX SpriteStudio 7](https://www.webtech.co.jp/spritestudio/) is a professional 2D **raster**
    animation editor: bone rigs, mesh deformation, and particle effects applied to raster sprite
    art. Your artist authors the motion visually; this player plays the finished file. It is a
    different fit from vector animation tools, and lighter than shipping a `.gif` or `.mp4`.

## Which reader are you?

Read only as far as your goal — the tabs are ordered so app developers never need the Rust/SDK material.

| You are… | Goal | Start here |
|---|---|---|
| **A Flutter app developer** | Just play an animation in your app | [**For Users → Installation**](guide/install.md) |
| **Customizing / automating** | Convert your own `.sspj`, bring your own runtime, live reload | [**Customization & Automation**](customize/index.md) |
| **A Player / SDK developer** | Extend the Rust runtime / Player, or contribute | [**For Player & SDK Developers**](contributing/architecture.md) |

## Highlights

- **Zero animation code** — characters, **UIs, and whole scenes** authored in SpriteStudio 7; you call `play()`.
- **Native drawing** — `dart:ffi` into a Rust runtime, rendered via `Canvas.drawVertices`. Not a WebView, not a video decode.
- **Composes with the widget tree — and [Flame](guide/flame.md)** — `SpriteStudioView` is a plain `RenderBox`.
- **Sub-frame interpolation** — smooth motion that follows the display refresh rate, not a fixed fps.
See [Packages](packages.md) for the published packages and [API Reference](api.md) for the generated API docs.
