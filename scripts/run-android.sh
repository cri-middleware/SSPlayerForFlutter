#!/usr/bin/env bash
#
# Run an example on Android: scripts/run-example.sh with platform=android. What it
# brings up first and what it takes are in that script's header (or --help).
set -euo pipefail
exec bash "$(dirname "$0")/run-example.sh" platform=android "$@"
