# ssgen_flutter

Live-reload for SpriteStudio art: save a `.sspj` in your editor and watch the
running app swap the animation in place — no `r`, no restart, no rebuild.

**Dev tooling only.** The host runner (`sswatch`) watches your sources,
reconverts what went stale through [`ssgen_dart`](../ssgen_dart), and pushes the
fresh pack into the running app over the VM Service, where
[`ssplayer_flutter`](../ssplayer_flutter) hands it to the player's `reload`. The
app never imports this package, and the runtime stays converter-free: the
receiving end comes up only in a debug build launched for it.

## Install

```bash
flutter pub add --dev ssgen_flutter
```

`ssplayer_flutter`, `ssgen_dart`, `ssconverter_dart` and `ssruntime_dart` come with it — see
[Installation](https://cri-middleware.github.io/SSPlayerForFlutter/guide/install/).

## Use

There is nothing to add to the app. A player that loads its pack by asset key —
every `SpriteStudioAnimation`, and `SpriteStudioPlayer.loadAsset` — takes the
push by itself. Run the watcher — one tool, one mechanism; you only choose how
the app is launched:

```bash
dart run ssgen_flutter:sswatch --run -d macos                # desktop
dart run ssgen_flutter:sswatch --run -d <emulator> --device  # device
```

### Notes

* **A device cannot convert on-device**, so `sswatch` converts on the host and
  sends an embedded `.ssab` as bytes.
* **It is opt-in at build time.** Apps gate on the `SS_LIVE_RELOAD`
  `--dart-define` (`ssLiveReloadDefine`); `sswatch --run` injects it, so a
  release build carries none of this.
* **The push channel is the VM Service** (`ext.ssgen.reload`), which is why this
  works from an IDE debugger session as well as from `--run`.
* **A player loaded from bytes** has no asset key to be found by. Mix
  `ssplayer_flutter`'s `SsLiveReload` into the `State` that owns it — which also
  lets a screen react to the reload.

## More

* [Live reload](https://cri-middleware.github.io/SSPlayerForFlutter/guide/live-reload/) — the full setup
* [Live Web demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/)
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter)
