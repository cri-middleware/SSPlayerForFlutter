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
3. The new pack is **pushed directly to the running app over the VM Service** (no keypress; works
   alongside an IDE debugger — the same mechanism on desktop and device).
    - **Desktop** — the app reads the re-converted `.ssab` off disk.
    - **Device (iOS / Android)** — a texture-embedded `.ssab` is sent as bytes (a device can't read a
      host path).
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

3. Run `sswatch`. One tool, one mechanism (VM Service push) — you only choose **how you launch**
   (opt in with the `SS_LIVE_RELOAD` define; a plain `flutter run` does **not** re-convert art).

    ```bash
    # One command (wraps `flutter run` and injects the define)
    dart run ssgen_flutter:sswatch --run -d macos                 # desktop
    dart run ssgen_flutter:sswatch --run -d <emulator> --device   # device (embedded push)

    # Launching from your IDE instead (keep the debugger; attach) — pass
    #   --dart-define=SS_LIVE_RELOAD=true --vmservice-out-file=/tmp/ss.uri to the launch, then:
    dart run ssgen_flutter:sswatch --vmservice-uri-file=/tmp/ss.uri   # add --device for a device
    ```

    A device can't convert on-device, so the host-side `sswatch` sends an embedded `.ssab` as bytes.

Place your source projects under `SpriteStudio_Source/<project>/`. Save a real edit (a `touch` produces
identical bytes — and may not even trip the watcher).

## Platform status

| Platform | Path | Status |
|---|---|---|
| macOS desktop | VM Service push (file) | Verified end-to-end |
| Android | VM Service push (embedded) | Verified end-to-end (emulator) |
| iOS | VM Service push (embedded) | Expected, not yet confirmed |
| Windows / Linux desktop | VM Service push (file) | Expected (OS-independent), not yet confirmed |

For a one-off manual conversion instead, see [CLI Conversion](conversion.md).
