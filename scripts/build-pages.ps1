#!/usr/bin/env pwsh
#
# Build the GitHub Pages site locally -- everything .github/workflows/pages.yml
# publishes, in the same order: the documentation in both locales into site/,
# then both Web demos into site/demo/. PowerShell twin of build-pages.sh.
#
#   scripts/build-pages.ps1              # the tree pages.yml uploads
#   scripts/build-pages.ps1 serve=yes    # ... and serve it under the base path
#   scripts/build-pages.ps1 demo=skip    # documentation only, no Flutter toolchain
#   scripts/build-pages.ps1 base=/ zip=yes   # a tree for an upload host, packed
#
# base= is baked into the demo at build time (--base-href), which is why it is an
# option here: the documentation uses relative links and does not care, the
# Flutter app does. It defaults to the
# project-site path (/<repo>/), so serve=yes hangs the tree off a scratch root at
# that path rather than serving site/ directly -- otherwise every asset URL in
# the demo 404s.
#
# GitHub Pages is where this site is published from, and pages.yml does that. A
# second copy goes up by hand to Cloudflare Pages, whose dashboard takes an
# upload rather than a git push -- that is what zip=yes is for, and why it wants
# base=/: Cloudflare serves a project at its own root, GitHub Pages serves it
# under /<repo>/, and --base-href cannot be both.
#
# What this does NOT reproduce is the deploy job (actions/deploy-pages) -- there
# is no local equivalent of publishing.
$ErrorActionPreference = "Stop"

$APP = Split-Path -Leaf $PSCommandPath
$ROOT_DIR = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# The examples that become the demos, as <example dir> -> <url slug under demo/>.
# The slugs are what a reader sees, so they name the package each example
# exercises rather than the directory it lives in.
$DEMO_APPS = [ordered]@{
    "examples/overall" = "flutter"
    "examples/flame"   = "flame"
}

# Where the web runtime lands. Which release it comes from, and how, belongs to
# scripts/download-web-runtime.ps1 -- this only needs to know where to look.
$RUNTIME_WEB_DIR = "packages/ssplayer_flutter/assets/runtime-web"

# zip=yes writes this, for a host that takes an upload rather than a git push --
# Cloudflare Pages' drag-and-drop, today. Git-ignored; rebuilt, never edited.
$SITE_ZIP = "SSPlayerForFlutter-site.zip"

function Fail {
    param([string] $Message, [int] $Code = 1)
    [Console]::Error.WriteLine("${APP}: $Message")
    exit $Code
}

# --- options --------------------------------------------------------------

# A project site is served under /<repo>/. The workflow passes
# github.event.repository.name; here the origin remote names the repository,
# falling back to the clone's directory name.
function Get-DefaultBase {
    $url = ""
    try { $url = (& git -C $ROOT_DIR config --get remote.origin.url 2>$null) } catch { }
    $name = ($url -split '/')[-1] -replace '\.git$', ''
    if (-not $name) { $name = Split-Path -Leaf $ROOT_DIR }
    return "/$name/"
}

$opts = [ordered]@{
    docs    = "yes"
    demo    = "build"
    sdk     = "download"
    base    = (Get-DefaultBase)
    prepare = "auto"
    venv    = ".venv"
    zip     = "no"
    serve   = "no"
    port    = "8000"
}
$defaultBase = $opts.base

function Show-Usage {
    Write-Host "Usage: $APP [options]"
    Write-Host "$APP options:"
    Write-Host "  docs=<yes|no>           Build the documentation, both locales (default: yes)."
    Write-Host "                          no keeps whatever site/ already holds -- handy when"
    Write-Host "                          only the demo is being re-checked."
    Write-Host "  demo=<build|skip>       Build both Web demos into site/demo (default: build):"
    Write-Host "                          examples/overall -> demo/flutter, examples/flame ->"
    Write-Host "                          demo/flame, plus a chooser page at demo/. There is no"
    Write-Host "                          download option: release.yml publishes to pub.dev and"
    Write-Host "                          attaches no release asset."
    Write-Host "  sdk=<download|build|skip>"
    Write-Host "                          Where the Brain comes from (default: download)."
    Write-Host "                          download = the SpriteStudio-SDK release the"
    Write-Host "                                     native-asset hooks pin, for the web wasm;"
    Write-Host "                                     the host libraries come from that same"
    Write-Host "                                     release, fetched by the hooks themselves."
    Write-Host "                                     Needs no Rust toolchain -- what CI uses."
    Write-Host "                          build    = build-runtime.ps1 twice, the host libs and"
    Write-Host "                                     the web wasm, both release. Needs cargo +"
    Write-Host "                                     wasm-pack, and is the way out when the"
    Write-Host "                                     pinned release does not exist yet."
    Write-Host "                          skip     = use what is in packages/*/native and"
    Write-Host "                                     assets/runtime-web as it stands."
    Write-Host "                          Only consulted for demo=build."
    Write-Host "  base=<path>             Public base path, baked into the demo as --base-href."
    Write-Host "                          Defaults to this clone's repository name ($defaultBase),"
    Write-Host "                          which is what a project site is served under. Must"
    Write-Host "                          start and end with '/'. base=/ builds a site you can"
    Write-Host "                          serve from a document root."
    Write-Host "  prepare=<auto|yes|no>   Run prepare-docs.ps1 first (default: auto)."
    Write-Host "                          auto = only when no zensical is found."
    Write-Host "  venv=<dir>              Virtualenv for the docs toolchain, relative to the"
    Write-Host "                          repo root (default: .venv). Passed to prepare-docs.ps1"
    Write-Host "                          and build-docs.ps1."
    Write-Host "  zip=<yes|no>            Pack the finished tree into $SITE_ZIP (default: no),"
    Write-Host "                          contents at the archive root -- what Cloudflare Pages'"
    Write-Host "                          drag-and-drop upload expects. That host serves a project"
    Write-Host "                          at its own root, so pair it with base=/ or every asset"
    Write-Host "                          URL in the demos is wrong; this says so if you do not."
    Write-Host "  serve=<yes|no>          Serve the tree over HTTP when the build is done"
    Write-Host "                          (default: no), under base= so the demo resolves."
    Write-Host "                          Foreground; Ctrl-C to stop."
    Write-Host "  port=<n>                Port for serve=yes (default: 8000)"
    Write-Host "  -h | --help             Show this help"
    Write-Host ""
    Write-Host "Output: site/ (en) + site/ja/ (ja) + site/demo/{flutter,flame}/ -- the exact"
    Write-Host "tree pages.yml uploads."
    Write-Host "The documentation builds are --strict, so a broken internal link fails"
    Write-Host "the build here rather than on a release publish."
    Write-Host ""
    Write-Host "The demos need a real HTTP server and the base path they were built for, so"
    Write-Host "open them through serve=yes rather than by pointing a server at site/."
}

foreach ($item in $args) {
    if ($item -in "-h", "--help", "help") {
        Show-Usage
        exit 0
    } elseif ($item -match "=") {
        $key, $value = $item -split "=", 2
        if (-not $opts.Contains($key)) {
            Fail "unknown option '$key' (see $APP --help)" 2
        }
        # Lower-cased where the option is an enum; base=/venv=/port= are not.
        $opts[$key] = if ($key -in "base", "venv", "port") { $value } else { $value.ToLower() }
    } else {
        Fail "unknown argument '$item' (options are key=value; see $APP --help)" 2
    }
}

if ($opts.docs    -notin @("yes", "no"))                   { Fail "docs must be yes or no (got '$($opts.docs)')" 2 }
if ($opts.demo    -notin @("build", "skip"))               { Fail "demo must be build or skip (got '$($opts.demo)')" 2 }
if ($opts.sdk     -notin @("download", "build", "skip"))   { Fail "sdk must be download, build or skip (got '$($opts.sdk)')" 2 }
if ($opts.prepare -notin @("auto", "yes", "no"))           { Fail "prepare must be auto, yes or no (got '$($opts.prepare)')" 2 }
if ($opts.zip     -notin @("yes", "no"))                   { Fail "zip must be yes or no (got '$($opts.zip)')" 2 }
if ($opts.serve   -notin @("yes", "no"))                   { Fail "serve must be yes or no (got '$($opts.serve)')" 2 }
if ($opts.port -notmatch '^\d+$')                          { Fail "port must be a number (got '$($opts.port)')" 2 }

# A base that does not start and end with / silently produces a demo whose every
# asset URL is wrong, and nothing downstream notices until it is deployed.
if ($opts.base -notmatch '^/$' -and $opts.base -notmatch '^/.*/$') {
    Fail "base must start and end with '/' (got '$($opts.base)')" 2
}

# Nothing to build at all is a typo, not a request -- unless serve=yes, where
# "build nothing, show me what is already in site/" is exactly the ask.
if ($opts.docs -eq "no" -and $opts.demo -eq "skip" -and $opts.serve -eq "no" -and $opts.zip -eq "no") {
    Fail "docs=no demo=skip builds nothing (add serve=yes or zip=yes to use what site/ holds)" 2
}

$sdkNote = if ($opts.demo -eq "build") { "" } else { " (unused: demo=$($opts.demo))" }
$serveNote = if ($opts.serve -eq "no") { "" } else { " (port $($opts.port))" }

Write-Host "options"
Write-Host "  docs    => $($opts.docs)"
Write-Host "  demo    => $($opts.demo)"
Write-Host "  sdk     => $($opts.sdk)$sdkNote"
Write-Host "  base    => $($opts.base)"
Write-Host "  prepare => $($opts.prepare)"
Write-Host "  venv    => $($opts.venv)"
Write-Host "  zip     => $($opts.zip)"
Write-Host "  serve   => $($opts.serve)$serveNote"
Write-Host ""

# --- preflight ------------------------------------------------------------
if (-not (Test-Path (Join-Path $ROOT_DIR "mkdocs.base.yml"))) {
    Fail "mkdocs.base.yml not found -- is this the SSPlayerForFlutter repo?"
}

if ($opts.demo -eq "build") {
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("${APP}: flutter not found -- install the Flutter SDK (https://flutter.dev), or")
        Fail "build the documentation on its own with '$APP demo=skip'"
    }
    # deploy-examples converts SpriteStudio-SDK/tests/*.sspj, which only exist
    # once the submodule is checked out; sdk=build compiles that same submodule.
    if (-not (Test-Path (Join-Path $ROOT_DIR "SpriteStudio-SDK/tests"))) {
        [Console]::Error.WriteLine("${APP}: SpriteStudio-SDK/tests is missing -- the submodule is not checked out")
        Fail "fix it with 'git submodule update --init --recursive'"
    }
}

$SITE_DIR = Join-Path $ROOT_DIR "site"
$DEMO_DIR = Join-Path $SITE_DIR "demo"

function Step {
    param([string] $What, [scriptblock] $Body)
    Write-Host ""
    Write-Host ">> $What"
    & $Body
    if ($LASTEXITCODE -ne 0) { Fail "$What failed ($LASTEXITCODE)" $LASTEXITCODE }
}

# Every script here resolves its own paths from the repo root, and site/ is
# written relative to it, so run from there however this was invoked.
Push-Location $ROOT_DIR
try {
    # --- documentation ----------------------------------------------------
    # Same probe as build-docs.ps1: a venv laid out either way, else PATH (which
    # is how a run with no venv at all still works).
    function Test-Zensical {
        $venvDir = Join-Path $ROOT_DIR $opts.venv
        $venvBin = if (Test-Path (Join-Path $venvDir "Scripts")) {
            Join-Path $venvDir "Scripts"
        } else {
            Join-Path $venvDir "bin"
        }
        foreach ($candidate in @((Join-Path $venvBin "zensical.exe"), (Join-Path $venvBin "zensical"))) {
            if (Test-Path $candidate) { return $true }
        }
        return [bool](Get-Command zensical -ErrorAction SilentlyContinue)
    }

    $prepareScript = Join-Path $ROOT_DIR "scripts/prepare-docs.ps1"
    $buildDocsScript = Join-Path $ROOT_DIR "scripts/build-docs.ps1"
    $downloadWebScript = Join-Path $ROOT_DIR "scripts/download-web-runtime.ps1"
    $buildRuntimeScript = Join-Path $ROOT_DIR "scripts/build-runtime.ps1"
    $deployScript = Join-Path $ROOT_DIR "scripts/deploy-examples.ps1"

    if ($opts.docs -eq "yes") {
        switch ($opts.prepare) {
            "yes" { Step "prepare-docs.ps1 venv=$($opts.venv)" { & $prepareScript "venv=$($opts.venv)" } }
            "auto" {
                if (Test-Zensical) {
                    Write-Host "${APP}: zensical already available; skipping prepare-docs.ps1 (prepare=yes forces it)"
                } else {
                    Step "prepare-docs.ps1 venv=$($opts.venv)" { & $prepareScript "venv=$($opts.venv)" }
                }
            }
            "no" { }
        }

        # Both locales, English first -- build-docs.ps1 owns that order, because
        # the English build clears site/ and the Japanese site lives inside it at
        # site/ja.
        Step "build-docs.ps1 venv=$($opts.venv)" { & $buildDocsScript "venv=$($opts.venv)" }
    } else {
        Write-Host "${APP}: docs=no -- site/ keeps whatever the last build left there"
    }

    # --- demo -------------------------------------------------------------
    # The web Brain comes from scripts/download-web-runtime.ps1, which owns the
    # whole of it: the tag packages/ssruntime_dart/hook/build.dart pins, the
    # download, the SHA256SUMS check, and the flattening of the release's two
    # wasm-bindgen packages into the one-directory layout the loader's SIMD probe
    # expects.

    # build_one_demo <example dir, repo-relative> <url slug under demo/>
    function Build-OneDemo {
        param([string] $Example, [string] $Slug)

        $src = Join-Path $ROOT_DIR $Example
        $out = Join-Path $DEMO_DIR $Slug

        if (-not (Test-Path (Join-Path $src "pubspec.yaml"))) {
            Fail "no $Example/pubspec.yaml -- is that example still there?"
        }

        # The examples' platform runners are git-ignored on purpose -- "generated
        # per-clone", says .gitignore -- so web/ has to be materialised before a
        # web build. `flutter create` also rewrites .metadata, replacing the
        # platform list rather than adding to it, so the file goes back the way it
        # was afterwards.
        if (-not (Test-Path (Join-Path $src "web"))) {
            $meta = Join-Path $src ".metadata"
            $metaBackup = $null
            if (Test-Path $meta) {
                $metaBackup = [System.IO.Path]::GetTempFileName()
                Copy-Item -Force $meta $metaBackup
            }
            Step "flutter create --platforms=web . (in $Example)" {
                Push-Location $src
                try { & flutter create --platforms=web . } finally { Pop-Location }
            }
            if ($metaBackup) {
                Copy-Item -Force $metaBackup $meta
                Remove-Item -Force $metaBackup
                Write-Host "   (.metadata restored -- flutter create rewrites its platform list)"
            }
        } else {
            Write-Host ""
            Write-Host "${APP}: $Example/web present; not re-creating the web runner"
        }

        # --base-href is baked in, and it has to match where this demo will be
        # served: <base>demo/<slug>/ on the published site, and the same path
        # under the preview root serve=yes sets up.
        $href = "$($opts.base)demo/$Slug/"
        Step "flutter build web --base-href='$href' (in $Example)" {
            Push-Location $src
            try { & flutter build web --base-href=$href } finally { Pop-Location }
        }

        if (-not (Test-Path (Join-Path $src "build/web/index.html"))) {
            Fail "flutter build web produced no $Example/build/web/index.html"
        }

        Write-Host ""
        Write-Host ">> copying $Example/build/web/ into site/demo/$Slug/"
        if (Test-Path $out) { Remove-Item -Recurse -Force $out }
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        Copy-Item -Path (Join-Path $src "build/web/*") -Destination $out -Recurse -Force
        Add-DemoLinks $out "../../"
    }

    # Puts a fixed "Powered by" box, linking to the docs and the repository, into
    # every *.html directly in $Dir, ahead of the last </body>. $Root is the path
    # from those pages to the site root.
    function Add-DemoLinks {
        param([string] $Dir, [string] $Root)
        if (!(Test-Path -LiteralPath $Dir -PathType Container)) { return }
        $a = 'target="_blank" rel="noopener" style="color:#fff"'
        $links = '<div id="ss-demo-links" style="position:fixed;left:12px;bottom:12px;z-index:2147483647;padding:4px 10px;border-radius:6px;background:rgba(0,0,0,.65);color:#fff;font:12px/1.6 system-ui,sans-serif">' +
            "Powered by SpriteStudio Player for Flutter &middot; <a href=`"$Root`" $a>Docs</a>" +
            " &middot; <a href=`"https://github.com/cri-middleware/SSPlayerForFlutter`" $a>GitHub</a></div>"
        foreach ($page in Get-ChildItem -LiteralPath $Dir -Filter '*.html' -File) {
            $text = [IO.File]::ReadAllText($page.FullName)
            if ($text.Contains('id="ss-demo-links"')) { continue }
            $at = $text.LastIndexOf('</body>', [StringComparison]::OrdinalIgnoreCase)
            if ($at -ge 0) {
                $text = $text.Insert($at, $links)
            } else {
                if ($text.Length -gt 0 -and !$text.EndsWith("`n")) { $text += "`n" }
                $text += $links
            }
            if (!$text.EndsWith("`n")) { $text += "`n" }
            [IO.File]::WriteAllText($page.FullName, $text)
        }
        Write-Host "   links to the docs and the repository -> site/$($Dir.Substring($SITE_DIR.Length).TrimStart('/', '\'))/*.html"
    }

    # site/demo/ itself is not a Flutter build: with two apps under it, something
    # has to answer at the address the documentation links to. Both locale index
    # pages point here, so the page is bilingual rather than picking a side.
    function Write-DemoIndex {
        $html = @'
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SpriteStudio Player for Flutter — Web demos</title>
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
  <h1>SpriteStudio Player for Flutter — Web demos / Web デモ</h1>
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
'@
        # LF and a trailing newline, so the file matches the .sh twin's heredoc
        # byte for byte. UTF-8 without a BOM, for the Japanese line.
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText((Join-Path $DEMO_DIR "index.html"), ($html -replace "`r`n", "`n") + "`n", $utf8)
        Write-Host "   -> site/demo/index.html (chooser)"
    }

    if ($opts.demo -eq "build") {
        switch ($opts.sdk) {
            "download" {
                # Only the web half is fetched here. The host libraries
                # deploy-examples needs are downloaded by each package's own build
                # hook, from this same release -- so a failure there reads as the
                # hook's message, not this one.
                & $downloadWebScript
                if ($LASTEXITCODE -ne 0) { Fail "download-web-runtime.ps1 failed ($LASTEXITCODE)" $LASTEXITCODE }
            }
            "build" {
                # Two builds, because the demo needs two different things: the
                # host libs deploy-examples drives over dart:ffi to convert the
                # .sspj projects, and the wasm the browser loads. Release for
                # both -- what a downloaded SDK would have been, and a debug wasm
                # is several times larger.
                Step "build-runtime.ps1 build=release" { & $buildRuntimeScript build=release }
                Step "build-runtime.ps1 platform=web build=release" { & $buildRuntimeScript platform=web build=release }
            }
            "skip" { }
        }

        if (-not (Test-Path (Join-Path $ROOT_DIR "$RUNTIME_WEB_DIR/ssruntime_bg.wasm"))) {
            [Console]::Error.WriteLine("${APP}: no web runtime under $RUNTIME_WEB_DIR/ --")
            Fail "rerun with sdk=download (or sdk=build) rather than sdk=$($opts.sdk)"
        }

        # The .ssab both demos play, and one script produces both: deploy-examples
        # converts into examples/overall and copies Ringo into examples/flame.
        # Generated per clone (the example assets are git-ignored), so this runs
        # every time rather than only when they are missing: a stale pack is the
        # kind of thing nobody notices in a published demo.
        Step "deploy-examples.ps1" { & $deployScript }

        if (Test-Path $DEMO_DIR) { Remove-Item -Recurse -Force $DEMO_DIR }
        New-Item -ItemType Directory -Force -Path $DEMO_DIR | Out-Null

        foreach ($example in $DEMO_APPS.Keys) {
            Build-OneDemo -Example $example -Slug $DEMO_APPS[$example]
        }

        Write-DemoIndex
        Add-DemoLinks $DEMO_DIR "../"
    } else {
        Write-Host ""
        Write-Host "${APP}: demo=skip -- site/demo is not part of this build"
    }
} finally {
    Pop-Location
}

# --- what landed ----------------------------------------------------------
Write-Host ""
Write-Host "${APP}: done -> site/  (base $($opts.base))"
function Report {
    param([string] $Path, [string] $Label)
    if (Test-Path (Join-Path $ROOT_DIR $Path)) {
        Write-Host "  ${Label}: $Path"
    } else {
        Write-Host "  ${Label}: MISSING ($Path)"
    }
}
Report "site/index.html" "en  "
Report "site/ja/index.html" "ja  "
if ($opts.demo -eq "build") {
    Report "site/demo/index.html" "demo"
    Report "site/demo/flutter/index.html" "  fl"
    Report "site/demo/flame/index.html" "  fm"
}

# --- pack -----------------------------------------------------------------
# For a host that takes an upload instead of a git push. The archive holds the
# tree itself, not a directory containing it: Cloudflare Pages' drag-and-drop
# publishes what is at the root of the zip, so a wrapping folder becomes a
# wrapping path segment and every page 404s.
if ($opts.zip -eq "yes") {
    if (-not (Test-Path $SITE_DIR)) { Fail "no site/ to pack" }
    # Said, not enforced: an upload host may well serve under a subpath, and only
    # the person uploading knows. What is worth refusing is silence -- a zip built
    # for /SSPlayerForFlutter/ looks fine until every demo asset 404s on it.
    if ($opts.base -ne "/") {
        Write-Host ""
        [Console]::Error.WriteLine("${APP}: WARNING: packing a tree built for base=$($opts.base).")
        [Console]::Error.WriteLine("${APP}: Cloudflare Pages serves a project at its own root, so rebuild with")
        [Console]::Error.WriteLine("${APP}: 'base=/' unless the destination really does serve from $($opts.base).")
    }
    $zipPath = Join-Path $ROOT_DIR $SITE_ZIP
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Write-Host ""
    Write-Host ">> packing site/ into $SITE_ZIP"
    # The contents, not the directory: every entry is named relative to site/,
    # which is what the .sh twin's `cd site && zip -qr` produces. Written entry
    # by entry rather than with Compress-Archive, for two reasons: the directory
    # entries `zip -r` records are kept (Compress-Archive stores files only), and
    # the separator is forced to '/' whatever the host uses.
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $prefix = $SITE_DIR.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Length + 1
        foreach ($dir in Get-ChildItem -Recurse -Directory $SITE_DIR) {
            $rel = ($dir.FullName.Substring($prefix) -replace '\\', '/') + '/'
            [void]$zip.CreateEntry($rel)
        }
        foreach ($file in Get-ChildItem -Recurse -File $SITE_DIR) {
            $rel = $file.FullName.Substring($prefix) -replace '\\', '/'
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $rel)
        }
    } finally {
        $zip.Dispose()
    }
    $size = "{0:N1} MB" -f ((Get-Item $zipPath).Length / 1MB)
    $count = (Get-ChildItem -Recurse -File $SITE_DIR | Measure-Object).Count
    Write-Host "   ${SITE_ZIP}: $size, $count files"
}

# --- serve ----------------------------------------------------------------
# py first: it is the Windows launcher, and what build-docs.ps1 already tells
# people to serve with. python/python3 are the fallbacks elsewhere -- on Windows
# a bare `python` can be the Store stub that does nothing.
$PYTHON_CMD = $null
foreach ($candidate in @("py", "python", "python3")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $PYTHON_CMD = $candidate; break }
}

# Everything the demos load is addressed from base=, so serving site/ itself
# 404s on it. Hang the tree off a scratch root under the base path instead --
# the same trick the .sh twin and SSPlayerForWeb's build-pages document.
$PREVIEW_ROOT = Join-Path $ROOT_DIR ".pages-preview"
$PREVIEW_LINK = Join-Path $PREVIEW_ROOT ($opts.base.Trim('/') -replace '/', [System.IO.Path]::DirectorySeparatorChar)

Write-Host ""
if ($opts.serve -eq "yes") {
    if (-not $PYTHON_CMD) {
        Fail "no python on PATH to serve with -- use any static server"
    }
    if ($opts.base -eq "/") {
        $serveDir = $SITE_DIR
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PREVIEW_LINK) | Out-Null
        if (Test-Path $PREVIEW_LINK) { Remove-Item -Force -Recurse $PREVIEW_LINK }
        # A junction rather than a symbolic link: on Windows a directory junction
        # needs no Developer Mode and no elevation, which a symlink does.
        $linkType = if ($IsWindows) { "Junction" } else { "SymbolicLink" }
        New-Item -ItemType $linkType -Path $PREVIEW_LINK -Target $SITE_DIR | Out-Null
        $serveDir = $PREVIEW_ROOT
    }
    Write-Host "${APP}: http://localhost:$($opts.port)$($opts.base)  (docs)"
    Write-Host "${APP}: http://localhost:$($opts.port)$($opts.base)ja/  (Japanese)"
    if ($opts.demo -eq "build") {
        Write-Host "${APP}: http://localhost:$($opts.port)$($opts.base)demo/  (Web demos: flutter/ + flame/)"
    }
    Write-Host "${APP}: Ctrl-C to stop"
    Write-Host ""
    & $PYTHON_CMD -m http.server $opts.port --bind 127.0.0.1 -d $serveDir
    exit $LASTEXITCODE
} else {
    $shown = if ($PYTHON_CMD) { $PYTHON_CMD } else { "python" }
    Write-Host "${APP}: serve it (the demo needs HTTP, and the base path it was built for):"
    Write-Host "${APP}:   $APP serve=yes"
    if ($opts.base -eq "/") {
        Write-Host "${APP}:   $shown -m http.server $($opts.port) --bind 127.0.0.1 -d site"
    } else {
        Write-Host "${APP}:   New-Item -ItemType Junction -Path '$PREVIEW_LINK' -Target site"
        Write-Host "${APP}:   $shown -m http.server $($opts.port) --bind 127.0.0.1 -d .pages-preview"
        Write-Host "${APP}:   start http://localhost:$($opts.port)$($opts.base)"
    }
}
