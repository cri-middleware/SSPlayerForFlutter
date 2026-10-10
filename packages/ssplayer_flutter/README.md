# ssplayer_flutter

Play **SpriteStudio** raster animations (`.ssab`) natively in Flutter —
rigged by an artist in a dedicated editor, drawn straight to the Flutter
`Canvas`, with no animation code to hand-write.

This is the package most apps depend on: a `dart:ffi` **Body** over the
SpriteStudio-SDK Rust **Brain** (`libssruntime`, in
[`ssruntime_dart`](../ssruntime_dart)). The Brain loads the pack, advances time
and emits a per-frame draw plan; this package turns that plan into
`Canvas.drawVertices` calls and gives you a widget and a controller.

The native runtime arrives through Dart **native assets** — no CocoaPods, no
framework to embed, no `DynamicLibrary` path, and no Rust toolchain.

## Install

Take it as a git dependency on a release tag, `ssplayer_flutter-v<version>` on
[Releases](https://github.com/cri-middleware/SSPlayerForFlutter/releases?q=ssplayer_flutter&expanded=true),
with `ssruntime_dart` from the same tag under `dependency_overrides`, since `ssplayer_flutter` names
it by version ([Installation](https://cri-middleware.github.io/SSPlayerForFlutter/guide/install/)):

```yaml
dependencies:
  ssplayer_flutter:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssplayer_flutter-v7.0.0-beta.1
      path: packages/ssplayer_flutter

dependency_overrides:
  ssruntime_dart:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssplayer_flutter-v7.0.0-beta.1
      path: packages/ssruntime_dart
```

Needs **Flutter 3.47+ / Dart 3.13+** — native assets is stable and default-on, and the
flutter_gpu backend needs the GPU API that landed in 3.47.

## Use

```dart
SpriteStudioAnimation.asset(
  'assets/overall/Basic.ssab',
  width: 400,
  height: 400,
)
```

It reads the bytes from the asset bundle, resolves sibling reference textures
from the key's own folder (embedded packs too), selects the pack's first
animation, loops it, and disposes everything with the widget. `animation:`
chooses another; `placeholder:` is what to show until the first frame is
drawable; `onError:` hears about a load that failed.

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
    await _player.loadAsset('assets/overall/Basic.ssab');
    _player
      ..setAnimation(_player.animationNames.first)
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
  adapter ([`ssplayer_flame`](../ssplayer_flame)) hands the game loop's time to
  the same player.
* **Every buffer the Brain hands over is valid until the next `update`.** That
  rule is the reason for the `dispose` discipline above; hold the player, not
  the frames.
* **A pack is either Reference or Embedded.** Reference packs load sibling PNG /
  WebP files from the asset key's own folder; embedded packs carry their
  textures and need nothing else. `loadAsset` handles both.
* **The `.sspj` → `.ssab` conversion is a host-side step**, not something the
  runtime does — see [`ssconverter_dart`](../ssconverter_dart).
* **Web is a developer preview.** There is no `dart:ffi` there; the Brain is a
  wasm module driven over `dart:js_interop`, so call `await loadSsRuntime()`
  once before `runApp` (a no-op on native).

## More

* [Documentation](https://cri-middleware.github.io/SSPlayerForFlutter/)
* [Live Web demo](https://cri-middleware.github.io/SSPlayerForFlutter/demo/flutter/) — this API running in a browser
* [What is and is not supported](https://cri-middleware.github.io/SSPlayerForFlutter/limitations/)
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter) · example app under [`examples/overall`](../../examples/overall)
