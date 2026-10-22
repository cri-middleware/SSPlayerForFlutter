#!/usr/bin/env bash
#
# Generate the Layer-1 dart:ffi bindings (ffigen) for EVERY package that carries
# an ffigen generator (tool/ffigen.dart), from the plain-C headers the native
# build already produced:
#
#   packages/ssruntime_dart/native/include/ssruntime.h     -> lib/src/ssruntime_bindings.g.dart
#   packages/ssconverter_dart/native/include/ssconverter.h -> lib/src/ssconverter_bindings.g.dart
#
# The headers are emitted by the SpriteStudio-SDK `build.rs` (cbindgen, C) and
# copied into each package's native/include/ by build-runtime.sh — so this script
# runs NO cbindgen of its own. It is a STANDALONE step (NOT part of build-runtime,
# like generate-fbs-code): run it after a C-API change (or a tool/ffigen.dart
# edit), then commit the result.
#
# The generated bindings are COMMITTED (so a normal checkout / pub.dev consumer
# builds without ffigen). The .fbs FlatBuffers accessors are a separate concern
# (see scripts/generate-fbs-code.sh).
#
# Prerequisites: Dart/Flutter SDK (ffigen needs libclang; `dart pub get` first).
set -euo pipefail

if [ "$#" -gt 0 ]; then
  echo "$(basename "$0"): takes no arguments — what it does is in its header comment" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v dart >/dev/null; then
  echo "generate-ffigen-code.sh: dart not found — skipping ffigen (bindings are regenerated once the Dart SDK is installed)"
  exit 0
fi

shopt -s nullglob
generators=("$ROOT_DIR"/packages/*/tool/ffigen.dart)
shopt -u nullglob
if [ "${#generators[@]}" -eq 0 ]; then
  echo "generate-ffigen-code.sh: no packages/*/tool/ffigen.dart — nothing to do"
  exit 0
fi

echo "Generating ffigen bindings (dart run tool/ffigen.dart)..."
for gen in "${generators[@]}"; do
  pkg_dir="$(dirname "$(dirname "$gen")")"
  pkg="$(basename "$pkg_dir")"
  ( cd "$pkg_dir" && dart pub get >/dev/null 2>&1 ) || true
  ( cd "$pkg_dir" && dart run tool/ffigen.dart ) \
    && echo "   -> $pkg (tool/ffigen.dart)" \
    || echo "   ($pkg/tool/ffigen.dart skipped — check the ffigen dev_dependency + native/include/*.h)"
done

echo "generate-ffigen-code.sh: done."
