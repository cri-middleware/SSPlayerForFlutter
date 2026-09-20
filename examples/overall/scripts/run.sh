#!/usr/bin/env bash
#
# Run the overall example, with the flutter_gpu switches behind one flag.
#
#   bash scripts/run.sh -d macos                 # Canvas (the default backend)
#   bash scripts/run.sh --gpu -d macos           # flutter_gpu
#   bash scripts/run.sh --gpu --watch -d macos   # flutter_gpu + live reload
#
# --gpu expands to the three switches the backend actually needs:
#   --dart-define=SS_BACKEND=gpu   the example's backend selector (lib/main.dart)
#   --enable-flutter-gpu           the flutter_gpu API itself
#   --enable-impeller              Impeller, which flutter_gpu requires
#
# The last one matters only on Android, where Impeller is available but not the
# default; `flutter run` ignores it on macOS and iOS (verified on macOS: the
# other two alone already report "running on gpu"). It is passed everywhere
# anyway so one flag is correct on every target.
#
# --watch routes the same launch through the live-reload watcher, which owns
# `flutter run` and injects SS_LIVE_RELOAD. Add --device after it for a device or
# the web, where the push carries bytes instead of a host path.
#
# Every other argument goes to `flutter run` (or to `sswatch --run`) untouched.
set -euo pipefail

EXAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GPU=0
WATCH=0
PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    --gpu)   GPU=1 ;;
    --watch) WATCH=1 ;;
    *)       PASSTHROUGH+=("$arg") ;;
  esac
done

GPU_ARGS=()
if [ "$GPU" = 1 ]; then
  GPU_ARGS=(--dart-define=SS_BACKEND=gpu --enable-impeller --enable-flutter-gpu)
fi

cd "$EXAMPLE_DIR"
if [ "$WATCH" = 1 ]; then
  set -x
  exec dart run ssgen_flutter:sswatch --run "${PASSTHROUGH[@]}" "${GPU_ARGS[@]}"
else
  set -x
  exec flutter run "${PASSTHROUGH[@]}" "${GPU_ARGS[@]}"
fi
