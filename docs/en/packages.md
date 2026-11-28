# 📦 Packages

This monorepo releases the following packages (see [Installation](guide/install.md)).
`ssplayer_flutter` is the one most apps depend on; the rest are pulled in transitively or used for
specific needs.

Both players have a live demo you can open in a browser: the widget one at
[demo/flutter/](https://cri-middleware.github.io/SSPlayerForFlutter/demo/flutter/) and the Flame one at [demo/flame/](https://cri-middleware.github.io/SSPlayerForFlutter/demo/flame/).

| Purpose | Package | Kind |
|---|---|---|
| Animation playback (runtime rendering) | [`ssplayer_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flutter) | Flutter package (all platforms; depends on `ssruntime_dart`) |
| [Flame](https://flame-engine.org/) game-engine adapter | [`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame) | Flutter package (`SpriteStudioComponent`) |
| Runtime FFI bindings | [`ssruntime_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssruntime_dart) | Pure Dart (renderer-agnostic core) |
| `.sspj` → `.ssab` conversion (CLI / library) | [`ssconverter_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssconverter_dart) | Pure Dart (desktop-only host tool) |
| Reconvert-only-stale host lib (powers `ssgen_flutter`) | [`ssgen_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_dart) | Pure Dart (desktop host lib, over `ssconverter_dart`) |
| Live reload for the edit-to-runtime loop | [`ssgen_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_flutter) | Flutter dev tooling (on `ssgen_dart`) |

For how these map onto the rendering layers, see [How the Player Is Put Together](development/architecture.md).
