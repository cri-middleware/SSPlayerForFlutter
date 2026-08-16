# ssplayer_flutter

Play **OPTPiX SpriteStudio 7** raster animations (`.ssab`) natively in Flutter —
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

Until the first pub.dev release, take the packages from the
[GitHub Releases bundle](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest)
and reference the extracted folder:

```yaml
dependencies:
  ssplayer_flutter:
    # The bundle keeps the packages/ layout, so ssruntime_dart resolves with it.
    path: vendor/SSPlayerForFlutter/packages/ssplayer_flutter
```

Needs **Flutter 3.38+ / Dart 3.10+** (native assets stable and default-on).

## Use

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Reads the bytes from the asset bundle and resolves sibling reference
    // textures from the key's own folder (embedded packs too).
    await _player.loadAsset('assets/overall/Basic.ssab');
    _player
      ..setupAnimation(_player.getAnimations().first)
      ..loop = -1
      ..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

`SpriteStudioView` is a plain `RenderBox` — position, transform and clip it like
any other widget.

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

* [Documentation](https://cri-middleware.github.io/SSPlayerForFlutter/) — 🚧 live after the first release
* [Live Web demo](https://cri-middleware.github.io/SSPlayerForFlutter/demo/flutter/) — this API running in a browser — 🚧 live after the first release
* [What is and is not supported](https://cri-middleware.github.io/SSPlayerForFlutter/limitations/)
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter) · example app under [`examples/overall`](../../examples/overall)
