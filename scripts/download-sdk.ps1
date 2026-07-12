#!/usr/bin/env pwsh
#
# Download the prebuilt SpriteStudio-SDK native libraries + headers and unpack
# them into the Flutter package so the app can be built without a Rust toolchain.
# PowerShell counterpart of scripts/download-sdk.sh:
#   - target version comes from scripts/SDK_VERSION.txt
#   - the cache stamp lives at packages/ssplayer_flutter/native/VERSION
#     (build-runtime.ps1 writes the same file), so a matching version skips the
#     download.
#   - artifacts land in packages/ssplayer_flutter/native/ (libs/<platform>/...,
#     include/, VERSION).

$ErrorActionPreference = "Stop"

$RootDir            = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ScriptDir          = Split-Path -Parent $PSCommandPath
$NativeDir          = Join-Path $RootDir "packages/ssplayer_flutter/native"
$VersionFile        = Join-Path $ScriptDir "SDK_VERSION.txt"
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
$Artifact = "spritestudio-sdk-dynamic-libs.zip"
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

# CocoaPods only embeds a vendored framework at/below the podspec dir, so symlink
# the unpacked macOS framework under the plugin's macos/Frameworks/ (same as
# build-runtime.ps1). No-op when the artifact has no macOS framework.
if (Test-Path (Join-Path $NativeDir "libs/macos/libssruntime.framework")) {
    $podFwDir = Join-Path $RootDir "packages/ssplayer_flutter/macos/Frameworks"
    New-Item -ItemType Directory -Force -Path $podFwDir | Out-Null
    $podFwLink = Join-Path $podFwDir "libssruntime.framework"
    if (Test-Path $podFwLink) { Remove-Item -Recurse -Force $podFwLink }
    New-Item -ItemType SymbolicLink -Path $podFwLink -Target "../../native/libs/macos/libssruntime.framework" -Force | Out-Null
    Write-Host "   -> macos/Frameworks/libssruntime.framework -> ../../native/libs/macos/libssruntime.framework"
}

# stamp the cache with the version we just unpacked
Set-Content -Path $CurrentVersionFile -Value $TargetVersion

# Regenerate the Layer-1 ffigen bindings from the unpacked C headers
# (native/include/*.h). Flutter-specific; folded in so `download-sdk` alone
# suffices (matches build-runtime). No-op without the Dart SDK.
& (Join-Path $ScriptDir "generate-ffigen-code.ps1")

Write-Host "Done."
