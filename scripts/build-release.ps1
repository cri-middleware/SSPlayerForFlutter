#!/usr/bin/env pwsh
#
# Build the release: for every package under packages/, the exact file set
# `dart pub publish` would upload -- packed where you can look inside it -- and
# every check that has to pass before the release tags go out. PowerShell
# counterpart of scripts/build-release.sh; same options, same output, same
# exit codes.
#
#   scripts/build-release.ps1                            # the whole thing
#   scripts/build-release.ps1 checks=analyze             # ... without the tests
#   scripts/build-release.ps1 checks=skip sdk=skip       # archives only, offline
#   scripts/build-release.ps1 sdk=build                  # compile the web Brain here
#   scripts/build-release.ps1 packages=ssruntime_dart    # one package
#   scripts/build-release.ps1 out=C:\tmp\rel             # somewhere else
#
# A release here attaches nothing, which is the whole reason this script looks
# different from the sibling players' build-release. There, one archive is built
# and attached to a Release. Here, release.yml sets the versions it is given,
# runs the .sh twin, and only then commits them and pushes `<package>-v<version>`
# tags; each tag triggers publish.yml, which runs `dart pub publish` in that
# package's directory and uploads it to pub.dev, and the package's GitHub Release
# carries its notes and nothing else. So what there is to "build" is the file set
# each of those publishes would send, and the confidence that all of them will
# succeed.
#
# The confidence is the valuable half, because a version on pub.dev is permanent:
# once its tag is pushed, a publish that fails can only be followed by another
# version. Everything below runs before that point, which is why release.yml
# runs the .sh twin before it commits or tags anything.
#
# What this does NOT do is set a version or push a tag. Those are decisions:
# scripts/set-versions.dart makes the first, release.yml the second.
#
# A package carrying `publish_to: none` is not published: publish.yml skips its
# tag and `dart pub publish` refuses it outright. That one line is the on/off
# switch for pub.dev. Such a package is PREVIEWED rather than skipped, so what
# would block it is known before it opts in -- the line is lifted for the length
# of the dry run (and put straight back), everything that would block its
# publish is reported, and none of it fails the run. Every other package is
# checked for real, with warnings fatal exactly as `dart pub publish` has them.
#
# Prerequisites: Dart/Flutter SDK, git, tar (Windows 10 1803+ ships bsdtar).

$ErrorActionPreference = "Stop"

$App = Split-Path -Leaf $PSCommandPath
$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# The SDK release the native-asset hooks pin, and the assets a consumer's build
# actually fetches from it. Read from the hooks rather than repeated here.
$SdkReleaseBase = "https://github.com/cri-middleware/SpriteStudio-SDK/releases/download"
$SdkLibsZip     = "spritestudio-sdk-dynamic-libs.zip"
$SdkPinSources  = @(
    "packages/ssruntime_dart/hook/build.dart",
    "packages/ssconverter_dart/hook/build.dart"
)

# Committed generator output: regenerating it must produce no diff.
$FfigenPaths = @(
    "packages/ssruntime_dart/lib/src/ssruntime_bindings.g.dart",
    "packages/ssconverter_dart/lib/src/ssconverter_bindings.g.dart"
)
$FbsPaths = @(
    "packages/ssplayer_flutter/lib/src/ssab",
    "packages/ssruntime_dart/lib/src/fbs",
    "packages/ssplayer_flutter/test/support"
)

# The web Brain, as ssruntime_dart's web_runtime.dart asks for it by name.
$WebRuntimeDir   = "assets/runtime-web"
$WebRuntimeFiles = @("ssruntime.js", "ssruntime_bg.wasm", "ssruntime_bg.nosimd.wasm")

# pub.dev's hard limit on an uploaded archive.
$MaxArchiveBytes = 104857600

# --- options --------------------------------------------------------------

$Out      = "release-dist"
$Packages = "all"
$Checks   = "full"
$Codegen  = "check"
$Sdk      = "download"
$Verify   = "yes"
$Clean    = "yes"

function Show-Usage {
    Write-Host "Usage: $App [options]"
    Write-Host "$App options:"
    Write-Host "  out=<dir>               Where the archives, their manifests and SHA256SUMS"
    Write-Host "                          land (default: $Out). Relative paths resolve against"
    Write-Host "                          the current directory."
    Write-Host "  packages=<all|a,b,...>  Which packages to build (default: $Packages). Names are"
    Write-Host "                          directory names under packages/. Versions here are"
    Write-Host "                          INDEPENDENT, so a release is usually a subset."
    Write-Host "  checks=<full|analyze|skip>"
    Write-Host "                          How much to run per package before packing it"
    Write-Host "                          (default: $Checks). full = analyze + tests; analyze ="
    Write-Host "                          the analyzer only; skip = neither. The tests need the"
    Write-Host "                          Brain, which the build hooks download from the pinned"
    Write-Host "                          SDK release -- so checks=full is also the only thing"
    Write-Host "                          here that proves that download works end to end."
    Write-Host "  codegen=<check|skip>    Re-run the generators and require no diff (default:"
    Write-Host "                          $Codegen). Each half is skipped, loudly, when its"
    Write-Host "                          input is missing: ffigen needs the C headers"
    Write-Host "                          build-runtime.ps1 copies into packages/*/native/include,"
    Write-Host "                          flatc needs to be on PATH."
    Write-Host "  sdk=<download|build|skip>"
    Write-Host "                          Where the web Brain comes from, and whether the pinned"
    Write-Host "                          SDK release is checked at all (default: $Sdk)."
    Write-Host "                          download = download-web-runtime.ps1, the release"
    Write-Host "                                     packages/*/hook/build.dart pin -- what CI"
    Write-Host "                                     uses, and what publish.yml runs before it"
    Write-Host "                                     publishes ssplayer_flutter. Also checks that"
    Write-Host "                                     release carries the host library archive the"
    Write-Host "                                     hooks fetch for every consumer. Needs network."
    Write-Host "                          build    = build-runtime.ps1 platform=web, compiled from"
    Write-Host "                                     the submodule (needs cargo + wasm-pack). The"
    Write-Host "                                     way out while that release does not exist"
    Write-Host "                                     yet, so it does not check for it."
    Write-Host "                          skip     = use assets/runtime-web as it stands, and"
    Write-Host "                                     check nothing. For an offline tree, never"
    Write-Host "                                     for a release."
    Write-Host "  verify=<yes|no>         Re-open the finished archives and check them"
    Write-Host "                          (default: $Verify)."
    Write-Host "  clean=<yes|no>          Delete <out> before building (default: $Clean)."
        Write-Host "  in= skip=               Accepted and ignored here. The family's build-release"
    Write-Host "                          scripts share out= clean= verify= in= sdk= skip=,"
    Write-Host "                          so one command line drives all of them."
Write-Host "  -h | --help             Show this help"
    Write-Host ""
    Write-Host "Output: <out>/ holds, per package, <name>-<version>.tar.gz (the file set pub"
    Write-Host "would upload, packed here so it can be looked at -- pub builds its own archive"
    Write-Host "at publish time, so this one is for inspection and is uploaded nowhere),"
    Write-Host "<name>-<version>.files (one path per line) and <name>-<version>.publish.txt (the"
    Write-Host "dry run verbatim), plus SHA256SUMS over the archives."
    Write-Host ""
    Write-Host "There is no option for which release this is: a tag is a decision already made,"
    Write-Host "and this reads it. GITHUB_REF_NAME, or the '<package>-v<version>' tag HEAD is"
    Write-Host "checked out at, must agree with that package's pubspec version."
}

foreach ($item in $args) {
    switch -Regex ($item) {
        '^(-h|--help|help)$' { Show-Usage; exit 0 }
        '^[^=]+=.*$' {
            $key   = $item.Substring(0, $item.IndexOf('='))
            $value = $item.Substring($item.IndexOf('=') + 1)
            switch ($key) {
                # Lower-cased where the option is a keyword; out= is a path and
                # packages= is a list of directory names.
                "out"      { $Out = $value }
                "packages" { $Packages = $value }
                "checks"   { $Checks = $value.ToLowerInvariant() }
                "codegen"  { $Codegen = $value.ToLowerInvariant() }
                "sdk"      { $Sdk = $value.ToLowerInvariant() }
                "verify"   { $Verify = $value.ToLowerInvariant() }
                "clean"    { $Clean = $value.ToLowerInvariant() }
                # Accepted so one command line drives build-release in every
                # repository of the family; this one has no use for them.
                "in"       { [Console]::Error.WriteLine("${App}: in= does not apply here; ignored") }
                "skip"     { [Console]::Error.WriteLine("${App}: skip= does not apply here; ignored") }
                default {
                    # Plain stderr and the code, matching the .sh twin. Write-Error
                    # throws under $ErrorActionPreference = "Stop", so the exit 2
                    # below it never ran and the shell saw 1.
                    [Console]::Error.WriteLine("${App}: unknown option '$key' (see $App --help)")
                    exit 2
                }
            }
        }
        default {
            [Console]::Error.WriteLine("${App}: unknown argument '$item' (options are key=value; see $App --help)")
            exit 2
        }
    }
}

if ($Checks  -notin @("full", "analyze", "skip")) { Write-Error "$App`: checks must be full, analyze or skip (got '$Checks')"; exit 2 }
if ($Codegen -notin @("check", "skip"))           { Write-Error "$App`: codegen must be check or skip (got '$Codegen')"; exit 2 }
if ($Sdk     -notin @("download", "build", "skip")) { Write-Error "$App`: sdk must be download, build or skip (got '$Sdk')"; exit 2 }
if ($Verify  -notin @("yes", "no"))               { Write-Error "$App`: verify must be yes or no (got '$Verify')"; exit 2 }
if ($Clean   -notin @("yes", "no"))               { Write-Error "$App`: clean must be yes or no (got '$Clean')"; exit 2 }

# Resolve against the invoking directory, before anything moves away from it.
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
$Out = [System.IO.Path]::GetFullPath($Out)

# clean=yes deletes this path, so refuse the ones that would take the repository
# (or the filesystem) with them.
$Forbidden = @($RootDir, (Join-Path $RootDir "packages")) | ForEach-Object { [System.IO.Path]::GetFullPath($_) }
if ($Out -in $Forbidden -or $Out -eq [System.IO.Path]::GetPathRoot($Out)) {
    Write-Error "$App`: refusing to use '$Out' as out= (it is deleted when clean=yes)"
    exit 2
}

Set-Location $RootDir

# --- preflight ------------------------------------------------------------

if (-not (Test-Path (Join-Path $RootDir "packages"))) {
    Write-Error "$App`: no packages/ here -- is this the SSPlayerForFlutter repo?"
    exit 1
}
foreach ($tool in @("dart", "tar")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$App`: $tool not found -- it is what this script builds the release with"
        exit 1
    }
}

function Write-Step { param([string]$Message) Write-Host ""; Write-Host ">> $Message" }

# Everything at once: finding out about the second blocker on the second run is
# not a debugging loop worth having, and one of these runs the test suites.
$script:Failed = @()
function Add-Failure { param([string]$Message) $script:Failed += $Message }

# What a previewed package would hit. Reported in full, never fatal: a package
# carrying `publish_to: none` is not in the release, so nothing about it can
# block one.
$script:PreviewBlocked = @()
function Add-PreviewBlock { param([string]$Message) $script:PreviewBlocked += $Message }

# `key: value` out of a pubspec, comment and quotes stripped. Only ever used on
# the top-level scalars (name / version / publish_to), which are unindented.
function Get-PubspecField {
    param([string]$Pubspec, [string]$Key)
    foreach ($line in Get-Content -LiteralPath $Pubspec) {
        if ($line -match "^$Key\:\s*(.*)$") {
            return ($Matches[1] -replace '\s*#.*$', '').Trim().Trim('"', "'")
        }
    }
    return ""
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    & git -C $RootDir @GitArgs 2>$null
}

# --- the packages ---------------------------------------------------------

$AllPackages = Get-ChildItem -LiteralPath (Join-Path $RootDir "packages") -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "pubspec.yaml") } |
    ForEach-Object { $_.Name }

if ($Packages -eq "all") {
    $Selected = $AllPackages
} else {
    $Selected = @()
    foreach ($name in ($Packages -split ',')) {
        $name = $name.Trim()
        if (-not (Test-Path (Join-Path $RootDir "packages/$name/pubspec.yaml"))) {
            Write-Error "$App`: no such package '$name' (have: $($AllPackages -join ' '))"
            exit 2
        }
        $Selected += $name
    }
}

# --- what this release is called ------------------------------------------
#
# Tags here are per package -- `<package>-v<version>` -- because the versions are
# independent. So the ref only ever names ONE of the packages being built, and
# the check is against that one's pubspec; the rest are along for the ride.
$Tag = ""
if ($env:GITHUB_REF_TYPE -eq "tag" -and $env:GITHUB_REF_NAME) {
    $Tag = $env:GITHUB_REF_NAME
    $TagSource = "GITHUB_REF_NAME -- the ref this run was dispatched from"
} else {
    $described = Invoke-Git describe --exact-match --match '*-v[0-9]*' --tags HEAD
    if ($LASTEXITCODE -eq 0 -and $described) {
        $Tag = "$described".Trim()
        $TagSource = "the release tag HEAD is checked out at"
    } else {
        $TagSource = "HEAD is not on a release tag, so this is a build, not a release"
    }
}

Write-Host "options"
Write-Host "  out      => $Out"
Write-Host "  packages => $($Selected -join ' ')"
Write-Host "  checks   => $Checks"
Write-Host "  codegen  => $Codegen"
Write-Host "  sdk      => $Sdk"
Write-Host "  verify   => $Verify"
Write-Host "  clean    => $Clean"
Write-Host "  tag      => $(if ($Tag) { $Tag } else { '(none)' })"
Write-Host "              ($TagSource)"

if ($Tag) {
    $tagPkg = $Tag -replace '-v[^-]*$', ''
    $tagVersion = $Tag.Substring($Tag.LastIndexOf('-v') + 2)
    $tagPubspec = Join-Path $RootDir "packages/$tagPkg/pubspec.yaml"
    if (Test-Path $tagPubspec) {
        $have = Get-PubspecField $tagPubspec "version"
        if ($have -ne $tagVersion) {
            Write-Host ""
            Write-Error "$App`: tag $Tag does not match packages/$tagPkg (version $have). pub publishes the pubspec's version whatever the tag says, so the tag would name one release and pub.dev carry another. Bump, or retag."
            exit 1
        }
        Write-Host "              (matches packages/$tagPkg $have)"
    } else {
        Write-Host "              (names no package under packages/ -- not checked)"
    }
}

# --- the working tree -----------------------------------------------------
#
# A dirty tree is the one way a published package can contain something that is
# in no commit, which is unreproducible in exactly the way a release must not be.
# pub says the same thing as a warning; this says it first, and before anything
# below edits a pubspec, so that a preview can tell pub's complaint about the
# tree apart from its own.
Write-Step "checking the working tree"
$dirty = @(Invoke-Git status --porcelain | Where-Object { $_ })
if ($dirty.Count -gt 0) {
    Add-Failure ("the working tree is dirty -- commit or stash before releasing:`n" +
        (($dirty | ForEach-Object { "      $_" }) -join "`n"))
    Write-Host "   dirty ($($dirty.Count) path(s))"
} else {
    Write-Host "   clean"
}
$branch = "$(Invoke-Git rev-parse --abbrev-ref HEAD)".Trim()
if ($branch -ne "main") { Write-Host "   note: on '$branch', not main" }

# --- the pinned SDK release -----------------------------------------------
Write-Step "the SpriteStudio-SDK release the build hooks pin"
$SdkVersion = ""
foreach ($src in $SdkPinSources) {
    $path = Join-Path $RootDir $src
    if (-not (Test-Path $path)) { Add-Failure "$src is missing -- nothing pins an SDK release there"; continue }
    $pin = ""
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match "^const _sdkVersion = '(.*)';") { $pin = $Matches[1]; break }
    }
    if (-not $pin) { Add-Failure "no _sdkVersion found in $src"; continue }
    Write-Host "   $src => $pin"
    if (-not $SdkVersion) {
        $SdkVersion = $pin
    } elseif ($pin -ne $SdkVersion) {
        # One Brain, built once. Two hooks pinned to different releases ships a
        # runtime and a converter from different SDK builds.
        Add-Failure "the build hooks pin different SDK releases ($SdkVersion vs $pin) -- they must agree"
    }
}

# Only ssplayer_flutter carries the web Brain, so only a build that includes it
# needs one fetched.
$NeedWeb = $Selected -contains "ssplayer_flutter"

switch ($Sdk) {
    "download" {
        if ($SdkVersion) {
            foreach ($asset in @("SHA256SUMS", $SdkLibsZip)) {
                $url = "$SdkReleaseBase/$SdkVersion/$asset"
                $ok = $false
                try {
                    Invoke-WebRequest -Uri $url -Method Head -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 30 | Out-Null
                    $ok = $true
                } catch { $ok = $false }
                if ($ok) {
                    Write-Host "   $asset  ok"
                } else {
                    Write-Host "   $asset  MISSING"
                    # Every consumer without a Rust toolchain -- which is every
                    # consumer -- gets libssruntime from this release at
                    # `flutter pub get` time.
                    Add-Failure ("SpriteStudio-SDK $SdkVersion does not carry $asset (or the release does not exist).`n" +
                        "      Nothing downstream can build: packages/*/hook/build.dart download it for`n" +
                        "      every consumer who has no Rust toolchain. Publish the SDK release first,`n" +
                        "      or repin _sdkVersion.")
                }
            }
        }
        # The web Brain into the directory pub packs from -- the same script
        # publish.yml's ssplayer_flutter job runs, so this archive is that upload.
        if ($NeedWeb) {
            & (Join-Path $RootDir "scripts/download-web-runtime.ps1")
            if ($LASTEXITCODE) { Add-Failure "scripts/download-web-runtime.ps1 failed -- there is no web Brain to pack" }
        }
    }
    "build" {
        # No release check: sdk=build exists precisely for when there is no release.
        if ($NeedWeb) {
            Write-Host "   building the web Brain from the submodule (needs cargo + wasm-pack)"
            & (Join-Path $RootDir "scripts/build-runtime.ps1") platform=web build=release
            if ($LASTEXITCODE) { Add-Failure "scripts/build-runtime.ps1 platform=web failed -- there is no web Brain to pack" }
        } else {
            Write-Host "   sdk=build -- nothing selected needs a web Brain"
        }
    }
    "skip" {
        Write-Host "   sdk=skip -- the release is not checked, assets/runtime-web left as it stands"
    }
}

# --- the generated code ---------------------------------------------------
#
# ffigen bindings and flatc accessors are COMMITTED, so what matters is that the
# tree matches what today's inputs produce. A stale binding reads the Brain's
# structs at the wrong offsets and does it silently.
Write-Step "the committed generator output"
if ($Codegen -eq "skip") {
    Write-Host "   codegen=skip -- not regenerated"
} else {
    $headers = Get-ChildItem -Path (Join-Path $RootDir "packages") -Filter "*.h" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "[\\/]native[\\/]include[\\/]" } | Select-Object -First 1
    if (-not $headers) {
        Write-Host "   ffigen SKIPPED -- no packages/*/native/include/*.h (run scripts/build-runtime.ps1)"
    } else {
        & (Join-Path $RootDir "scripts/generate-ffigen-code.ps1") | Out-Null
        Invoke-Git diff --quiet -- @FfigenPaths | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ffigen bindings current"
        } else {
            Add-Failure "the ffigen bindings are stale -- regenerate and commit:`n      scripts/generate-ffigen-code.ps1"
        }
    }

    if (-not (Get-Command flatc -ErrorAction SilentlyContinue)) {
        Write-Host "   flatc SKIPPED -- flatc not on PATH"
    } else {
        & (Join-Path $RootDir "scripts/generate-fbs-code.ps1") | Out-Null
        Invoke-Git diff --quiet -- @FbsPaths | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   flatc accessors current"
        } else {
            Add-Failure "the flatc accessors are stale -- regenerate and commit:`n      scripts/generate-fbs-code.ps1"
        }
    }
}

# --- resolve --------------------------------------------------------------
# One workspace, one lockfile: resolving here is what lets the analyzer and the
# test suites run below, and `dart pub publish` re-resolves each package anyway.
Write-Step "resolving the workspace"
if (Get-Command flutter -ErrorAction SilentlyContinue) {
    & flutter pub get | Out-Null
    Write-Host "   flutter pub get"
} else {
    # Every Flutter member would fail to resolve, but a pure-Dart-only selection
    # still works -- worth trying rather than refusing outright.
    Write-Host "   flutter not on PATH -- falling back to dart pub get"
    & dart pub get | Out-Null
}

# --- output ---------------------------------------------------------------
if ($Clean -eq "yes" -and (Test-Path -LiteralPath $Out)) { Remove-Item -Recurse -Force -LiteralPath $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# Turn the tree `dart pub publish --dry-run` prints into one relative path per
# line. Depth comes from stripping the two indent units it draws with; a leaf
# carries a `(<size>)` suffix and a directory does not, which is what tells the
# two apart.
function Get-ManifestFromReport {
    param([string]$Report)
    $paths = @()
    $seg = @{}
    $capturing = $false
    foreach ($line in Get-Content -LiteralPath $Report) {
        if (-not $capturing) {
            if ($line -like "Publishing *") { $capturing = $true }
            continue
        }
        if ($line -like "Total compressed archive size:*") { break }
        if (-not $line) { continue }

        $rest = $line
        $depth = 0
        while ($true) {
            if ($rest.StartsWith([char]0x2502 + "   ")) { $rest = $rest.Substring(4); $depth++ }
            elseif ($rest.StartsWith("    "))           { $rest = $rest.Substring(4); $depth++ }
            else { break }
        }
        if ($rest.Length -lt 4) { continue }
        $marker = $rest.Substring(0, 4)
        if ($marker -ne ([char]0x251C + [string][char]0x2500 + [char]0x2500 + " ") -and
            $marker -ne ([char]0x2514 + [string][char]0x2500 + [char]0x2500 + " ")) { continue }
        $name = $rest.Substring(4)

        $isFile = $false
        $open = $name.LastIndexOf(" (")
        if ($open -ge 0 -and $name.EndsWith("B)")) {
            $isFile = $true
            $name = $name.Substring(0, $open)
        }
        $seg[$depth] = $name
        if ($isFile) {
            $full = $name
            for ($i = $depth - 1; $i -ge 0; $i--) { $full = "$($seg[$i])/$full" }
            $paths += $full
        }
    }
    return $paths
}

# A previewed package has its `publish_to: none` lifted for the length of its dry
# run, and put straight back -- however this exits.
#
# The backup lives OUTSIDE the package, and that is not tidiness: pub publishes
# every file git does not ignore, tracked or not, so a `pubspec.yaml.bak` beside
# the original would be listed in the manifest and packed into the archive.
$BakDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ssrel-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $BakDir | Out-Null
$script:PendingPubspec = ""
function Restore-Pubspec {
    if (-not $script:PendingPubspec) { return }
    $bak = Join-Path $BakDir "pubspec.yaml"
    if (Test-Path -LiteralPath $bak) { Move-Item -Force -LiteralPath $bak -Destination $script:PendingPubspec }
    $script:PendingPubspec = ""
}

$Summary = @()
$Archives = @()

try {
    foreach ($name in $Selected) {
        $pkgDir  = Join-Path $RootDir "packages/$name"
        $pubspec = Join-Path $pkgDir "pubspec.yaml"
        $version = Get-PubspecField $pubspec "version"
        $publishTo = Get-PubspecField $pubspec "publish_to"
        $state = if ($publishTo) { "preview" } else { "release" }

        Write-Step "$name $version  ($state)"

        if (-not $version) { Add-Failure "packages/$name has no version in its pubspec"; continue }

        # `flutter test` for a package that depends on the Flutter SDK, `dart
        # test` otherwise -- the same split CONTRIBUTING.md's Test section draws.
        $runner = "dart"
        if (Select-String -LiteralPath $pubspec -Pattern "sdk: flutter" -Quiet) { $runner = "flutter" }
        if ($runner -eq "flutter" -and -not (Get-Command flutter -ErrorAction SilentlyContinue)) {
            Write-Host "   flutter not on PATH -- $name cannot be analyzed or tested here"
            $runner = ""
        }

        if ($Checks -ne "skip" -and $runner) {
            Write-Host "   $runner analyze"
            Push-Location $pkgDir
            try { & $runner analyze; if ($LASTEXITCODE) { Add-Failure "$name`: analyze failed" } } finally { Pop-Location }
        }
        if ($Checks -eq "full" -and $runner -and (Test-Path (Join-Path $pkgDir "test"))) {
            Write-Host "   $runner test"
            Push-Location $pkgDir
            try { & $runner test; if ($LASTEXITCODE) { Add-Failure "$name`: tests failed" } } finally { Pop-Location }
        }

        # --- the publish itself, minus the upload ---------------------------
        $report = Join-Path $Out "$name-$version.publish.txt"
        $pubArgs = @("pub", "publish", "--dry-run")
        if ($state -eq "preview") {
            # Lift `publish_to: none`, and with it accept that pub will also
            # report the tree as modified -- this script made that edit, and
            # checked the tree was clean before making it. --ignore-warnings
            # keeps that one self-inflicted warning from masking the errors
            # underneath; every warning is still printed below, because for a
            # package that is not opted in yet they are the point.
            Copy-Item -LiteralPath $pubspec -Destination (Join-Path $BakDir "pubspec.yaml") -Force
            $script:PendingPubspec = $pubspec
            (Get-Content -LiteralPath (Join-Path $BakDir "pubspec.yaml") |
                Where-Object { $_ -notmatch '^publish_to:' }) |
                Set-Content -LiteralPath $pubspec -Encoding utf8
            $pubArgs += "--ignore-warnings"
        }

        Write-Host "   dart pub publish --dry-run"
        Push-Location $pkgDir
        try {
            & dart @pubArgs *>&1 | Out-File -LiteralPath $report -Encoding utf8
            $pubOk = ($LASTEXITCODE -eq 0)
        } finally { Pop-Location }

        Restore-Pubspec

        # Everything pub found, verbatim, so the reader never has to open the
        # report to learn there was something in it.
        $reportLines = Get-Content -LiteralPath $report
        $start = ($reportLines | Select-String -Pattern '^Package validation found' | Select-Object -First 1)
        if ($start) {
            $reportLines[($start.LineNumber - 1)..($reportLines.Count - 1)] |
                ForEach-Object { Write-Host "      $_" }
        }

        if (-not $pubOk) {
            if ($state -eq "preview") {
                Add-PreviewBlock "$name`: would not publish -- see $name-$version.publish.txt"
            } else {
                Add-Failure "$name`: dart pub publish would fail -- see $name-$version.publish.txt"
            }
        }

        # --- the file set ---------------------------------------------------
        $listPath = Join-Path $Out "$name-$version.files"
        # Ordinal, not culture-aware: `LC_ALL=C sort` is what the .sh twin uses,
        # and the two manifests should be the same bytes on either host.
        $files = [string[]](Get-ManifestFromReport $report)
        [Array]::Sort($files, [System.StringComparer]::Ordinal)
        [System.IO.File]::WriteAllText($listPath, (($files -join "`n") + "`n"))

        if ($files.Count -eq 0) {
            # No manifest means pub bailed before listing anything -- the errors
            # are in the report, and there is nothing to pack.
            Add-Failure "$name`: pub listed no files (it stopped before packing -- see $name-$version.publish.txt)"
            $Summary += ("  {0,-18} {1,-14} {2,-8} {3}" -f $name, $version, $state, "no archive")
            continue
        }

        $archive = "$name-$version.tar.gz"
        # pub's archive is flat -- pubspec.yaml at the root, no wrapping
        # directory -- so this one is too.
        & tar -czf (Join-Path $Out $archive) -C $pkgDir -T $listPath
        if ($LASTEXITCODE) { Add-Failure "$name`: tar failed to pack $archive"; continue }
        $Archives += $archive
        Write-Host "   $($files.Count) file(s) -> $archive"

        $Summary += ("  {0,-18} {1,-14} {2,-8} {3}" -f $name, $version, $state, $archive)
    }
} finally {
    Restore-Pubspec
    Remove-Item -Recurse -Force -LiteralPath $BakDir -ErrorAction SilentlyContinue
}

# --- checksums ------------------------------------------------------------
# `<hash>  <name>`, lower-cased and two-spaced, so the SHA256SUMS this writes is
# the one `sha256sum -c` (and the .sh twin) reads.
if ($Archives.Count -gt 0) {
    Write-Step "writing SHA256SUMS"
    $lines = foreach ($archive in $Archives) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $Out $archive) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $archive"
    }
    [System.IO.File]::WriteAllText((Join-Path $Out "SHA256SUMS"), (($lines -join "`n") + "`n"))
    Write-Host "   $($Archives.Count) archive(s)"
}

# --- verify ---------------------------------------------------------------
#
# The manifest above is what pub said it would send; this is what actually
# landed, and the two are not the same question -- a file pub lists but that has
# since been deleted packs as nothing at all.
if ($Verify -eq "yes" -and $Archives.Count -gt 0) {
    Write-Step "verifying $Out"

    foreach ($archive in $Archives) {
        $name = ($Selected | Where-Object { $archive.StartsWith("$_-") } | Select-Object -First 1)
        $entries = @(& tar -tzf (Join-Path $Out $archive))
        function Test-Entry    { param($p) return ($entries -contains $p) }
        function Test-EntryAny { param($p) return [bool]($entries | Where-Object { $_.StartsWith($p) }) }

        # What a consumer needs to have downloaded anything useful at all.
        if (-not (Test-Entry "pubspec.yaml")) { Add-Failure "$archive has no pubspec.yaml" }
        if (-not (Test-EntryAny "lib/"))      { Add-Failure "$archive contains nothing under lib/" }
        if (-not (Test-Entry "README.md"))    { Add-Failure "$archive has no README.md" }
        if (-not (Test-EntryAny "LICENSE"))   { Add-Failure "$archive carries no LICENSE" }

        # A hook that is not in the archive is a package that delivers no native
        # library, and nothing about the build says so.
        if (Test-Path (Join-Path $RootDir "packages/$name/hook/build.dart")) {
            if (-not (Test-Entry "hook/build.dart")) {
                Add-Failure "$archive has no hook/build.dart -- it would deliver no native asset"
            }
        }

        # packages/*/native is git-ignored build output. If one leaks into an
        # archive, every consumer gets one host's dylib instead of their own.
        if (Test-EntryAny "native/") {
            Add-Failure "$archive contains native/ -- that is local build output, not something to publish"
        }

        # The web Brain: three files ssruntime_dart's web_runtime.dart loads by
        # name. There are two ways they go missing from what a consumer
        # downloads, both silent -- the app builds, the animation simply never
        # starts -- so they are reported apart.
        if (Test-Path (Join-Path $RootDir "packages/$name/$WebRuntimeDir")) {
            foreach ($f in $WebRuntimeFiles) {
                $rel = "$WebRuntimeDir/$f"
                if (-not (Test-Entry $rel)) {
                    Add-Failure ("$archive has no $rel -- the web target would load nothing.`n" +
                        "      pub publishes nothing git ignores, and that whole directory is git-ignored`n" +
                        "      build output; the .pubignore beside it is what re-includes it. Build the`n" +
                        "      runtime too (scripts/build-runtime.ps1 platform=web) -- pub packs what is`n" +
                        "      on disk.")
                } elseif ((-not (Invoke-Git ls-files -- "packages/$name/$rel")) -and
                          (-not (Select-String -LiteralPath (Join-Path $RootDir ".github/workflows/publish.yml") -Pattern "download-web-runtime" -Quiet))) {
                    # git does not track these, so the ONLY reason the published
                    # package gets them is that publish.yml fetches them first --
                    # that job exists instead of dart-lang's reusable workflow,
                    # which has no step between its checkout and its `dart pub
                    # publish`. If that step ever goes, this archive still looks
                    # complete and what reaches pub.dev is an empty
                    # assets/runtime-web/, silently.
                    Add-Failure ("$rel is in $archive only because this working tree built it, and nothing in`n" +
                        "      .github/workflows/publish.yml fetches it any more. The package that reaches`n" +
                        "      pub.dev would carry an empty $WebRuntimeDir/. Restore the`n" +
                        "      download-web-runtime step in the ssplayer_flutter job, or track these files.")
                }
            }
        }

        # pub.dev refuses anything larger, and a package that grew past it grew
        # by accident.
        $bytes = (Get-Item -LiteralPath (Join-Path $Out $archive)).Length
        if ($bytes -gt $MaxArchiveBytes) {
            Add-Failure "$archive is $([math]::Round($bytes / 1MB)) MB -- pub.dev refuses anything over 100 MB"
        }
    }

    foreach ($line in Get-Content -LiteralPath (Join-Path $Out "SHA256SUMS")) {
        if (-not $line) { continue }
        $want, $file = $line -split '\s\s', 2
        $got = (Get-FileHash -LiteralPath (Join-Path $Out $file) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $want) { Add-Failure "SHA256SUMS does not verify for $file" }
    }
    if ($script:Failed.Count -eq 0) { Write-Host "   every archive complete, SHA256SUMS verified" }
} elseif ($Verify -eq "no") {
    Write-Step "verify=no -- the archives are not checked"
}

# --- done -----------------------------------------------------------------
Write-Host ""
Write-Host "$App`: what this build would publish"
$Summary | ForEach-Object { Write-Host $_ }
Write-Host ""

if ($script:PreviewBlocked.Count -gt 0) {
    Write-Host "$App`: previewed packages that would NOT publish as they stand:"
    $script:PreviewBlocked | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "$App`: none of that fails this run -- a package carrying 'publish_to: none' is"
    Write-Host "$App`: not in the release. Remove that line to opt one in, and it is checked"
    Write-Host "$App`: for real from the next run on."
    Write-Host ""
}

if ($script:Failed.Count -gt 0) {
    Write-Host "$App`: this release is not shippable:" -ForegroundColor Red
    $script:Failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host "$App`: done -> $Out  $(if ($Tag) { "($Tag)" } else { '(no tag)' })"
Write-Host ""
Get-ChildItem -LiteralPath $Out -Filter "*.tar.gz" | ForEach-Object { Write-Host ("  {0,12}  {1}" -f $_.Length, $_.Name) }
Write-Host ""
Write-Host "$App`: the archives are for inspection -- pub builds its own at publish time."
Write-Host "$App`: what ships is the tags: release.yml versions the packages and pushes"
Write-Host "$App`: '<package>-v<version>', and publish.yml publishes each one to pub.dev."
