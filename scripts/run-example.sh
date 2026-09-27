#!/usr/bin/env bash
#
# Run an example app on one platform, bringing up what it needs first — the one
# command behind scripts/run-<platform>.sh. In order:
#   1. assets  — the example's .ssab packs: scripts/deploy-examples.sh if absent.
#   2. runner  — the example's <platform>/ folder, generated if absent: macOS
#                through the example's own setup-macos (it knows its
#                entitlements), Android / iOS through setup-mobile, the rest by
#                `flutter create`.
#   3. runtime — the web build's wasm, which no build hook fetches: a missing one
#                is named, with the two commands that provide it. A native target
#                without a local build falls back to its hook's download, so it
#                is only reported.
#   4. device  — macos / linux / chrome as they are. Android / iOS take the first
#                running device of that platform, else launch one — the first
#                Android emulator `flutter emulators` lists, or the first
#                available iPhone simulator — and wait for it. -d <id> skips this.
# Then it runs the example — through its own scripts/run.sh when it has one (the
# overall example, the only one that wires --gpu and --watch), else plain
# `flutter run`. Nothing here builds Rust.
#
# Usage: scripts/run-example.sh platform=<p> [example=<name>] [--gpu] [--watch] [flutter run args...]
#   platform : macos linux android ios web   (windows: scripts\run-windows.ps1)
#   example  : a directory under examples/   (default: overall)
#   --gpu    : the flutter_gpu backend
#   --watch  : live reload through sswatch; on android / ios / web the push
#              carries bytes, so --device is added for you
#   Anything else goes to `flutter run` as it is: -d <id>, --release, ...
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="run-example.sh"

usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

PLATFORM=""; EXAMPLE="overall"; GPU=0; WATCH=0; HAS_DEVICE=0; PASS=()
for arg in "$@"; do
  case "$arg" in
    platform=*) PLATFORM="${arg#*=}" ;;
    example=*)  EXAMPLE="${arg#*=}" ;;
    --gpu)      GPU=1 ;;
    --watch)    WATCH=1 ;;
    -h|--help|help) usage; exit 0 ;;
    -d|--device-id|--device-id=*) HAS_DEVICE=1; PASS+=("$arg") ;;
    *)          PASS+=("$arg") ;;
  esac
done

case "$PLATFORM" in
  macos|ios) [[ "${OSTYPE:-}" == darwin* ]] || { echo "$APP: $PLATFORM needs a macOS host" >&2; exit 1; } ;;
  linux)     [[ "${OSTYPE:-}" == linux* ]] || { echo "$APP: linux needs a Linux host" >&2; exit 1; } ;;
  android|web) ;;
  windows) echo "$APP: windows runs from PowerShell — scripts\\run-windows.ps1" >&2; exit 2 ;;
  "") echo "$APP: platform=<p> is required" >&2; usage >&2; exit 2 ;;
  *)  echo "$APP: unknown platform '$PLATFORM'" >&2; usage >&2; exit 2 ;;
esac

EXAMPLE_DIR="$ROOT_DIR/examples/$EXAMPLE"
[ -f "$EXAMPLE_DIR/pubspec.yaml" ] || { echo "$APP: no example at examples/$EXAMPLE" >&2; exit 1; }
if [ ! -f "$EXAMPLE_DIR/scripts/run.sh" ] && { [ "$GPU" = 1 ] || [ "$WATCH" = 1 ]; }; then
  echo "$APP: --gpu and --watch are wired by examples/overall only" >&2
  exit 2
fi

# 1. assets
if ! ls "$EXAMPLE_DIR"/assets/spritestudio/*/*.ssab >/dev/null 2>&1; then
  echo "[$APP] examples/$EXAMPLE has no .ssab yet — running deploy-examples"
  bash "$ROOT_DIR/scripts/deploy-examples.sh"
fi

# 2. runner
# `flutter create` rewrites .metadata's migration list to EXACTLY the platforms
# it is handed, dropping the entry for every runner it is not told about — so a
# run for web alone silently removes macos from a project that has macos/. The
# runners already on disk are therefore carried along; nothing is generated
# twice, because create only fills in what is absent.
carry_existing() {
  local list="$1" p
  for p in android ios macos windows linux web; do
    case ",$list," in *",$p,"*) continue ;; esac
    [ -d "$p" ] && list="${list:+$list,}$p"
  done
  echo "$list"
}
if [ ! -d "$EXAMPLE_DIR/$PLATFORM" ]; then
  case "$PLATFORM" in
    macos)
      if [ -f "$EXAMPLE_DIR/scripts/setup-macos.sh" ]; then
        bash "$EXAMPLE_DIR/scripts/setup-macos.sh"
      else
        bash "$ROOT_DIR/examples/scripts/setup-macos.sh" "$EXAMPLE"
      fi ;;
    android|ios) bash "$ROOT_DIR/examples/scripts/setup-mobile.sh" "$EXAMPLE" "--$PLATFORM" ;;
    *) ( cd "$EXAMPLE_DIR" && flutter create --platforms="$(carry_existing "$PLATFORM")" . ) ;;
  esac
fi

# 3. runtime
if [ "$PLATFORM" = web ]; then
  WEB_RT="$ROOT_DIR/packages/ssplayer_flutter/assets/runtime-web"
  if [ ! -f "$WEB_RT/ssruntime.js" ] || [ ! -f "$WEB_RT/ssruntime_bg.wasm" ]; then
    echo "$APP: the web runtime is missing from packages/ssplayer_flutter/assets/runtime-web/," >&2
    echo "$APP: and no build hook fetches it on the web. Provide it with either:" >&2
    echo "    bash scripts/download-web-runtime.sh          # the pinned release (no Rust)" >&2
    echo "    bash scripts/build-runtime.sh platform=web    # from the SDK source (Rust + wasm-pack)" >&2
    exit 1
  fi
elif [ ! -d "$ROOT_DIR/packages/ssruntime_dart/native/libs/$PLATFORM" ]; then
  echo "[$APP] no local libssruntime for $PLATFORM — the build downloads the pinned release instead."
  echo "[$APP] If that fails: bash scripts/build-runtime.sh platform=$PLATFORM"
fi

# 4. device
# `flutter devices` / `flutter emulators` columns are split on their bullet;
# the id is the 2nd field of a device and the 1st of an emulator. Each awk reads
# to the end rather than `exit` on the first match: under pipefail, a writer cut
# off by that early exit fails the whole assignment, and set -e then ends the
# script without a word — exactly when a device turns up.
running_device() {
  flutter devices 2>/dev/null | awk -F ' • ' -v want="$1" '
    !found && NF >= 3 {
      id = $2; tp = $3
      gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", tp)
      if ((want == "android" && tp ~ /^android/) || (want == "ios" && tp == "ios")) { print id; found = 1 }
    }'
}
first_emulator() {
  flutter emulators 2>/dev/null | awk -F ' • ' -v want="$1" '
    !found && NF >= 4 {
      id = $1; pf = $4
      gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", pf)
      if (pf == want) { print id; found = 1 }
    }'
}
# A simulator is booted by UDID: `flutter emulators --launch apple_ios_simulator`
# only opens Simulator.app, which boots the device it last showed — and nothing
# once that device is gone.
first_simulator() {
  xcrun simctl list devices available 2>/dev/null | awk '
    !found && /^[[:space:]]+iPhone/ && match($0, /\([0-9A-F-]+\)/) { print substr($0, RSTART + 1, RLENGTH - 2); found = 1 }'
}
launch_device() {
  local id
  case "$1" in
    android)
      id="$(first_emulator android)"
      [ -n "$id" ] || return 1
      echo "[$APP] no android device running — launching emulator $id"
      flutter emulators --launch "$id" ;;
    ios)
      id="$(first_simulator)"
      [ -n "$id" ] || return 1
      echo "[$APP] no ios device running — booting simulator $id"
      xcrun simctl boot "$id" || return 1
      # The window only, where Simulator.app is installed at all: `flutter run`
      # needs the booted device, not the app.
      open -b com.apple.iphonesimulator 2>/dev/null || true ;;
  esac
}
if [ "$HAS_DEVICE" = 0 ]; then
  case "$PLATFORM" in
    macos|linux) DEVICE="$PLATFORM" ;;
    web) DEVICE=chrome ;;
    android|ios)
      DEVICE="$(running_device "$PLATFORM")"
      if [ -z "$DEVICE" ]; then
        if ! launch_device "$PLATFORM"; then
          echo "$APP: no $PLATFORM device is running and none can be launched — start one" >&2
          echo "$APP: yourself, or pass -d <id>" >&2
          exit 1
        fi
        for _ in $(seq 1 60); do
          DEVICE="$(running_device "$PLATFORM")"
          [ -n "$DEVICE" ] && break
          sleep 3
        done
        [ -n "$DEVICE" ] || { echo "$APP: the $PLATFORM device did not come up within 3 minutes" >&2; exit 1; }
      fi ;;
  esac
  PASS=(-d "$DEVICE" ${PASS[@]+"${PASS[@]}"})
fi

# 5. run
cd "$EXAMPLE_DIR"
if [ -f scripts/run.sh ]; then
  FLAGS=()
  [ "$GPU" = 1 ] && FLAGS+=(--gpu)
  if [ "$WATCH" = 1 ]; then
    FLAGS+=(--watch)
    case "$PLATFORM" in android|ios|web) FLAGS+=(--device) ;; esac
  fi
  exec bash scripts/run.sh ${FLAGS[@]+"${FLAGS[@]}"} ${PASS[@]+"${PASS[@]}"}
fi
exec flutter run ${PASS[@]+"${PASS[@]}"}
