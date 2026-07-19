# Changelog

All notable changes to this repository are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the packages
adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Per-package versioning.** This is a monorepo whose packages (`ssplayer_flutter`,
> `ssplayer_flame`, `ssruntime_dart`, `ssconverter_dart`, `ssgen_flutter`, `ssgen_dart`) are versioned
> and published **independently**. Package-level history lives in each package's own `CHANGELOG.md`;
> this file records repository-wide milestones.

## [Unreleased]

### Added
- **Initial public release (work in progress).** A Flutter "Body" that plays OPTPiX SpriteStudio 7
  animations (`.ssab`) by driving the SpriteStudio-SDK Rust runtime (`libssruntime`) over `dart:ffi`
  and rendering with `Canvas.drawVertices`.
- **Rendering kinds**: Normal, PartColor, Mask, Mesh, Effect, Instance, and Shape.
- **Rendering adapters**: `SpriteStudioView` (a `RenderBox` widget) and, in the separate
  `ssplayer_flame` package, `SpriteStudioComponent` (a Flame `PositionComponent`).
- **Native delivery via Dart native assets** — the runtime is bundled automatically (no CocoaPods,
  no vendored framework); verified on macOS, iOS, and Android.
- **Asset conversion**: `ssconverter_dart` (`ssconvert` CLI + `SsConverter` library, desktop-only).
- **Live reload** (`ssgen_flutter` / `ssgen_dart`): save a `.sspj` and see it update in the running
  app.

### Known Limitations
- `Shape / Arrow` is broken upstream (fix belongs in the SDK).
- Blend `Sub` / `Invert` approximate to `difference`; `Div2` / `Overlay2` fall back to `srcOver`.
- A physical iOS device (signed `iphoneos` slice) and the `armeabi-v7a` ABI are not yet confirmed at
  runtime; Web is planned.
