#!/usr/bin/env pwsh
#
# Generate the Layer-1 dart:ffi bindings (ffigen) for EVERY package that carries
# an ffigen config, from the plain-C headers the native build already produced
# (packages/*/native/include/*.h -> that package's lib/src/*_bindings.g.dart).
# PowerShell counterpart of scripts/generate-ffigen-code.sh. Runs NO cbindgen —
# the SpriteStudio-SDK build.rs emits the C headers and build-runtime.ps1 copies
# them into each package. STANDALONE (NOT part of build-runtime, like
# generate-fbs-code): run after a C-API change or an ffigen*.yaml edit, then commit.
#
# The generated bindings are COMMITTED (so a normal checkout / pub.dev consumer
# builds without ffigen). .fbs accessors are separate — see scripts/generate-fbs-code.ps1.
#
# Prerequisites: Dart/Flutter SDK (ffigen needs libclang; `dart pub get` first).

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Write-Host "generate-ffigen-code.ps1: dart not found — skipping ffigen (bindings are regenerated once the Dart SDK is installed)"
    exit 0
}

$configs = Get-ChildItem -Path (Join-Path $RootDir "packages") -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "ffigen*.yaml" -File -ErrorAction SilentlyContinue }
if (-not $configs) {
    Write-Host "generate-ffigen-code.ps1: no packages/*/ffigen*.yaml — nothing to do"
    exit 0
}

Write-Host "Generating ffigen bindings (dart run ffigen)..."
foreach ($cfg in $configs) {
    $pkgDir = $cfg.Directory.FullName
    $pkg = $cfg.Directory.Name
    Push-Location $pkgDir
    try {
        & dart pub get 2>&1 | Out-Null
        & dart run ffigen --config $cfg.Name
        if ($LASTEXITCODE) { Write-Host "   ($pkg/$($cfg.Name) skipped — check the ffigen dev_dependency + native/include/*.h)" }
        else { Write-Host "   -> $pkg ($($cfg.Name))" }
    } finally { Pop-Location }
}

Write-Host "generate-ffigen-code.ps1: done."
