# Build Guide

For developing the core (the Rust runtime or the Player itself). **App users and customizers do not
need this** — the native libraries are auto-downloaded (see
[Native Runtime](native-runtime.md)).

## Prerequisites

| Tool | When |
|---|---|
| Rust (`rustup`) | Building the native libs from source |
| Flutter 3.38+ / Dart 3.10+ | Always (native assets is stable and default-on) |
| `flatc` | Only when regenerating a `.fbs` schema |
| cbindgen | Never install manually — it is a build-dependency of the SDK's `build.rs` |

Clone with submodules — the SDK (the Brain's source) is a git submodule:

```bash
git submodule update --init --recursive
```

## Build from source

```bash
# Build the native libs + copy the C headers into each binding package's native/include/
scripts/build-runtime.sh              # e.g. build-runtime.sh platform=macos build=release

# Generate example assets, then run
scripts/deploy-examples.sh
cd examples/overall && flutter run    # expect [ssplayer] OK + on-screen animation
```

Windows uses the `.ps1` variant of each script. Cross-builds for android / ios / web are delegated to
`SpriteStudio-SDK/scripts/release-*`; `build-runtime` itself builds the host target directly.

!!! note "First macOS runner"
    If `examples/overall/macos/` is missing, generate it once:
    `cd examples/overall && flutter create --platforms=macos .`

## Code generation (committed; regenerate on change)

Generated code is **committed** so a normal checkout / pub.dev consumer builds without ffigen or
flatc. Regenerate and commit after the corresponding change:

- **ffigen bindings** (`lib/src/*_bindings.g.dart`) — after a C-API change, run
  `scripts/generate-ffigen-code.sh` and commit. This is **standalone** — `build-runtime` does *not*
  run it.
- **FlatBuffers** (`lib/src/ssab/*.g.dart` asset format; `ssruntime_dart` runtime fbs) — after a
  `.fbs` change, run `scripts/generate-fbs-code.sh`.

## Verify

```bash
# in packages/ssplayer_flutter/
flutter analyze lib test
flutter test          # native assets bundles the Brain via hook/build.dart — no env vars, no framework
```

`ssruntime_dart` and `ssconverter_dart` each run `dart test` in their own package.

| Check | Where |
|---|---|
| Analyze + unit/render tests | `packages/ssplayer_flutter/` |
| L1 bindings smoke | `packages/ssruntime_dart/` (`dart test`) |
| Converter smoke + CLI | `packages/ssconverter_dart/` (`dart test`) |
| macOS embedding | `examples/overall/` → `flutter build macos` → `ssruntime.framework` under `*.app/Contents/Frameworks/` |

See [`AGENTS.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/AGENTS.md) for the
full implementation rules and hard-won gotchas (FFI pointer lifetime, the `updateFlag` trap, UV pixel
coordinates, native-asset packaging).
