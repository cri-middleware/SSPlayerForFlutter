#!/usr/bin/env pwsh
#
# Run the overall example, with the flutter_gpu switches behind one flag.
#
#   pwsh scripts/run.ps1 -d windows                # Canvas (the default backend)
#   pwsh scripts/run.ps1 -Gpu -d windows           # flutter_gpu
#   pwsh scripts/run.ps1 -Gpu -Watch -d windows    # flutter_gpu + live reload
#
# -Gpu expands to the three switches the backend actually needs:
#   --dart-define=SS_BACKEND=gpu   the example's backend selector (lib/main.dart)
#   --enable-flutter-gpu           the flutter_gpu API itself
#   --enable-impeller              Impeller, which flutter_gpu requires
#
# The last one matters only on Android, where Impeller is available but not the
# default; `flutter run` ignores it elsewhere. It is passed everywhere anyway so
# one flag is correct on every target.
#
# -Watch routes the same launch through the live-reload watcher, which owns
# `flutter run` and injects SS_LIVE_RELOAD. Add --device after it for a device or
# the web, where the push carries bytes instead of a host path.
#
# Every other argument goes to `flutter run` (or to `sswatch --run`) untouched.
$ErrorActionPreference = 'Stop'

# Parsed by hand, not by a param() block: [Parameter()] makes this an advanced
# script, whose common -Debug takes a bare `-d` and drops it — `-d windows` would
# reach flutter as `flutter run windows`.
$Gpu = $false
$Watch = $false
$Passthrough = @()
foreach ($arg in $args) {
    switch -Regex ($arg) {
        '^--?gpu$'   { $Gpu = $true }
        '^--?watch$' { $Watch = $true }
        default      { $Passthrough += $arg }
    }
}

$ExampleDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$GpuArgs = @()
if ($Gpu) {
    $GpuArgs = @('--dart-define=SS_BACKEND=gpu', '--enable-impeller', '--enable-flutter-gpu')
}

Push-Location $ExampleDir
try {
    if ($Watch) {
        $cmd = @('run', 'ssgen_flutter:sswatch', '--run') + $Passthrough + $GpuArgs
        Write-Host "+ dart $($cmd -join ' ')"
        & dart @cmd
    }
    else {
        $cmd = @('run') + $Passthrough + $GpuArgs
        Write-Host "+ flutter $($cmd -join ' ')"
        & flutter @cmd
    }
    exit $LASTEXITCODE
}
finally { Pop-Location }
