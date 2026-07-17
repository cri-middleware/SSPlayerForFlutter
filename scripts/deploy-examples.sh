#!/usr/bin/env bash
#
# Stage the SDK's bundled test projects (tests/overall, tests/Ringo) into the
# example's SpriteStudio_Source/, then convert THOSE copies into .ssab assets,
# using the Dart `ssconvert` CLI (ssconverter_dart). SpriteStudio_Source is the
# single source of truth the desktop live-reload (example reassemble()) reconverts
# on hot reload, so the initial assets and the live output come from the same place.
# It loads the PREBUILT libssconverter over dart:ffi, so this needs NO Rust
# toolchain — build the native libs via scripts/build-runtime.sh.
# All the sibling players share this "Rust-free for customizers" philosophy.
# Output lands in examples/overall/assets/spritestudio/<stem>/ (the SsProjectSync
# convention — <stem> is the .sspj filename, so it matches what live-reload
# regenerates; both dirs are referenced by examples/overall/pubspec.yaml).
#
# SDK location (for the source .sspj): $SSSDK, else ./SpriteStudio-SDK, else
# ../SpriteStudio-SDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONV_PKG="$ROOT_DIR/packages/ssconverter_dart"

# Projects to deploy: "<SDK tests subdir>|<.sspj filename>". The output/stage
# name is the .sspj STEM (filename minus .sspj) so it matches SsProjectSync's
# live-reload convention (Ringo.sspj -> assets/spritestudio/Ringo/).
PROJECTS=(
  "overall|overall.sspj"
  "Ringo|Ringo.sspj"
)

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

# Resolve the converter package deps once (the CLI loads the PREBUILT
# libssconverter via native assets — hook/build.dart bundles the dylib that
# build-runtime.sh produces; no SSCONVERTER_LIBRARY_PATH needed).
( cd "$CONV_PKG" && dart pub get >/dev/null 2>&1 )

# Stage a source project, then convert THAT copy (not the SDK original):
#  1) SpriteStudio_Source/<stem>/ is the single source of truth the desktop
#     live-reload (example reassemble()) reconverts on hot reload. Copy the
#     project dir wholesale so its referenced .ssae/.ssce/.png travel with it.
#  2) Convert into examples/overall/assets/spritestudio/<stem>/ — the same SsProjectSync
#     convention + location the hot-reload path reuses. The non-embedded
#     converter also copies the referenced textures/fonts/sounds into the output,
#     so this single call produces the complete asset tree.
deploy_project() {
  local sdk_sub="$1" sspj="$2"
  local stem="${sspj%.sspj}"
  local src_project="$SDK_DIR/tests/$sdk_sub"
  [ -f "$src_project/$sspj" ] || {
    echo "deploy-examples.sh: $sdk_sub/$sspj not found (init the SpriteStudio-SDK submodule or set SSSDK)" >&2
    exit 1
  }
  local stage="$ROOT_DIR/examples/overall/SpriteStudio_Source/$stem"
  local out="$ROOT_DIR/examples/overall/assets/spritestudio/$stem"

  echo "Staging $sdk_sub -> examples/overall/SpriteStudio_Source/$stem/ ..."
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -R "$src_project/." "$stage/"

  echo "Converting SpriteStudio_Source/$stem/$sspj via ssconvert (Dart) ..."
  mkdir -p "$out"
  ( cd "$CONV_PKG" && dart run ssconverter_dart:ssconvert -o "$out" "$stage/$sspj" )
  echo "   -> examples/overall/assets/spritestudio/$stem/"
}

for entry in "${PROJECTS[@]}"; do
  deploy_project "${entry%%|*}" "${entry##*|}"
done

# The Flame example (examples/flame) needs just one self-contained pack, not the
# whole overall tree. Reuse the Ringo output the loop just produced (a character
# animation + its reference PNG) — copy, don't reconvert, so it stays a single
# source of truth. Skipped cleanly if Ringo wasn't deployed.
FLAME_SRC="$ROOT_DIR/examples/overall/assets/spritestudio/Ringo"
FLAME_DST="$ROOT_DIR/examples/flame/assets/spritestudio/Ringo"
if [ -d "$FLAME_SRC" ]; then
  echo "Copying Ringo -> examples/flame/assets/spritestudio/Ringo/ ..."
  rm -rf "$FLAME_DST"
  mkdir -p "$FLAME_DST"
  cp -R "$FLAME_SRC/." "$FLAME_DST/"
  echo "   -> examples/flame/assets/spritestudio/Ringo/"
fi

echo "deploy-examples.sh: done."
