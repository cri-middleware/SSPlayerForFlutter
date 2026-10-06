# Changelog

All notable changes to `ssplayer_flutter` are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the package adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **First release.** The SpriteStudio player for Flutter: `.ssab` loading, playback and part
  control, driving the SpriteStudio-SDK Rust runtime (`libssruntime`) through `ssruntime_dart`.
- **Rendering backends**: a `Canvas` backend (`Canvas.drawVertices`) everywhere, and a
  `flutter_gpu` backend on Impeller, selected automatically (`auto`) with a manual override.
- **Rendering kinds**: Normal, PartColor, Mask, Mesh, Effect, Instance, and Shape.
- **`SpriteStudioView`**, a `RenderBox` widget.
- **Flip & offset** (`SpriteStudioPlayer.flipX` / `flipY` / `offset`): mirror or shift what the
  player draws without touching the widget tree. Part anchors follow the mirrored pose, and can keep
  their own child upright (`SpriteStudioAnchorMirror.cancel`).
