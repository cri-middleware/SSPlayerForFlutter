# Packages

This monorepo publishes the following packages. `ssplayer_flutter` is the one most apps depend on;
the rest are pulled in transitively or used for specific needs.

| Purpose | Package | Kind |
|---|---|---|
| Animation playback (runtime rendering) | [`ssplayer_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flutter) | Flutter package (all platforms; depends on `ssruntime_dart`) |
| [Flame](https://flame-engine.org/) game-engine adapter | [`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame) | Flutter package (`SpriteStudioComponent`) |
| Runtime FFI bindings (Layer 1) | [`ssruntime_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssruntime_dart) | Pure Dart (renderer-agnostic core) |
| `.sspj` → `.ssab` conversion (CLI / library) | [`ssconverter_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssconverter_dart) | Pure Dart (desktop-only host tool) |
| Live reload for the edit-to-runtime loop | [`ssgen_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_flutter) | Flutter dev tooling (on `ssgen_dart`) |

For how these map onto the rendering layers, see [Architecture](contributing/architecture.md).
