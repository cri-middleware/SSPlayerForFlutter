#!/usr/bin/env pwsh
#
# Download the prebuilt SpriteStudio-SDK native libraries + headers and unpack
# them into the Flutter package so the app can be built without a Rust toolchain.
# PowerShell counterpart of scripts/download-sdk.sh:
#   - target version comes from the repo-root SDK_VERSION.txt
#   - the cache stamp lives at packages/ssplayer_flutter/native/VERSION
#     (build-runtime.ps1 writes the same file), so a matching version skips the
#     download.
#   - artifacts land in packages/ssplayer_flutter/native/ (libs/<platform>/...,
#     include/, VERSION).

$ErrorActionPreference = "Stop"

$RootDir            = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$NativeDir          = Join-Path $RootDir "packages/ssplayer_flutter/native"
$VersionFile        = Join-Path $RootDir "SDK_VERSION.txt"
$CurrentVersionFile = Join-Path $NativeDir "VERSION"

$TargetVersion = (Get-Content $VersionFile).Trim()

# skip if the cached libs already match the requested version
if (Test-Path $CurrentVersionFile) {
    if ((Get-Content $CurrentVersionFile).Trim() -eq $TargetVersion) {
        Write-Host "SDK $TargetVersion is already up to date. Skipping download."
        exit 0
    }
}

# A Flutter FFI plugin loads shared objects at runtime (dart:ffi DynamicLibrary),
# so we want the DYNAMIC-libs artifact (.dylib/.so/.dll + dynamic xcframework) —
# the same one SSPlayerForRenPy uses. NOTE: the exact zip name must match what is
# actually published on the SpriteStudio-SDK releases; adjust here (and in
# download-sdk.sh) once the release pipeline publishes Flutter/dynamic artifacts.
$Artifact = "spritestudio7-sdk-dynamic-libs.zip"
$Url = "https://github.com/cri-middleware/SpriteStudio-SDK/releases/download/$TargetVersion/$Artifact"
$ZipFile = Join-Path $NativeDir "sdk.zip"

Write-Host "Target SDK Version: $TargetVersion"
Write-Host "Download URL: $Url"
Write-Host "Downloading SDK..."
New-Item -ItemType Directory -Force -Path $NativeDir | Out-Null
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $Url -OutFile $ZipFile
$ProgressPreference = 'Continue'

Write-Host "Extracting SDK..."
Expand-Archive -Path $ZipFile -DestinationPath $NativeDir -Force
Remove-Item $ZipFile

# stamp the cache with the version we just unpacked
Set-Content -Path $CurrentVersionFile -Value $TargetVersion

Write-Host "Done."
