#!/usr/bin/env pwsh
#
# Build the native Brain (libssruntime / libssconverter) from the
# SpriteStudio-SDK submodule and place the DYNAMIC libraries into the Flutter
# package's per-platform / per-arch layout so that `dart:ffi`
# (DynamicLibrary.open / .process) can load them at runtime.
#
# PowerShell counterpart of scripts/build-runtime.sh (same platform= / arch= /
# build= / hostbuild= interface); modeled on the sibling players' .ps1 build
# scripts (SSPlayerForRenPy / -Unity / -Godot). For DESKTOP hosts we build the
# feature-enabled `ssruntime` cdylib directly with cargo (fast). android / ios /
# web are toolchain-heavy cross builds and delegate to the SDK's own release
# scripts (SpriteStudio-SDK/scripts/release-*), preferring the .ps1 variant and
# falling back to the .sh (via bash/sh) when only a shell script is published.
#
# Output layout (LibRoot = packages/ssplayer_flutter/native):
#   native/libs/macos/libssruntime.framework        (universal on cross build; runtime, embedded)
#   (libssconverter → packages/ssconverter_dart/native/libs/<platform>/; host tool)
#   native/libs/windows/<arch>/ssruntime.dll
#   native/libs/linux/<arch>/libssruntime.so
#   native/libs/android/<abi>/libssruntime.so
#   native/libs/ios/libssruntime.xcframework
#   native/libs/web/...                              (wasm bundle)
#   native/libs/LICENSE.md
#   native/VERSION
#
# After building, this copies the SDK build.rs-emitted plain-C headers into
# native/include/ and regenerates the ffigen bindings (scripts/generate-ffigen-code.ps1).
# The .fbs FlatBuffers accessors are a separate concern (scripts/generate-fbs-code.ps1).
#
# Usage: scripts\build-runtime.ps1 [platform=<p>] [arch=<a>] [build=<m>] [hostbuild=<auto|false>]
#   platform : windows macos linux android ios web   (default: host)
#   arch     : x86_64 arm64 universal ...            (default: host arch)
#   build    : debug release                         (default: debug)
#   hostbuild: false to force cross even on host
#
# SDK location: $env:SSSDK, else .\SpriteStudio-SDK, else ..\SpriteStudio-SDK.

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$PkgDir  = Join-Path $RootDir "packages/ssplayer_flutter"
$LibRoot = Join-Path $PkgDir "native"
$LibsDir = Join-Path $LibRoot "libs"
# The host converter (libssconverter) lives in its own desktop-only package.
$ConvPkgDir  = Join-Path $RootDir "packages/ssconverter_dart"
$ConvLibsDir = Join-Path $ConvPkgDir "native/libs"
# The Layer-1 runtime bindings live in their own pure-Dart package.
$RtPkgDir = Join-Path $RootDir "packages/ssruntime_dart"

# --- detect the host platform / arch (pwsh runs on win/mac/linux) ----------
if ($null -eq $IsWindows -or $IsWindows) { $HOST_PLATFORM = "windows" }  # $IsWindows is $null on Windows PowerShell 5.1
elseif ($IsMacOS)                        { $HOST_PLATFORM = "macos" }
else                                     { $HOST_PLATFORM = "linux" }
$rawArch  = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$HOST_ARCH = if ($rawArch -match "Arm64") { "arm64" } else { "x86_64" }

function usage() {
    Get-Content $PSCommandPath | Select-String -Pattern '^# Usage:','^#   ' |
        ForEach-Object { $_.Line -replace '^# ?','' }
}

# --- parse args -----------------------------------------------------------
$PLATFORM = $HOST_PLATFORM; $ARCH = $HOST_ARCH; $BUILD_MODE = "debug"; $HOSTBUILD = "auto"
foreach ($item in $Args) {
    if ($item -match "=") {
        $kv = $item -split "=", 2
        switch ($kv[0]) {
            "platform"  { $PLATFORM = $kv[1].ToLower() }
            "arch"      { $ARCH = $kv[1].ToLower() }
            "build"     { $BUILD_MODE = $kv[1].ToLower() }
            "hostbuild" { $HOSTBUILD = $kv[1].ToLower() }
            default     { Write-Error "build-runtime.ps1: unknown arg '$item'" }
        }
    } elseif ($item -match "help" -or $item -eq "-h" -or $item -eq "--help") {
        usage; exit 0
    } else {
        Write-Error "build-runtime.ps1: unknown arg '$item'"
    }
}

# --- locate the SDK -------------------------------------------------------
$SdkDir = $env:SSSDK
if (-not $SdkDir) {
    foreach ($cand in @((Join-Path $RootDir "SpriteStudio-SDK"), (Join-Path $RootDir "../SpriteStudio-SDK"))) {
        if (Test-Path (Join-Path $cand "Cargo.toml")) { $SdkDir = (Resolve-Path $cand).Path; break }
    }
}
if (-not $SdkDir -or -not (Test-Path (Join-Path $SdkDir "Cargo.toml"))) {
    Write-Error "build-runtime.ps1: SpriteStudio-SDK not found (init the submodule or set `$env:SSSDK)"
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "build-runtime.ps1: cargo (Rust) not on PATH"
}

$IS_HOST_BUILD = $false
if ($HOSTBUILD -ne "false" -and $PLATFORM -eq $HOST_PLATFORM -and $ARCH -eq $HOST_ARCH) {
    $IS_HOST_BUILD = $true
}
Write-Host "Building for $PLATFORM ($ARCH) in $BUILD_MODE mode (host build: $IS_HOST_BUILD)"
$CargoFlags = if ($BUILD_MODE -eq "release") { @("--release") } else { @() }

# The runtime is no_std: a host cdylib needs an allocator + panic handler.
function Build-Ss {
    param([string[]]$Extra = @())
    Push-Location $SdkDir
    try { & cargo build @CargoFlags @Extra -p ssruntime --features libc_alloc,panic-handler; if ($LASTEXITCODE) { throw "cargo build ssruntime failed" } }
    finally { Pop-Location }
}
function Build-Converter {
    param([string[]]$Extra = @())
    Push-Location $SdkDir
    try { & cargo build @CargoFlags @Extra -p ssconverter; if ($LASTEXITCODE) { throw "cargo build ssconverter failed" } }
    finally { Pop-Location }
}
function Place($sub, $src, $name) {
    if (-not $name) { $name = Split-Path $src -Leaf }
    $d = Join-Path $LibsDir $sub
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item $src (Join-Path $d $name) -Force
    Write-Host "   -> native/libs/$sub/$name"
}
# Same, but into the ssconverter_dart package (the host converter's home).
function Place-Conv($sub, $src, $name) {
    if (-not $name) { $name = Split-Path $src -Leaf }
    $d = Join-Path $ConvLibsDir $sub
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item $src (Join-Path $d $name) -Force
    Write-Host "   -> ssconverter_dart native/libs/$sub/$name"
}
# Read the SDK workspace version (for the framework Info.plist on the host path).
function Get-SdkVersion() {
    $m = (Get-Content (Join-Path $SdkDir "Cargo.toml") |
          Select-String -Pattern '^version = "(.*)"' | Select-Object -First 1)
    if ($m) { return $m.Matches.Groups[1].Value } else { return "0.0.0" }
}

# Run an SDK release script, preferring the .ps1 variant and falling back to the
# .sh (via bash, else sh) when only a shell script is published.
function Invoke-Release($name, $mode) {
    $ps1 = Join-Path $SdkDir "scripts/$name.ps1"
    $sh  = Join-Path $SdkDir "scripts/$name.sh"
    if (Test-Path $ps1) {
        & $ps1 $mode
    } elseif (Test-Path $sh) {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if ($bash) { & bash $sh $mode } else { & sh $sh $mode }
    } else {
        Write-Error "build-runtime.ps1: SDK release script not found: scripts/$name.(ps1|sh)"
    }
    if ($LASTEXITCODE) { throw "$name failed" }
}

New-Item -ItemType Directory -Force -Path $LibsDir | Out-Null
# licenses
if (Test-Path "$SdkDir/LICENSE.md") { Copy-Item "$SdkDir/LICENSE.md" "$LibsDir/" -Force }
if (Test-Path "$SdkDir/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md") {
    Copy-Item "$SdkDir/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" "$LibsDir/" -Force
}
# record the version we built from (used by download-sdk.ps1 cache check too)
if (Test-Path "$RootDir/scripts/SDK_VERSION.txt") { Copy-Item "$RootDir/scripts/SDK_VERSION.txt" "$LibRoot/VERSION" -Force }

$T = Join-Path $SdkDir "target"
switch ($PLATFORM) {
    "macos" {
        New-Item -ItemType Directory -Force -Path (Join-Path $LibsDir "macos") | Out-Null
        # Runtime ships ONLY as libssruntime.framework (single copy in native/libs/macos;
        # a symlink under the plugin's macos/Frameworks/ below is what the podspec embeds).
        # libssconverter stays a bare dylib (host tool, never embedded).
        if ($IS_HOST_BUILD -and $ARCH -ne "universal") {
            # Fast host/debug path: plain cargo build, then wrap into a .framework via
            # the SDK's shared packaging helper (single source of truth; needs the
            # macOS toolchain, so reachable only under pwsh-on-macOS where bash exists).
            Build-Ss; Build-Converter
            $mkfw = Join-Path $SdkDir "scripts/make-macos-framework.sh"
            $minOs = if ($env:MACOSX_DEPLOYMENT_TARGET) { $env:MACOSX_DEPLOYMENT_TARGET } else { "11.0" }
            & bash $mkfw `
                "$T/$BUILD_MODE/libssruntime.dylib" `
                (Join-Path $LibsDir "macos/libssruntime.framework") `
                (Get-SdkVersion) `
                "jp.co.cri-mw.optpix.ssruntime" `
                $minOs `
                (Join-Path $SdkDir "libs/ssruntime/target/ssruntime.h")
            Write-Host "   -> native/libs/macos/libssruntime.framework"
            Place-Conv "macos" "$T/$BUILD_MODE/libssconverter.dylib"
            & install_name_tool -id "@rpath/libssconverter.dylib" (Join-Path $ConvLibsDir "macos/libssconverter.dylib") 2>$null
        } else {
            # Universal (arm64 + x86_64): the SDK release script now BUILDS the versioned
            # libssruntime.framework itself, so consume it directly (cp -R to keep the
            # version symlinks + code signature).
            Invoke-Release "release-macos" $BUILD_MODE
            $uni = "$T/universal-apple-darwin/$BUILD_MODE"
            $fwDest = Join-Path $LibsDir "macos/libssruntime.framework"
            if (Test-Path $fwDest) { Remove-Item -Recurse -Force $fwDest }
            & cp -R "$uni/libssruntime.framework" (Join-Path $LibsDir "macos/")
            Write-Host "   -> native/libs/macos/libssruntime.framework"
            if (Test-Path "$uni/libssconverter.dylib") {
                Place-Conv "macos" "$uni/libssconverter.dylib"
                & install_name_tool -id "@rpath/libssconverter.dylib" (Join-Path $ConvLibsDir "macos/libssconverter.dylib") 2>$null
            }
        }
        # Symlink the single framework under the plugin's macos/Frameworks/ so CocoaPods
        # embeds it (no second copy; install_framework resolves the symlink). gitignored.
        $podFwDir = Join-Path $PkgDir "macos/Frameworks"
        New-Item -ItemType Directory -Force -Path $podFwDir | Out-Null
        $podFwLink = Join-Path $podFwDir "libssruntime.framework"
        if (Test-Path $podFwLink) { Remove-Item -Recurse -Force $podFwLink }
        New-Item -ItemType SymbolicLink -Path $podFwLink -Target "../../native/libs/macos/libssruntime.framework" -Force | Out-Null
        Write-Host "   -> macos/Frameworks/libssruntime.framework -> ../../native/libs/macos/libssruntime.framework"
    }

    "linux" {
        # Linux arch dir uses the kernel/Rust spelling: aarch64 (not arm64),
        # x86_64 — matching the SDK release layout native/libs/linux/aarch64.
        # Accept arm64 as an alias for ergonomics but always emit aarch64.
        $larch = if ($ARCH -eq "arm64" -or $ARCH -eq "aarch64") { "aarch64" } else { $ARCH }
        if ($IS_HOST_BUILD) {
            Build-Ss; Build-Converter
            Place "linux/$larch" "$T/$BUILD_MODE/libssruntime.so"
            Place-Conv "linux/$larch" "$T/$BUILD_MODE/libssconverter.so"
        } else {
            $triple = if ($larch -eq "aarch64") { "aarch64-unknown-linux-gnu" } else { "x86_64-unknown-linux-gnu" }
            Build-Ss @("--target", $triple); Build-Converter @("--target", $triple)
            Place "linux/$larch" "$T/$triple/$BUILD_MODE/libssruntime.so"
            Place-Conv "linux/$larch" "$T/$triple/$BUILD_MODE/libssconverter.so"
        }
    }

    "windows" {
        if ($IS_HOST_BUILD) {
            Build-Ss; Build-Converter
            Place "windows/$ARCH" "$T/$BUILD_MODE/ssruntime.dll"
            Place-Conv "windows/$ARCH" "$T/$BUILD_MODE/ssconverter.dll"
        } else {
            $triple = if ($ARCH -eq "arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
            Build-Ss @("--target", $triple); Build-Converter @("--target", $triple)
            Place "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssruntime.dll"
            Place-Conv "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssconverter.dll"
        }
    }

    # --- toolchain-heavy cross builds: delegate to the SDK release scripts ---
    "android" {
        Invoke-Release "release-android" $BUILD_MODE
        foreach ($p in @(@{triple="aarch64-linux-android";abi="arm64-v8a"},
                         @{triple="armv7-linux-androideabi";abi="armeabi-v7a"},
                         @{triple="x86_64-linux-android";abi="x86_64"})) {
            $src = "$T/$($p.triple)/$BUILD_MODE/libssruntime.so"
            if (Test-Path $src) { Place "android/$($p.abi)" $src }
        }
    }

    "ios" {
        Invoke-Release "release-ios-xcframework" $BUILD_MODE
        $dest = Join-Path $LibsDir "ios"; New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Remove-Item -Recurse -Force "$dest/libssruntime.xcframework" -ErrorAction SilentlyContinue
        # Ship the DYNAMIC xcframework so the app embeds one framework and dyld
        # resolves the Brain via @rpath (DynamicLibrary.open('libssruntime.framework/libssruntime')).
        Copy-Item -Recurse -Force "$T/xcframework/dynamic/libssruntime.xcframework" "$dest/"
        Write-Host "   -> native/libs/ios/libssruntime.xcframework"
    }

    "web" {
        Invoke-Release "release-web" $BUILD_MODE
        $webSrc  = Join-Path $SdkDir "pkg/runtime-web/$BUILD_MODE"
        $webDest = Join-Path $LibsDir "web"
        New-Item -ItemType Directory -Force -Path $webDest | Out-Null
        if (Test-Path (Join-Path $webSrc "*")) {
            Copy-Item -Recurse -Force (Join-Path $webSrc "*") $webDest
        }
        Write-Host "   -> native/libs/web/"
    }

    default { Write-Error "build-runtime.ps1: unknown platform '$PLATFORM'" }
}

# --- C headers (ffigen input): consume the plain-C headers the SDK build.rs
# emitted (Language::C, <crate>.h; .hpp is the C++ twin). Single source of truth
# = the SDK; no local cbindgen. Each crate's header goes to its OWN package:
# ssruntime → ssplayer_flutter, ssconverter → ssconverter_dart.
$RtIncludeDir = Join-Path $RtPkgDir "native/include"
$ConvIncludeDir = Join-Path $ConvPkgDir "native/include"
New-Item -ItemType Directory -Force -Path $RtIncludeDir, $ConvIncludeDir | Out-Null
$rh = Join-Path $SdkDir "libs/ssruntime/target/ssruntime.h"
if (Test-Path $rh) { Copy-Item $rh (Join-Path $RtIncludeDir "ssruntime.h") -Force; Write-Host "   -> ssruntime_dart native/include/ssruntime.h" }
$ch = Join-Path $SdkDir "libs/ssconverter/target/ssconverter.h"
if (Test-Path $ch) { Copy-Item $ch (Join-Path $ConvIncludeDir "ssconverter.h") -Force; Write-Host "   -> ssconverter_dart native/include/ssconverter.h" }

# --- Layer-1 ffigen bindings: regenerate now that the headers are fresh. ffigen
# is Flutter-specific; folding it in here keeps the dev-facing script count the
# same as the sibling players. No-op without the Dart SDK.
& (Join-Path $RootDir "scripts/generate-ffigen-code.ps1")

Write-Host "build-runtime.ps1: done."
