#!/usr/bin/env bash
#
# Stage the SDK's bundled test project (tests/overall) into the example's
# SpriteStudio_Source/, then convert THAT copy into .ssab assets, using the Dart
# `ssconvert` CLI (ssconverter_dart). SpriteStudio_Source is the single source of
# truth the desktop live-reload (example reassemble()) reconverts on hot reload,
# so the initial assets and the live output come from the same place.
# It loads the PREBUILT libssconverter over dart:ffi, so this needs NO Rust
# toolchain — build the native libs via scripts/build-runtime.sh.
# All the sibling players share this "Rust-free for customizers" philosophy.
# Output lands in example/assets/spritestudio/overall/ (the SsProjectSync
# convention; referenced by example/pubspec.yaml).
#
# SDK location (for the source .sspj): $SSSDK, else ./SpriteStudio-SDK, else
# ../SpriteStudio-SDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/example/assets/spritestudio/overall"
CONV_PKG="$ROOT_DIR/packages/ssconverter_dart"

SDK_DIR="${SSSDK:-}"
if [ -z "$SDK_DIR" ]; then
  for cand in "$ROOT_DIR/SpriteStudio-SDK" "$ROOT_DIR/../SpriteStudio-SDK"; do
    if [ -f "$cand/Cargo.toml" ]; then SDK_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi
[ -n "$SDK_DIR" ] && [ -f "$SDK_DIR/tests/overall/overall.sspj" ] || {
  echo "deploy-examples.sh: overall.sspj not found (init the SpriteStudio-SDK submodule or set SSSDK)" >&2
  exit 1
}

command -v dart >/dev/null || {
  echo "deploy-examples.sh: dart not found (install the Dart/Flutter SDK)" >&2
  exit 1
}

# 1) Stage the SOURCE project first: SpriteStudio_Source/<project> is the single
# source of truth the desktop live-reload (example reassemble()) reconverts on
# hot reload. Copy the overall project dir wholesale so its referenced
# .ssae/.ssce/.png travel with the .sspj.
SRC_STAGE="$ROOT_DIR/example/SpriteStudio_Source/overall"
echo "Staging source project -> example/SpriteStudio_Source/overall/ ..."
rm -rf "$SRC_STAGE"
mkdir -p "$SRC_STAGE"
cp -R "$SDK_DIR/tests/overall/." "$SRC_STAGE/"
echo "   -> example/SpriteStudio_Source/overall/"

# 2) Convert the STAGED copy (not the SDK original) into
# example/assets/spritestudio/overall/ — the same SsProjectSync convention +
# location the hot-reload path reuses. The non-embedded converter also copies the
# referenced textures/fonts/sounds into OUT_DIR, so this single call produces the
# complete asset tree. libssconverter is delivered via native assets — the
# package's hook/build.dart bundles the prebuilt dylib (build-runtime.sh
# produces it); no SSCONVERTER_LIBRARY_PATH needed.
echo "Converting SpriteStudio_Source/overall/overall.sspj via ssconvert (Dart) ..."
mkdir -p "$OUT_DIR"
( cd "$CONV_PKG" && dart pub get >/dev/null 2>&1 && \
  dart run ssconverter_dart:ssconvert -o "$OUT_DIR" "$SRC_STAGE/overall.sspj" )
echo "   -> example/assets/spritestudio/overall/"

echo "deploy-examples.sh: done."
