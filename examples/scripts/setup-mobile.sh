#!/usr/bin/env bash
#
# Generate the ios/ and android/ platform folders for an example. They are
# .gitignore'd like every other runner here (see the root .gitignore), so each
# checkout regenerates them — this script is the one command that does it.
#
# Usage:  bash examples/scripts/setup-mobile.sh <example> [--android] [--ios]
#   <example>   a subdir of examples/ (e.g. overall, flame)
#   --android   generate android/ only
#   --ios       generate ios/ only
#   (neither)   both — except off macOS, where iOS is skipped (it needs Xcode)
#
# Windows runs Android through the .ps1 beside this file; iOS cannot be set up
# there at all. Both halves must change together.
#
# Idempotent — `flutter create` only fills in what is absent and never touches
# lib/ or pubspec.yaml.
set -euo pipefail

EXAMPLES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$EXAMPLES_DIR/.." && pwd)"

WANT_ANDROID=0
WANT_IOS=0
EXAMPLE=""
for arg in "$@"; do
  case "$arg" in
    --android) WANT_ANDROID=1 ;;
    --ios)     WANT_IOS=1 ;;
    --*)       echo "[setup-mobile] unknown flag: $arg" >&2; exit 2 ;;
    *)         EXAMPLE="$arg" ;;
  esac
done

if [ -z "$EXAMPLE" ]; then
  echo "[setup-mobile] usage: setup-mobile.sh <example> [--android] [--ios]" >&2
  exit 2
fi
EXAMPLE_DIR="$EXAMPLES_DIR/$EXAMPLE"
[ -f "$EXAMPLE_DIR/pubspec.yaml" ] || {
  echo "[setup-mobile] no example at $EXAMPLE_DIR" >&2
  exit 1
}

# Neither flag means both. iOS needs Xcode, so it is dropped off macOS rather
# than failing the whole run — Android is the half that works everywhere.
if [ "$WANT_ANDROID" = 0 ] && [ "$WANT_IOS" = 0 ]; then
  WANT_ANDROID=1
  case "${OSTYPE:-}" in
    darwin*) WANT_IOS=1 ;;
    *) echo "[setup-mobile] not macOS — generating android/ only (iOS needs Xcode)." ;;
  esac
fi
if [ "$WANT_IOS" = 1 ]; then
  case "${OSTYPE:-}" in
    darwin*) ;;
    *) echo "[setup-mobile] --ios needs macOS + Xcode." >&2; exit 1 ;;
  esac
fi

PLATFORMS=""
[ "$WANT_ANDROID" = 1 ] && PLATFORMS="android"
[ "$WANT_IOS" = 1 ] && PLATFORMS="${PLATFORMS:+$PLATFORMS,}ios"
REQUESTED="$PLATFORMS"

# `flutter create` rewrites .metadata's migration list to EXACTLY the platforms
# it is handed, dropping the entry for every runner it is not told about — so a
# run for android alone silently removes macos from a project that has macos/.
# The runners already on disk are therefore carried along; nothing is generated
# twice, because create only fills in what is absent.
carry_existing() {
  local list="$1" p
  for p in android ios macos windows linux web; do
    case ",$list," in *",$p,"*) continue ;; esac
    [ -d "$p" ] && list="${list:+$list,}$p"
  done
  echo "$list"
}

cd "$EXAMPLE_DIR"
flutter create --platforms="$(carry_existing "$PLATFORMS")" .

# The native Brain is the part `flutter create` cannot produce. hook/build.dart
# prefers a local build and falls back to downloading the pinned SDK release —
# which is not published yet, so before the first release a local cross build is
# the ONLY route on these two platforms. Say so here rather than let the build
# fail 90 seconds later inside Gradle with an HTTP 404.
RT_LIBS="$ROOT_DIR/packages/ssruntime_dart/native/libs"
for p in $(echo "$REQUESTED" | tr ',' ' '); do
  if [ ! -d "$RT_LIBS/$p" ]; then
    echo "[setup-mobile] no libssruntime for $p yet — build it with:"
    echo "[setup-mobile]   bash scripts/build-runtime.sh platform=$p"
    echo "[setup-mobile] (needs Rust + the $p cross targets; Android also needs"
    echo "[setup-mobile]  a real NDK on \$ANDROID_NDK_HOME)"
  fi
done

echo "[setup-mobile] done — $EXAMPLE/{$REQUESTED} ready (run: flutter run -d <device>)"
