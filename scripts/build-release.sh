#!/usr/bin/env bash
#
# Build the release: for every package under packages/, the exact file set
# `dart pub publish` would upload -- packed where you can look inside it -- and
# every check that has to pass before the release tags go out.
#
#   scripts/build-release.sh                            # the whole thing
#   scripts/build-release.sh checks=analyze             # ... without the tests
#   scripts/build-release.sh checks=skip sdk=skip       # archives only, offline
#   scripts/build-release.sh sdk=build                  # compile the web Brain here
#   scripts/build-release.sh packages=ssruntime_dart    # one package
#   scripts/build-release.sh out=/tmp/rel               # somewhere else
#
# A release here attaches nothing, which is the whole reason this script looks
# different from the sibling players' build-release. There, one archive is built
# and attached to a Release. Here, release.yml sets the versions it is given,
# runs this script, and only then commits them and pushes `<package>-v<version>`
# tags; each tag triggers publish.yml, which runs `dart pub publish` in that
# package's directory and uploads it to pub.dev, and the package's GitHub Release
# carries its notes and nothing else. So what there is to "build" is the file set
# each of those publishes would send, and the confidence that all of them will
# succeed.
#
# The confidence is the valuable half, because a version on pub.dev is permanent:
# once its tag is pushed, a publish that fails can only be followed by another
# version. Everything below runs before that point, which is why release.yml
# runs this script before it commits or tags anything: CI and a local run cannot
# drift.
#
# What this does NOT do is set a version or push a tag. Those are decisions:
# scripts/set-versions.dart makes the first, release.yml the second.
#
# ---------------------------------------------------------------------------
#
# A package still carrying `publish_to: none` is not published: publish.yml skips
# its tag and `dart pub publish` refuses it outright. That one line is the on/off
# switch for pub.dev. While it is still there
# on every package, skipping them would leave this script with nothing to do, so
# a private package is PREVIEWED instead -- the line is lifted for the length of
# the dry run (and put straight back), everything that would block its publish is
# reported, and none of it fails the run. Remove the line and the same package is
# checked for real, with warnings fatal exactly as `dart pub publish` has them.
#
# Four checks are here because they have already been the difference between a
# working package and a published one that does nothing:
#
#   The pinned SDK release exists. packages/*/hook/build.dart download
#   libssruntime / libssconverter from a SpriteStudio-SDK release tag for every
#   consumer who has no Rust toolchain -- which is all of them. If that release
#   is not published, every `flutter pub get` downstream 404s. It is also the
#   check that fails while the SDK has not been tagged yet, and that is the
#   correct failure: there is nothing to publish against.
#
#   The two hooks agree on which release. A runtime from one SDK build and a
#   converter from another is the kind of mismatch that surfaces as a wrong
#   pixel weeks later.
#
#   ssplayer_flutter's archive carries the web Brain. assets/runtime-web/ holds
#   git-ignored build output, and a git-ignored file is not published -- so
#   without the .pubignore that re-includes it, every web consumer downloads a
#   package whose wasm loader points at three assets that are not there. Nothing
#   fails at build time; the animation simply never starts. Getting the files
#   there is this script's business too, because pub packs what is on disk:
#   sdk=download runs the same scripts/download-web-runtime.sh that publish.yml's
#   ssplayer_flutter job runs, so this archive is what that job would upload.
#
#   The generated code is current. The ffigen bindings and the flatc accessors
#   are committed (so a pub.dev consumer needs neither libclang nor flatc), which
#   means a stale one ships and reads the Brain's structs at the wrong offsets.
set -euo pipefail

APP="$(basename "$0")"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# The SDK release the native-asset hooks pin, and the assets a consumer's build
# actually fetches from it. Read from the hooks rather than repeated here -- see
# scripts/build-pages.sh, which reads the same constant for the web wasm.
SDK_RELEASE_BASE="https://github.com/cri-middleware/SpriteStudio-SDK/releases/download"
SDK_LIBS_ZIP="spritestudio-sdk-dynamic-libs.zip"
SDK_PIN_SOURCES="packages/ssruntime_dart/hook/build.dart packages/ssconverter_dart/hook/build.dart"

# Committed generator output: regenerating it must produce no diff.
FFIGEN_PATHS="packages/ssruntime_dart/lib/src/ssruntime_bindings.g.dart packages/ssconverter_dart/lib/src/ssconverter_bindings.g.dart"
FBS_PATHS="packages/ssplayer_flutter/lib/src/ssab packages/ssruntime_dart/lib/src/fbs packages/ssplayer_flutter/test/support"

# The web Brain, as ssruntime_dart's web_runtime.dart asks for it by name.
WEB_RUNTIME_DIR="assets/runtime-web"
WEB_RUNTIME_FILES="ssruntime.js ssruntime_bg.wasm ssruntime_bg.nosimd.wasm"

# pub.dev's hard limit on an uploaded archive.
MAX_ARCHIVE_BYTES=104857600

# --- options --------------------------------------------------------------

OUT="release-dist"
PACKAGES="all"
CHECKS="full"
CODEGEN="check"
SDK="download"
VERIFY="yes"
CLEAN="yes"

usage () {
  echo "Usage: $APP [options]"
  echo "$APP options:"
  echo "  out=<dir>               Where the archives, their manifests and SHA256SUMS"
  echo "                          land (default: $OUT). Relative paths resolve against"
  echo "                          the current directory."
  echo "  packages=<all|a,b,...>  Which packages to build (default: $PACKAGES). Names are"
  echo "                          directory names under packages/. Versions here are"
  echo "                          INDEPENDENT, so a release is usually a subset."
  echo "  checks=<full|analyze|skip>"
  echo "                          How much to run per package before packing it"
  echo "                          (default: $CHECKS). full = analyze + tests; analyze ="
  echo "                          the analyzer only; skip = neither. The tests need the"
  echo "                          Brain, which the build hooks download from the pinned"
  echo "                          SDK release -- so checks=full is also the only thing"
  echo "                          here that proves that download works end to end."
  echo "  codegen=<check|skip>    Re-run the generators and require no diff (default:"
  echo "                          $CODEGEN). Each half is skipped, loudly, when its"
  echo "                          input is missing: ffigen needs the C headers"
  echo "                          build-runtime.sh copies into packages/*/native/include,"
  echo "                          flatc needs to be on PATH."
  echo "  sdk=<download|build|skip>"
  echo "                          Where the web Brain comes from, and whether the pinned"
  echo "                          SDK release is checked at all (default: $SDK)."
  echo "                          download = download-web-runtime.sh, the release"
  echo "                                     packages/*/hook/build.dart pin -- what CI"
  echo "                                     uses, and what publish.yml runs before it"
  echo "                                     publishes ssplayer_flutter. Also checks that"
  echo "                                     release carries the host library archive the"
  echo "                                     hooks fetch for every consumer. Needs network."
  echo "                          build    = build-runtime.sh platform=web, compiled from"
  echo "                                     the submodule (needs cargo + wasm-pack). The"
  echo "                                     way out while that release does not exist"
  echo "                                     yet, so it does not check for it."
  echo "                          skip     = use assets/runtime-web as it stands, and"
  echo "                                     check nothing. For an offline tree, never"
  echo "                                     for a release."
  echo "  verify=<yes|no>         Re-open the finished archives and check them"
  echo "                          (default: $VERIFY)."
  echo "  clean=<yes|no>          Delete <out> before building (default: $CLEAN)."
    echo "  in= skip=               Accepted and ignored here. The family's build-release"
  echo "                          scripts share out= clean= verify= in= sdk= skip=,"
  echo "                          so one command line drives all of them."
echo "  -h | --help             Show this help"
  echo ""
  echo "Output: <out>/ holds, per package, <name>-<version>.tar.gz (the file set pub"
  echo "would upload, packed here so it can be looked at -- pub builds its own archive"
  echo "at publish time, so this one is for inspection and is uploaded nowhere),"
  echo "<name>-<version>.files (one path per line) and <name>-<version>.publish.txt (the"
  echo "dry run verbatim), plus SHA256SUMS over the archives."
  echo ""
  echo "There is no option for which release this is: a tag is a decision already made,"
  echo "and this reads it. GITHUB_REF_NAME, or the '<package>-v<version>' tag HEAD is"
  echo "checked out at, must agree with that package's pubspec version."
}

while [ $# -gt 0 ]; do
  item="$1"
  shift

  case "$item" in
    -h|--help|help)
      usage
      exit 0
      ;;
    *=*)
      key="${item%%=*}"
      value="${item#*=}"
      case "$key" in
        out)      OUT="$value" ;;
        # Lower-cased where the option is a keyword; out= is a path and
        # packages= is a list of directory names.
        packages) PACKAGES="$value" ;;
        checks)   CHECKS="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        codegen)  CODEGEN="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        sdk)      SDK="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        verify)   VERIFY="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        clean)    CLEAN="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        # Accepted so one command line drives build-release in every repository
        # of the family; this one has no use for them.
        in|skip) echo "$APP: ${key}= does not apply here; ignored" >&2 ;;
        *)
          echo "$APP: unknown option '$key' (see $APP --help)" >&2
          exit 2
          ;;
      esac
      ;;
    *)
      echo "$APP: unknown argument '$item' (options are key=value; see $APP --help)" >&2
      exit 2
      ;;
  esac
done

case "$CHECKS"  in full|analyze|skip) ;; *) echo "$APP: checks must be full, analyze or skip (got '$CHECKS')" >&2; exit 2 ;; esac
case "$CODEGEN" in check|skip) ;;       *) echo "$APP: codegen must be check or skip (got '$CODEGEN')" >&2; exit 2 ;; esac
case "$SDK"     in download|build|skip) ;; *) echo "$APP: sdk must be download, build or skip (got '$SDK')" >&2; exit 2 ;; esac
case "$VERIFY"  in yes|no) ;;           *) echo "$APP: verify must be yes or no (got '$VERIFY')" >&2; exit 2 ;; esac
case "$CLEAN"   in yes|no) ;;           *) echo "$APP: clean must be yes or no (got '$CLEAN')" >&2; exit 2 ;; esac

# Resolve against the invoking directory, before anything cds away from it.
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

# clean=yes deletes this path, so refuse the ones that would take the repository
# (or the filesystem) with them.
if [ "$OUT" = "/" ] || [ "$OUT" = "$ROOT_DIR" ] || [ "$OUT" = "$ROOT_DIR/packages" ]; then
  echo "$APP: refusing to use '$OUT' as out= (it is deleted when clean=yes)" >&2
  exit 2
fi

cd "$ROOT_DIR"

# --- preflight ------------------------------------------------------------

[ -d "$ROOT_DIR/packages" ] || {
  echo "$APP: no packages/ here -- is this the SSPlayerForFlutter repo?" >&2
  exit 1
}

command -v dart > /dev/null 2>&1 || {
  echo "$APP: dart not found -- it is what validates and lists every package" >&2
  exit 1
}
command -v tar > /dev/null 2>&1 || {
  echo "$APP: tar not found -- it is what packs the archives" >&2
  exit 1
}

# The runners have sha256sum (coreutils); macOS ships shasum instead. Both write
# the same `<hash>  <name>` lines and both take -c, so SHA256SUMS is identical
# either way -- and matches what the build hooks check the SDK archive with.
if command -v sha256sum > /dev/null 2>&1; then
  sha256 () { sha256sum "$@"; }
elif command -v shasum > /dev/null 2>&1; then
  sha256 () { shasum -a 256 "$@"; }
else
  echo "$APP: neither sha256sum nor shasum found -- one of them writes SHA256SUMS" >&2
  exit 1
fi

step () {
  echo ""
  echo ">> $*"
}

# Everything at once: finding out about the second blocker on the second run is
# not a debugging loop worth having, and one of these runs the test suites.
FAILED=""
fail () {
  FAILED="${FAILED}
  $1"
}

# What a previewed package would hit. Reported in full, never fatal: a package
# carrying `publish_to: none` is not in the release, so nothing about it can
# block one.
PREVIEW_BLOCKED=""
preview_block () {
  PREVIEW_BLOCKED="${PREVIEW_BLOCKED}
  $1"
}

# `key: value` out of a pubspec, comment and quotes stripped. Only ever used on
# the top-level scalars (name / version / publish_to), which are unindented.
pubspec_field () { # <pubspec> <key>
  sed -n "s/^$2:[[:space:]]*\(.*\)$/\1/p" "$1" \
    | head -1 \
    | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//'
}

# --- the packages ---------------------------------------------------------

ALL_PACKAGES=""
for dir in "$ROOT_DIR"/packages/*/; do
  [ -f "$dir/pubspec.yaml" ] || continue
  ALL_PACKAGES="$ALL_PACKAGES $(basename "$dir")"
done
ALL_PACKAGES="${ALL_PACKAGES# }"

if [ "$PACKAGES" = "all" ]; then
  SELECTED="$ALL_PACKAGES"
else
  SELECTED=""
  for name in $(printf '%s' "$PACKAGES" | tr ',' ' '); do
    if [ ! -f "$ROOT_DIR/packages/$name/pubspec.yaml" ]; then
      echo "$APP: no such package '$name' (have: $ALL_PACKAGES)" >&2
      exit 2
    fi
    SELECTED="$SELECTED $name"
  done
  SELECTED="${SELECTED# }"
fi

# --- what this release is called ------------------------------------------
#
# Tags here are per package -- `<package>-v<version>` -- because the versions are
# independent. So the ref only ever names ONE of the packages being built, and
# the check is against that one's pubspec; the rest are along for the ride.
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
  TAG="$GITHUB_REF_NAME"
  TAG_SOURCE="GITHUB_REF_NAME -- the ref this run was dispatched from"
elif TAG="$(git -C "$ROOT_DIR" describe --exact-match --match '*-v[0-9]*' --tags HEAD 2>/dev/null)"; then
  TAG_SOURCE="the release tag HEAD is checked out at"
else
  TAG=""
  TAG_SOURCE="HEAD is not on a release tag, so this is a build, not a release"
fi

echo "options"
echo "  out      => $OUT"
echo "  packages => $SELECTED"
echo "  checks   => $CHECKS"
echo "  codegen  => $CODEGEN"
echo "  sdk      => $SDK"
echo "  verify   => $VERIFY"
echo "  clean    => $CLEAN"
echo "  tag      => ${TAG:-(none)}"
echo "              ($TAG_SOURCE)"

if [ -n "$TAG" ]; then
  TAG_PKG="${TAG%-v*}"
  TAG_VERSION="${TAG##*-v}"
  if [ -f "$ROOT_DIR/packages/$TAG_PKG/pubspec.yaml" ]; then
    HAVE="$(pubspec_field "$ROOT_DIR/packages/$TAG_PKG/pubspec.yaml" version)"
    if [ "$HAVE" != "$TAG_VERSION" ]; then
      echo "" >&2
      echo "$APP: tag $TAG does not match packages/$TAG_PKG (version $HAVE)." >&2
      echo "$APP: pub publishes the pubspec's version whatever the tag says, so the tag" >&2
      echo "$APP: would name one release and pub.dev carry another. Bump, or retag." >&2
      exit 1
    fi
    echo "              (matches packages/$TAG_PKG $HAVE)"
  else
    echo "              (names no package under packages/ -- not checked)"
  fi
fi

# --- the working tree -----------------------------------------------------
#
# A dirty tree is the one way a published package can contain something that is
# in no commit, which is unreproducible in exactly the way a release must not be.
# pub says the same thing as a warning; this says it first, and before anything
# below edits a pubspec, so that a preview can tell pub's complaint about the
# tree apart from its own.
step "checking the working tree"
TREE_DIRTY="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)"
if [ -n "$TREE_DIRTY" ]; then
  fail "the working tree is dirty -- commit or stash before releasing:
$(printf '%s\n' "$TREE_DIRTY" | sed 's|^|      |')"
  echo "   dirty ($(printf '%s\n' "$TREE_DIRTY" | wc -l | tr -d ' ') path(s))"
else
  echo "   clean"
fi
BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
[ "$BRANCH" = "main" ] || echo "   note: on '$BRANCH', not main"

# --- the pinned SDK release -----------------------------------------------
sdk_pin () { # <hook file>
  sed -n "s/^const _sdkVersion = '\(.*\)';.*$/\1/p" "$1" | head -1
}

step "the SpriteStudio-SDK release the build hooks pin"
SDK_VERSION=""
for src in $SDK_PIN_SOURCES; do
  [ -f "$ROOT_DIR/$src" ] || { fail "$src is missing -- nothing pins an SDK release there"; continue; }
  pin="$(sdk_pin "$ROOT_DIR/$src")"
  if [ -z "$pin" ]; then
    fail "no _sdkVersion found in $src"
    continue
  fi
  echo "   $src => $pin"
  if [ -z "$SDK_VERSION" ]; then
    SDK_VERSION="$pin"
  elif [ "$pin" != "$SDK_VERSION" ]; then
    # One Brain, built once. Two hooks pinned to different releases ships a
    # runtime and a converter from different SDK builds.
    fail "the build hooks pin different SDK releases ($SDK_VERSION vs $pin) -- they must agree"
  fi
done

# Only ssplayer_flutter carries the web Brain, so only a build that includes it
# needs one fetched.
NEED_WEB=no
case " $SELECTED " in *" ssplayer_flutter "*) NEED_WEB=yes ;; esac

case "$SDK" in
  download)
    if [ -n "$SDK_VERSION" ]; then
      if ! command -v curl > /dev/null 2>&1; then
        echo "   curl not on PATH -- cannot check the release exists"
      else
        for asset in SHA256SUMS "$SDK_LIBS_ZIP"; do
          if curl -fsSLI -o /dev/null "$SDK_RELEASE_BASE/$SDK_VERSION/$asset" 2> /dev/null; then
            echo "   $asset  ok"
          else
            echo "   $asset  MISSING"
            # Every consumer without a Rust toolchain -- which is every consumer
            # -- gets libssruntime from this release at `flutter pub get` time.
            fail "SpriteStudio-SDK $SDK_VERSION does not carry $asset (or the release does not exist).
      Nothing downstream can build: packages/*/hook/build.dart download it for
      every consumer who has no Rust toolchain. Publish the SDK release first,
      or repin _sdkVersion."
          fi
        done
      fi
    fi
    # The web Brain into the directory pub packs from -- the same script
    # publish.yml's ssplayer_flutter job runs, so this archive is that upload.
    if [ "$NEED_WEB" = "yes" ]; then
      ./scripts/download-web-runtime.sh || fail "scripts/download-web-runtime.sh failed -- there is no web Brain to pack"
    fi
    ;;
  build)
    # No release check: sdk=build exists precisely for when there is no release.
    if [ "$NEED_WEB" = "yes" ]; then
      echo "   building the web Brain from the submodule (needs cargo + wasm-pack)"
      ./scripts/build-runtime.sh platform=web build=release || fail "scripts/build-runtime.sh platform=web failed -- there is no web Brain to pack"
    else
      echo "   sdk=build -- nothing selected needs a web Brain"
    fi
    ;;
  skip)
    echo "   sdk=skip -- the release is not checked, assets/runtime-web left as it stands"
    ;;
esac

# --- the generated code ---------------------------------------------------
#
# ffigen bindings and flatc accessors are COMMITTED, so what matters is that the
# tree matches what today's inputs produce. A stale binding reads the Brain's
# structs at the wrong offsets and does it silently.
step "the committed generator output"
if [ "$CODEGEN" = "skip" ]; then
  echo "   codegen=skip -- not regenerated"
else
  HEADERS="$(find "$ROOT_DIR"/packages/*/native/include -name '*.h' 2>/dev/null | head -1 || true)"
  if [ -z "$HEADERS" ]; then
    echo "   ffigen SKIPPED -- no packages/*/native/include/*.h (run scripts/build-runtime.sh)"
  else
    ./scripts/generate-ffigen-code.sh > /dev/null || fail "scripts/generate-ffigen-code.sh failed"
    if git -C "$ROOT_DIR" diff --quiet -- $FFIGEN_PATHS; then
      echo "   ffigen bindings current"
    else
      fail "the ffigen bindings are stale -- regenerate and commit:
      scripts/generate-ffigen-code.sh"
    fi
  fi

  if ! command -v flatc > /dev/null 2>&1; then
    echo "   flatc SKIPPED -- flatc not on PATH (brew install flatbuffers)"
  else
    ./scripts/generate-fbs-code.sh > /dev/null || fail "scripts/generate-fbs-code.sh failed"
    if git -C "$ROOT_DIR" diff --quiet -- $FBS_PATHS; then
      echo "   flatc accessors current"
    else
      fail "the flatc accessors are stale -- regenerate and commit:
      scripts/generate-fbs-code.sh"
    fi
  fi
fi

# --- resolve --------------------------------------------------------------
# One workspace, one lockfile: resolving here is what lets the analyzer and the
# test suites run below, and `dart pub publish` re-resolves each package anyway.
step "resolving the workspace"
if command -v flutter > /dev/null 2>&1; then
  flutter pub get > /dev/null
  echo "   flutter pub get"
else
  # Every Flutter member would fail to resolve, but a pure-Dart-only selection
  # still works -- worth trying rather than refusing outright.
  echo "   flutter not on PATH -- falling back to dart pub get"
  dart pub get > /dev/null
fi

# --- output ---------------------------------------------------------------
if [ "$CLEAN" = "yes" ]; then
  rm -rf "$OUT"
fi
mkdir -p "$OUT"

# Turn the tree `dart pub publish --dry-run` prints into one relative path per
# line. Depth comes from stripping the two indent units it draws with rather than
# from counting characters -- they are box-drawing characters, and counting them
# would need a UTF-8-aware shell. A leaf carries a `(<size>)` suffix and a
# directory does not, which is what tells the two apart.
manifest_from_report () { # <report file>
  local capturing=0 line rest depth name isfile i out
  local seg
  seg=()
  while IFS= read -r line; do
    if [ "$capturing" -eq 0 ]; then
      case "$line" in "Publishing "*) capturing=1 ;; esac
      continue
    fi
    case "$line" in
      "Total compressed archive size:"*) break ;;
      "") continue ;;
    esac
    rest="$line"
    depth=0
    while : ; do
      case "$rest" in
        '│   '*) rest="${rest#'│   '}"; depth=$((depth + 1)) ;;
        '    '*) rest="${rest#'    '}"; depth=$((depth + 1)) ;;
        *) break ;;
      esac
    done
    case "$rest" in
      '├── '*) name="${rest#'├── '}" ;;
      '└── '*) name="${rest#'└── '}" ;;
      *) continue ;;
    esac
    isfile=0
    case "$name" in
      *' ('*'B)') isfile=1; name="${name% (*}" ;;
    esac
    seg[$depth]="$name"
    if [ "$isfile" -eq 1 ]; then
      out="$name"
      i=$((depth - 1))
      while [ "$i" -ge 0 ]; do
        out="${seg[$i]}/$out"
        i=$((i - 1))
      done
      printf '%s\n' "$out"
    fi
  done < "$1"
}

# A previewed package has its `publish_to: none` lifted for the length of its dry
# run, and put straight back -- however this exits. A release script that can
# leave a package publishable is worse than no script.
#
# The backup lives OUTSIDE the package, and that is not tidiness: pub publishes
# every file git does not ignore, tracked or not, so a `pubspec.yaml.bak` beside
# the original would be listed in the manifest and packed into the archive.
BAK_DIR="$(mktemp -d)"
PENDING_PUBSPEC=""
restore_pubspec () {
  [ -n "$PENDING_PUBSPEC" ] || return 0
  [ -f "$BAK_DIR/pubspec.yaml" ] || return 0
  mv -f "$BAK_DIR/pubspec.yaml" "$PENDING_PUBSPEC"
  PENDING_PUBSPEC=""
}
cleanup () {
  restore_pubspec
  rm -rf "$BAK_DIR"
}
trap cleanup EXIT INT TERM

SUMMARY=""
ARCHIVES=""

for name in $SELECTED; do
  PKG_DIR="$ROOT_DIR/packages/$name"
  PUBSPEC="$PKG_DIR/pubspec.yaml"
  VERSION="$(pubspec_field "$PUBSPEC" version)"
  PUBLISH_TO="$(pubspec_field "$PUBSPEC" publish_to)"
  STATE="release"
  [ -z "$PUBLISH_TO" ] || STATE="preview"

  step "$name $VERSION  ($STATE)"

  if [ -z "$VERSION" ]; then
    fail "packages/$name has no version in its pubspec"
    continue
  fi

  # `flutter test` for a package that depends on the Flutter SDK, `dart test`
  # otherwise -- the same split CONTRIBUTING.md's Test section draws.
  RUNNER="dart"
  if grep -q 'sdk: flutter' "$PUBSPEC"; then RUNNER="flutter"; fi
  if [ "$RUNNER" = "flutter" ] && ! command -v flutter > /dev/null 2>&1; then
    echo "   flutter not on PATH -- $name cannot be analyzed or tested here"
    RUNNER=""
  fi

  if [ "$CHECKS" != "skip" ] && [ -n "$RUNNER" ]; then
    echo "   $RUNNER analyze"
    ( cd "$PKG_DIR" && $RUNNER analyze ) || fail "$name: analyze failed"
  fi
  if [ "$CHECKS" = "full" ] && [ -n "$RUNNER" ] && [ -d "$PKG_DIR/test" ]; then
    echo "   $RUNNER test"
    ( cd "$PKG_DIR" && $RUNNER test ) || fail "$name: tests failed"
  fi

  # --- the publish itself, minus the upload -------------------------------
  REPORT="$OUT/$name-$VERSION.publish.txt"
  PUB_ARGS=""
  if [ "$STATE" = "preview" ]; then
    # Lift `publish_to: none`, and with it accept that pub will also report the
    # tree as modified -- this script made that edit, and checked the tree was
    # clean before making it. --ignore-warnings keeps that one self-inflicted
    # warning from masking the errors underneath; every warning is still printed
    # below, because for a package that is not opted in yet they are the point.
    cp "$PUBSPEC" "$BAK_DIR/pubspec.yaml"
    PENDING_PUBSPEC="$PUBSPEC"
    sed '/^publish_to:/d' "$BAK_DIR/pubspec.yaml" > "$PUBSPEC"
    PUB_ARGS="--ignore-warnings"
  fi

  echo "   dart pub publish --dry-run"
  PUB_OK=yes
  ( cd "$PKG_DIR" && dart pub publish --dry-run $PUB_ARGS ) > "$REPORT" 2>&1 || PUB_OK=no

  restore_pubspec

  # Everything pub found, verbatim, so the reader never has to open the report to
  # learn there was something in it.
  VALIDATION="$(sed -n '/^Package validation found/,$p' "$REPORT" || true)"
  if [ -n "$VALIDATION" ]; then
    printf '%s\n' "$VALIDATION" | sed 's|^|      |'
  fi

  if [ "$PUB_OK" = "no" ]; then
    if [ "$STATE" = "preview" ]; then
      preview_block "$name: would not publish -- see $(basename "$REPORT")"
    else
      fail "$name: dart pub publish would fail -- see ${REPORT#"$ROOT_DIR"/}"
    fi
  fi

  # --- the file set -------------------------------------------------------
  LIST="$OUT/$name-$VERSION.files"
  manifest_from_report "$REPORT" | LC_ALL=C sort > "$LIST"
  COUNT="$(wc -l < "$LIST" | tr -d ' ')"
  if [ "$COUNT" -eq 0 ]; then
    # No manifest means pub bailed before listing anything -- the errors are in
    # the report, and there is nothing to pack.
    fail "$name: pub listed no files (it stopped before packing -- see ${REPORT#"$ROOT_DIR"/})"
    SUMMARY="${SUMMARY}
  $(printf '%-18s %-14s %-8s %s' "$name" "$VERSION" "$STATE" "no archive")"
    continue
  fi

  ARCHIVE="$name-$VERSION.tar.gz"
  # pub's archive is flat -- pubspec.yaml at the root, no wrapping directory --
  # so this one is too. COPYFILE_DISABLE keeps macOS from adding an AppleDouble
  # entry per file, which would be in pub's archive for no one.
  COPYFILE_DISABLE=1 tar -czf "$OUT/$ARCHIVE" -C "$PKG_DIR" -T "$LIST"
  ARCHIVES="$ARCHIVES $ARCHIVE"
  echo "   $COUNT file(s) -> $ARCHIVE"

  SUMMARY="${SUMMARY}
  $(printf '%-18s %-14s %-8s %s' "$name" "$VERSION" "$STATE" "$ARCHIVE")"
done

trap - EXIT INT TERM
cleanup

# --- checksums ------------------------------------------------------------
if [ -n "$ARCHIVES" ]; then
  step "writing SHA256SUMS"
  ( cd "$OUT" && sha256 ./*.tar.gz | sed 's|\./||' > SHA256SUMS )
  echo "   $(wc -l < "$OUT/SHA256SUMS" | tr -d ' ') archive(s)"
fi

# --- verify ---------------------------------------------------------------
#
# The manifest above is what pub said it would send; this is what actually
# landed, and the two are not the same question -- a file pub lists but that has
# since been deleted packs as nothing at all.
if [ "$VERIFY" = "yes" ] && [ -n "$ARCHIVES" ]; then
  step "verifying $OUT"

  for archive in $ARCHIVES; do
    name="${archive%%-*}"
    for n in $SELECTED; do case "$archive" in "$n"-*) name="$n" ;; esac; done
    ENTRIES="$(tar -tzf "$OUT/$archive")"
    has ()     { printf '%s\n' "$ENTRIES" | grep -qx "$1"; }
    has_any () { printf '%s\n' "$ENTRIES" | grep -q "^$1"; }

    # What a consumer needs to have downloaded anything useful at all.
    has "pubspec.yaml" || fail "$archive has no pubspec.yaml"
    has_any "lib/"     || fail "$archive contains nothing under lib/"
    has "README.md"    || fail "$archive has no README.md"
    printf '%s\n' "$ENTRIES" | grep -q '^LICENSE' || fail "$archive carries no LICENSE"

    # A hook that is not in the archive is a package that delivers no native
    # library, and nothing about the build says so.
    if [ -f "$ROOT_DIR/packages/$name/hook/build.dart" ]; then
      has "hook/build.dart" || fail "$archive has no hook/build.dart -- it would deliver no native asset"
    fi

    # packages/*/native is git-ignored build output. If one leaks into an
    # archive, every consumer gets one host's dylib instead of their own.
    if has_any "native/"; then
      fail "$archive contains native/ -- that is local build output, not something to publish"
    fi

    # The web Brain: three files ssruntime_dart's web_runtime.dart loads by name.
    # There are two ways they go missing from what a consumer downloads, both
    # silent -- the app builds, the animation simply never starts -- so they are
    # reported apart.
    if [ -d "$ROOT_DIR/packages/$name/$WEB_RUNTIME_DIR" ]; then
      for f in $WEB_RUNTIME_FILES; do
        rel="$WEB_RUNTIME_DIR/$f"
        if ! has "$rel"; then
          fail "$archive has no $rel -- the web target would load nothing.
      pub publishes nothing git ignores, and that whole directory is git-ignored
      build output; the .pubignore beside it is what re-includes it. Build the
      runtime too (scripts/build-runtime.sh platform=web) -- pub packs what is
      on disk."
        elif [ -z "$(git -C "$ROOT_DIR" ls-files -- "packages/$name/$rel")" ] \
             && ! grep -q 'download-web-runtime' "$ROOT_DIR/.github/workflows/publish.yml"; then
          # git does not track these, so the ONLY reason the published package
          # gets them is that publish.yml fetches them first -- that job exists
          # instead of dart-lang's reusable workflow, which has no step between
          # its checkout and its `dart pub publish`. If that step ever goes, this
          # archive still looks complete and what reaches pub.dev is an empty
          # assets/runtime-web/, silently.
          fail "$rel is in $archive only because this working tree built it, and nothing in
      .github/workflows/publish.yml fetches it any more. The package that reaches
      pub.dev would carry an empty $WEB_RUNTIME_DIR/. Restore the
      download-web-runtime step in the ssplayer_flutter job, or track these files."
        fi
      done
    fi

    # pub.dev refuses anything larger, and a package that grew past it grew by
    # accident.
    BYTES="$(wc -c < "$OUT/$archive" | tr -d ' ')"
    if [ "$BYTES" -gt "$MAX_ARCHIVE_BYTES" ]; then
      fail "$archive is $((BYTES / 1048576)) MB -- pub.dev refuses anything over 100 MB"
    fi
  done

  ( cd "$OUT" && sha256 -c SHA256SUMS > /dev/null ) || fail "SHA256SUMS does not verify"
  [ -n "$FAILED" ] || echo "   every archive complete, SHA256SUMS verified"
elif [ "$VERIFY" = "no" ]; then
  step "verify=no -- the archives are not checked"
fi

# --- done -----------------------------------------------------------------
echo ""
echo "$APP: what this build would publish"
printf '%s\n' "$SUMMARY"
echo ""

if [ -n "$PREVIEW_BLOCKED" ]; then
  echo "$APP: previewed packages that would NOT publish as they stand:$PREVIEW_BLOCKED"
  echo ""
  echo "$APP: none of that fails this run -- a package carrying 'publish_to: none' is"
  echo "$APP: not in the release. Remove that line to opt one in, and it is checked"
  echo "$APP: for real from the next run on."
  echo ""
fi

if [ -n "$FAILED" ]; then
  echo "$APP: this release is not shippable:$FAILED" >&2
  exit 1
fi

echo "$APP: done -> $OUT  (${TAG:-no tag})"
echo ""
( cd "$OUT" && ls -l ./*.tar.gz SHA256SUMS 2> /dev/null | sed 's|^|  |' ) || true
echo ""
echo "$APP: the archives are for inspection -- pub builds its own at publish time."
echo "$APP: what ships is the tags: release.yml versions the packages and pushes"
echo "$APP: '<package>-v<version>', and publish.yml publishes each one to pub.dev."
