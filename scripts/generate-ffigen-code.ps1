#!/usr/bin/env pwsh
#
# Generate the Layer-1 dart:ffi bindings (ffigen) for EVERY package that carries
# an ffigen generator (tool/ffigen.dart), from the plain-C headers the native
# build already produced
# (packages/*/native/include/*.h -> that package's lib/src/*_bindings.g.dart).
# PowerShell counterpart of scripts/generate-ffigen-code.sh. The
# SpriteStudio-SDK build.rs emits the C headers and build-runtime.ps1 copies
# them into each package. STANDALONE (NOT part of build-runtime, like
# generate-fbs-code): run after a C-API change or a tool/ffigen.dart edit, then commit.
#
# The generated bindings are COMMITTED (so a normal checkout / pub.dev consumer
# builds without ffigen). .fbs accessors are separate — see scripts/generate-fbs-code.ps1.
#
# Prerequisites: Dart/Flutter SDK (ffigen needs libclang; `dart pub get` first).

$ErrorActionPreference = "Stop"

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine("$(Split-Path -Leaf $PSCommandPath): takes no arguments — what it does is in its header comment")
    exit 2
}

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Write-Host "generate-ffigen-code.ps1: dart not found — skipping ffigen (bindings are regenerated once the Dart SDK is installed)"
    exit 0
}

$generators = Get-ChildItem -Path (Join-Path $RootDir "packages") -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName "tool") -Filter "ffigen.dart" -File -ErrorAction SilentlyContinue }
if (-not $generators) {
    Write-Host "generate-ffigen-code.ps1: no packages/*/tool/ffigen.dart — nothing to do"
    exit 0
}

Write-Host "Generating ffigen bindings (dart run tool/ffigen.dart)..."
foreach ($gen in $generators) {
    $pkgDir = $gen.Directory.Parent.FullName
    $pkg = $gen.Directory.Parent.Name
    Push-Location $pkgDir
    try {
        & dart pub get 2>&1 | Out-Null
        & dart run tool/ffigen.dart
        if ($LASTEXITCODE) { Write-Host "   ($pkg/tool/ffigen.dart skipped — check the ffigen dev_dependency + native/include/*.h)" }
        else { Write-Host "   -> $pkg (tool/ffigen.dart)" }
    } finally { Pop-Location }
}

Write-Host "generate-ffigen-code.ps1: done."
