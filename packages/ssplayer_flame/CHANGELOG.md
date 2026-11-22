# Changelog

All notable changes to `ssplayer_flame` are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the package adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- pub.dev shows an example on the Example tab, and links the documentation from the sidebar.

### Fixed
- pub.dev lists Android, iOS, Linux, macOS, Web and Windows; it had detected Web alone.

## [7.0.0-beta.1] - 2026-11-18

### Added
- **First release.** The Flame adapter for `ssplayer_flutter`: `SpriteStudioComponent`, a Flame
  `PositionComponent` driven by the Flame game loop (external clock) rather than its own ticker.
- **Buttons** (`SpriteStudioButtonComponent`): a `SpriteStudioComponent` whose states — hover, pressed,
  disabled, and a focus the game sets — play the sections `ssplayer_flutter`'s UI state rule calls for,
  and that can take taps and hovers on named parts only.

[7.0.0-beta.1]: https://github.com/cri-middleware/SSPlayerForFlutter/releases/tag/ssplayer_flame-v7.0.0-beta.1
