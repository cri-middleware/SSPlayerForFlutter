#!/usr/bin/env bash
#
# Generate the Dart FlatBuffers accessors (flatc --dart) for the .ssab/.ssqb
# asset formats and the runtime's per-frame FrameData / EffectDrawPlan, routing
# each schema to the package that owns it:
#
#   libs/ssab/fbs/{ssab,ssqb}.fbs                -> ssplayer_flutter/lib/src/ssab/
#     (the .ssab / .ssqb asset FILE format — parsed on the Player side)
#   libs/ssruntime/fbs/{framedata,effect_draw_plan}.fbs -> ssruntime_dart/lib/src/fbs/
#     (the runtime's OUTPUT read back over dart:ffi — owned by the bindings pkg)
#
# Each generated file is then piped through scripts/strip_fbs_builders.dart,
# which removes the write-side <Type>Builder / <Type>ObjectBuilder classes flatc
# always emits (~2/3 of the output): every one of these schemas is read-only on
# the Dart side.
#
# These track the .fbs SCHEMAS (not the native library), so run this only when a
# schema changes — it is deliberately NOT part of build-runtime.
# The output IS committed (so a normal checkout builds without flatc installed).
# The ffigen FFI bindings are a separate concern — see
# scripts/generate-ffigen-code.sh.
#
# Prerequisites: flatc (Google FlatBuffers), dart.
# SDK location: $SSSDK, else ./SpriteStudio-SDK, else ../SpriteStudio-SDK.
set -euo pipefail

if [ "$#" -gt 0 ]; then
  echo "$(basename "$0"): takes no arguments — what it does is in its header comment" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSAB_OUT_DIR="$ROOT_DIR/packages/ssplayer_flutter/lib/src/ssab"   # asset format (Player)
RT_FBS_OUT_DIR="$ROOT_DIR/packages/ssruntime_dart/lib/src/fbs"    # runtime output
# The write-side classes land here instead of lib/ — only tests build buffers.
BUILDERS_OUT_DIR="$ROOT_DIR/packages/ssplayer_flutter/test/support"

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

if ! command -v dart >/dev/null; then
  echo "generate-fbs-code.sh: dart not found — needed to strip the generated write-side classes" >&2
  exit 1
fi

mkdir -p "$SSAB_OUT_DIR" "$RT_FBS_OUT_DIR" "$BUILDERS_OUT_DIR"
echo "Generating Dart FlatBuffers (flatc --dart)..."
TMP_FB="$(mktemp -d)"; trap 'rm -rf "$TMP_FB"' EXIT
for f in \
  "$SDK_DIR/libs/ssab/fbs/ssab.fbs" \
  "$SDK_DIR/libs/ssab/fbs/ssqb.fbs" \
  "$SDK_DIR/libs/ssruntime/fbs/framedata.fbs" \
  "$SDK_DIR/libs/ssruntime/fbs/effect_draw_plan.fbs"; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .fbs)"
  # Route by schema origin: runtime output -> ssruntime_dart, asset format -> Player.
  # `reader` is the library a test imports; the write-side shim re-exports it so
  # only the URI changes. Every schema gets a shim, including ones nothing reads
  # yet (ssqb — sequence playback is still on the roadmap), so the fixture
  # builders are already there when the feature lands.
  case "$name" in
    framedata)
      out="$RT_FBS_OUT_DIR"; reader="package:ssruntime_dart/framedata.dart" ;;
    effect_draw_plan)
      out="$RT_FBS_OUT_DIR"; reader="package:ssruntime_dart/effect_draw_plan.dart" ;;
    *)
      out="$SSAB_OUT_DIR";   reader="package:ssplayer_flutter/src/ssab/${name}.g.dart" ;;
  esac
  flatc --dart -o "$TMP_FB" "$f"
  # flatc emits <name>_<namespace>_generated.dart; normalise to <name>.g.dart
  gen="$(ls "$TMP_FB/${name}"_*_generated.dart 2>/dev/null | head -n1)"
  if [ -n "$gen" ]; then
    mv "$gen" "$out/${name}.g.dart"
    echo "   -> ${out#"$ROOT_DIR"/}/${name}.g.dart"
    # Split the serializer half out of lib/ — these schemas are read-only there.
    dart "$ROOT_DIR/scripts/strip_fbs_builders.dart" \
      --builders-out="$BUILDERS_OUT_DIR/${name}_builders.g.dart" \
      --reader-library="$reader" \
      "$out/${name}.g.dart"
  fi
done

echo "generate-fbs-code.sh: done."
