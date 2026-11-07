#!/usr/bin/env pwsh
#
# Generate the Dart FlatBuffers accessors (flatc --dart), routing each schema to
# the package that owns it:
#   libs/ssab/fbs/{ssab,ssqb}.fbs                -> ssplayer_flutter/lib/src/ssab/
#   libs/ssruntime/fbs/{framedata,effect_draw_plan}.fbs -> ssruntime_dart/lib/src/fbs/
# Each generated file is then piped through scripts/strip_fbs_builders.dart,
# which removes the write-side <Type>Builder / <Type>ObjectBuilder classes flatc
# always emits (~2/3 of the output): these schemas are read-only on the Dart side.
#
# PowerShell counterpart of scripts/generate-fbs-code.sh. These track the .fbs
# SCHEMAS (not the native library), so run only when a schema changes — it is
# deliberately NOT part of build-runtime. Output IS committed.
# ffigen bindings are separate — see scripts/generate-ffigen-code.ps1.
#
# Prerequisites: flatc (Google FlatBuffers), dart.
# SDK location: $env:SSSDK, else .\SpriteStudio-SDK, else ..\SpriteStudio-SDK.

$ErrorActionPreference = "Stop"

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine("$(Split-Path -Leaf $PSCommandPath): takes no arguments — what it does is in its header comment")
    exit 2
}

$RootDir     = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$SsabOutDir  = Join-Path $RootDir "packages/ssplayer_flutter/lib/src/ssab"   # asset format (Player)
$RtFbsOutDir = Join-Path $RootDir "packages/ssruntime_dart/lib/src/fbs"      # runtime output
# The write-side classes land here instead of lib/ — only tests build buffers.
$BuildersOutDir = Join-Path $RootDir "packages/ssplayer_flutter/test/support"

# `reader` is the library a test imports; the write-side shim re-exports it so
# only the URI changes. Every schema gets a shim, including ones nothing reads
# yet (ssqb), so the fixture builders are there when something does.
$ReaderLibrary = @{
    "ssab"             = "package:ssplayer_flutter/src/ssab/ssab.g.dart"
    "ssqb"             = "package:ssplayer_flutter/src/ssab/ssqb.g.dart"
    "framedata"        = "package:ssruntime_dart/framedata.dart"
    "effect_draw_plan" = "package:ssruntime_dart/effect_draw_plan.dart"
}

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
if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Write-Error "generate-fbs-code.ps1: dart not found — needed to strip the generated write-side classes"
}

New-Item -ItemType Directory -Force -Path $SsabOutDir, $RtFbsOutDir, $BuildersOutDir | Out-Null
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
        # Route by schema origin: runtime output -> ssruntime_dart, asset format -> Player.
        $out = if ($name -in @("framedata", "effect_draw_plan")) { $RtFbsOutDir } else { $SsabOutDir }
        & flatc --dart -o $tmpFb $f
        if ($LASTEXITCODE) { throw "flatc failed for $f" }
        # flatc emits <name>_<namespace>_generated.dart; normalise to <name>.g.dart
        $gen = Get-ChildItem -Path $tmpFb -Filter "${name}_*_generated.dart" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gen) {
            $dest = Join-Path $out "$name.g.dart"
            Move-Item $gen.FullName $dest -Force
            Write-Host "   -> $out/$name.g.dart"
            # Split the serializer half out of lib/ — these schemas are read-only there.
            & dart (Join-Path $RootDir "scripts/strip_fbs_builders.dart") `
                "--builders-out=$(Join-Path $BuildersOutDir "${name}_builders.g.dart")" `
                "--reader-library=$($ReaderLibrary[$name])" $dest
            if ($LASTEXITCODE) { throw "strip_fbs_builders failed for $dest" }
        }
    }
} finally { Remove-Item -Recurse -Force $tmpFb -ErrorAction SilentlyContinue }

Write-Host "generate-fbs-code.ps1: done."
