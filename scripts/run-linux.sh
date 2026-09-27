#!/usr/bin/env bash
#
# Run an example on Linux: scripts/run-example.sh with platform=linux. What it
# brings up first and what it takes are in that script's header (or --help).
set -euo pipefail
exec bash "$(dirname "$0")/run-example.sh" platform=linux "$@"
