# Live Reload

Live reload closes the edit-to-runtime loop: **save a `.sspj` in SpriteStudio 7 and the running app
updates** — only the changed project is re-converted, and the player keeps its transport state (the
current animation and frame keep playing). It piggybacks on Flutter's development workflow, so
animation editing gets the same fast iteration as a code hot reload.

!!! note "🚧 Developing — opt-in, not yet in a release"
    This is dev-only tooling under active development. It is **off by default** and never affects
    release builds. Commands and flags may still change before the first release.

## What it is

- Provided by the
  [`ssgen_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_flutter)
  dev tooling (built on `ssgen_dart`, which drives [conversion](conversion.md)).
- The player runtime (`ssplayer_flutter`) stays **converter-free** — nothing extra ships in your app.
  The converter lives only in the development tooling.

## How it works

1. A host watcher observes your `SpriteStudio_Source/` directory while the app runs.
2. On save, the changed project is re-converted to `.ssab` (stale-checked by modified time — only what
   changed is rebuilt).
3. The new pack reaches the running app:
    - **Desktop** — pushed directly over the VM Service (no keypress; works alongside an IDE debugger).
    - **Device (iOS / Android)** — delivered through Flutter's hot reload.
4. The player calls `reload()`, swapping the resource while preserving playback state.

## Enabling it (recipe)

1. Add `ssgen_flutter` to your app's `pubspec.yaml`.
2. Mix `SsLiveReload` into your `State` and point it at your player and current pack:

    ```dart
    class _MyPageState extends State<MyPage>
        with SingleTickerProviderStateMixin, SsLiveReload<MyPage> {
      @override SpriteStudioPlayer get ssPlayer => _player;
      @override String get ssAssetDir => 'assets/spritestudio/overall'; // current pack's output dir
      @override String get ssPack => _pack;                             // current pack (.ssab stem)
      @override void ssOnLiveReloaded() => setState(() {});             // optional UI refresh
    }
    ```

3. Launch with the opt-in define (a plain `flutter run` does **not** re-convert art):
    - **Desktop** — run with `--dart-define=SS_LIVE_RELOAD=true` (and expose the VM Service URI), then
      attach the watcher: `dart run ssgen_flutter:sswatch`.
    - **Device** — `dart run ssgen_flutter:ssdev -d <device>` replaces `flutter run`, injects the
      define, and re-converts + hot-reloads on save.

Place your source projects under `SpriteStudio_Source/<project>/`. Save a real edit (a `touch` produces
identical bytes and won't appear to change anything).

## Platform status

| Platform | Path | Status |
|---|---|---|
| macOS desktop | VM Service push | Verified end-to-end |
| iOS / Android | hot reload / `reassemble` | Working |
| Windows / Linux desktop | VM Service push | Expected (OS-independent), not yet confirmed |

For a one-off manual conversion instead, see [CLI Conversion](conversion.md).
