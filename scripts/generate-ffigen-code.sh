#!/usr/bin/env bash
#
# Generate the Layer-1 dart:ffi bindings (ffigen) for EVERY package that carries
# an ffigen config, from the plain-C headers the native build already produced:
#
#   packages/ssruntime_dart/native/include/ssruntime.h     -> lib/src/ssruntime_bindings.g.dart
#   packages/ssconverter_dart/native/include/ssconverter.h -> lib/src/ssconverter_bindings.g.dart
#
# The headers are emitted by the SpriteStudio-SDK `build.rs` (cbindgen, C) and
# copied into each package's native/include/ by build-runtime.sh — so this script
# runs NO cbindgen of its own. It is a STANDALONE step (NOT part of build-runtime,
# like generate-fbs-code): run it after a C-API change (or an ffigen*.yaml edit),
# then commit the result.
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
