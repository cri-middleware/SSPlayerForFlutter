#!/usr/bin/env pwsh
#
# Run an example on Windows: scripts\run-example.ps1 with platform=windows. What it
# brings up first and what it takes are in that script's header (or --help).
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'run-example.ps1') 'platform=windows' @args
exit $LASTEXITCODE
