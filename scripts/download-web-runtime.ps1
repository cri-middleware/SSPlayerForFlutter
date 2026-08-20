#!/usr/bin/env pwsh
#
# Put the web Brain into packages/ssplayer_flutter/assets/runtime-web/ -- the
# wasm-bindgen build of libssruntime the browser loads, taken from the
# SpriteStudio-SDK release the native-asset hooks are pinned to. PowerShell
# counterpart of scripts/download-web-runtime.sh; same options, same layout.
#
#   scripts/download-web-runtime.ps1            # the pinned release
#   scripts/download-web-runtime.ps1 force=no   # leave an existing runtime alone
#
# Its own script rather than a function inside a caller because there are
# several: scripts/build-release.ps1 sdk=download (pub packs what is on disk, and
# this directory is git-ignored build output), scripts/build-pages.sh
# sdk=download, and publish.yml's ssplayer_flutter job -- which publishes from a
# clean checkout where this directory is empty.
#
# The three files are what ssruntime_dart's web_runtime.dart loads BY NAME, and
# their names are not the release's: the SDK ships the SIMD build and the
# fallback as two separate packages, each with its own ssruntime_bg.wasm, and
# this flattens them into the one-directory layout the loader's runtime SIMD
# probe expects. build-runtime.ps1 platform=web lays them out the same way.

$ErrorActionPreference = "Stop"

$App = Split-Path -Leaf $PSCommandPath
$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

$DestDir = "packages/ssplayer_flutter/assets/runtime-web"
$SdkReleaseBase = "https://github.com/cri-middleware/SpriteStudio-SDK/releases/download"
$SdkWebZip = "spritestudio-sdk-web-libs.zip"
# The release everything is pinned to. Read from the build hook rather than
# repeated: the host libraries come from this same tag.
$SdkVersionSource = "packages/ssruntime_dart/hook/build.dart"

$Force = "yes"

function Show-Usage {
    Write-Host "Usage: $App [options]"
    Write-Host "$App options:"
    Write-Host "  force=<yes|no>          Download even when $DestDir"
    Write-Host "                          already holds a runtime (default: $Force). no makes"
    Write-Host "                          this a no-op in that case -- for a caller that only"
    Write-Host "                          needs SOME runtime there, not the pinned one."
    Write-Host "  -h | --help             Show this help"
    Write-Host ""
    Write-Host "There is no version option: the release is the one"
    Write-Host "$SdkVersionSource pins, because that is the one the"
    Write-Host "rest of the build already depends on."
}

foreach ($item in $args) {
    switch -Regex ($item) {
        '^(-h|--help|help)$' { Show-Usage; exit 0 }
        '^force=.*$'         { $Force = $item.Substring(6).ToLowerInvariant() }
        default {
            Write-Error "$App`: unknown argument '$item' (see $App --help)"
            exit 2
        }
    }
}
if ($Force -notin @("yes", "no")) { Write-Error "$App`: force must be yes or no (got '$Force')"; exit 2 }

Set-Location $RootDir

$dest = Join-Path $RootDir $DestDir
if ($Force -eq "no" -and (Test-Path (Join-Path $dest "ssruntime_bg.wasm"))) {
    Write-Host "$App`: $DestDir already holds a runtime -- force=no, leaving it"
    exit 0
}

$version = ""
foreach ($line in Get-Content -LiteralPath (Join-Path $RootDir $SdkVersionSource)) {
    if ($line -match "^const _sdkVersion = '(.*)';") { $version = $Matches[1]; break }
}
if (-not $version) {
    Write-Error "$App`: no _sdkVersion found in $SdkVersionSource"
    exit 1
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sswebrt-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp $SdkWebZip
    Write-Host ""
    Write-Host ">> downloading $SdkWebZip ($version)"
    try {
        Invoke-WebRequest -Uri "$SdkReleaseBase/$version/$SdkWebZip" -OutFile $zip -UseBasicParsing
    } catch {
        # Reached from CI as well as from a working tree, so it says what is
        # wrong rather than assuming the reader can just build the runtime
        # instead -- on a runner there is no Rust toolchain to build it with.
        Write-Host ""
        Write-Error @"
$App`: could not download $SdkWebZip from SpriteStudio-SDK $version.
That release is the one $SdkVersionSource pins, and its assets are attached by
the SDK's own release.yml -- check the release exists and carries $SdkWebZip.
In a working tree with cargo + wasm-pack,
'scripts/build-runtime.ps1 platform=web build=release' compiles it instead.
"@
        exit 1
    }

    # The same integrity check hook/build.dart runs on the dynamic-libs archive.
    # A release without SHA256SUMS is reported rather than treated as verified.
    $sums = Join-Path $tmp "SHA256SUMS"
    $haveSums = $true
    try { Invoke-WebRequest -Uri "$SdkReleaseBase/$version/SHA256SUMS" -OutFile $sums -UseBasicParsing } catch { $haveSums = $false }
    if ($haveSums) {
        $want = ""
        foreach ($line in Get-Content -LiteralPath $sums) {
            if ($line -match "\s$([regex]::Escape($SdkWebZip))\s*$") { $want = ($line -split '\s+')[0]; break }
        }
        $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $want) {
            Write-Warning "$App`: SHA256SUMS carries no line for $SdkWebZip -- not verified"
        } elseif ($want.ToLowerInvariant() -ne $got) {
            Write-Error "$App`: $SdkWebZip does not match SHA256SUMS ($got != $want)"
            exit 1
        } else {
            Write-Host "   sha256 ok"
        }
    } else {
        Write-Warning "$App`: no SHA256SUMS for $version -- the archive was not verified"
    }

    $unpacked = Join-Path $tmp "unpacked"
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
    foreach ($f in @("runtime-web/ssruntime.js", "runtime-web/ssruntime_bg.wasm", "runtime-web-nosimd/ssruntime_bg.wasm")) {
        if (-not (Test-Path (Join-Path $unpacked $f))) {
            Write-Error "$App`: $SdkWebZip has no $f -- the release layout may have changed"
            exit 1
        }
    }

    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Force (Join-Path $unpacked "runtime-web/ssruntime.js")          (Join-Path $dest "ssruntime.js")
    Copy-Item -Force (Join-Path $unpacked "runtime-web/ssruntime_bg.wasm")     (Join-Path $dest "ssruntime_bg.wasm")
    Copy-Item -Force (Join-Path $unpacked "runtime-web-nosimd/ssruntime_bg.wasm") (Join-Path $dest "ssruntime_bg.nosimd.wasm")
    Write-Host "   -> $DestDir/ (ssruntime.js + ssruntime_bg.wasm + ssruntime_bg.nosimd.wasm)"
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
