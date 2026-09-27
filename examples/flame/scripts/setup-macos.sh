#!/usr/bin/env bash
#
# macOS Runner setup for the flame example — a thin wrapper over the shared
# examples/scripts/setup-macos.sh. The Flame demo needs no special entitlements
# (no drag-&-drop, no live-reload), so this just regenerates the gitignored
# macos/ Runner via `flutter create --platforms=macos .`.
#
# Run from anywhere:  bash examples/flame/scripts/setup-macos.sh
set -euo pipefail
exec bash "$(cd "$(dirname "$0")/../../scripts" && pwd)/setup-macos.sh" flame "$@"
