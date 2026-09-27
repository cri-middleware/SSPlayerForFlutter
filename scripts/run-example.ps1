#!/usr/bin/env pwsh
#
# PowerShell counterpart of scripts/run-example.sh, for the targets a Windows host
# runs: windows, android and web. The same five steps — assets, runner, runtime,
# device, run — in the same order; the .sh header says what each one does. Both
# halves must change together.
#
# Usage: scripts\run-example.ps1 platform=<p> [example=<name>] [--gpu] [--watch] [flutter run args...]
#   platform : windows android web   (macos / linux / ios: scripts/run-<p>.sh)
#   example  : a directory under examples\   (default: overall)
#   --gpu    : the flutter_gpu backend   (-Gpu works too)
#   --watch  : live reload through sswatch; on android / web the push carries
#              bytes, so --device is added for you   (-Watch works too)
#   Anything else goes to `flutter run` as it is: -d <id>, --release, ...
$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$App = 'run-example.ps1'

function Show-Usage {
    foreach ($line in (Get-Content $PSCommandPath | Select-Object -Skip 2)) {
        if ($line -notmatch '^#') { break }
        Write-Host ($line -replace '^# ?', '')
    }
}
function Stop-Run([string]$message, [int]$code = 1) {
    [Console]::Error.WriteLine("${App}: $message")
    exit $code
}

# Parsed by hand, not by a param() block: an advanced script's common -Debug
# would take a bare `-d` and drop it before it reached flutter.
$Platform = ''
$Example = 'overall'
$Gpu = $false
$Watch = $false
$HasDevice = $false
$Pass = @()
foreach ($arg in $args) {
    switch -Regex ($arg) {
        '^platform=' { $Platform = $arg.Substring(9) }
        '^example='  { $Example = $arg.Substring(8) }
        '^--?gpu$'   { $Gpu = $true }
        '^--?watch$' { $Watch = $true }
        '^(-h|--help|help)$' { Show-Usage; exit 0 }
        '^(-d|--device-id|--device-id=.*)$' { $HasDevice = $true; $Pass += $arg }
        default { $Pass += $arg }
    }
}

switch ($Platform) {
    'windows' { if (-not $IsWindows) { Stop-Run 'windows needs a Windows host' } }
    'android' { }
    'web' { }
    { $_ -in 'macos', 'linux', 'ios' } { Stop-Run "$Platform runs from bash — scripts/run-$Platform.sh" 2 }
    '' { Show-Usage; Stop-Run 'platform=<p> is required' 2 }
    default { Stop-Run "unknown platform '$Platform'" 2 }
}

$ExampleDir = Join-Path $RootDir "examples/$Example"
if (-not (Test-Path (Join-Path $ExampleDir 'pubspec.yaml'))) { Stop-Run "no example at examples/$Example" }
$ExampleRun = Join-Path $ExampleDir 'scripts/run.ps1'
if (-not (Test-Path $ExampleRun) -and ($Gpu -or $Watch)) {
    Stop-Run '--gpu and --watch are wired by examples/overall only' 2
}

# 1. assets
$Packs = Get-ChildItem -Path (Join-Path $ExampleDir 'assets/spritestudio') -Filter '*.ssab' -Recurse -Depth 1 -ErrorAction SilentlyContinue
if (-not $Packs) {
    Write-Host "[$App] examples/$Example has no .ssab yet — running deploy-examples"
    & (Join-Path $RootDir 'scripts/deploy-examples.ps1')
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

# 2. runner — create carries the runners already on disk, for the reason the
# .sh gives (it rewrites .metadata to exactly the platforms it is handed).
if (-not (Test-Path -PathType Container (Join-Path $ExampleDir $Platform))) {
    if ($Platform -eq 'android') {
        & (Join-Path $RootDir 'examples/scripts/setup-mobile.ps1') $Example -Android
    }
    else {
        Push-Location $ExampleDir
        try {
            $Carry = @($Platform)
            foreach ($p in @('android', 'ios', 'macos', 'windows', 'linux', 'web')) {
                if ($Carry -notcontains $p -and (Test-Path -PathType Container $p)) { $Carry += $p }
            }
            & flutter create --platforms=($Carry -join ',') .
            if ($LASTEXITCODE) { exit $LASTEXITCODE }
        }
        finally { Pop-Location }
    }
}

# 3. runtime
if ($Platform -eq 'web') {
    $WebRt = Join-Path $RootDir 'packages/ssplayer_flutter/assets/runtime-web'
    if (-not (Test-Path (Join-Path $WebRt 'ssruntime.js')) -or -not (Test-Path (Join-Path $WebRt 'ssruntime_bg.wasm'))) {
        [Console]::Error.WriteLine("${App}: the web runtime is missing from packages/ssplayer_flutter/assets/runtime-web/,")
        [Console]::Error.WriteLine("${App}: and no build hook fetches it on the web. Provide it with either:")
        [Console]::Error.WriteLine('    pwsh scripts/download-web-runtime.ps1          # the pinned release (no Rust)')
        [Console]::Error.WriteLine('    pwsh scripts/build-runtime.ps1 platform=web    # from the SDK source (Rust + wasm-pack)')
        exit 1
    }
}
elseif (-not (Test-Path (Join-Path $RootDir "packages/ssruntime_dart/native/libs/$Platform"))) {
    Write-Host "[$App] no local libssruntime for $Platform — the build downloads the pinned release instead."
    Write-Host "[$App] If that fails: pwsh scripts/build-runtime.ps1 platform=$Platform"
}

# 4. device — devices come from `flutter devices --machine`; `flutter emulators`
# has no machine form, so its rows are split on the bullet, read as UTF-8.
function Get-RunningDevice([string]$want) {
    $devices = (& flutter devices --machine 2>$null | Out-String) | ConvertFrom-Json
    foreach ($d in $devices) {
        if ($want -eq 'android' -and $d.targetPlatform -like 'android*') { return $d.id }
    }
    return $null
}
function Get-FirstEmulator([string]$want) {
    $saved = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try { $rows = & flutter emulators 2>$null }
    finally { [Console]::OutputEncoding = $saved }
    $bullet = " $([char]0x2022) "
    foreach ($row in $rows) {
        $cols = $row -split [regex]::Escape($bullet)
        if ($cols.Count -ge 4 -and $cols[3].Trim() -eq $want) { return $cols[0].Trim() }
    }
    return $null
}
if (-not $HasDevice) {
    switch ($Platform) {
        'windows' { $Device = 'windows' }
        'web' { $Device = 'chrome' }
        'android' {
            $Device = Get-RunningDevice 'android'
            if (-not $Device) {
                $Emulator = Get-FirstEmulator 'android'
                if (-not $Emulator) {
                    Stop-Run 'no android device is running and `flutter emulators` lists none to launch — start one yourself, or pass -d <id>'
                }
                Write-Host "[$App] no android device running — launching emulator $Emulator"
                & flutter emulators --launch $Emulator
                for ($i = 0; $i -lt 60 -and -not $Device; $i++) {
                    Start-Sleep -Seconds 3
                    $Device = Get-RunningDevice 'android'
                }
                if (-not $Device) { Stop-Run "$Emulator did not come up within 3 minutes" }
            }
        }
    }
    $Pass = @('-d', $Device) + $Pass
}

# 5. run
Push-Location $ExampleDir
try {
    if (Test-Path $ExampleRun) {
        $Flags = @()
        if ($Gpu) { $Flags += '--gpu' }
        if ($Watch) {
            $Flags += '--watch'
            if ($Platform -in 'android', 'web') { $Flags += '--device' }
        }
        & $ExampleRun @Flags @Pass
    }
    else {
        & flutter run @Pass
    }
    exit $LASTEXITCODE
}
finally { Pop-Location }
