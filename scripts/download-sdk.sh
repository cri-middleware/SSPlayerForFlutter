#!/usr/bin/env bash
#
# Download the prebuilt SpriteStudio-SDK native libraries + headers and unpack
# them into the Flutter package so the app can be built without a Rust toolchain.
# Mirrors SSPlayerForGodot/scripts/download-sdk.sh, adapted to THIS repo:
#   - target version comes from scripts/SDK_VERSION.txt
#   - the cache stamp lives at packages/ssruntime_dart/native/VERSION
#     (build-runtime.sh writes the same file), so a matching version skips the
#     download; a fresh checkout / bumped version re-fetches.
#   - artifacts currently unpack into packages/ssplayer_flutter/native/; splitting
#     them across ssruntime_dart / ssconverter_dart (to match build-runtime's
#     native-assets layout) is a pending follow-up — see NOTE at the ARTIFACT line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Unpack destination (pending migration to the ssruntime_dart / ssconverter_dart
# native-assets layout — see NOTE below); the SDK-version cache stamp, however,
# lives with the runtime package to match build-runtime.sh's writer.
NATIVE_DIR="$ROOT_DIR/packages/ssplayer_flutter/native"
VERSION_FILE="$SCRIPT_DIR/SDK_VERSION.txt"
CURRENT_VERSION_FILE="$ROOT_DIR/packages/ssruntime_dart/native/VERSION"

TARGET_VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"

# skip if the cached libs already match the requested version
if [ -f "$CURRENT_VERSION_FILE" ]; then
  CURRENT_VERSION="$(tr -d '\r\n' < "$CURRENT_VERSION_FILE")"
  if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
    echo "SDK $TARGET_VERSION is already up to date. Skipping download."
    exit 0
  fi
fi

# A Flutter FFI plugin loads shared objects at runtime (dart:ffi DynamicLibrary),
# so we want the DYNAMIC-libs artifact (.dylib/.so/.dll + dynamic xcframework) —
# the same one SSPlayerForRenPy uses. NOTE: the exact zip name must match what is
# actually published on the SpriteStudio-SDK releases; adjust here (and in
# download-sdk.ps1) once the release pipeline publishes Flutter/dynamic artifacts.
ARTIFACT="spritestudio-sdk-dynamic-libs.zip"
URL="https://github.com/cri-middleware/SpriteStudio-SDK/releases/download/${TARGET_VERSION}/${ARTIFACT}"
ZIP_FILE="$NATIVE_DIR/sdk.zip"

echo "Target SDK Version: ${TARGET_VERSION}"
echo "Download URL: ${URL}"
echo "Downloading SDK..."
mkdir -p "$NATIVE_DIR"
curl -fL -o "$ZIP_FILE" "$URL"

echo "Extracting SDK..."
unzip -q -o "$ZIP_FILE" -d "$NATIVE_DIR/"
rm -f "$ZIP_FILE"

# No macos/Frameworks symlink: the Brain is delivered as a native-assets code
# asset (ssruntime_dart/hook/build.dart), so Flutter embeds it automatically —
# there is no vendored CocoaPods framework to link.

# stamp the cache with the version we just unpacked (next to the runtime package)
mkdir -p "$(dirname "$CURRENT_VERSION_FILE")"
echo "$TARGET_VERSION" > "$CURRENT_VERSION_FILE"

# Regenerate the Layer-1 ffigen bindings from the unpacked C headers
# (native/include/*.h). Flutter-specific; folded in so `download-sdk` alone
# suffices (matches build-runtime). No-op without the Dart SDK.
bash "$SCRIPT_DIR/generate-ffigen-code.sh" || true

echo "Done."
