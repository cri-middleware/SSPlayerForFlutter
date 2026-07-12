#!/usr/bin/env bash
#
# Generate the Layer-1 dart:ffi bindings (ffigen) from the plain-C headers the
# native build already produced:
#
#   native/include/ssruntime.h  (+ ssconverter.h)  ->  lib/src/bindings/*.g.dart
#
# The headers are emitted by the SpriteStudio-SDK `build.rs` (cbindgen, C) and
# copied into native/include/ by build-runtime.sh / download-sdk.sh — so this
# script runs NO cbindgen of its own. It is invoked automatically at the end of
# build-runtime / download-sdk (ffigen is Flutter-specific; folding it in keeps
# the dev-facing script set the same size as the sibling players). Run it
# directly only when you changed an ffigen*.yaml but not the native library.
#
# The generated bindings are gitignored — they are regenerated from the native
# C-API on every build. The .fbs FlatBuffers accessors are a separate concern —
# see scripts/generate-fbs-code.sh.
#
# Prerequisites: Dart/Flutter SDK (ffigen needs libclang; `dart pub get` first).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packages/ssplayer_flutter"
INCLUDE_DIR="$PKG_DIR/native/include"

if ! command -v dart >/dev/null; then
  echo "generate-ffigen-code.sh: dart not found — skipping ffigen (bindings are regenerated once the Dart SDK is installed)"
  exit 0
fi

# ffigen reads native/include/*.h; warn (don't fail) if the native build has not
# placed them yet — running build-runtime.sh / download-sdk.sh first is expected.
if [ ! -f "$INCLUDE_DIR/ssruntime.h" ]; then
  echo "generate-ffigen-code.sh: $INCLUDE_DIR/ssruntime.h not found — run build-runtime.sh or download-sdk.sh first" >&2
fi

shopt -s nullglob
configs=("$PKG_DIR"/ffigen*.yaml)
shopt -u nullglob
if [ "${#configs[@]}" -eq 0 ]; then
  echo "generate-ffigen-code.sh: no ffigen*.yaml under $PKG_DIR — nothing to do"
  exit 0
fi

echo "Generating ffigen bindings (dart run ffigen)..."
( cd "$PKG_DIR" && dart pub get >/dev/null 2>&1 ) || true
for cfg in "${configs[@]}"; do
  name="$(basename "$cfg")"
  ( cd "$PKG_DIR" && dart run ffigen --config "$name" ) \
    && echo "   -> ffigen($name)" \
    || echo "   (ffigen $name skipped — check that ffigen is a dev_dependency)"
done

echo "generate-ffigen-code.sh: done."
