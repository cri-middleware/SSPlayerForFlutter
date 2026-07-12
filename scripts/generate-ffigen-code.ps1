#!/usr/bin/env pwsh
#
# Generate the Layer-1 dart:ffi bindings (ffigen) from the plain-C headers the
# native build already produced (native/include/*.h -> lib/src/bindings/*.g.dart).
# PowerShell counterpart of scripts/generate-ffigen-code.sh. Runs NO cbindgen —
# the SpriteStudio-SDK build.rs emits the C headers and build-runtime.ps1 /
# download-sdk.ps1 copy them in. Invoked automatically at the end of those two;
# run directly only when you changed an ffigen*.yaml but not the native library.
#
# The generated bindings are gitignored — regenerated from the native C-API on
# every build. .fbs accessors are separate — see scripts/generate-fbs-code.ps1.
#
# Prerequisites: Dart/Flutter SDK (ffigen needs libclang; `dart pub get` first).

$ErrorActionPreference = "Stop"

$RootDir    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$PkgDir     = Join-Path $RootDir "packages/ssplayer_flutter"
$IncludeDir = Join-Path $PkgDir "native/include"

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Write-Host "generate-ffigen-code.ps1: dart not found — skipping ffigen (bindings are regenerated once the Dart SDK is installed)"
    exit 0
}

# ffigen reads native/include/*.h; warn (don't fail) if the native build has not
# placed them yet — running build-runtime.ps1 / download-sdk.ps1 first is expected.
if (-not (Test-Path (Join-Path $IncludeDir "ssruntime.h"))) {
    Write-Warning "generate-ffigen-code.ps1: $IncludeDir/ssruntime.h not found — run build-runtime.ps1 or download-sdk.ps1 first"
}

$configs = Get-ChildItem -Path $PkgDir -Filter "ffigen*.yaml" -ErrorAction SilentlyContinue
if (-not $configs) {
    Write-Host "generate-ffigen-code.ps1: no ffigen*.yaml under $PkgDir — nothing to do"
    exit 0
}

Write-Host "Generating ffigen bindings (dart run ffigen)..."
Push-Location $PkgDir
try {
    & dart pub get 2>&1 | Out-Null
    foreach ($cfg in $configs) {
        & dart run ffigen --config $cfg.Name
        if ($LASTEXITCODE) { Write-Host "   (ffigen $($cfg.Name) skipped — check that ffigen is a dev_dependency)" }
        else { Write-Host "   -> ffigen($($cfg.Name))" }
    }
} finally { Pop-Location }

Write-Host "generate-ffigen-code.ps1: done."
