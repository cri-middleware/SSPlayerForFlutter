#!/usr/bin/env pwsh
#
# Generate the android/ platform folder for an example on Windows. It is
# .gitignore'd like every other runner here (see the root .gitignore), so each
# checkout regenerates it — this script is the one command that does it.
#
# Usage:  pwsh examples/scripts/setup-mobile.ps1 <example> [-Android]
#   <example>   a subdir of examples/ (e.g. overall, flame)
#   -Android    generate android/ (the default, and the only option here)
#
# iOS is absent on purpose: it needs Xcode, so it exists only in the .sh beside
# this file. Both halves must change together.
#
# Idempotent — `flutter create` only fills in what is absent and never touches
# lib/ or pubspec.yaml.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Example,
    [switch]$Android
)
$ErrorActionPreference = 'Stop'

$ExamplesDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RootDir = (Resolve-Path (Join-Path $ExamplesDir '..')).Path
$ExampleDir = Join-Path $ExamplesDir $Example

if (-not (Test-Path (Join-Path $ExampleDir 'pubspec.yaml'))) {
    Write-Error "[setup-mobile] no example at $ExampleDir"
}

# -Android is the only target here, so it is implied when nothing is passed.
$Platforms = 'android'

Push-Location $ExampleDir
try {
    # `flutter create` rewrites .metadata's migration list to EXACTLY the
    # platforms it is handed, dropping the entry for every runner it is not told
    # about — so a run for android alone silently removes macos from a project
    # that has macos/. Carry the runners already on disk; nothing is generated
    # twice, because create only fills in what is absent.
    $Carry = @($Platforms)
    foreach ($p in @('android', 'ios', 'macos', 'windows', 'linux', 'web')) {
        if ($Carry -notcontains $p -and (Test-Path -PathType Container $p)) {
            $Carry += $p
        }
    }
    & flutter create --platforms=($Carry -join ',') .
    if ($LASTEXITCODE -ne 0) { Write-Error "[setup-mobile] flutter create failed" }
}
finally { Pop-Location }

# The native Brain is the part `flutter create` cannot produce. hook/build.dart
# prefers a local build and falls back to downloading the pinned SDK release —
# which is not published yet, so before the first release a local cross build is
# the ONLY route here. Say so now rather than let the build fail 90 seconds
# later inside Gradle with an HTTP 404.
$RtLibs = Join-Path $RootDir 'packages/ssruntime_dart/native/libs'
if (-not (Test-Path (Join-Path $RtLibs $Platforms))) {
    Write-Host "[setup-mobile] no libssruntime for $Platforms yet — build it with:"
    Write-Host "[setup-mobile]   pwsh scripts/build-runtime.ps1 platform=$Platforms"
    Write-Host "[setup-mobile] (needs Rust + the $Platforms cross targets and a real"
    Write-Host "[setup-mobile]  NDK on `$env:ANDROID_NDK_HOME)"
}

Write-Host "[setup-mobile] done — $Example/$Platforms ready (run: flutter run -d <device>)"
