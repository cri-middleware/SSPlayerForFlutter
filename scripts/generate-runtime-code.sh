#!/usr/bin/env bash
#
# Generate the source code that the Flutter package needs to talk to the Brain:
#
#   1. C headers (ffigen input) from the Rust C-API, via `cbindgen --lang c`
#        -> packages/ssplayer_flutter/native/include/ssruntime.h
#        -> packages/ssplayer_flutter/native/include/ssconverter.h
#   2. Dart FlatBuffers accessors for the .ssab metadata + runtime FrameData /
#      EffectDrawPlan, via `flatc --dart`
#        -> packages/ssplayer_flutter/lib/src/ssab/<schema>.g.dart
#   3. (optional) the ffigen Dart bindings (Layer 1) when the Dart SDK is present
#        -> packages/ssplayer_flutter/lib/src/bindings/ssruntime_bindings.g.dart
#
# Mirrors the sibling players' scripts/generate-runtime-code.* (Godot uses flatc
# to emit C++ headers; here we emit Dart + the C header ffigen consumes).
#
# Prerequisites: cbindgen (`cargo install cbindgen`), flatc (Google FlatBuffers).
# ffigen additionally needs the Dart/Flutter SDK + `dart pub get`.
#
# SDK location: $SSSDK, else ./SpriteStudio-SDK, else ../SpriteStudio-SDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packages/ssplayer_flutter"
INCLUDE_DIR="$PKG_DIR/native/include"
SSAB_OUT_DIR="$PKG_DIR/lib/src/ssab"

# --- locate the SDK -------------------------------------------------------
SDK_DIR="${SSSDK:-}"
if [ -z "$SDK_DIR" ]; then
  for cand in "$ROOT_DIR/SpriteStudio-SDK" "$ROOT_DIR/../SpriteStudio-SDK"; do
    if [ -f "$cand/Cargo.toml" ]; then SDK_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi
if [ -z "$SDK_DIR" ] || [ ! -f "$SDK_DIR/Cargo.toml" ]; then
  echo "generate-runtime-code.sh: SpriteStudio-SDK not found (init the submodule or set SSSDK)" >&2
  exit 1
fi

mkdir -p "$INCLUDE_DIR" "$SSAB_OUT_DIR"

# --- 1. C headers via cbindgen (ffigen prefers plain C over the C++ output) --
if command -v cbindgen >/dev/null; then
  echo "Generating C headers (cbindgen --lang c)..."
  ( cd "$SDK_DIR/libs/ssruntime" && cbindgen --lang c --crate ssruntime --output "$INCLUDE_DIR/ssruntime.h" ) \
    && echo "   -> native/include/ssruntime.h"
  if [ -d "$SDK_DIR/libs/ssconverter" ]; then
    ( cd "$SDK_DIR/libs/ssconverter" && cbindgen --lang c --crate ssconverter --output "$INCLUDE_DIR/ssconverter.h" ) \
      && echo "   -> native/include/ssconverter.h" || echo "   (ssconverter header skipped)"
  fi
else
  echo "generate-runtime-code.sh: cbindgen not found — skipping C headers (run: cargo install cbindgen)" >&2
fi

# --- 2. Dart FlatBuffers accessors via flatc --------------------------------
if command -v flatc >/dev/null; then
  echo "Generating Dart FlatBuffers (flatc --dart)..."
  TMP_FB="$(mktemp -d)"; trap 'rm -rf "$TMP_FB"' EXIT
  for f in \
    "$SDK_DIR/libs/ssab/fbs/ssab.fbs" \
    "$SDK_DIR/libs/ssab/fbs/ssqb.fbs" \
    "$SDK_DIR/libs/ssruntime/fbs/framedata.fbs" \
    "$SDK_DIR/libs/ssruntime/fbs/effect_draw_plan.fbs"; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .fbs)"
    flatc --dart -o "$TMP_FB" "$f"
    # flatc emits <name>_<namespace>_generated.dart; normalise to <name>.g.dart
    gen="$(ls "$TMP_FB/${name}"_*_generated.dart 2>/dev/null | head -n1)"
    if [ -n "$gen" ]; then
      mv "$gen" "$SSAB_OUT_DIR/${name}.g.dart"
      echo "   -> lib/src/ssab/${name}.g.dart"
    fi
  done
else
  echo "generate-runtime-code.sh: flatc not found — skipping Dart FlatBuffers (install Google FlatBuffers)" >&2
fi

# --- 3. ffigen Dart bindings (Layer 1), only when the Dart SDK is available --
if command -v dart >/dev/null && [ -f "$PKG_DIR/ffigen.yaml" ]; then
  echo "Generating ffigen bindings (dart run ffigen)..."
  ( cd "$PKG_DIR" && dart pub get >/dev/null 2>&1 && dart run ffigen --config ffigen.yaml ) \
    && echo "   -> lib/src/bindings/ssruntime_bindings.g.dart" \
    || echo "   (ffigen skipped — check that ffigen is a dev_dependency)"
else
  echo "generate-runtime-code.sh: dart not found — skipping ffigen (bindings are hand-authored until then)"
fi

echo "generate-runtime-code.sh: done."
