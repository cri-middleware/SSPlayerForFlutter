# Changelog

All notable changes to `ssruntime_dart` are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and the package adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **First release.** `dart:ffi` `@Native` bindings for `libssruntime` (the SpriteStudio-SDK Rust
  runtime), plus the flatc `FrameData` / `EffectDrawPlan` accessors and the `dart:js_interop` web
  backend.
- **Native delivery via Dart native assets**: the runtime is bundled automatically, with no
  CocoaPods and no vendored framework.

[7.0.0-beta.1]: https://github.com/cri-middleware/SSPlayerForFlutter/releases/tag/ssruntime_dart-v7.0.0-beta.1
