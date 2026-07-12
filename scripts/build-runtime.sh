#!/usr/bin/env bash
#
# Build the native Brain (libssruntime / libssconverter) from the
# SpriteStudio-SDK submodule and place the DYNAMIC libraries into the Flutter
# package's per-platform / per-arch layout so that `dart:ffi`
# (DynamicLibrary.open / .process) can load them at runtime.
#
# Interface mirrors the sibling players (SSPlayerForRenPy / -Unity / -Godot):
#   platform=<p> arch=<a> build=<m> hostbuild=<auto|false>
# For DESKTOP hosts we build the feature-enabled `ssruntime` cdylib directly
# (fast). android / ios / web are toolchain-heavy cross builds and delegate to
# the SDK's own release scripts (SpriteStudio-SDK/scripts/release-*).
#
# Output layout (LIB_ROOT = packages/ssplayer_flutter/native):
#   native/libs/macos/libssruntime.framework        (universal on build=release; runtime, embedded)
#   (libssconverter → packages/ssconverter_dart/native/libs/<platform>/; host tool)
#   native/libs/windows/<arch>/ssruntime.dll
#   native/libs/linux/<arch>/libssruntime.so
#   native/libs/android/<abi>/libssruntime.so
#   native/libs/ios/libssruntime.xcframework
#   native/libs/web/...                              (wasm bundle)
#   native/libs/LICENSE.md
#   native/VERSION
#
# After building, this copies the SDK build.rs-emitted plain-C headers into
# native/include/ and regenerates the ffigen bindings (scripts/generate-ffigen-code.sh).
# The .fbs FlatBuffers accessors are a separate concern (scripts/generate-fbs-code.sh).
#
# Usage: scripts/build-runtime.sh [platform=<p>] [arch=<a>] [build=<m>] [hostbuild=<auto|false>]
#   platform : windows macos linux android ios web   (default: host)
#   arch     : x86_64 arm64 universal ...            (default: host arch)
#   build    : debug release                         (default: debug)
#   hostbuild: false to force cross even on host
#
# SDK location: $SSSDK, else ./SpriteStudio-SDK, else ../SpriteStudio-SDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packages/ssplayer_flutter"
LIB_ROOT="$PKG_DIR/native"
LIBS_DIR="$LIB_ROOT/libs"
# The host converter (libssconverter) lives in its own desktop-only package.
CONV_PKG_DIR="$ROOT_DIR/packages/ssconverter_dart"
CONV_LIBS_DIR="$CONV_PKG_DIR/native/libs"
# The Layer-1 runtime bindings live in their own pure-Dart package.
RT_PKG_DIR="$ROOT_DIR/packages/ssruntime_dart"

usage() { sed -n '/^# Usage:/,/^# SDK location/p' "$0" | sed 's/^# \{0,1\}//'; }

case "${OSTYPE:-}" in
  msys*|cygwin*|win*) HOST_PLATFORM=windows ;;
  darwin*)            HOST_PLATFORM=macos ;;
  *)                  HOST_PLATFORM=linux ;;
esac
HOST_ARCH="$(uname -m)"; [ "$HOST_ARCH" = "aarch64" ] && HOST_ARCH=arm64

PLATFORM="$HOST_PLATFORM"; ARCH="$HOST_ARCH"; BUILD_MODE="debug"; HOSTBUILD="auto"
for item in "$@"; do
  case "$item" in
    platform=*)  PLATFORM="${item#*=}" ;;
    arch=*)      ARCH="${item#*=}" ;;
    build=*)     BUILD_MODE="${item#*=}" ;;
    hostbuild=*) HOSTBUILD="${item#*=}" ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "build-runtime.sh: unknown arg '$item'" >&2; usage; exit 2 ;;
  esac
done

# --- locate the SDK -------------------------------------------------------
SDK_DIR="${SSSDK:-}"
if [ -z "$SDK_DIR" ]; then
  for cand in "$ROOT_DIR/SpriteStudio-SDK" "$ROOT_DIR/../SpriteStudio-SDK"; do
    if [ -f "$cand/Cargo.toml" ]; then SDK_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi
if [ -z "$SDK_DIR" ] || [ ! -f "$SDK_DIR/Cargo.toml" ]; then
  echo "build-runtime.sh: SpriteStudio-SDK not found (init the submodule or set SSSDK)" >&2
  exit 1
fi
command -v cargo >/dev/null || { echo "build-runtime.sh: cargo (Rust) not on PATH" >&2; exit 1; }

IS_HOST_BUILD=false
if [ "$HOSTBUILD" != "false" ] && [ "$PLATFORM" = "$HOST_PLATFORM" ] && [ "$ARCH" = "$HOST_ARCH" ]; then
  IS_HOST_BUILD=true
fi
echo "Building for $PLATFORM ($ARCH) in $BUILD_MODE mode (host build: $IS_HOST_BUILD)"
CARGO_FLAGS=""; [ "$BUILD_MODE" = "release" ] && CARGO_FLAGS="--release"

# The runtime is no_std: a host cdylib needs an allocator + panic handler.
build_ss()        { ( cd "$SDK_DIR" && cargo build $CARGO_FLAGS "$@" -p ssruntime --features libc_alloc,panic-handler ); }
build_converter() { ( cd "$SDK_DIR" && cargo build $CARGO_FLAGS "$@" -p ssconverter ); }
place() { mkdir -p "$LIBS_DIR/$1"; cp "$2" "$LIBS_DIR/$1/${3:-$(basename "$2")}"; echo "   -> native/libs/$1/${3:-$(basename "$2")}"; }
# Same, but into the ssconverter_dart package (the host converter's home).
place_conv() { mkdir -p "$CONV_LIBS_DIR/$1"; cp "$2" "$CONV_LIBS_DIR/$1/${3:-$(basename "$2")}"; echo "   -> ssconverter_dart native/libs/$1/${3:-$(basename "$2")}"; }

# Read the SDK workspace version (for the framework Info.plist on the host path).
sdk_version() { sed -n 's/^version = "\(.*\)"/\1/p' "$SDK_DIR/Cargo.toml" | head -1; }

mkdir -p "$LIBS_DIR"
# licenses
[ -f "$SDK_DIR/LICENSE.md" ] && cp "$SDK_DIR/LICENSE.md" "$LIBS_DIR/"
[ -f "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" ] && \
  cp "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" "$LIBS_DIR/"
# record the version we built from (used by download-sdk.sh cache check too)
[ -f "$ROOT_DIR/scripts/SDK_VERSION.txt" ] && cp "$ROOT_DIR/scripts/SDK_VERSION.txt" "$LIB_ROOT/VERSION"

T="$SDK_DIR/target"
case "$PLATFORM" in
  macos)
    mkdir -p "$LIBS_DIR/macos"
    # The runtime ships ONLY as libssruntime.framework: a bare .dylib is not
    # embeddable via CocoaPods vendored_frameworks and the SDK no longer ships one.
    # The single copy lives here in native/libs/macos/; a symlink under the plugin's
    # macos/Frameworks/ (below) is what the podspec embeds (CocoaPods only embeds a
    # vendored framework at/below the podspec dir). libssconverter stays a bare dylib
    # — a host tool (prepare-example-assets.sh), never embedded in the app.
    if [ "$IS_HOST_BUILD" = true ] && [ "$ARCH" != universal ]; then
      # Fast host/debug path: plain `cargo build` (single arch, honours build=debug),
      # then wrap the fresh dylib into a .framework via the SDK's shared packaging
      # helper (single source of truth — release-macos.sh uses the same one, like
      # SSPlayerForUnity does with make-macos-bundle.sh). We skip release-macos.sh
      # here because it is a slow universal cross-build.
      build_ss; build_converter
      bash "$SDK_DIR/scripts/make-macos-framework.sh" \
        "$T/$BUILD_MODE/libssruntime.dylib" \
        "$LIBS_DIR/macos/libssruntime.framework" \
        "$(sdk_version)" \
        "jp.co.cri-mw.optpix.ssruntime" \
        "${MACOSX_DEPLOYMENT_TARGET:-11.0}" \
        "$SDK_DIR/libs/ssruntime/target/ssruntime.h"
      echo "   -> native/libs/macos/libssruntime.framework"
      place_conv macos "$T/$BUILD_MODE/libssconverter.dylib"
      install_name_tool -id "@rpath/libssconverter.dylib" "$CONV_LIBS_DIR/macos/libssconverter.dylib" 2>/dev/null || true
    else
      # Universal (arm64 + x86_64): the SDK release script now BUILDS the versioned
      # libssruntime.framework itself (correct Info.plist, Headers/Modules, and code
      # signature), so consume it directly instead of re-wrapping a bare dylib.
      bash "$SDK_DIR/scripts/release-macos.sh" "$BUILD_MODE"
      UNI="$T/universal-apple-darwin/$BUILD_MODE"
      rm -rf "$LIBS_DIR/macos/libssruntime.framework"
      cp -R "$UNI/libssruntime.framework" "$LIBS_DIR/macos/"
      echo "   -> native/libs/macos/libssruntime.framework"
      if [ -f "$UNI/libssconverter.dylib" ]; then
        place_conv macos "$UNI/libssconverter.dylib"
        install_name_tool -id "@rpath/libssconverter.dylib" "$CONV_LIBS_DIR/macos/libssconverter.dylib" 2>/dev/null || true
      fi
    fi
    # Symlink the single framework under the plugin's macos/Frameworks/ so CocoaPods
    # embeds it (a relative symlink keeps it inside the podspec dir with no second
    # copy; `install_framework` resolves it at embed time). gitignored.
    POD_FW_DIR="$PKG_DIR/macos/Frameworks"
    mkdir -p "$POD_FW_DIR"
    rm -rf "$POD_FW_DIR/libssruntime.framework"
    ln -sfn ../../native/libs/macos/libssruntime.framework "$POD_FW_DIR/libssruntime.framework"
    echo "   -> macos/Frameworks/libssruntime.framework -> ../../native/libs/macos/libssruntime.framework" ;;

  linux)
    # Linux arch dir uses the kernel/Rust spelling: aarch64 (not arm64), x86_64 —
    # matching the SDK release layout native/libs/linux/aarch64. Accept arm64 as
    # an alias for ergonomics but always emit aarch64.
    case "$ARCH" in arm64|aarch64) larch=aarch64 ;; *) larch="$ARCH" ;; esac
    if [ "$IS_HOST_BUILD" = true ]; then
      build_ss; build_converter
      place "linux/$larch" "$T/$BUILD_MODE/libssruntime.so"
      place_conv "linux/$larch" "$T/$BUILD_MODE/libssconverter.so"
    else
      triple=$([ "$larch" = aarch64 ] && echo aarch64-unknown-linux-gnu || echo x86_64-unknown-linux-gnu)
      build_ss --target "$triple"; build_converter --target "$triple"
      place "linux/$larch" "$T/$triple/$BUILD_MODE/libssruntime.so"
      place_conv "linux/$larch" "$T/$triple/$BUILD_MODE/libssconverter.so"
    fi ;;

  windows)
    if [ "$IS_HOST_BUILD" = true ]; then
      build_ss; build_converter
      place "windows/$ARCH" "$T/$BUILD_MODE/ssruntime.dll"
      place_conv "windows/$ARCH" "$T/$BUILD_MODE/ssconverter.dll"
    else
      triple=$([ "$ARCH" = arm64 ] && echo aarch64-pc-windows-msvc || echo x86_64-pc-windows-msvc)
      build_ss --target "$triple"; build_converter --target "$triple"
      place "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssruntime.dll"
      place_conv "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssconverter.dll"
    fi ;;

  # --- toolchain-heavy cross builds: delegate to the SDK release scripts ---
  android)
    bash "$SDK_DIR/scripts/release-android.sh" "$BUILD_MODE"
    for pair in "aarch64-linux-android:arm64-v8a" "armv7-linux-androideabi:armeabi-v7a" "x86_64-linux-android:x86_64"; do
      tr="${pair%%:*}"; abi="${pair##*:}"
      [ -f "$T/$tr/$BUILD_MODE/libssruntime.so" ] && place "android/$abi" "$T/$tr/$BUILD_MODE/libssruntime.so"
    done ;;

  ios)
    bash "$SDK_DIR/scripts/release-ios-xcframework.sh" "$BUILD_MODE"
    mkdir -p "$LIBS_DIR/ios"; rm -rf "$LIBS_DIR/ios/libssruntime.xcframework"
    # Ship the DYNAMIC xcframework so the app embeds one framework and dyld
    # resolves the Brain via @rpath (DynamicLibrary.open('libssruntime.framework/libssruntime')).
    cp -R "$T/xcframework/dynamic/libssruntime.xcframework" "$LIBS_DIR/ios/"
    echo "   -> native/libs/ios/libssruntime.xcframework" ;;

  web)
    bash "$SDK_DIR/scripts/release-web.sh" "$BUILD_MODE"
    mkdir -p "$LIBS_DIR/web"
    cp -R "$SDK_DIR/pkg/runtime-web/$BUILD_MODE/"* "$LIBS_DIR/web/" 2>/dev/null || true
    echo "   -> native/libs/web/" ;;

  *) echo "build-runtime.sh: unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac

# --- C headers (ffigen input): consume the plain-C headers the SDK build.rs
# emitted (Language::C, <crate>.h; .hpp is the C++ twin). The SDK is the single
# source of truth for the C-API surface — no local cbindgen. Each crate's header
# goes to its OWN binding package: ssruntime → ssruntime_dart, ssconverter →
# ssconverter_dart (copied only when that crate was part of this build).
mkdir -p "$RT_PKG_DIR/native/include" "$CONV_PKG_DIR/native/include"
rh="$SDK_DIR/libs/ssruntime/target/ssruntime.h"
[ -f "$rh" ] && { cp "$rh" "$RT_PKG_DIR/native/include/ssruntime.h"; echo "   -> ssruntime_dart native/include/ssruntime.h"; }
ch="$SDK_DIR/libs/ssconverter/target/ssconverter.h"
[ -f "$ch" ] && { cp "$ch" "$CONV_PKG_DIR/native/include/ssconverter.h"; echo "   -> ssconverter_dart native/include/ssconverter.h"; }

# --- Layer-1 ffigen bindings: regenerate now that the headers are fresh. ffigen
# is Flutter-specific; folding it in here keeps the dev-facing script count the
# same as the sibling players. No-op without the Dart SDK.
bash "$ROOT_DIR/scripts/generate-ffigen-code.sh" || true

echo "build-runtime.sh: done."
