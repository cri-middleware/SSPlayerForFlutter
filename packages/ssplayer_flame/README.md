# ssplayer_flame

[Flame](https://flame-engine.org/) adapter for
[`ssplayer_flutter`](../ssplayer_flutter) — play a **SpriteStudio `.ssab`**
animation inside a `FlameGame` with a single component.

`SpriteStudioComponent` is a Layer‑4 drawing adapter (a sibling to the
Widget‑based `SpriteStudioView`). It owns an **externally‑clocked**
`SpriteStudioPlayer`: Flame's game loop supplies the time — `update(dt)` forwards
to the player and `render` delegates to the same Layer‑2 paint path the Widget
uses. The whole rich player surface (transport, events, instance packs, texture
loading) is reused as‑is; only the clock differs.

The heavy SpriteStudio dependency (the `dart:ffi` Rust "Brain", textures) comes
transitively via `ssplayer_flutter`, delivered by **native assets** — no
CocoaPods, no framework to embed. Adding this package to `ssplayer_flutter`
directly was avoided on purpose: the core Widget/headless player never pays for
Flame; an app opts in by depending on `ssplayer_flame`.

The [documentation](https://cri-middleware.github.io/SSPlayerForFlutter/) covers both packages. The
same pages for this version are in this package's `doc/` as Markdown, readable offline: start at
`doc/index.md`, and the Flame page is `doc/guide/flame.md`. They are also the Agent Skill
`skills/ssplayer-flame-docs/`, which `dart run skills@ get` installs into your coding agent's skills
directory.

## Install

```bash
flutter pub add flame ssplayer_flame
```

`ssplayer_flutter` and `ssruntime_dart` come with `ssplayer_flame` ([Installation](https://cri-middleware.github.io/SSPlayerForFlutter/guide/install/)).
`ssplayer_flame` re‑exports the entire `ssplayer_flutter` API, so a single
`import 'package:ssplayer_flame/ssplayer_flame.dart';` gives you both
`SpriteStudioComponent` and `SpriteStudioPlayer`.

## Use

```dart
import 'package:flame/game.dart';
import 'package:ssplayer_flame/ssplayer_flame.dart';

class MyGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    // Straight from a bundled asset key… reference textures (sibling PNGs)
    // resolve from the key's own folder, so no baseAssetDir is needed.
    add(SpriteStudioComponent.asset(
      'assets/hero.ssab',
      position: size / 2,
      anchor: Anchor.center,         // SpriteStudio origins are centered
    ));

    // …or from bytes you already have (e.g. downloaded). With no asset key,
    // pass baseAssetDir so the reference textures still resolve:
    // add(SpriteStudioComponent(ssab: bytes, baseAssetDir: 'assets'));
  }
}
```

Control playback through the underlying player once it has loaded:

```dart
component.player?.pause();
component.player?.setAnimation('run');
component.player?.seek(0);
```

### Notes

* The animation is centered inside the component's box (`size`): its world origin
  lands on the box centre (`size / 2` in local space), exactly like
  `SpriteStudioView`. With the default zero `size` that is the component's
  `position`.
* `loopCount` / `speed` / `subFrame` / `animation` / `autoStart` are constructor
  options; anything finer goes through `component.player`.
* `SpriteStudioComponent.asset` resolves reference textures (sibling PNGs) from
  the asset key's own folder — no `baseAssetDir` needed. Pass `baseAssetDir` only
  with the bytes constructor (no asset key), or when the textures live in a
  different folder (a shared atlas). Embedded‑texture packs need nothing.

## Example

For an on‑screen check, run the example app under
[`examples/flame`](../../examples/flame).
