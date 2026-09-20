#!/usr/bin/env bash
#
# iOS / Android setup for the overall example — a thin wrapper over the shared
# examples/scripts/setup-mobile.sh. Unlike macOS, overall needs no per-platform
# tweaks here: the drag-&-drop entitlement is a macOS sandbox concept, and the
# live-reload device push carries its bytes over the VM Service rather than
# reading a host path, so nothing in the generated runners has to be edited.
#
# Run from anywhere:  bash examples/overall/scripts/setup-mobile.sh [--android|--ios]
set -euo pipefail
exec bash "$(cd "$(dirname "$0")/../../scripts" && pwd)/setup-mobile.sh" overall "$@"
