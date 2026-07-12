#!/usr/bin/env pwsh
#
# Generate the Dart FlatBuffers accessors (flatc --dart) for the .ssab metadata +
# runtime FrameData / EffectDrawPlan schemas
#   (SpriteStudio-SDK/libs/**/fbs/*.fbs -> lib/src/ssab/<schema>.g.dart).
# PowerShell counterpart of scripts/generate-fbs-code.sh. These track the .fbs
# SCHEMAS (not the native library), so run only when a schema changes — it is
# deliberately NOT part of build-runtime / download-sdk. Output IS committed.
# ffigen bindings are separate — see scripts/generate-ffigen-code.ps1.
#
# Prerequisites: flatc (Google FlatBuffers).
# SDK location: $env:SSSDK, else .\SpriteStudio-SDK, else ..\SpriteStudio-SDK.

$ErrorActionPreference = "Stop"

$RootDir    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$PkgDir     = Join-Path $RootDir "packages/ssplayer_flutter"
$SsabOutDir = Join-Path $PkgDir "lib/src/ssab"

# --- locate the SDK -------------------------------------------------------
$SdkDir = $env:SSSDK
if (-not $SdkDir) {
    foreach ($cand in @((Join-Path $RootDir "SpriteStudio-SDK"), (Join-Path $RootDir "../SpriteStudio-SDK"))) {
        if (Test-Path (Join-Path $cand "Cargo.toml")) { $SdkDir = (Resolve-Path $cand).Path; break }
    }
}
if (-not $SdkDir -or -not (Test-Path (Join-Path $SdkDir "Cargo.toml"))) {
    Write-Error "generate-fbs-code.ps1: SpriteStudio-SDK not found (init the submodule or set `$env:SSSDK)"
}
if (-not (Get-Command flatc -ErrorAction SilentlyContinue)) {
    Write-Error "generate-fbs-code.ps1: flatc not found — install Google FlatBuffers"
}

New-Item -ItemType Directory -Force -Path $SsabOutDir | Out-Null
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

Write-Host "generate-fbs-code.ps1: done."
