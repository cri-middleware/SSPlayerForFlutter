#!/usr/bin/env bash
#
# Convert the SDK's bundled test project (tests/overall/overall.sspj) into .ssab
# assets for the example app, using the Dart `ssconvert` CLI (ssconverter_dart).
# It loads the PREBUILT libssconverter over dart:ffi, so this needs NO Rust
# toolchain — build the native libs via scripts/build-runtime.sh.
# All the sibling players share this "Rust-free for customizers" philosophy.
# Output lands in example/assets/overall/ (referenced by example/pubspec.yaml).
#
# SDK location (for the source .sspj): $SSSDK, else ./SpriteStudio-SDK, else
# ../SpriteStudio-SDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/example/assets/overall"
CONV_PKG="$ROOT_DIR/packages/ssconverter_dart"

SDK_DIR="${SSSDK:-}"
if [ -z "$SDK_DIR" ]; then
  for cand in "$ROOT_DIR/SpriteStudio-SDK" "$ROOT_DIR/../SpriteStudio-SDK"; do
    if [ -f "$cand/Cargo.toml" ]; then SDK_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi
[ -n "$SDK_DIR" ] && [ -f "$SDK_DIR/tests/overall/overall.sspj" ] || {
  echo "prepare-example-assets.sh: overall.sspj not found (init the SpriteStudio-SDK submodule or set SSSDK)" >&2
  exit 1
}

command -v dart >/dev/null || {
  echo "prepare-example-assets.sh: dart not found (install the Dart/Flutter SDK)" >&2
  exit 1
}

# The non-embedded converter writes the .ssab files AND copies the referenced
# textures/fonts/sounds into OUT_DIR, so this single call produces the complete
# example asset tree. libssconverter is delivered via native assets — the
# package's hook/build.dart bundles the prebuilt dylib (build-runtime.sh
# produces it); no SSCONVERTER_LIBRARY_PATH needed.
echo "Converting tests/overall/overall.sspj via ssconvert (Dart) ..."
mkdir -p "$OUT_DIR"
( cd "$CONV_PKG" && dart pub get >/dev/null 2>&1 && \
  dart run ssconverter_dart:ssconvert -o "$OUT_DIR" "$SDK_DIR/tests/overall/overall.sspj" )
echo "   -> example/assets/overall/"
echo "prepare-example-assets.sh: done."
