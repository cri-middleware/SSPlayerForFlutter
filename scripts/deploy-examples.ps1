#!/usr/bin/env pwsh
#
# Stage the SDK's bundled test projects (tests/overall, tests/Ringo) into the
# example's SpriteStudio_Source/, then convert THOSE copies into .ssab assets,
# using the Dart `ssconvert` CLI (ssconverter_dart). SpriteStudio_Source is the
# single source of truth the desktop live-reload (example reassemble()) reconverts
# on hot reload, so the initial assets and the live output come from the same place.
# It loads the PREBUILT libssconverter over dart:ffi, so this needs NO Rust
# toolchain — build the native libs via scripts/build-runtime.ps1.
# All the sibling players share this "Rust-free for customizers" philosophy.
# Output lands in examples/overall/assets/spritestudio/<stem>/ (the SsProjectSync
# convention — <stem> is the .sspj filename, so it matches what live-reload
# regenerates; both dirs are referenced by examples/overall/pubspec.yaml).
# PowerShell counterpart of scripts/deploy-examples.sh.
#
# Prerequisites: the Dart/Flutter SDK; native libs built (scripts/build-runtime.ps1).
# SDK location (for the source .sspj): $env:SSSDK, else .\SpriteStudio-SDK, else
# ..\SpriteStudio-SDK.

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ConvPkg = Join-Path $RootDir "packages/ssconverter_dart"

# Projects to deploy. The output/stage name is the .sspj STEM (filename minus
# .sspj) so it matches SsProjectSync's live-reload convention
# (Ringo.sspj -> assets/spritestudio/Ringo/).
$Projects = @(
    @{ Sub = "overall"; Sspj = "overall.sspj" },
    @{ Sub = "Ringo";   Sspj = "Ringo.sspj" }
)

# --- locate the SDK -------------------------------------------------------
$SdkDir = $env:SSSDK
if (-not $SdkDir) {
    foreach ($cand in @((Join-Path $RootDir "SpriteStudio-SDK"), (Join-Path $RootDir "../SpriteStudio-SDK"))) {
        if (Test-Path (Join-Path $cand "Cargo.toml")) { $SdkDir = (Resolve-Path $cand).Path; break }
    }
}
if (-not $SdkDir -or -not (Test-Path (Join-Path $SdkDir "tests/overall/overall.sspj"))) {
    Write-Error "deploy-examples.ps1: overall.sspj not found (init the SpriteStudio-SDK submodule or set `$env:SSSDK)"
}
if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Write-Error "deploy-examples.ps1: dart not found (install the Dart/Flutter SDK)"
}

# Resolve the converter package deps once (the CLI loads the PREBUILT
# libssconverter via native assets — hook/build.dart bundles the dylib that
# build-runtime.ps1 produces; no SSCONVERTER_LIBRARY_PATH needed).
Push-Location $ConvPkg
try { & dart pub get 2>&1 | Out-Null } finally { Pop-Location }

# Stage a source project, then convert THAT copy (not the SDK original):
#  1) SpriteStudio_Source/<stem>/ is the single source of truth the desktop
#     live-reload (example reassemble()) reconverts on hot reload. Copy the
#     project dir wholesale so its referenced .ssae/.ssce/.png travel with it.
#  2) Convert into examples/overall/assets/spritestudio/<stem>/ — the same SsProjectSync
#     convention + location the hot-reload path reuses. The non-embedded
#     converter also copies the referenced textures/fonts/sounds into the output,
#     so this single call produces the complete asset tree.
function Deploy-Project {
    param([string]$SdkSub, [string]$Sspj)

    $stem       = [System.IO.Path]::GetFileNameWithoutExtension($Sspj)
    $srcProject = Join-Path $SdkDir "tests/$SdkSub"
    if (-not (Test-Path (Join-Path $srcProject $Sspj))) {
        Write-Error "deploy-examples.ps1: $SdkSub/$Sspj not found (init the SpriteStudio-SDK submodule or set `$env:SSSDK)"
    }
    $stage = Join-Path $RootDir "examples/overall/SpriteStudio_Source/$stem"
    $out   = Join-Path $RootDir "examples/overall/assets/spritestudio/$stem"

    Write-Host "Staging $SdkSub -> examples/overall/SpriteStudio_Source/$stem/ ..."
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -Path (Join-Path $srcProject '*') -Destination $stage -Recurse -Force

    Write-Host "Converting SpriteStudio_Source/$stem/$Sspj via ssconvert (Dart) ..."
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    Push-Location $ConvPkg
    try {
        & dart run ssconverter_dart:ssconvert -o $out (Join-Path $stage $Sspj)
        if ($LASTEXITCODE) { throw "ssconvert failed for $stage/$Sspj" }
    } finally { Pop-Location }
    Write-Host "   -> examples/overall/assets/spritestudio/$stem/"
}

foreach ($p in $Projects) {
    Deploy-Project -SdkSub $p.Sub -Sspj $p.Sspj
}

# The single-pack examples (flame, part_following) each need just one
# self-contained pack, not the whole overall tree. Reuse the Ringo output the
# loop just produced (a character animation + its reference PNG) — copy, don't
# reconvert, so it stays a single source of truth. Skipped cleanly if Ringo
# wasn't deployed.
$RingoSrc = Join-Path $RootDir "examples/overall/assets/spritestudio/Ringo"
if (Test-Path $RingoSrc) {
    foreach ($example in @("flame", "part_following")) {
        $dst = Join-Path $RootDir "examples/$example/assets/spritestudio/Ringo"
        Write-Host "Copying Ringo -> examples/$example/assets/spritestudio/Ringo/ ..."
        Remove-Item -Recurse -Force $dst -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item -Path (Join-Path $RingoSrc '*') -Destination $dst -Recurse -Force
        Write-Host "   -> examples/$example/assets/spritestudio/Ringo/"
    }
}

Write-Host "deploy-examples.ps1: done."
