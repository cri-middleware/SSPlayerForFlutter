#!/usr/bin/env bash
#
# Regenerate the example's macOS Runner and ensure the drag-&-drop entitlement
# is present. example/macos/ is gitignored (Flutter regenerates it via `flutter
# create`), so rather than track a full copy of the entitlements this script
# just applies the entitlement tweaks the app needs — idempotently, on top of
# whatever Flutter's current template provides.
#
# 1) com.apple.security.files.user-selected.read-only — lets the sandboxed app
#    read the .ssab folders/files dropped onto the window (the desktop_drop
#    drag-&-drop in lib/main.dart).
# 2) DEBUG-only: com.apple.security.app-sandbox = false — the desktop dev
#    live-reload (State.reassemble -> reconvert the stale SpriteStudio_Source
#    projects -> reload) reads the project sources and runs the host
#    libssconverter IN-PROCESS, both of which the sandbox confines to the app's
#    container. Release.entitlements keeps the sandbox ON.
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

# 3. DEBUG-only: disable the App Sandbox so the desktop dev live-reload can read
#    the project sources and run the host libssconverter in-process. `Set`
#    handles the usual template value (true); `Add` covers a template without the
#    key. Release.entitlements is left untouched — production keeps the sandbox.
SANDBOX="com.apple.security.app-sandbox"
DBG="macos/Runner/DebugProfile.entitlements"
if "$PLISTBUDDY" -c "Set :$SANDBOX false" "$DBG" 2>/dev/null; then
  echo "[setup-macos] $DBG: $SANDBOX = false (dev live-reload)"
else
  "$PLISTBUDDY" -c "Add :$SANDBOX bool false" "$DBG"
  echo "[setup-macos] $DBG: added $SANDBOX = false (dev live-reload)"
fi

echo "[setup-macos] done — macos/ ready (run: flutter run -d macos)"
