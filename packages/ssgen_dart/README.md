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

Take it as a git dependency on a release tag, `ssgen_dart-v<version>` on
[Releases](https://github.com/cri-middleware/SSPlayerForFlutter/releases?q=ssgen_dart&expanded=true),
with `ssconverter_dart` from the same tag under `dependency_overrides`, since `ssgen_dart` names it
by version ([Installation](https://cri-middleware.github.io/SSPlayerForFlutter/guide/install/)):

```yaml
dev_dependencies:
  ssgen_dart:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssgen_dart-v<version>
      path: packages/ssgen_dart

dependency_overrides:
  ssconverter_dart:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssgen_dart-v<version>
      path: packages/ssconverter_dart
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

* [Live reload](https://cri-middleware.github.io/SSPlayerForFlutter/guide/live-reload/) — the loop this package sits in
* [Live Web demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/)
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter)
