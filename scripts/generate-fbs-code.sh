#!/usr/bin/env bash
#
# Generate the Dart FlatBuffers accessors (flatc --dart) for the .ssab metadata +
# runtime FrameData / EffectDrawPlan schemas:
#
#   SpriteStudio-SDK/libs/**/fbs/*.fbs   ->   lib/src/ssab/<schema>.g.dart
#
# These track the .fbs SCHEMAS (not the native library), so run this only when a
# schema changes — it is deliberately NOT part of build-runtime / download-sdk.
# The output IS committed (so a normal checkout builds without flatc installed).
# The ffigen FFI bindings are a separate concern — see
# scripts/generate-ffigen-code.sh.
#
# Prerequisites: flatc (Google FlatBuffers).
# SDK location: $SSSDK, else ./SpriteStudio-SDK, else ../SpriteStudio-SDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packages/ssplayer_flutter"
SSAB_OUT_DIR="$PKG_DIR/lib/src/ssab"

# --- locate the SDK -------------------------------------------------------
SDK_DIR="${SSSDK:-}"
if [ -z "$SDK_DIR" ]; then
  for cand in "$ROOT_DIR/SpriteStudio-SDK" "$ROOT_DIR/../SpriteStudio-SDK"; do
    if [ -f "$cand/Cargo.toml" ]; then SDK_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi
if [ -z "$SDK_DIR" ] || [ ! -f "$SDK_DIR/Cargo.toml" ]; then
  echo "generate-fbs-code.sh: SpriteStudio-SDK not found (init the submodule or set SSSDK)" >&2
  exit 1
fi

if ! command -v flatc >/dev/null; then
  echo "generate-fbs-code.sh: flatc not found — install Google FlatBuffers (brew install flatbuffers)" >&2
  exit 1
fi

mkdir -p "$SSAB_OUT_DIR"
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

echo "generate-fbs-code.sh: done."
