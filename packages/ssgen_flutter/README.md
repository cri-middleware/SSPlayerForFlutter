# ssgen_flutter

Live-reload for SpriteStudio art: save a `.sspj` in your editor and watch the
running app swap the animation in place — no `r`, no restart, no rebuild.

**Dev tooling only.** The host runner (`sswatch`) watches your sources,
reconverts what went stale through [`ssgen_dart`](../ssgen_dart), and pushes the
fresh pack into the running app over the VM Service, where the `SsLiveReload`
mixin hands it to the player's `reload`. Add this package only in apps that want
that loop — the [`ssplayer_flutter`](../ssplayer_flutter) runtime itself stays
converter-free.

## Install

Until the first pub.dev release, take it from the
[GitHub Releases bundle](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest):

```yaml
dev_dependencies:
  ssgen_flutter:
    path: vendor/SSPlayerForFlutter/packages/ssgen_flutter
```

## Use

Mix `SsLiveReload` into the `State` that owns the player, and point it at the
player and the pack it is showing:

```dart
class _MyState extends State<MyPage>
    with SingleTickerProviderStateMixin, SsLiveReload<MyPage> {
  // ... the mixin registers with the in-app dev channel and applies pushes.
}
```

Then run the watcher — one tool, one mechanism; you only choose how the app is
launched:

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
  works from an IDE debugger session as well as from `--run`. Apps that wire
  their own target instead of using the mixin can talk to `SsDevChannel`
  directly.

## More

* [Live reload](https://cri-middleware.github.io/SSPlayerForFlutter/guide/live-reload/) — the full setup — 🚧 live after the first release
* [Live Web demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — 🚧 live after the first release
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter)
