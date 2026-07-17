#!/usr/bin/env bash
#
# macOS Runner setup for the overall example — a thin wrapper over the shared
# examples/scripts/setup-macos.sh. On top of `flutter create`, overall needs two
# entitlement tweaks:
#   --drag-drop      com.apple.security.files.user-selected.read-only, so the
#                    sandboxed app can read the .ssab folders/files dropped on the
#                    window (the desktop_drop drag-&-drop in lib/main.dart).
#   --dev-unsandbox  DEBUG-only com.apple.security.app-sandbox = false, so the
#                    desktop dev live-reload (State.reassemble -> reconvert the
#                    stale SpriteStudio_Source projects -> reload) can read the
#                    project sources and run the host libssconverter in-process.
#                    Release keeps the sandbox ON.
#
# Run from anywhere:  bash examples/overall/scripts/setup-macos.sh
set -euo pipefail
exec bash "$(cd "$(dirname "$0")/../../scripts" && pwd)/setup-macos.sh" \
  overall --drag-drop --dev-unsandbox
