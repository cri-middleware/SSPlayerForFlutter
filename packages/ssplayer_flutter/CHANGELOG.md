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
- **`SpriteStudioAnimation`**, a widget that loads a pack from the asset bundle and plays it, and
  **`SpriteStudioView`**, a `RenderBox` widget for a `SpriteStudioPlayer` you own.
- **Events**: user data, signals and audio cues as callbacks (`onUserData` / `onSignal` / `onAudio`).
  Audio is reported, not played.
- **Motion blending**: layer animations on tracks and crossfade between them (`crossfade`,
  `setTrackAnimation`).
- **Part following** (`SpriteStudioPartAnchor`): stick a widget to a part.
- **Part overrides**: recolour, hide or swap the cell of a part at runtime.
- **Texture replacement** (`setCellmapTexture`): swap a cellmap's atlas at runtime.
- **Web** (developer preview): the runtime runs as wasm; call `loadSsRuntime()` before `runApp`.
- **Live reload's receiving end** (`SsDevChannel`, `SsLiveReload`, the `ext.ssgen.reload` service
  extension), active only in a debug build launched with `SS_LIVE_RELOAD`.
- **Flip & offset** (`SpriteStudioPlayer.flipX` / `flipY` / `offset`): mirror or shift what the
  player draws without touching the widget tree. Part anchors follow the mirrored pose, and can keep
  their own child upright (`SpriteStudioAnchorMirror.cancel`).
- **Label playback** (`SpriteStudioPlayer.setAnimationSectionByLabel`): set the playback section by a
  start and an end label of the current animation, each with an offset.
- **Part outlines** (`SpriteStudioPlayer.partQuad` / `hitTestPart`): the outline a part is drawn with,
  and the front-most part under a point.

[7.0.0-beta.1]: https://github.com/cri-middleware/SSPlayerForFlutter/releases/tag/ssplayer_flutter-v7.0.0-beta.1
