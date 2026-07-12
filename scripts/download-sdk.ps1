#!/usr/bin/env pwsh
#
# Download the prebuilt SpriteStudio-SDK native libraries + headers and unpack
# them into the Flutter package so the app can be built without a Rust toolchain.
# PowerShell counterpart of scripts/download-sdk.sh:
#   - target version comes from scripts/SDK_VERSION.txt
#   - the cache stamp lives at packages/ssruntime_dart/native/VERSION
#     (build-runtime.ps1 writes the same file), so a matching version skips the
#     download.
#   - artifacts currently unpack into packages/ssplayer_flutter/native/; splitting
#     them across ssruntime_dart / ssconverter_dart (to match build-runtime's
#     native-assets layout) is a pending follow-up — see NOTE at the Artifact line.

$ErrorActionPreference = "Stop"

$RootDir            = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ScriptDir          = Split-Path -Parent $PSCommandPath
# Unpack destination (pending migration to the ssruntime_dart / ssconverter_dart
# native-assets layout — see NOTE below); the SDK-version cache stamp, however,
# lives with the runtime package to match build-runtime.ps1's writer.
$NativeDir          = Join-Path $RootDir "packages/ssplayer_flutter/native"
$VersionFile        = Join-Path $ScriptDir "SDK_VERSION.txt"
$CurrentVersionFile = Join-Path $RootDir "packages/ssruntime_dart/native/VERSION"

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

# No macos/Frameworks symlink: the Brain is delivered as a native-assets code
# asset (ssruntime_dart/hook/build.dart), so Flutter embeds it automatically —
# there is no vendored CocoaPods framework to link.

# stamp the cache with the version we just unpacked (next to the runtime package)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CurrentVersionFile) | Out-Null
Set-Content -Path $CurrentVersionFile -Value $TargetVersion

# Regenerate the Layer-1 ffigen bindings from the unpacked C headers
# (native/include/*.h). Flutter-specific; folded in so `download-sdk` alone
# suffices (matches build-runtime). No-op without the Dart SDK.
& (Join-Path $ScriptDir "generate-ffigen-code.ps1")

Write-Host "Done."
