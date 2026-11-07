#!/usr/bin/env bash
#
# Build the native Brain (libssruntime / libssconverter) from the
# SpriteStudio-SDK submodule and place the DYNAMIC libraries into each binding
# package's native/libs/ layout so the native-assets build hook (hook/build.dart)
# bundles them as code assets the `@Native` bindings resolve at runtime.
#
# Interface mirrors the sibling players (SSPlayerForRenPy / -Unity / -Godot):
#   platform=<p> arch=<a> build=<m> hostbuild=<auto|false>
# For DESKTOP hosts we build the feature-enabled `ssruntime` cdylib directly
# (fast). android / ios / web are toolchain-heavy cross builds and delegate to
# the SDK's own release scripts (SpriteStudio-SDK/scripts/release-*).
#
# Output layout — each library lands in the binding package that bundles it as a
# native-assets code asset (hook/build.dart), NOT in ssplayer_flutter:
#   libssruntime   → packages/ssruntime_dart/native/libs/<platform>/[<arch>]/   (bare dylib/.so/.dll)
#   libssconverter → packages/ssconverter_dart/native/libs/<platform>/[<arch>]/ (host tool)
#   packages/ssruntime_dart/native/libs/LICENSE.md, THIRD-PARTY-LICENSES.ssruntime.md
#   packages/ssconverter_dart/native/libs/LICENSE.md
# Native assets embed the bare dylib; Flutter re-wraps it at build time.
# iOS uses bare per-slice dylibs, NOT an xcframework:
#   native/libs/ios/iphoneos/arm64/libssruntime.dylib          (device)
#   native/libs/ios/iphonesimulator/{arm64,x86_64}/libssruntime.dylib  (simulator)
# hook/build.dart picks one by (targetSdk, arch). Web is the exception: it has
# no build hook / native asset, so `platform=web` builds the wasm-bindgen `web`
# runtime and places it as a Flutter ASSET under
# packages/ssplayer_flutter/assets/runtime-web/ (loaded via dart:js_interop).
#
# After building, this copies the SDK build.rs-emitted plain-C headers into
# native/include/. The ffigen bindings are COMMITTED (like the .fbs accessors), so
# regenerating them is a separate manual step — run scripts/generate-ffigen-code.sh
# after a C-API change and commit the result (scripts/generate-fbs-code.sh for .fbs).
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
build_ss()        { ( cd "$SDK_DIR" && cargo build $CARGO_FLAGS "$@" -p ssruntime-ffi --features libc_alloc,panic-handler ); }
build_converter() { ( cd "$SDK_DIR" && cargo build $CARGO_FLAGS "$@" -p ssconverter-ffi ); }
place() { mkdir -p "$LIBS_DIR/$1"; cp "$2" "$LIBS_DIR/$1/${3:-$(basename "$2")}"; echo "   -> native/libs/$1/${3:-$(basename "$2")}"; }
# Same, but into the ssconverter_dart package (the host converter's home).
place_conv() { mkdir -p "$CONV_LIBS_DIR/$1"; cp "$2" "$CONV_LIBS_DIR/$1/${3:-$(basename "$2")}"; echo "   -> ssconverter_dart native/libs/$1/${3:-$(basename "$2")}"; }
# The runtime (libssruntime) lives in ssruntime_dart — its native-assets
# hook/build.dart bundles this bare dylib/.so/.dll as a code asset (no framework).
RT_LIBS_DIR="$RT_PKG_DIR/native/libs"
place_rt() { mkdir -p "$RT_LIBS_DIR/$1"; cp "$2" "$RT_LIBS_DIR/$1/${3:-$(basename "$2")}"; echo "   -> ssruntime_dart native/libs/$1/${3:-$(basename "$2")}"; }

# Licenses ship next to the library they cover: the SDK LICENSE.md with BOTH
# binding packages (each ships a CRI dylib), the ssruntime third-party notices
# with ssruntime_dart (and the ssconverter notices with ssconverter_dart, if any).
mkdir -p "$RT_LIBS_DIR" "$CONV_LIBS_DIR"
if [ -f "$SDK_DIR/LICENSE.md" ]; then
  cp "$SDK_DIR/LICENSE.md" "$RT_LIBS_DIR/"
  cp "$SDK_DIR/LICENSE.md" "$CONV_LIBS_DIR/"
fi
[ -f "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" ] && \
  cp "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" "$RT_LIBS_DIR/"
[ -f "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssconverter.md" ] && \
  cp "$SDK_DIR/target/licenses/THIRD-PARTY-LICENSES.ssconverter.md" "$CONV_LIBS_DIR/"

T="$SDK_DIR/target"
case "$PLATFORM" in
  macos)
    # Native assets: ship BARE dylibs (@rpath install id). ssruntime_dart's and
    # ssconverter_dart's hook/build.dart bundle them as code assets.
    if [ "$IS_HOST_BUILD" = true ] && [ "$ARCH" != universal ]; then
      # Fast host/debug path: plain single-arch `cargo build` (honours build=debug).
      build_ss; build_converter
      place_rt   macos "$T/$BUILD_MODE/libssruntime.dylib"
      install_name_tool -id "@rpath/libssruntime.dylib" "$RT_LIBS_DIR/macos/libssruntime.dylib" 2>/dev/null || true
      place_conv macos "$T/$BUILD_MODE/libssconverter.dylib"
      install_name_tool -id "@rpath/libssconverter.dylib" "$CONV_LIBS_DIR/macos/libssconverter.dylib" 2>/dev/null || true
    else
      # Universal (arm64 + x86_64): release-macos.sh lipos the universal dylibs
      # (it also builds a .framework, which is unused here — native assets embeds
      # the bare dylib itself).
      bash "$SDK_DIR/scripts/release-macos.sh" "$BUILD_MODE"
      UNI="$T/universal-apple-darwin/$BUILD_MODE"
      place_rt macos "$UNI/libssruntime.dylib"
      install_name_tool -id "@rpath/libssruntime.dylib" "$RT_LIBS_DIR/macos/libssruntime.dylib" 2>/dev/null || true
      if [ -f "$UNI/libssconverter.dylib" ]; then
        place_conv macos "$UNI/libssconverter.dylib"
        install_name_tool -id "@rpath/libssconverter.dylib" "$CONV_LIBS_DIR/macos/libssconverter.dylib" 2>/dev/null || true
      fi
    fi ;;

  linux)
    # Linux arch dir uses the kernel/Rust spelling: aarch64 (not arm64), x86_64 —
    # matching the SDK release layout native/libs/linux/aarch64. Accept arm64 as
    # an alias for ergonomics but always emit aarch64.
    case "$ARCH" in arm64|aarch64) larch=aarch64 ;; *) larch="$ARCH" ;; esac
    if [ "$IS_HOST_BUILD" = true ]; then
      build_ss; build_converter
      place_rt "linux/$larch" "$T/$BUILD_MODE/libssruntime.so"
      place_conv "linux/$larch" "$T/$BUILD_MODE/libssconverter.so"
    else
      triple=$([ "$larch" = aarch64 ] && echo aarch64-unknown-linux-gnu || echo x86_64-unknown-linux-gnu)
      build_ss --target "$triple"; build_converter --target "$triple"
      place_rt "linux/$larch" "$T/$triple/$BUILD_MODE/libssruntime.so"
      place_conv "linux/$larch" "$T/$triple/$BUILD_MODE/libssconverter.so"
    fi ;;

  windows)
    if [ "$IS_HOST_BUILD" = true ]; then
      build_ss; build_converter
      place_rt "windows/$ARCH" "$T/$BUILD_MODE/ssruntime.dll"
      place_conv "windows/$ARCH" "$T/$BUILD_MODE/ssconverter.dll"
    else
      triple=$([ "$ARCH" = arm64 ] && echo aarch64-pc-windows-msvc || echo x86_64-pc-windows-msvc)
      build_ss --target "$triple"; build_converter --target "$triple"
      place_rt "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssruntime.dll"
      place_conv "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssconverter.dll"
    fi ;;

  # --- toolchain-heavy cross builds: delegate to the SDK release scripts ---
  android)
    bash "$SDK_DIR/scripts/release-android.sh" "$BUILD_MODE"
    for pair in "aarch64-linux-android:arm64-v8a" "armv7-linux-androideabi:armeabi-v7a" "x86_64-linux-android:x86_64"; do
      tr="${pair%%:*}"; abi="${pair##*:}"
      [ -f "$T/$tr/$BUILD_MODE/libssruntime.so" ] && place_rt "android/$abi" "$T/$tr/$BUILD_MODE/libssruntime.so"
    done ;;

  ios)
    bash "$SDK_DIR/scripts/release-ios-xcframework.sh" "$BUILD_MODE"
    # No xcframework: hook/build.dart selects a bare per-slice dylib by
    # (targetSdk, arch). device-arm64, simulator-arm64 and simulator-x86_64 are
    # distinct Mach-O targets (same arch can't coexist in a fat binary — that is
    # exactly what an xcframework separates). Flutter's native-assets embedding
    # wraps the chosen slice into a framework and (re)signs it, as on macOS.
    for triple_slot in \
      "aarch64-apple-ios:ios/iphoneos/arm64" \
      "aarch64-apple-ios-sim:ios/iphonesimulator/arm64" \
      "x86_64-apple-ios:ios/iphonesimulator/x86_64"; do
      tr="${triple_slot%%:*}"; slot="${triple_slot#*:}"
      dylib="$T/$tr/$BUILD_MODE/libssruntime.dylib"
      if [ -f "$dylib" ]; then
        place_rt "$slot" "$dylib"
        install_name_tool -id "@rpath/libssruntime.dylib" \
          "$RT_LIBS_DIR/$slot/libssruntime.dylib" 2>/dev/null || true
      fi
    done ;;

  web)
    # Flutter web has NO build hooks / native assets and NO dart:ffi, so the
    # Brain cannot ship as a native-asset dylib. Instead it ships as the SDK's
    # wasm-bindgen `web` build (a .wasm + JS glue), bundled as a plain Flutter
    # ASSET in ssplayer_flutter and driven from Dart over dart:js_interop
    # (lib/src/runtime_api.dart → web backend). This branch builds the runtime
    # crate to wasm and places the two files where pubspec.yaml's `assets:`
    # expects them. Only the runtime is needed here (converter-web is a separate
    # concern for ssconverter_dart), so we invoke wasm-pack directly rather than
    # the SDK's release-web.sh, which also builds the nosimd + converter packages.
    if ! command -v wasm-pack >/dev/null 2>&1; then
      echo "build-runtime.sh: wasm-pack not found — install it with:" >&2
      echo "    cargo install wasm-pack        # + rustup target add wasm32-unknown-unknown" >&2
      exit 3
    fi
    WP_MODE="--release"; [ "$BUILD_MODE" = "debug" ] && WP_MODE="--dev"
    SIMD_OUT="$SDK_DIR/pkg/runtime-web/$BUILD_MODE"
    NOSIMD_OUT="$SDK_DIR/pkg/runtime-web-nosimd/$BUILD_MODE"
    # Primary build: inherits the SDK's repo-wide `+simd128` (its .cargo/config.toml)
    # — the fast path for modern browsers. NB: wasm-pack's --out-dir is relative to
    # the CRATE dir (libs/ssruntime-ffi), so ../../ anchors it at the SDK-root pkg/
    # (same as the SDK's own release-web.sh).
    ( cd "$SDK_DIR" && wasm-pack build libs/ssruntime-ffi "$WP_MODE" --target web \
        --out-dir "../../pkg/runtime-web/$BUILD_MODE" -- --features web --no-default-features )
    # nosimd fallback: override `+simd128` with `-simd128`, for WASM engines
    # without stable SIMD (e.g. the NW.js bundled with RPG Maker MZ). Same source
    # + same wasm-bindgen, so the JS glue is interface-identical to the simd build
    # — only the `_bg.wasm` differs, and loadSsRuntime() picks it at runtime via a
    # WebAssembly.validate(simd128) probe. We therefore ship one JS glue (simd's)
    # plus both binaries (simd as ssruntime_bg.wasm, nosimd as *.nosimd.wasm).
    ( cd "$SDK_DIR" && RUSTFLAGS="-C target-feature=-simd128" wasm-pack build libs/ssruntime-ffi "$WP_MODE" \
        --target web --out-dir "../../pkg/runtime-web-nosimd/$BUILD_MODE" -- --features web --no-default-features )
    ASSET_DIR="$PKG_DIR/assets/runtime-web"
    mkdir -p "$ASSET_DIR"
    cp "$SIMD_OUT/ssruntime.js"       "$ASSET_DIR/ssruntime.js"
    cp "$SIMD_OUT/ssruntime_bg.wasm"  "$ASSET_DIR/ssruntime_bg.wasm"
    cp "$NOSIMD_OUT/ssruntime_bg.wasm" "$ASSET_DIR/ssruntime_bg.nosimd.wasm"
    # Guard the "one JS glue drives both binaries" assumption we ship on.
    cmp -s "$SIMD_OUT/ssruntime.js" "$NOSIMD_OUT/ssruntime.js" || \
      echo "build-runtime.sh: WARN — simd/nosimd JS glue differ; the shared ssruntime.js may not drive the nosimd wasm." >&2
    echo "   -> packages/ssplayer_flutter/assets/runtime-web/ (ssruntime.js + ssruntime_bg.wasm + ssruntime_bg.nosimd.wasm)" ;;

  *) echo "build-runtime.sh: unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac

# --- C headers (ffigen input): consume the plain-C headers the SDK build.rs
# emitted (Language::C, <crate>.h; .hpp is the C++ twin). The SDK is the single
# source of truth for the C-API surface. Each crate's header goes to its OWN
# binding package: ssruntime → ssruntime_dart, ssconverter → ssconverter_dart
# (copied only when that crate was part of this build).
mkdir -p "$RT_PKG_DIR/native/include" "$CONV_PKG_DIR/native/include"
# The generating build scripts live in the *-ffi crates and write beside
# themselves, so these are `libs/<crate>-ffi/target/`. These copies are guarded,
# so a stale path fails silently: the header never updates and ffigen keeps
# regenerating yesterday's C-API.
rh="$SDK_DIR/libs/ssruntime-ffi/target/ssruntime.h"
[ -f "$rh" ] && { cp "$rh" "$RT_PKG_DIR/native/include/ssruntime.h"; echo "   -> ssruntime_dart native/include/ssruntime.h"; }
ch="$SDK_DIR/libs/ssconverter-ffi/target/ssconverter.h"
[ -f "$ch" ] && { cp "$ch" "$CONV_PKG_DIR/native/include/ssconverter.h"; echo "   -> ssconverter_dart native/include/ssconverter.h"; }

# The ffigen bindings (lib/src/*_bindings.g.dart) are committed, not regenerated
# here. If this build changed the C-API, run scripts/generate-ffigen-code.sh and
# commit the updated bindings.

echo "build-runtime.sh: done."
