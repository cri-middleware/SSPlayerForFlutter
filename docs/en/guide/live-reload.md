# ♻️ Live Reload

Live reload closes the edit-to-runtime loop: **save a `.sspj` in SpriteStudio and the running app
updates** — only the changed project is re-converted, and the player keeps its transport state (the
current animation and frame keep playing). It piggybacks on Flutter's development workflow, so
animation editing gets the same fast iteration as a code hot reload.

## What it is

- The watcher is `sswatch`, from the
  [`ssgen_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_flutter)
  dev tooling (built on `ssgen_dart`, which drives [conversion](conversion.md)). It is a **dev
  dependency**: your app never imports it.
- The player runtime (`ssplayer_flutter`) stays **converter-free**. The converter lives only in the
  watcher; what the app holds is the end that receives the push.
- **Debug builds only, and off by default** — that end comes up only in a debug build launched with
  the `SS_LIVE_RELOAD` define (below). Any other build, a release build included, compiles it out.

## How it works

1. A host watcher observes your `SpriteStudio_Source/` directory while the app runs.
2. On save, the changed project is re-converted to `.ssab` (stale-checked by modified time — only what
   changed is rebuilt).
3. The new pack is **pushed directly to the running app over the VM Service** (no keypress; works
   alongside an IDE debugger — the same mechanism on desktop, device and the web).
    - **Desktop** — the app reads the re-converted `.ssab` off disk.
    - **Device (iOS / Android)** — a texture-embedded `.ssab` is sent as bytes (a device can't read a
      host path). The pack is routed by convention: the **last folder of the pack's asset key**
      (`assets/spritestudio/Ringo/Ringo.ssab` → `Ringo`) names the `<stem>.sspj` it came from. `sswatch` says so on stderr when the two disagree —
      nothing is pushed until they match.
    - **Web (`flutter run -d chrome`, debug)** — like a device, a texture-embedded `.ssab` is sent as
      bytes; the VM Service extension is routed by DWDS. Debug builds only: a `--wasm`
      build exposes no VM Service, so `sswatch --run` refuses `--wasm` up front.
4. The player calls `reload()`, swapping the resource while preserving playback state. If it
   throws, `sswatch` prints the app's error on stderr.
5. On `--device`, `assets/` is re-converted too, after the push. A byte push only reaches the
   running isolate, so without this the next hot restart would drop back to the art bundled at
   launch. It costs a second conversion per save; desktop needs none, as its reconvert already
   writes into `assets/`.

## Enabling it (recipe)

1. Add `ssgen_flutter` to your app's `dev_dependencies`: `flutter pub add --dev ssgen_flutter`
   ([Installation](install.md)).
2. Nothing in the app. A player that loads its pack by asset key — every `SpriteStudioAnimation`, and
   any `SpriteStudioPlayer` you `loadAsset` — takes the push by itself.
3. Run `sswatch`. One tool, one mechanism (VM Service push) — you only choose **how you launch**
   (opt in with the `SS_LIVE_RELOAD` define; a plain `flutter run` does **not** re-convert art).

    ```bash
    # One command (wraps `flutter run` and injects the define)
    dart run ssgen_flutter:sswatch --run -d macos                 # desktop (macOS: turn the App Sandbox off for debug first, see the warning below)
    dart run ssgen_flutter:sswatch --run -d <emulator> --device   # device (embedded push)
    dart run ssgen_flutter:sswatch --run -d chrome --device       # web (embedded push; debug DDC)

    # Launching from your IDE instead (keep the debugger; attach) — pass
    #   --dart-define=SS_LIVE_RELOAD=true --vmservice-out-file=/tmp/ss.uri to the launch, then:
    dart run ssgen_flutter:sswatch --vmservice-uri-file=/tmp/ss.uri   # add --device for a device
    ```

    A device can't convert on-device, so the host-side `sswatch` sends an embedded `.ssab` as bytes.
    `--run` hands `flutter run` the terminal, so its own keys (`r`, `R`, `q`) keep working alongside
    the watcher.

Place your source projects under `SpriteStudio_Source/<project>/`. `sswatch` works relative to the
directory you run it in — your app's root: it watches `SpriteStudio_Source/` and writes
`assets/spritestudio/<project>/`. To use other folders, put a `spritestudio.yaml` there (`source:`,
`output:`, `embedded:`), or point at another root with `--project-root=<dir>`. Save a real edit (a `touch` produces
identical bytes — and may not even trip the watcher).

!!! tip "A player loaded from bytes, or a screen that reacts to the reload"
    A player that loaded bytes — a download, a file picked at runtime — has no asset key to be found
    by. Mix `SsLiveReload` into the `State` that owns it and name the pack. The same mixin lets a
    screen react to a reload, and turn it off while it shows something the watcher does not own.
    Where it names a player that also joined by itself, the mixin is the one used.

    ```dart
    class _MyPageState extends State<MyPage>
        with SingleTickerProviderStateMixin, SsLiveReload<MyPage> {
      @override SpriteStudioPlayer get ssPlayer => _player;
      @override String get ssAssetDir => 'assets/spritestudio/overall'; // current pack's output dir
      @override String get ssPack => _pack;                             // current pack (.ssab stem)
      @override void ssOnLiveReloaded() => setState(() {});             // optional UI refresh
    }
    ```

!!! warning "macOS desktop: the App Sandbox blocks the file push"
    A `file` push hands the app a host path outside its container, so a sandboxed debug build
    cannot read it and the push reports `reloaded 0 player(s)` with no error. Set
    `com.apple.security.app-sandbox` to `false` in `macos/Runner/DebugProfile.entitlements`
    (debug only — Release keeps the sandbox on). `--device` is unaffected: those bytes travel
    over the VM Service.

## Platform status

| Platform | Path | Status |
|---|---|---|
| macOS desktop | VM Service push (file) | Supported |
| Android | VM Service push (embedded) | Supported |
| iOS | VM Service push (embedded) | Supported |
| Web (`-d chrome`, debug) | VM Service push (embedded, via DWDS) | Supported |
| `--wasm`, `--release`, `--profile` | — | Not possible: the first two have no VM Service, and a profile build has no push channel. `sswatch --run` refuses them |

`--device` is a choice of payload, not of target: it sends the pack as bytes instead of a host path,
and any target accepts it. Running `sswatch --run -d macos --device` therefore exercises the whole
embedded path — routing, transport, `reload()` — on a machine with no device attached, which is a
quick way to tell a broken push from a target that simply is not connected.

Save a **real** edit to test it. A `touch` does not reliably reach the watcher (it can produce no event
at all), which is a property of the filesystem watch, not of the reload.

For a one-off manual conversion instead, see [Preparing Assets](conversion.md).
