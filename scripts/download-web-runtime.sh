#!/usr/bin/env bash
#
# Put the web Brain into packages/ssplayer_flutter/assets/runtime-web/ -- the
# wasm-bindgen build of libssruntime the browser loads, taken from the
# SpriteStudio-SDK release the native-asset hooks are pinned to.
#
#   scripts/download-web-runtime.sh            # the pinned release
#   scripts/download-web-runtime.sh force=no   # leave an existing runtime alone
#
# Three callers, which is why this is its own script rather than a function in
# any of them:
#
#   scripts/build-pages.sh sdk=download -- the published demo runs on this wasm.
#   scripts/build-release.sh sdk=download -- pub packs what is on disk, and this
#     directory is git-ignored build output, so a release archive gets a web
#     Brain only if one is here first.
#   .github/workflows/publish.yml -- the ssplayer_flutter job, for the same
#     reason: it publishes from a clean checkout where this directory is empty.
#
# The three files are what ssruntime_dart's web_runtime.dart loads BY NAME, and
# their names are not the release's: the SDK ships the SIMD build and the
# fallback as two separate packages, each with its own ssruntime_bg.wasm, and
# this flattens them into the one-directory layout the loader's runtime SIMD
# probe expects (one shared JS glue -- the two are interface-identical -- plus
# both binaries). scripts/build-runtime.sh platform=web lays them out the same
# way, which is what makes sdk=build interchangeable with sdk=download.
set -euo pipefail

APP="$(basename "$0")"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DEST_DIR="packages/ssplayer_flutter/assets/runtime-web"
SDK_RELEASE_BASE="https://github.com/cri-middleware/SpriteStudio-SDK/releases/download"
SDK_WEB_ZIP="spritestudio-sdk-web-libs.zip"
# The release everything is pinned to. Read from the build hook rather than
# repeated: the host libraries come from this same tag (the hooks fetch them
# themselves), and a demo whose wasm and dylib came from different releases is
# the kind of mismatch nobody notices until a draw call misbehaves.
SDK_VERSION_SOURCE="packages/ssruntime_dart/hook/build.dart"

FORCE="yes"

usage () {
  echo "Usage: $APP [options]"
  echo "$APP options:"
  echo "  force=<yes|no>          Download even when $DEST_DIR"
  echo "                          already holds a runtime (default: $FORCE). no makes"
  echo "                          this a no-op in that case -- for a caller that only"
  echo "                          needs SOME runtime there, not the pinned one."
  echo "  -h | --help             Show this help"
  echo ""
  echo "There is no version option: the release is the one"
  echo "$SDK_VERSION_SOURCE pins, because that is the one the"
  echo "rest of the build already depends on."
}

while [ $# -gt 0 ]; do
  item="$1"
  shift
  case "$item" in
    -h|--help|help) usage; exit 0 ;;
    force=*) FORCE="$(printf '%s' "${item#*=}" | tr '[:upper:]' '[:lower:]')" ;;
    *) echo "$APP: unknown argument '$item' (see $APP --help)" >&2; exit 2 ;;
  esac
done
case "$FORCE" in yes|no) ;; *) echo "$APP: force must be yes or no (got '$FORCE')" >&2; exit 2 ;; esac

cd "$ROOT_DIR"

if [ "$FORCE" = "no" ] && [ -f "$ROOT_DIR/$DEST_DIR/ssruntime_bg.wasm" ]; then
  echo "$APP: $DEST_DIR already holds a runtime -- force=no, leaving it"
  exit 0
fi

VERSION="$(sed -n "s/^const _sdkVersion = '\(.*\)';.*$/\1/p" "$ROOT_DIR/$SDK_VERSION_SOURCE" | head -1)"
[ -n "$VERSION" ] || {
  echo "$APP: no _sdkVersion found in $SDK_VERSION_SOURCE" >&2
  exit 1
}

for tool in curl unzip; do
  command -v "$tool" > /dev/null 2>&1 || { echo "$APP: $tool not on PATH" >&2; exit 1; }
done

TMP_DIR="$(mktemp -d)"
cleanup () { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo ""
echo ">> downloading $SDK_WEB_ZIP ($VERSION)"
if ! curl -fsSL -o "$TMP_DIR/$SDK_WEB_ZIP" "$SDK_RELEASE_BASE/$VERSION/$SDK_WEB_ZIP"; then
  # Reached from CI as well as from a working tree, so it says what is wrong
  # rather than assuming the reader can just build the runtime instead -- on a
  # runner there is no Rust toolchain to build it with.
  echo "" >&2
  echo "$APP: could not download $SDK_WEB_ZIP from SpriteStudio-SDK $VERSION." >&2
  echo "$APP: that release is the one $SDK_VERSION_SOURCE pins," >&2
  echo "$APP: and its assets are attached by the SDK's own release.yml -- check the" >&2
  echo "$APP: release exists and carries $SDK_WEB_ZIP." >&2
  echo "$APP: In a working tree with cargo + wasm-pack," >&2
  echo "$APP: 'scripts/build-runtime.sh platform=web build=release' compiles it instead." >&2
  exit 1
fi

# The same integrity check hook/build.dart runs on the dynamic-libs archive: an
# archive SHA256SUMS does not vouch for is not used.
if command -v shasum > /dev/null 2>&1; then SHA_TOOL="shasum -a 256"
elif command -v sha256sum > /dev/null 2>&1; then SHA_TOOL="sha256sum"
else
  echo "$APP: neither shasum nor sha256sum on PATH" >&2
  exit 1
fi
if ! curl -fsSL -o "$TMP_DIR/SHA256SUMS" "$SDK_RELEASE_BASE/$VERSION/SHA256SUMS"; then
  echo "$APP: could not download SHA256SUMS from SpriteStudio-SDK $VERSION" >&2
  exit 1
fi
WANT="$(awk -v f="$SDK_WEB_ZIP" '$2 == f || $2 == "*" f {print $1}' "$TMP_DIR/SHA256SUMS" | head -1)"
GOT="$($SHA_TOOL "$TMP_DIR/$SDK_WEB_ZIP" | awk '{print $1}')"
if [ -z "$WANT" ]; then
  echo "$APP: SHA256SUMS carries no line for $SDK_WEB_ZIP" >&2
  exit 1
elif [ "$WANT" != "$GOT" ]; then
  echo "$APP: $SDK_WEB_ZIP does not match SHA256SUMS ($GOT != $WANT)" >&2
  exit 1
fi
echo "   sha256 ok"

unzip -q -o "$TMP_DIR/$SDK_WEB_ZIP" -d "$TMP_DIR/unpacked"
for f in runtime-web/ssruntime.js runtime-web/ssruntime_bg.wasm runtime-web-nosimd/ssruntime_bg.wasm; do
  [ -f "$TMP_DIR/unpacked/$f" ] || {
    echo "$APP: $SDK_WEB_ZIP has no $f -- the release layout may have changed" >&2
    exit 1
  }
done

mkdir -p "$ROOT_DIR/$DEST_DIR"
cp "$TMP_DIR/unpacked/runtime-web/ssruntime.js"          "$ROOT_DIR/$DEST_DIR/ssruntime.js"
cp "$TMP_DIR/unpacked/runtime-web/ssruntime_bg.wasm"     "$ROOT_DIR/$DEST_DIR/ssruntime_bg.wasm"
cp "$TMP_DIR/unpacked/runtime-web-nosimd/ssruntime_bg.wasm" "$ROOT_DIR/$DEST_DIR/ssruntime_bg.nosimd.wasm"
echo "   -> $DEST_DIR/ (ssruntime.js + ssruntime_bg.wasm + ssruntime_bg.nosimd.wasm)"
