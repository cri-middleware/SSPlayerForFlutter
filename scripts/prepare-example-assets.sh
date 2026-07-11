#!/usr/bin/env bash
#
# Convert the SDK's bundled test project (tests/overall/overall.sspj) into
# .ssab assets for the example app, using ssconverter-cli. Output lands in
# example/assets/overall/ (referenced by example/pubspec.yaml).
#
# SDK location: $SSSDK, else ./SpriteStudio-SDK, else ../SpriteStudio-SDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/example/assets/overall"

SDK_DIR="${SSSDK:-}"
if [ -z "$SDK_DIR" ]; then
  for cand in "$ROOT_DIR/SpriteStudio-SDK" "$ROOT_DIR/../SpriteStudio-SDK"; do
    if [ -f "$cand/Cargo.toml" ]; then SDK_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi
[ -n "$SDK_DIR" ] && [ -f "$SDK_DIR/Cargo.toml" ] || {
  echo "prepare-example-assets.sh: SpriteStudio-SDK not found" >&2; exit 1; }

echo "Building ssconverter-cli (release)..."
( cd "$SDK_DIR" && cargo build --release -p ssconverter-cli )
CLI="$SDK_DIR/target/release/ssconverter-cli"

echo "Converting tests/overall/overall.sspj ..."
( cd "$SDK_DIR" && "$CLI" tests/overall/overall.sspj )

mkdir -p "$OUT_DIR"
# The converter writes .ssab (and copies textures) next to the project under
# tests/overall/overall/. Mirror that tree into the example assets.
cp -R "$SDK_DIR/tests/overall/overall/." "$OUT_DIR/"
echo "   -> example/assets/overall/"
echo "prepare-example-assets.sh: done."
