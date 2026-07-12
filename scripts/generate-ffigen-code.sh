#!/usr/bin/env bash
#
# Generate the Layer-1 dart:ffi bindings (ffigen) for EVERY package that carries
# an ffigen config, from the plain-C headers the native build already produced:
#
#   packages/ssplayer_flutter/native/include/ssruntime.h   -> lib/src/bindings/*.g.dart
#   packages/ssconverter_dart/native/include/ssconverter.h  -> lib/src/*.g.dart
#
# The headers are emitted by the SpriteStudio-SDK `build.rs` (cbindgen, C) and
# copied into each package's native/include/ by build-runtime.sh / download-sdk.sh
# — so this script runs NO cbindgen of its own. It is invoked automatically at the
# end of build-runtime / download-sdk (ffigen is Flutter/Dart-specific; folding it
# in keeps the dev-facing script set the same size as the sibling players). Run it
# directly only when you changed an ffigen*.yaml but not the native library.
#
# The generated bindings are gitignored — regenerated from the native C-API on
# every build. The .fbs FlatBuffers accessors are a separate concern (see
# scripts/generate-fbs-code.sh).
#
# Prerequisites: Dart/Flutter SDK (ffigen needs libclang; `dart pub get` first).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v dart >/dev/null; then
  echo "generate-ffigen-code.sh: dart not found — skipping ffigen (bindings are regenerated once the Dart SDK is installed)"
  exit 0
fi

shopt -s nullglob
configs=("$ROOT_DIR"/packages/*/ffigen*.yaml)
shopt -u nullglob
if [ "${#configs[@]}" -eq 0 ]; then
  echo "generate-ffigen-code.sh: no packages/*/ffigen*.yaml — nothing to do"
  exit 0
fi

echo "Generating ffigen bindings (dart run ffigen)..."
for cfg in "${configs[@]}"; do
  pkg_dir="$(dirname "$cfg")"
  pkg="$(basename "$pkg_dir")"
  name="$(basename "$cfg")"
  ( cd "$pkg_dir" && dart pub get >/dev/null 2>&1 ) || true
  ( cd "$pkg_dir" && dart run ffigen --config "$name" ) \
    && echo "   -> $pkg ($name)" \
    || echo "   ($pkg/$name skipped — check the ffigen dev_dependency + native/include/*.h)"
done

echo "generate-ffigen-code.sh: done."
