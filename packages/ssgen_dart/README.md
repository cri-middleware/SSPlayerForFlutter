# ssgen_dart

Reconvert only the SpriteStudio projects that went **stale** — a thin
orchestration layer over [`ssconverter_dart`](../ssconverter_dart): scan a
directory, compare mtimes against the converted output, and convert what
changed.

**Desktop only** (macOS / Windows / Linux), pure Dart, and deliberately small:
no CLI, no watcher, no daemon state. One shot per call, triggered by whoever
owns the loop — typically the `sswatch` runner in
[`ssgen_flutter`](../ssgen_flutter), which watches the source tree and pushes
what this reconverted into the running app.

It lives outside [`ssplayer_flutter`](../ssplayer_flutter) on purpose: the
runtime an app ships stays converter-free.

## Install

Until the first pub.dev release, take it from the
[GitHub Releases bundle](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest):

```yaml
dev_dependencies:
  ssgen_dart:
    path: vendor/SSPlayerForFlutter/packages/ssgen_dart
```

## Use

```dart
import 'package:ssgen_dart/ssgen_dart.dart';

final SsReconvertReport report = await const SsProjectSync().reconvert();
```

With no arguments it follows the convention — `SpriteStudio_Source/` in,
`assets/spritestudio/<stem>/` out — resolved from the current directory, or from
a `spritestudio.yaml` beside the sources. `reconvert()` takes `projectRoot` /
`sourceDir` / `outputDir` / `embedded` to override any of that.

### Notes

* **Staleness is an mtime diff over the whole project directory**, not just the
  `.sspj`: editing a referenced `.ssae` or `.png` rebuilds it too, and a project
  with no output yet always counts as stale.
* **It converts; it does not reload.** Pushing the fresh pack into a running app
  is [`ssgen_flutter`](../ssgen_flutter)'s job (and the player's `reload`).
* Converting one project by hand, or in CI, is
  [`ssconverter_dart`](../ssconverter_dart) — this package is for the
  edit-to-runtime loop.

## More

* [Live reload](https://cri-middleware.github.io/SSPlayerForFlutter/guide/live-reload/) — the loop this package sits in — 🚧 live after the first release
* [Live Web demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — 🚧 live after the first release
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter)
