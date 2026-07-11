#!/usr/bin/env pwsh
#
# Generate the source code that the Flutter package needs to talk to the Brain:
#
#   1. C headers (ffigen input) from the Rust C-API, via `cbindgen --lang c`
#        -> packages/ssplayer_flutter/native/include/ssruntime.h
#        -> packages/ssplayer_flutter/native/include/ssconverter.h
#   2. Dart FlatBuffers accessors for the .ssab metadata + runtime FrameData /
#      EffectDrawPlan, via `flatc --dart`
#        -> packages/ssplayer_flutter/lib/src/ssab/<schema>.g.dart
#   3. (optional) the ffigen Dart bindings (Layer 1) when the Dart SDK is present
#        -> packages/ssplayer_flutter/lib/src/bindings/ssruntime_bindings.g.dart
#
# PowerShell counterpart of scripts/generate-runtime-code.sh.
#
# Prerequisites: cbindgen (`cargo install cbindgen`), flatc (Google FlatBuffers).
# ffigen additionally needs the Dart/Flutter SDK + `dart pub get`.
#
# SDK location: $env:SSSDK, else .\SpriteStudio-SDK, else ..\SpriteStudio-SDK.

$ErrorActionPreference = "Stop"

$RootDir    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$PkgDir     = Join-Path $RootDir "packages/ssplayer_flutter"
$IncludeDir = Join-Path $PkgDir "native/include"
$SsabOutDir = Join-Path $PkgDir "lib/src/ssab"

# --- locate the SDK -------------------------------------------------------
$SdkDir = $env:SSSDK
if (-not $SdkDir) {
    foreach ($cand in @((Join-Path $RootDir "SpriteStudio-SDK"), (Join-Path $RootDir "../SpriteStudio-SDK"))) {
        if (Test-Path (Join-Path $cand "Cargo.toml")) { $SdkDir = (Resolve-Path $cand).Path; break }
    }
}
if (-not $SdkDir -or -not (Test-Path (Join-Path $SdkDir "Cargo.toml"))) {
    Write-Error "generate-runtime-code.ps1: SpriteStudio-SDK not found (init the submodule or set `$env:SSSDK)"
}

New-Item -ItemType Directory -Force -Path $IncludeDir, $SsabOutDir | Out-Null

# --- 1. C headers via cbindgen (ffigen prefers plain C over the C++ output) --
if (Get-Command cbindgen -ErrorAction SilentlyContinue) {
    Write-Host "Generating C headers (cbindgen --lang c)..."
    Push-Location "$SdkDir/libs/ssruntime"
    try {
        & cbindgen --lang c --crate ssruntime --output "$IncludeDir/ssruntime.h"
        if ($LASTEXITCODE) { throw "cbindgen ssruntime failed" }
        Write-Host "   -> native/include/ssruntime.h"
    } finally { Pop-Location }
    if (Test-Path "$SdkDir/libs/ssconverter") {
        Push-Location "$SdkDir/libs/ssconverter"
        try {
            & cbindgen --lang c --crate ssconverter --output "$IncludeDir/ssconverter.h"
            if ($LASTEXITCODE) { Write-Host "   (ssconverter header skipped)" }
            else { Write-Host "   -> native/include/ssconverter.h" }
        } finally { Pop-Location }
    }
} else {
    Write-Warning "generate-runtime-code.ps1: cbindgen not found — skipping C headers (run: cargo install cbindgen)"
}

# --- 2. Dart FlatBuffers accessors via flatc --------------------------------
if (Get-Command flatc -ErrorAction SilentlyContinue) {
    Write-Host "Generating Dart FlatBuffers (flatc --dart)..."
    $tmpFb = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $tmpFb | Out-Null
    try {
        foreach ($f in @(
            "$SdkDir/libs/ssab/fbs/ssab.fbs",
            "$SdkDir/libs/ssab/fbs/ssqb.fbs",
            "$SdkDir/libs/ssruntime/fbs/framedata.fbs",
            "$SdkDir/libs/ssruntime/fbs/effect_draw_plan.fbs")) {
            if (-not (Test-Path $f)) { continue }
            $name = [System.IO.Path]::GetFileNameWithoutExtension($f)
            & flatc --dart -o $tmpFb $f
            if ($LASTEXITCODE) { throw "flatc failed for $f" }
            # flatc emits <name>_<namespace>_generated.dart; normalise to <name>.g.dart
            $gen = Get-ChildItem -Path $tmpFb -Filter "${name}_*_generated.dart" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($gen) {
                Move-Item $gen.FullName (Join-Path $SsabOutDir "$name.g.dart") -Force
                Write-Host "   -> lib/src/ssab/$name.g.dart"
            }
        }
    } finally { Remove-Item -Recurse -Force $tmpFb -ErrorAction SilentlyContinue }
} else {
    Write-Warning "generate-runtime-code.ps1: flatc not found — skipping Dart FlatBuffers (install Google FlatBuffers)"
}

# --- 3. ffigen Dart bindings (Layer 1), only when the Dart SDK is available --
if ((Get-Command dart -ErrorAction SilentlyContinue) -and (Test-Path "$PkgDir/ffigen.yaml")) {
    Write-Host "Generating ffigen bindings (dart run ffigen)..."
    Push-Location $PkgDir
    try {
        & dart pub get 2>&1 | Out-Null
        & dart run ffigen --config ffigen.yaml
        if ($LASTEXITCODE) { Write-Host "   (ffigen skipped — check that ffigen is a dev_dependency)" }
        else { Write-Host "   -> lib/src/bindings/ssruntime_bindings.g.dart" }
    } finally { Pop-Location }
} else {
    Write-Host "generate-runtime-code.ps1: dart not found — skipping ffigen (bindings are hand-authored until then)"
}

Write-Host "generate-runtime-code.ps1: done."
