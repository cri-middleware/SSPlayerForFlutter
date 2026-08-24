#!/usr/bin/env pwsh
#
# Build the native Brain (libssruntime / libssconverter) from the
# SpriteStudio-SDK submodule and place the DYNAMIC libraries into each binding
# package's native/libs/ layout so the native-assets build hook (hook/build.dart)
# bundles them as code assets the `@Native` bindings resolve at runtime.
#
# PowerShell counterpart of scripts/build-runtime.sh (same platform= / arch= /
# build= / hostbuild= interface); modeled on the sibling players' .ps1 build
# scripts (SSPlayerForRenPy / -Unity / -Godot). For DESKTOP hosts we build the
# feature-enabled `ssruntime` cdylib directly with cargo (fast). android / ios /
# web are toolchain-heavy cross builds and delegate to the SDK's own release
# scripts (SpriteStudio-SDK/scripts/release-*), preferring the .ps1 variant and
# falling back to the .sh (via bash/sh) when only a shell script is published.
#
# Output layout — each library lands in the binding package that bundles it as a
# native-assets code asset (hook/build.dart), NOT in ssplayer_flutter:
#   libssruntime   → packages/ssruntime_dart/native/libs/<platform>/[<arch>]/   (bare dylib/.so/.dll)
#   libssconverter → packages/ssconverter_dart/native/libs/<platform>/[<arch>]/ (host tool)
#   packages/ssruntime_dart/native/libs/LICENSE.md, THIRD-PARTY-LICENSES.ssruntime.md
#   packages/ssconverter_dart/native/libs/LICENSE.md
# No macos framework / macos/Frameworks symlink: native assets replace the
# CocoaPods framework path (Flutter re-wraps the bare dylib at build time).
# Web is the exception: it has no build hook / native asset, so `platform=web`
# builds the wasm-bindgen `web` runtime and places it as a Flutter ASSET under
# packages/ssplayer_flutter/assets/runtime-web/ (loaded via dart:js_interop).
# (NB: ios output still lands under ssplayer_flutter/native/libs; host desktop
# platforms use the layout above.)
#
# After building, this copies the SDK build.rs-emitted plain-C headers into
# native/include/. The ffigen bindings are COMMITTED (like the .fbs accessors), so
# regenerating them is a separate manual step — run scripts/generate-ffigen-code.ps1
# after a C-API change and commit the result (scripts/generate-fbs-code.ps1 for .fbs).
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
$RtLibsDir = Join-Path $RtPkgDir "native/libs"

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
    try { & cargo build @CargoFlags @Extra -p ssruntime-ffi --features libc_alloc,panic-handler; if ($LASTEXITCODE) { throw "cargo build ssruntime failed" } }
    finally { Pop-Location }
}
function Build-Converter {
    param([string[]]$Extra = @())
    Push-Location $SdkDir
    try { & cargo build @CargoFlags @Extra -p ssconverter-ffi; if ($LASTEXITCODE) { throw "cargo build ssconverter failed" } }
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
# Same, but into the ssruntime_dart package (the runtime's native-assets home).
function Place-Rt($sub, $src, $name) {
    if (-not $name) { $name = Split-Path $src -Leaf }
    $d = Join-Path $RtLibsDir $sub
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Copy-Item $src (Join-Path $d $name) -Force
    Write-Host "   -> ssruntime_dart native/libs/$sub/$name"
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

# Licenses ship next to the library they cover: the SDK LICENSE.md with BOTH
# binding packages (each ships a CRI dylib), the ssruntime third-party notices
# with ssruntime_dart (and the ssconverter notices with ssconverter_dart, if any).
New-Item -ItemType Directory -Force -Path $RtLibsDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConvLibsDir | Out-Null
if (Test-Path "$SdkDir/LICENSE.md") {
    Copy-Item "$SdkDir/LICENSE.md" "$RtLibsDir/" -Force
    Copy-Item "$SdkDir/LICENSE.md" "$ConvLibsDir/" -Force
}
if (Test-Path "$SdkDir/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md") {
    Copy-Item "$SdkDir/target/licenses/THIRD-PARTY-LICENSES.ssruntime.md" "$RtLibsDir/" -Force
}
if (Test-Path "$SdkDir/target/licenses/THIRD-PARTY-LICENSES.ssconverter.md") {
    Copy-Item "$SdkDir/target/licenses/THIRD-PARTY-LICENSES.ssconverter.md" "$ConvLibsDir/" -Force
}

$T = Join-Path $SdkDir "target"
switch ($PLATFORM) {
    "macos" {
        # Native assets: ship BARE dylibs (@rpath install id). ssruntime_dart's and
        # ssconverter_dart's hook/build.dart bundle them as code assets — no
        # CocoaPods framework, no macos/Frameworks symlink, no ffiPlugin.
        if ($IS_HOST_BUILD -and $ARCH -ne "universal") {
            Build-Ss; Build-Converter
            Place-Rt "macos" "$T/$BUILD_MODE/libssruntime.dylib"
            & install_name_tool -id "@rpath/libssruntime.dylib" (Join-Path $RtLibsDir "macos/libssruntime.dylib") 2>$null
            Place-Conv "macos" "$T/$BUILD_MODE/libssconverter.dylib"
            & install_name_tool -id "@rpath/libssconverter.dylib" (Join-Path $ConvLibsDir "macos/libssconverter.dylib") 2>$null
        } else {
            # Universal (arm64 + x86_64): release-macos.sh lipos the universal dylibs
            # (it also builds a .framework, which is unused here — native assets embeds
            # the bare dylib itself).
            Invoke-Release "release-macos" $BUILD_MODE
            $uni = "$T/universal-apple-darwin/$BUILD_MODE"
            Place-Rt "macos" "$uni/libssruntime.dylib"
            & install_name_tool -id "@rpath/libssruntime.dylib" (Join-Path $RtLibsDir "macos/libssruntime.dylib") 2>$null
            if (Test-Path "$uni/libssconverter.dylib") {
                Place-Conv "macos" "$uni/libssconverter.dylib"
                & install_name_tool -id "@rpath/libssconverter.dylib" (Join-Path $ConvLibsDir "macos/libssconverter.dylib") 2>$null
            }
        }
    }

    "linux" {
        # Linux arch dir uses the kernel/Rust spelling: aarch64 (not arm64),
        # x86_64 — matching the SDK release layout native/libs/linux/aarch64.
        # Accept arm64 as an alias for ergonomics but always emit aarch64.
        $larch = if ($ARCH -eq "arm64" -or $ARCH -eq "aarch64") { "aarch64" } else { $ARCH }
        if ($IS_HOST_BUILD) {
            Build-Ss; Build-Converter
            Place-Rt "linux/$larch" "$T/$BUILD_MODE/libssruntime.so"
            Place-Conv "linux/$larch" "$T/$BUILD_MODE/libssconverter.so"
        } else {
            $triple = if ($larch -eq "aarch64") { "aarch64-unknown-linux-gnu" } else { "x86_64-unknown-linux-gnu" }
            Build-Ss @("--target", $triple); Build-Converter @("--target", $triple)
            Place-Rt "linux/$larch" "$T/$triple/$BUILD_MODE/libssruntime.so"
            Place-Conv "linux/$larch" "$T/$triple/$BUILD_MODE/libssconverter.so"
        }
    }

    "windows" {
        if ($IS_HOST_BUILD) {
            Build-Ss; Build-Converter
            Place-Rt "windows/$ARCH" "$T/$BUILD_MODE/ssruntime.dll"
            Place-Conv "windows/$ARCH" "$T/$BUILD_MODE/ssconverter.dll"
        } else {
            $triple = if ($ARCH -eq "arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
            Build-Ss @("--target", $triple); Build-Converter @("--target", $triple)
            Place-Rt "windows/$ARCH" "$T/$triple/$BUILD_MODE/ssruntime.dll"
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
        # resolves the Brain via @rpath; the `@Native` bindings load it as a native-asset code asset.
        Copy-Item -Recurse -Force "$T/xcframework/dynamic/libssruntime.xcframework" "$dest/"
        Write-Host "   -> native/libs/ios/libssruntime.xcframework"
    }

    "web" {
        # Flutter web has NO build hooks / native assets and NO dart:ffi, so the
        # Brain cannot ship as a native-asset dylib. Instead it ships as the SDK's
        # wasm-bindgen `web` build (a .wasm + JS glue), bundled as a plain Flutter
        # ASSET in ssplayer_flutter and driven from Dart over dart:js_interop
        # (lib/src/runtime_api.dart -> web backend). This branch builds the runtime
        # crate to wasm and places the two files where pubspec.yaml's `assets:`
        # expects them. Only the runtime is needed here (converter-web is a separate
        # concern for ssconverter_dart), so we invoke wasm-pack directly rather than
        # the SDK's release-web.sh, which also builds the nosimd + converter packages.
        if (-not (Get-Command wasm-pack -ErrorAction SilentlyContinue)) {
            Write-Error "build-runtime.ps1: wasm-pack not found - install it with: cargo install wasm-pack  (+ rustup target add wasm32-unknown-unknown)"
        }
        $wpMode    = if ($BUILD_MODE -eq "debug") { "--dev" } else { "--release" }
        $simdOut   = Join-Path $SdkDir "pkg/runtime-web/$BUILD_MODE"
        $nosimdOut = Join-Path $SdkDir "pkg/runtime-web-nosimd/$BUILD_MODE"
        Push-Location $SdkDir
        try {
            # Primary build: inherits the SDK's repo-wide `+simd128` (its
            # .cargo/config.toml) — the fast path for modern browsers. NB:
            # wasm-pack's --out-dir is relative to the CRATE dir (libs/ssruntime),
            # so ../../ anchors it at the SDK-root pkg/ (as the SDK's release-web.sh).
            & wasm-pack build libs/ssruntime $wpMode --target web `
                --out-dir "../../pkg/runtime-web/$BUILD_MODE" -- --features web --no-default-features
            if ($LASTEXITCODE) { throw "wasm-pack build (simd) failed" }
            # nosimd fallback: override `+simd128` with `-simd128`, for engines
            # without stable SIMD (e.g. RPG Maker MZ's NW.js). Same source + same
            # wasm-bindgen, so the JS glue matches — only the `_bg.wasm` differs,
            # and loadSsRuntime() picks it via a WebAssembly.validate(simd128) probe.
            $savedRustflags = $env:RUSTFLAGS
            $env:RUSTFLAGS = "-C target-feature=-simd128"
            try {
                & wasm-pack build libs/ssruntime $wpMode --target web `
                    --out-dir "../../pkg/runtime-web-nosimd/$BUILD_MODE" -- --features web --no-default-features
                if ($LASTEXITCODE) { throw "wasm-pack build (nosimd) failed" }
            } finally {
                if ($null -eq $savedRustflags) { Remove-Item Env:\RUSTFLAGS -ErrorAction SilentlyContinue }
                else { $env:RUSTFLAGS = $savedRustflags }
            }
        } finally { Pop-Location }
        $assetDir = Join-Path $PkgDir "assets/runtime-web"
        New-Item -ItemType Directory -Force -Path $assetDir | Out-Null
        # Ship one JS glue (simd's) + both binaries (simd + nosimd).
        Copy-Item (Join-Path $simdOut "ssruntime.js") (Join-Path $assetDir "ssruntime.js") -Force
        Copy-Item (Join-Path $simdOut "ssruntime_bg.wasm") (Join-Path $assetDir "ssruntime_bg.wasm") -Force
        Copy-Item (Join-Path $nosimdOut "ssruntime_bg.wasm") (Join-Path $assetDir "ssruntime_bg.nosimd.wasm") -Force
        if ((Get-FileHash (Join-Path $simdOut "ssruntime.js")).Hash -ne (Get-FileHash (Join-Path $nosimdOut "ssruntime.js")).Hash) {
            Write-Warning "build-runtime.ps1: simd/nosimd JS glue differ; the shared ssruntime.js may not drive the nosimd wasm."
        }
        Write-Host "   -> packages/ssplayer_flutter/assets/runtime-web/ (ssruntime.js + ssruntime_bg.wasm + ssruntime_bg.nosimd.wasm)"
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
# The generating build scripts live in the *-ffi crates and write beside
# themselves, so these are `libs/<crate>-ffi/target/`. They moved there with the
# SDK's "split the binary faces into *-ffi crates" refactor; the old
# `libs/<crate>/target/` paths are written by nothing now, and because these
# copies are guarded a stale path fails silently.
$rh = Join-Path $SdkDir "libs/ssruntime-ffi/target/ssruntime.h"
if (Test-Path $rh) { Copy-Item $rh (Join-Path $RtIncludeDir "ssruntime.h") -Force; Write-Host "   -> ssruntime_dart native/include/ssruntime.h" }
$ch = Join-Path $SdkDir "libs/ssconverter-ffi/target/ssconverter.h"
if (Test-Path $ch) { Copy-Item $ch (Join-Path $ConvIncludeDir "ssconverter.h") -Force; Write-Host "   -> ssconverter_dart native/include/ssconverter.h" }

# The ffigen bindings (lib/src/*_bindings.g.dart) are committed, not regenerated
# here. If this build changed the C-API, run scripts/generate-ffigen-code.ps1 and
# commit the updated bindings.

Write-Host "build-runtime.ps1: done."
