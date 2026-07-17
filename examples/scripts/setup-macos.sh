#!/usr/bin/env bash
#
# Shared macOS Runner setup for the example apps. Regenerates the gitignored
# macos/ Runner (`flutter create`) and applies ONLY the entitlements a given
# example asks for — different examples need different tweaks, so the logic lives
# here once and each example ships a thin wrapper that passes the right flags.
#
# Usage:  bash examples/scripts/setup-macos.sh <example> [--drag-drop] [--dev-unsandbox]
#   <example>         a subdir of examples/ (e.g. overall, flame)
#   --drag-drop       add com.apple.security.files.user-selected.read-only to BOTH
#                     build configs — for apps that read user-picked files/folders
#                     (e.g. desktop_drop drag-&-drop).
#   --dev-unsandbox   DEBUG-only: com.apple.security.app-sandbox = false, so a dev
#                     tool (in-process host converter / live-reload) can read
#                     project sources. Release keeps the sandbox ON.
#
# macOS-only (PlistBuddy). Idempotent — safe to re-run.
set -euo pipefail

EXAMPLES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DRAG_DROP=0
DEV_UNSANDBOX=0
EXAMPLE=""
for arg in "$@"; do
  case "$arg" in
    --drag-drop)     DRAG_DROP=1 ;;
    --dev-unsandbox) DEV_UNSANDBOX=1 ;;
    --*)             echo "[setup-macos] unknown flag: $arg" >&2; exit 2 ;;
    *)               EXAMPLE="$arg" ;;
  esac
done

if [ -z "$EXAMPLE" ]; then
  echo "[setup-macos] usage: setup-macos.sh <example> [--drag-drop] [--dev-unsandbox]" >&2
  exit 2
fi
EXAMPLE_DIR="$EXAMPLES_DIR/$EXAMPLE"
[ -f "$EXAMPLE_DIR/pubspec.yaml" ] || {
  echo "[setup-macos] no example at $EXAMPLE_DIR" >&2
  exit 1
}

PLISTBUDDY="/usr/libexec/PlistBuddy"
if [ ! -x "$PLISTBUDDY" ]; then
  echo "[setup-macos] $PLISTBUDDY not found — this script is macOS-only." >&2
  exit 1
fi

cd "$EXAMPLE_DIR"

# 1. Generate the macOS platform folder if missing. Idempotent: `flutter create`
#    only fills in what is absent and never clobbers lib/ or pubspec.yaml.
flutter create --platforms=macos .

DBG="macos/Runner/DebugProfile.entitlements"
REL="macos/Runner/Release.entitlements"

# 2. drag-&-drop entitlement (both configs), if requested. PlistBuddy uses ':' for
#    nesting, so the dotted KEY is a single root-level key; `Add` only runs when
#    `Print` shows it missing (keeps this re-runnable).
if [ "$DRAG_DROP" = 1 ]; then
  KEY="com.apple.security.files.user-selected.read-only"
  for f in "$DBG" "$REL"; do
    if "$PLISTBUDDY" -c "Print :$KEY" "$f" >/dev/null 2>&1; then
      echo "[setup-macos] $f: already has $KEY"
    else
      "$PLISTBUDDY" -c "Add :$KEY bool true" "$f"
      echo "[setup-macos] $f: added $KEY"
    fi
  done
fi

# 3. DEBUG-only App Sandbox off (dev tooling), if requested. `Set` handles the
#    usual template value; `Add` covers a template without the key. Release is
#    left untouched — production keeps the sandbox.
if [ "$DEV_UNSANDBOX" = 1 ]; then
  SANDBOX="com.apple.security.app-sandbox"
  if "$PLISTBUDDY" -c "Set :$SANDBOX false" "$DBG" 2>/dev/null; then
    echo "[setup-macos] $DBG: $SANDBOX = false"
  else
    "$PLISTBUDDY" -c "Add :$SANDBOX bool false" "$DBG"
    echo "[setup-macos] $DBG: added $SANDBOX = false"
  fi
fi

echo "[setup-macos] done — $EXAMPLE/macos/ ready (run: flutter run -d macos)"
