# Live reload in an app

The app keeps its SpriteStudio projects beside the assets they convert into:

```text
my_app/
├── SpriteStudio_Source/
│   └── Ringo/
│       └── Ringo.sspj
├── assets/
│   └── spritestudio/
│       └── Ringo/
│           └── Ringo.ssab
└── lib/
    └── main.dart
```

Nothing in `lib/` names this package. A widget that loads its pack by asset key takes the push by
itself:

```dart
SpriteStudioAnimation.asset(
  'assets/spritestudio/Ringo/Ringo.ssab',
  animation: 'wait1',
)
```

Launch the app through the watcher from `my_app/`, then save `Ringo.sspj` in SpriteStudio. The
running animation is replaced in place, at the frame it was on:

```bash
dart run ssgen_flutter:sswatch --run -d macos                # desktop
dart run ssgen_flutter:sswatch --run -d <emulator> --device  # device
```

On macOS the debug build has to run outside the App Sandbox; the
[Live reload](https://cri-middleware.github.io/SSPlayerForFlutter/guide/live-reload/) guide covers
that and a player loaded from bytes.
