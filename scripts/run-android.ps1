#!/usr/bin/env pwsh
#
# Run an example on Android: scripts\run-example.ps1 with platform=android. What it
# brings up first and what it takes are in that script's header (or --help).
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'run-example.ps1') 'platform=android' @args
exit $LASTEXITCODE
