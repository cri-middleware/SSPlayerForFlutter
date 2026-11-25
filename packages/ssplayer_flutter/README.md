# ssplayer_flutter

Play **[SpriteStudio](https://www.webtech.co.jp/eng/spritestudio/)** animations (`.ssab`) natively in Flutter.
SpriteStudio is a 2D animation tool: an artist adds bones, mesh deformation and
effects to their own illustrations, and this package draws the result straight
to the Flutter `Canvas`, with no animation code to hand-write.

- 📖 **[Documentation](https://cri-middleware.github.io/SSPlayerForFlutter/)** — installing, playback, events, part overrides, motion
  blending, Flame and live reload
- ▶️ **[Live demo](https://cri-middleware.github.io/SSPlayerForFlutter/demo/flutter/)** — this package in your browser, playing the SDK's
  sample projects; the dropdowns pick the project, pack and animation

This is the package most apps depend on: a widget and a controller that play a
`.ssab`, over the runtime in [`ssruntime_dart`](https://pub.dev/packages/ssruntime_dart).

The native runtime arrives through Dart **native assets** — no CocoaPods, no
framework to embed, no `DynamicLibrary` path, and no Rust toolchain.

## Install

```bash
flutter pub add ssplayer_flutter
```

`ssruntime_dart` comes with it ([Installation](https://cri-middleware.github.io/SSPlayerForFlutter/guide/install/)).
Needs **Flutter 3.47+ / Dart 3.13+** — native assets is stable and default-on, and the
flutter_gpu backend needs the GPU API that landed in 3.47.

## Use

```dart
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

SpriteStudioAnimation.asset(
  'assets/spritestudio/Ringo/Ringo.ssab',
  animation: 'wait1',
  width: 400,
  height: 400,
)
```

List the pack's folder under `flutter: assets:` in `pubspec.yaml`. The widget
reads the bytes from the asset bundle, resolves sibling reference textures
from the key's own folder (embedded packs too), plays `animation:` — the pack's
first animation without it — loops it, and disposes everything with the widget.
`placeholder:` is what to show until the first frame is drawable; `onError:`
hears about a load that failed.

No `.sspj` of your own yet? SpriteStudio's
[official sample data](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/) works as-is —
the page is in Japanese, the downloads are not — and
[`ssconverter_dart`](https://pub.dev/packages/ssconverter_dart) converts it to `.ssab`.
[Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) is a good character to start with. To make your
own, you use SpriteStudio itself — see [its site](https://www.webtech.co.jp/eng/spritestudio/).

### Owning the player

`SpriteStudioAnimation` builds a player because most screens do not want one.
When yours does — swapping animations from a state machine, subscribing to
events, sticking a widget to a part, or driving the clock yourself — build a
`SpriteStudioPlayer` and hand it to `SpriteStudioView`, which is a plain
`RenderBox` you position, transform and clip like any other widget:

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _player.loadAsset('assets/spritestudio/Ringo/Ringo.ssab');
    if (!mounted) return;
    _player
      ..setAnimation('wait1')
      ..loopCount = -1
      ..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

### Notes

* **`vsync` is optional.** With it the player owns a `Ticker`; without it you
  drive the clock yourself through `advance(dt)` — which is how the Flame
  adapter ([`ssplayer_flame`](https://pub.dev/packages/ssplayer_flame)) hands the game loop's time to
  the same player.
* **A pack is either Reference or Embedded.** Reference packs load sibling PNG /
  WebP files from the asset key's own folder; embedded packs carry their
  textures and need nothing else. `loadAsset` handles both.
* **The `.sspj` → `.ssab` conversion is a host-side step**, not something the
  runtime does — see [`ssconverter_dart`](https://pub.dev/packages/ssconverter_dart).
* **Web is a developer preview.** Call `await loadSsRuntime()` once before
  `runApp` (a no-op on native).

## More

* [Documentation](https://cri-middleware.github.io/SSPlayerForFlutter/) — and the same pages for
  this version, as Markdown, in this package's `doc/` (start at `doc/index.md`), readable offline,
  and as the Agent Skill `skills/ssplayer-flutter-docs/`, which `dart run skills@ get --all` installs
  into your coding agent's skills directory (add `--agent claude`, or another agent, when the
  project has none yet)
* [What is and is not supported](https://cri-middleware.github.io/SSPlayerForFlutter/limitations/)
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter) · example app under [`examples/overall`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/overall)
