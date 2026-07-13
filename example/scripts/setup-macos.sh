#!/usr/bin/env bash
#
# Regenerate the example's macOS Runner and ensure the drag-&-drop entitlement
# is present. example/macos/ is gitignored (Flutter regenerates it via `flutter
# create`), so rather than track a full copy of the entitlements this script
# just injects the one extra key the app needs — idempotently, on top of
# whatever Flutter's current template provides.
#
# Key: com.apple.security.files.user-selected.read-only — lets the sandboxed app
# read the .ssab folders/files dropped onto the window (the desktop_drop drag-&-
# drop in lib/main.dart). Without it, dropped files can't be read under the
# macOS sandbox.
#
# Run from anywhere:  bash example/scripts/setup-macos.sh
set -euo pipefail

EXAMPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$EXAMPLE_DIR"

KEY="com.apple.security.files.user-selected.read-only"
PLISTBUDDY="/usr/libexec/PlistBuddy"

if [ ! -x "$PLISTBUDDY" ]; then
  echo "[setup-macos] $PLISTBUDDY not found — this script is macOS-only." >&2
  exit 1
fi

# 1. Generate the macOS platform folder if missing. Idempotent: `flutter create`
#    only fills in what is absent and never clobbers lib/ or pubspec.yaml.
flutter create --platforms=macos .

# 2. Ensure the drag-&-drop entitlement exists in both build configs. PlistBuddy
#    uses ':' for nesting, so the dotted KEY is a single root-level key; `Add`
#    only runs when `Print` shows the key is missing (keeps this re-runnable).
for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  if "$PLISTBUDDY" -c "Print :$KEY" "$f" >/dev/null 2>&1; then
    echo "[setup-macos] $f: already has $KEY"
  else
    "$PLISTBUDDY" -c "Add :$KEY bool true" "$f"
    echo "[setup-macos] $f: added $KEY"
  fi
done

echo "[setup-macos] done — macos/ ready (run: flutter run -d macos)"
