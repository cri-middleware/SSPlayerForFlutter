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
#   native/libs/macos/libssruntime.dylib            (universal on build=release)
#   native/libs/windows/<arch>/ssruntime.dll
#   native/libs/linux/<arch>/libssruntime.so
#   native/libs/android/<abi>/libssruntime.so
#   native/libs/ios/libssruntime.xcframework
#   native/libs/web/...                              (wasm bundle)
#   native/libs/LICENSE.md
#   native/VERSION
#
# C headers for ffigen are produced separately by scripts/generate-runtime-code.sh.
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

# Wrap a macOS .dylib in a versioned .framework so CocoaPods `vendored_frameworks`
# can embed + codesign it into the app's Frameworks (a bare .dylib via
# `vendored_libraries` is NOT embedded for runtime dlopen). Produces
# lib<name>.framework with id @rpath/lib<name>.framework/Versions/A/lib<name>,
# which the Dart loader opens as 'lib<name>.framework/lib<name>'.
make_macos_framework() {
  local src="$1" name="$2"                      # src dylib, framework base name
  local fw="$LIBS_DIR/macos/lib${name}.framework"
  rm -rf "$fw"
  mkdir -p "$fw/Versions/A/Resources"
  cp "$src" "$fw/Versions/A/lib${name}"
  install_name_tool -id "@rpath/lib${name}.framework/Versions/A/lib${name}" \
    "$fw/Versions/A/lib${name}" 2>/dev/null || true
  cat > "$fw/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>lib${name}</string>
  <key>CFBundleIdentifier</key><string>jp.co.cri-mw.lib${name}</string>
  <key>CFBundleName</key><string>lib${name}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>7.0.0</string>
  <key>CFBundleVersion</key><string>7.0.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict></plist>
PLIST
  ( cd "$fw/Versions" && ln -sf A Current )
  ( cd "$fw" && ln -sf "Versions/Current/lib${name}" "lib${name}"
                ln -sf "Versions/Current/Resources" "Resources" )
  echo "   -> native/libs/macos/lib${name}.framework"
}

mkdir -p "$LIBS_DIR"
# licenses
[ -f "$SDK_DIR/LICENSE.md" ] && cp "$SDK_DIR/LICENSE.md" "$LIBS_DIR/"
[ -f "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" ] && \
  cp "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" "$LIBS_DIR/"
# record the version we built from (used by download-sdk.sh cache check too)
[ -f "$ROOT_DIR/SDK_VERSION.txt" ] && cp "$ROOT_DIR/SDK_VERSION.txt" "$LIB_ROOT/VERSION"

T="$SDK_DIR/target"
case "$PLATFORM" in
  macos)
    if [ "$IS_HOST_BUILD" = true ] && [ "$ARCH" != universal ]; then
      build_ss; build_converter
      place macos "$T/$BUILD_MODE/libssruntime.dylib"
      place macos "$T/$BUILD_MODE/libssconverter.dylib"
    else
      # universal (arm64 + x86_64): delegate to the SDK release script + lipo
      bash "$SDK_DIR/scripts/release-macos.sh" "$BUILD_MODE"
      UNI="$T/universal-apple-darwin/$BUILD_MODE"
      place macos "$UNI/libssruntime.dylib"
      [ -f "$UNI/libssconverter.dylib" ] && place macos "$UNI/libssconverter.dylib"
    fi
    # cargo stamps the dylib's install_name with an absolute build path; rewrite
    # it to @rpath so it is relocatable when bundled into an app (Frameworks).
    for lib in libssruntime.dylib libssconverter.dylib; do
      [ -f "$LIBS_DIR/macos/$lib" ] && install_name_tool -id "@rpath/$lib" "$LIBS_DIR/macos/$lib" 2>/dev/null || true
    done
    # Also emit a .framework for the runtime so the Flutter plugin can embed it
    # via CocoaPods vendored_frameworks (the app loads it at runtime). CocoaPods
    # only globs paths at/below the podspec dir, so the framework must live under
    # the plugin's macos/ folder — mirror it there (gitignored).
    if [ -f "$LIBS_DIR/macos/libssruntime.dylib" ]; then
      make_macos_framework "$LIBS_DIR/macos/libssruntime.dylib" ssruntime
      POD_FW_DIR="$PKG_DIR/macos/Frameworks"
      mkdir -p "$POD_FW_DIR"
      rm -rf "$POD_FW_DIR/libssruntime.framework"
      cp -R "$LIBS_DIR/macos/libssruntime.framework" "$POD_FW_DIR/"
      echo "   -> macos/Frameworks/libssruntime.framework"
    fi ;;

  linux)
    if [ "$IS_HOST_BUILD" = true ]; then
      build_ss; build_converter
      place "linux/$ARCH" "$T/$BUILD_MODE/libssruntime.so"
      place "linux/$ARCH" "$T/$BUILD_MODE/libssconverter.so"
    else
      triple=$([ "$ARCH" = arm64 ] && echo aarch64-unknown-linux-gnu || echo x86_64-unknown-linux-gnu)
      build_ss --target "$triple"; build_converter --target "$triple"
      place "linux/$ARCH" "$T/$triple/$BUILD_MODE/libssruntime.so"
      place "linux/$ARCH" "$T/$triple/$BUILD_MODE/libssconverter.so"
    fi ;;

  windows)
    if [ "$IS_HOST_BUILD" = true ]; then
      build_ss; build_converter
      place "windows/$ARCH" "$T/$BUILD_MODE/ssruntime.dll"
      place "windows/$ARCH" "$T/$BUILD_MODE/ssconverter.dll"
    else
      triple=$([ "$ARCH" = arm64 ] && echo aarch64-pc-windows-msvc || echo x86_64-pc-windows-msvc)
      build_ss --target "$triple"; build_converter --target "$triple"
      place "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssruntime.dll"
      place "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssconverter.dll"
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

echo "build-runtime.sh: done."
