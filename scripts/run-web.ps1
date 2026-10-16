#!/usr/bin/env pwsh
#
# Run an example on the web (Chrome): scripts\run-example.ps1 with platform=web. What it
# brings up first and what it takes are in that script's header (or --help).
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'run-example.ps1') 'platform=web' @args
exit $LASTEXITCODE
