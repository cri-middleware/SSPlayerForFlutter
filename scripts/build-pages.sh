#!/usr/bin/env bash
#
# Build the GitHub Pages site locally -- everything .github/workflows/pages.yml
# publishes, in the same order: the documentation in both locales into site/,
# then the two playable Web demos into site/demo/.
#
#   scripts/build-pages.sh                     # the tree pages.yml uploads
#   scripts/build-pages.sh serve=yes           # ... and serve it, base and all
#   scripts/build-pages.sh sdk=build           # ... compiling the Brain from source
#   scripts/build-pages.sh demo=skip           # documentation only
#   scripts/build-pages.sh docs=no sdk=skip    # re-export the demo, nothing else
#
# Two demos, because the repository ships two players: examples/overall drives
# the ssplayer_flutter widget and examples/flame the ssplayer_flame component, so
# they land at site/demo/flutter/ and site/demo/flame/ with a chooser page at
# site/demo/ -- the address both locale index pages link to.
#
# The demos are built here, not downloaded: unlike the sibling players, this
# repository's release.yml versions packages and publishes them to pub.dev -- it
# creates no GitHub Release and attaches no assets, so there is nothing for a
# demo=download option to fetch. pages.yml therefore runs the same export this
# script does, which is the whole reason the export lives here rather than in
# the workflow. (sdk=download is a different thing: the Brain's binaries, which
# the SDK's own release does publish.)
#
# Ordering: the English documentation build clears site/, and both the Japanese
# site (site/ja) and the demos (site/demo) live inside it -- so the demos go in
# last, exactly as in pages.yml. Rerunning is safe; nothing here is incremental.
#
# Three things the demo needs that a docs build does not, all of them generated
# per clone rather than committed:
#
#   1. The .ssab assets (deploy-examples.sh converts the SDK's test projects).
#   2. The Brain as a wasm pair in assets/runtime-web. sdk=download takes it from
#      the SpriteStudio-SDK release the native-asset hooks are pinned to, which
#      needs no Rust at all; sdk=build compiles it here with wasm-pack, in RELEASE
#      -- a debug wasm is 1.4 MB against ~270 KB and has no business in a
#      published site.
#   3. The example's web/ runner, which this repository deliberately git-ignores
#      along with the other platform runners: `flutter create --platforms=web .`
#      materialises it. That command also rewrites the example's .metadata, so
#      this script puts the file back afterwards.
#
# The host libraries deploy-examples.sh converts over dart:ffi follow the same
# split, but nothing here has to fetch them: each binding package's
# hook/build.dart prefers a locally built native/ and otherwise downloads the
# same release, verifying it against the release's SHA256SUMS. sdk=download
# therefore does nothing for the host side -- it just does not build it.
#
# base= is baked into the demo at build time (--base-href), which is why it is an
# option here and was not one in the Zensical-only siblings: the documentation
# uses relative links and does not care, the Flutter app does. It defaults to the
# project-site path (/<repo>/), so serve=yes hangs the tree off a scratch root at
# that path rather than serving site/ directly -- otherwise every asset URL in
# the demo 404s.
#
# What this does NOT reproduce is the deploy job (actions/deploy-pages) -- there
# is no local equivalent of publishing.
set -euo pipefail

APP="$(basename "$0")"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# The examples that become the demos, as <example dir>:<url slug under demo/>.
# The slugs are what a reader sees, so they name the package each example
# exercises rather than the directory it lives in.
DEMO_APPS="examples/overall:flutter examples/flame:flame"

# Where the web runtime lands, and where sdk=download takes it from. The zip is
# what SpriteStudio-SDK's release.yml attaches: runtime-web/, runtime-web-nosimd/
# and converter-web/ in one archive.
RUNTIME_WEB_DIR="packages/ssplayer_flutter/assets/runtime-web"
SDK_RELEASE_BASE="https://github.com/cri-middleware/SpriteStudio-SDK/releases/download"
SDK_WEB_ZIP="spritestudio-sdk-web-libs.zip"
# The SDK release everything here is pinned to. Read rather than repeated: the
# native-asset hooks download the host libraries from this same tag, and a demo
# whose wasm and dylib came from different releases is the kind of mismatch
# nobody notices until a draw call misbehaves.
SDK_VERSION_SOURCE="packages/ssruntime_dart/hook/build.dart"

# --- options --------------------------------------------------------------

# A project site is served under /<repo>/. The workflow passes
# github.event.repository.name; here the origin remote names the repository,
# falling back to the clone's directory name.
default_base () {
  local url name
  url="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true)"
  name="${url##*/}"
  name="${name%.git}"
  [ -n "$name" ] || name="$(basename "$ROOT_DIR")"
  printf '/%s/' "$name"
}

DOCS="yes"
DEMO="build"
SDK="download"
BASE="$(default_base)"
PREPARE="auto"
VENV=".venv"
SERVE="no"
PORT="8000"

usage () {
  echo "Usage: $APP [options]"
  echo "$APP options:"
  echo "  docs=<yes|no>           Build the documentation, both locales (default: $DOCS)."
  echo "                          no keeps whatever site/ already holds -- handy when"
  echo "                          only the demo is being re-checked."
  echo "  demo=<build|skip>       Build both Web demos into site/demo (default: $DEMO):"
  echo "                          examples/overall -> demo/flutter, examples/flame ->"
  echo "                          demo/flame, plus a chooser page at demo/. There is no"
  echo "                          download option: release.yml publishes to pub.dev and"
  echo "                          attaches no release asset."
  echo "  sdk=<download|build|skip>"
  echo "                          Where the Brain comes from (default: $SDK)."
  echo "                          download = the SpriteStudio-SDK release the"
  echo "                                     native-asset hooks pin, for the web wasm;"
  echo "                                     the host libraries come from that same"
  echo "                                     release, fetched by the hooks themselves."
  echo "                                     Needs no Rust toolchain -- what CI uses."
  echo "                          build    = build-runtime.sh twice, the host libs and"
  echo "                                     the web wasm, both release. Needs cargo +"
  echo "                                     wasm-pack, and is the way out when the"
  echo "                                     pinned release does not exist yet."
  echo "                          skip     = use what is in packages/*/native and"
  echo "                                     assets/runtime-web as it stands."
  echo "                          Only consulted for demo=build."
  echo "  base=<path>             Public base path, baked into the demo as --base-href."
  echo "                          Defaults to this clone's repository name ($BASE),"
  echo "                          which is what a project site is served under. Must"
  echo "                          start and end with '/'. base=/ builds a site you can"
  echo "                          serve from a document root."
  echo "  prepare=<auto|yes|no>   Run prepare-docs.sh first (default: $PREPARE)."
  echo "                          auto = only when no zensical is found."
  echo "  venv=<dir>              Virtualenv for the docs toolchain, relative to the"
  echo "                          repo root (default: $VENV). Passed to prepare-docs.sh"
  echo "                          and build-docs.sh."
  echo "  serve=<yes|no>          Serve the tree over HTTP when the build is done"
  echo "                          (default: $SERVE), under base= so the demo resolves."
  echo "                          Foreground; Ctrl-C to stop."
  echo "  port=<n>                Port for serve=yes (default: $PORT)"
  echo "  -h | --help             Show this help"
  echo ""
  echo "Output: site/ (en) + site/ja/ (ja) + site/demo/{flutter,flame}/ -- the exact"
  echo "tree pages.yml uploads."
  echo "The documentation builds are --strict, so a broken internal link or a"
  echo "nav entry pointing at a missing page fails the build here rather than on a"
  echo "release publish."
  echo ""
  echo "The demos need a real HTTP server and the base path they were built for, so"
  echo "open them through serve=yes rather than by pointing a server at site/."
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
        # Lower-cased where the option is an enum; base=/venv=/port= are not.
        docs)    DOCS="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        demo)    DEMO="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        sdk)     SDK="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        base)    BASE="$value" ;;
        prepare) PREPARE="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        venv)    VENV="$value" ;;
        serve)   SERVE="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        port)    PORT="$value" ;;
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

case "$DOCS" in yes|no) ;; *) echo "$APP: docs must be yes or no (got '$DOCS')" >&2; exit 2 ;; esac
case "$DEMO" in build|skip) ;; *) echo "$APP: demo must be build or skip (got '$DEMO')" >&2; exit 2 ;; esac
case "$SDK" in download|build|skip) ;; *) echo "$APP: sdk must be download, build or skip (got '$SDK')" >&2; exit 2 ;; esac
case "$PREPARE" in auto|yes|no) ;; *) echo "$APP: prepare must be auto, yes or no (got '$PREPARE')" >&2; exit 2 ;; esac
case "$SERVE" in yes|no) ;; *) echo "$APP: serve must be yes or no (got '$SERVE')" >&2; exit 2 ;; esac
case "$PORT" in ''|*[!0-9]*) echo "$APP: port must be a number (got '$PORT')" >&2; exit 2 ;; esac

# A base that does not start and end with / silently produces a demo whose every
# asset URL is wrong, and nothing downstream notices until it is deployed.
case "$BASE" in
  /*/|/) ;;
  *) echo "$APP: base must start and end with '/' (got '$BASE')" >&2; exit 2 ;;
esac

# Nothing to build at all is a typo, not a request -- unless serve=yes, where
# "build nothing, show me what is already in site/" is exactly the ask.
if [ "$DOCS" = "no" ] && [ "$DEMO" = "skip" ] && [ "$SERVE" = "no" ]; then
  echo "$APP: docs=no demo=skip builds nothing (add serve=yes to serve what site/ holds)" >&2
  exit 2
fi

SDK_NOTE=""
[ "$DEMO" = "build" ] || SDK_NOTE=" (unused: demo=$DEMO)"
SERVE_NOTE=""
[ "$SERVE" = "no" ] || SERVE_NOTE=" (port $PORT)"

echo "options"
echo "  docs    => $DOCS"
echo "  demo    => $DEMO"
echo "  sdk     => $SDK$SDK_NOTE"
echo "  base    => $BASE"
echo "  prepare => $PREPARE"
echo "  venv    => $VENV"
echo "  serve   => $SERVE$SERVE_NOTE"
echo ""

# --- preflight ------------------------------------------------------------
if [ ! -f "$ROOT_DIR/mkdocs.base.yml" ]; then
  echo "$APP: mkdocs.base.yml not found -- is this the SSPlayerForFlutter repo?" >&2
  exit 1
fi

if [ "$DEMO" = "build" ]; then
  command -v flutter > /dev/null 2>&1 || {
    echo "$APP: flutter not found -- install the Flutter SDK (https://flutter.dev), or" >&2
    echo "$APP: build the documentation on its own with '$APP demo=skip'" >&2
    exit 1
  }
  # deploy-examples.sh converts SpriteStudio-SDK/tests/*.sspj, which only exist
  # once the submodule is checked out; sdk=build compiles that same submodule.
  if [ ! -d "$ROOT_DIR/SpriteStudio-SDK/tests" ]; then
    echo "$APP: SpriteStudio-SDK/tests is missing -- the submodule is not checked out" >&2
    echo "$APP: fix it with 'git submodule update --init --recursive'" >&2
    exit 1
  fi
fi

# Every script here resolves its own paths from the repo root, and site/ is
# written relative to it, so run from there however this was invoked.
cd "$ROOT_DIR"

SITE_DIR="$ROOT_DIR/site"
DEMO_DIR="$SITE_DIR/demo"

TMP_DIR=""
cleanup () {
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

step () {
  echo ""
  echo ">> $*"
  "$@"
}

# --- documentation --------------------------------------------------------
# Same probe as build-docs.sh: a venv laid out either way, else PATH (which is
# how a run with no venv at all still works).
have_zensical () {
  local venv_bin="$ROOT_DIR/$VENV/bin"
  [ -d "$ROOT_DIR/$VENV/Scripts" ] && venv_bin="$ROOT_DIR/$VENV/Scripts"
  [ -x "$venv_bin/zensical" ] || [ -x "$venv_bin/zensical.exe" ] \
    || command -v zensical > /dev/null 2>&1
}

if [ "$DOCS" = "yes" ]; then
  case "$PREPARE" in
    yes)
      step ./scripts/prepare-docs.sh venv="$VENV"
      ;;
    auto)
      if have_zensical; then
        echo "$APP: zensical already available; skipping prepare-docs.sh (prepare=yes forces it)"
      else
        step ./scripts/prepare-docs.sh venv="$VENV"
      fi
      ;;
    no) ;;
  esac

  # Both locales, English first -- build-docs.sh owns that order, because the
  # English build clears site/ and the Japanese site lives inside it at site/ja.
  step ./scripts/build-docs.sh venv="$VENV"
else
  echo "$APP: docs=no -- site/ keeps whatever the last build left there"
fi

# --- demo -----------------------------------------------------------------
# The tag the native-asset hooks are pinned to, e.g. v7.0.0-beta.1.
sdk_version () {
  sed -n "s/^const _sdkVersion = '\(.*\)';.*$/\1/p" "$ROOT_DIR/$SDK_VERSION_SOURCE" | head -1
}

# Reached from pages.yml as well as from a working tree, so it says what is wrong
# rather than assuming the reader can just build the runtime instead -- on the
# Pages runner there is no Rust toolchain to build it with.
sdk_download_failed () { # <version> <what>
  echo "" >&2
  echo "$APP: could not download $2 from SpriteStudio-SDK $1." >&2
  echo "$APP: that release is the one packages/*/hook/build.dart pin, and its" >&2
  echo "$APP: assets are attached by the SDK's own release.yml -- check the release" >&2
  echo "$APP: exists and carries $SDK_WEB_ZIP." >&2
  echo "$APP: In a working tree with cargo + wasm-pack, '$APP sdk=build' compiles the" >&2
  echo "$APP: Brain from the submodule instead." >&2
  exit 1
}

# The web half of sdk=download: the wasm-bindgen packages the SDK release ships,
# laid out the way build-runtime.sh platform=web lays them out -- one JS glue
# (the SIMD build's; the two are interface-identical) plus both binaries, which
# is what loadSsRuntime()'s runtime SIMD probe expects to find.
download_web_runtime () {
  local version dest url
  version="$(sdk_version)"
  [ -n "$version" ] || {
    echo "$APP: no _sdkVersion found in $SDK_VERSION_SOURCE" >&2
    exit 1
  }

  command -v curl > /dev/null 2>&1 || { echo "$APP: curl not on PATH" >&2; exit 1; }
  command -v unzip > /dev/null 2>&1 || { echo "$APP: unzip not on PATH" >&2; exit 1; }

  TMP_DIR="$(mktemp -d)"
  url="$SDK_RELEASE_BASE/$version/$SDK_WEB_ZIP"
  echo ""
  echo ">> downloading $SDK_WEB_ZIP ($version)"
  curl -fsSL -o "$TMP_DIR/$SDK_WEB_ZIP" "$url" || sdk_download_failed "$version" "$SDK_WEB_ZIP"

  # The same integrity check hook/build.dart runs on the dynamic-libs archive.
  # A release without SHA256SUMS is reported rather than treated as verified.
  local sha_tool=""
  if command -v shasum > /dev/null 2>&1; then sha_tool="shasum -a 256"
  elif command -v sha256sum > /dev/null 2>&1; then sha_tool="sha256sum"
  fi
  if [ -n "$sha_tool" ] && curl -fsSL -o "$TMP_DIR/SHA256SUMS" "$SDK_RELEASE_BASE/$version/SHA256SUMS" 2>/dev/null; then
    local want got
    want="$(awk -v f="$SDK_WEB_ZIP" '$2 ~ f {print $1}' "$TMP_DIR/SHA256SUMS" | head -1)"
    got="$($sha_tool "$TMP_DIR/$SDK_WEB_ZIP" | awk '{print $1}')"
    if [ -z "$want" ]; then
      echo "$APP: SHA256SUMS carries no line for $SDK_WEB_ZIP -- not verified" >&2
    elif [ "$want" != "$got" ]; then
      echo "$APP: $SDK_WEB_ZIP does not match SHA256SUMS ($got != $want)" >&2
      exit 1
    else
      echo "   sha256 ok"
    fi
  else
    echo "$APP: no SHA256SUMS for $version -- the archive was not verified" >&2
  fi

  unzip -q -o "$TMP_DIR/$SDK_WEB_ZIP" -d "$TMP_DIR/unpacked"
  for f in runtime-web/ssruntime.js runtime-web/ssruntime_bg.wasm runtime-web-nosimd/ssruntime_bg.wasm; do
    [ -f "$TMP_DIR/unpacked/$f" ] || {
      echo "$APP: $SDK_WEB_ZIP has no $f -- the release layout may have changed" >&2
      exit 1
    }
  done

  dest="$ROOT_DIR/$RUNTIME_WEB_DIR"
  mkdir -p "$dest"
  cp "$TMP_DIR/unpacked/runtime-web/ssruntime.js" "$dest/ssruntime.js"
  cp "$TMP_DIR/unpacked/runtime-web/ssruntime_bg.wasm" "$dest/ssruntime_bg.wasm"
  cp "$TMP_DIR/unpacked/runtime-web-nosimd/ssruntime_bg.wasm" "$dest/ssruntime_bg.nosimd.wasm"
  echo "   -> $RUNTIME_WEB_DIR/ (ssruntime.js + ssruntime_bg.wasm + ssruntime_bg.nosimd.wasm)"

  rm -rf "$TMP_DIR"
  TMP_DIR=""
}

build_demo () {
  case "$SDK" in
    download)
      # Only the web half is fetched here. The host libraries deploy-examples.sh
      # needs are downloaded by each package's own build hook, from this same
      # release -- so a failure there reads as the hook's message, not this one.
      download_web_runtime
      ;;
    build)
      # Two builds, because the demo needs two different things: the host libs
      # deploy-examples.sh drives over dart:ffi to convert the .sspj projects, and
      # the wasm the browser loads. Release for both -- what a downloaded SDK
      # would have been, and a debug wasm is four times the size.
      step ./scripts/build-runtime.sh build=release
      step ./scripts/build-runtime.sh platform=web build=release
      ;;
    skip) ;;
  esac

  if [ ! -f "$ROOT_DIR/$RUNTIME_WEB_DIR/ssruntime_bg.wasm" ]; then
    echo "$APP: no web runtime under $RUNTIME_WEB_DIR/ --" >&2
    echo "$APP: rerun with sdk=download (or sdk=build) rather than sdk=$SDK" >&2
    exit 1
  fi

  # The .ssab both demos play, and one script produces both: deploy-examples.sh
  # converts into examples/overall and copies Ringo into examples/flame.
  # Generated per clone (the example assets are git-ignored), so this runs every
  # time rather than only when they are missing: a stale pack is the kind of
  # thing nobody notices in a published demo.
  step ./scripts/deploy-examples.sh

  rm -rf "$DEMO_DIR"
  mkdir -p "$DEMO_DIR"

  local entry example slug
  for entry in $DEMO_APPS; do
    example="${entry%%:*}"
    slug="${entry##*:}"
    build_one_demo "$example" "$slug"
  done

  write_demo_index
}

# build_one_demo <example dir, repo-relative> <url slug under demo/>
build_one_demo () {
  local example="$1" slug="$2"
  local src="$ROOT_DIR/$example" out="$DEMO_DIR/$slug"

  [ -f "$src/pubspec.yaml" ] || {
    echo "$APP: no $example/pubspec.yaml -- is that example still there?" >&2
    exit 1
  }

  # The examples' platform runners are git-ignored on purpose -- "generated
  # per-clone", says .gitignore -- so web/ has to be materialised before a web
  # build. `flutter create` also rewrites .metadata, replacing the platform list
  # rather than adding to it, so the file goes back the way it was afterwards.
  if [ ! -d "$src/web" ]; then
    local meta="$src/.metadata" meta_backup=""
    if [ -f "$meta" ]; then
      meta_backup="$(mktemp)"
      cp "$meta" "$meta_backup"
    fi
    step sh -c "cd '$src' && flutter create --platforms=web ."
    if [ -n "$meta_backup" ]; then
      cp "$meta_backup" "$meta"
      rm -f "$meta_backup"
      echo "   (.metadata restored -- flutter create rewrites its platform list)"
    fi
  else
    echo ""
    echo "$APP: $example/web present; not re-creating the web runner"
  fi

  # --base-href is baked in, and it has to match where this demo will be served:
  # <base>demo/<slug>/ on the published site, and the same path under the preview
  # root serve=yes sets up.
  step sh -c "cd '$src' && flutter build web --base-href='${BASE}demo/$slug/'"

  if [ ! -f "$src/build/web/index.html" ]; then
    echo "$APP: flutter build web produced no $example/build/web/index.html" >&2
    exit 1
  fi

  echo ""
  echo ">> copying $example/build/web/ into site/demo/$slug/"
  rm -rf "$out"
  mkdir -p "$out"
  cp -R "$src/build/web/." "$out/"
}

# site/demo/ itself is not a Flutter build: with two apps under it, something has
# to answer at the address the documentation links to. Both locale index pages
# point here, so the page is bilingual rather than picking a side -- it is eight
# lines of static HTML, and duplicating the docs' chrome for it would be worse.
write_demo_index () {
  cat > "$DEMO_DIR/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SpriteStudioPlayer for Flutter — Web demos</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         font: 16px/1.6 system-ui, sans-serif; }
  main { padding: 2rem; max-width: 34rem; }
  h1 { font-size: 1.25rem; margin: 0 0 1.5rem; }
  a.demo { display: block; padding: 1rem 1.25rem; margin-bottom: .75rem;
           border: 1px solid currentColor; border-radius: .5rem;
           text-decoration: none; color: inherit; }
  a.demo b { display: block; font-size: 1.05rem; }
  a.demo span { opacity: .75; font-size: .9rem; }
  p { opacity: .75; font-size: .9rem; }
</style>
<main>
  <h1>SpriteStudioPlayer for Flutter — Web demos / Web デモ</h1>
  <a class="demo" href="flutter/">
    <b>Flutter widget demo</b>
    <span>ssplayer_flutter — every draw kind, drawn to the Flutter Canvas.</span>
  </a>
  <a class="demo" href="flame/">
    <b>Flame demo</b>
    <span>ssplayer_flame — the same playback inside a Flame game loop.</span>
  </a>
  <p>The Web target is a developer preview. これらは developer preview のビルドです。</p>
</main>
HTML
  echo "   -> site/demo/index.html (chooser)"
}

if [ "$DEMO" = "build" ]; then
  build_demo
else
  echo ""
  echo "$APP: demo=skip -- site/demo is not part of this build"
fi

# --- what landed ----------------------------------------------------------
echo ""
echo "$APP: done -> site/  (base $BASE)"
report () { # <path> <label>
  if [ -e "$ROOT_DIR/$1" ]; then
    echo "  $2: $1"
  else
    echo "  $2: MISSING ($1)"
  fi
}
report "site/index.html" "en  "
report "site/ja/index.html" "ja  "
if [ "$DEMO" = "build" ]; then
  report "site/demo/index.html" "demo"
  report "site/demo/flutter/index.html" "  fl"
  report "site/demo/flame/index.html" "  fm"
fi

# --- serve ----------------------------------------------------------------
PYTHON_CMD="python3"
command -v "$PYTHON_CMD" > /dev/null 2>&1 || PYTHON_CMD="python"

# Everything the demos load is addressed from $BASE, so serving site/ itself
# 404s on it. Hang the tree off a scratch root under the base path instead --
# the same trick SSPlayerForWeb's build-pages.sh documents.
PREVIEW_ROOT="$ROOT_DIR/.pages-preview"
PREVIEW_LINK="$PREVIEW_ROOT${BASE%/}"

echo ""
if [ "$SERVE" = "yes" ]; then
  command -v "$PYTHON_CMD" > /dev/null 2>&1 || {
    echo "$APP: no python on PATH to serve with -- use any static server" >&2
    exit 1
  }
  if [ "$BASE" = "/" ]; then
    SERVE_DIR="$SITE_DIR"
  else
    mkdir -p "$(dirname "$PREVIEW_LINK")"
    ln -sfn "$SITE_DIR" "$PREVIEW_LINK"
    SERVE_DIR="$PREVIEW_ROOT"
  fi
  echo "$APP: http://localhost:$PORT$BASE  (docs)"
  echo "$APP: http://localhost:$PORT${BASE}ja/  (Japanese)"
  if [ "$DEMO" = "build" ]; then
    echo "$APP: http://localhost:$PORT${BASE}demo/  (Web demos: flutter/ + flame/)"
  fi
  echo "$APP: Ctrl-C to stop"
  echo ""
  exec "$PYTHON_CMD" -m http.server "$PORT" --bind 127.0.0.1 -d "$SERVE_DIR"
else
  echo "$APP: serve it (the demo needs HTTP, and the base path it was built for):"
  echo "$APP:   $APP serve=yes"
  if [ "$BASE" = "/" ]; then
    echo "$APP:   $PYTHON_CMD -m http.server $PORT --bind 127.0.0.1 -d site"
  else
    echo "$APP:   mkdir -p \"$(dirname "$PREVIEW_LINK")\" && ln -sfn site \"$PREVIEW_LINK\""
    echo "$APP:   $PYTHON_CMD -m http.server $PORT --bind 127.0.0.1 -d .pages-preview"
    echo "$APP:   open http://localhost:$PORT$BASE"
  fi
fi
