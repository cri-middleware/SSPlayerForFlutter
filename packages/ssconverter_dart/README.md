# ssconverter_dart

Turn SpriteStudio 7 projects (`.sspj`) into the optimized runtime packs
(`.ssab`) the player loads — a `dart:ffi` wrapper and an `ssconvert` CLI over
the SpriteStudio-SDK converter (`libssconverter`).

**A host tool, desktop only** (macOS / Windows / Linux). Conversion happens on
your machine or in CI; the app ships the `.ssab`. Its native library is
downloaded by the package build hook, so this works out of the box — **no Rust
toolchain, no separate binary to install**.

## Install

Until the first pub.dev release, take it from the
[GitHub Releases bundle](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest):

```yaml
dev_dependencies:
  ssconverter_dart:
    path: vendor/SSPlayerForFlutter/packages/ssconverter_dart
```

A `dev_dependency` is usually right: nothing in a shipped app calls the
converter.

## Use

```bash
dart run ssconverter_dart:ssconvert    -o out/     path/to/project.sspj  # reference textures
dart run ssconverter_dart:ssconvert -e -o out_emb/ path/to/project.sspj  # embedded
```

Because it is a plain `dart run`, it drops into any Dart/Flutter CI job with no
extra binaries — convert straight into the app's `assets/` as a build step.

The same engine is available programmatically for custom tooling:

```dart
import 'package:ssconverter_dart/ssconverter_dart.dart';

// Returns the output directory; throws SsConverterException on a converter error.
final out = await const SsConverter()
    .convert('path/to/project.sspj', outputDir: 'out', embedded: true);
```

### Notes

* **`-e` / `embedded` produces a single self-contained `.ssab`** with its
  textures inside — the recommended form for device and OTA distribution. The
  default reference form keeps the PNG / WebP files beside the pack.
* **Keep `.sspj` sources out of the shipped app.** Manage them outside the
  Flutter package and commit only the converted `.ssab`; the game never needs
  the source data.
* **Reconverting a whole directory on every hot reload is a different job** —
  see [`ssgen_dart`](../ssgen_dart), which reconverts only what went stale.
* Other front-ends for the same converter: the
  [SSConverterGUI](https://github.com/cri-middleware/SSConverterGUI) desktop app
  and the SDK's own `ssconverter-cli`.

## More

* [Preparing assets (`.sspj` → `.ssab`)](https://cri-middleware.github.io/SSPlayerForFlutter/guide/conversion/) — 🚧 live after the first release
* [Live Web demos](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — packs built by this converter, playing — 🚧 live after the first release
* [Repository](https://github.com/cri-middleware/SSPlayerForFlutter)
