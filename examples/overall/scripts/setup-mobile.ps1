#!/usr/bin/env pwsh
#
# Android setup for the overall example on Windows — a thin wrapper over the
# shared examples/scripts/setup-mobile.ps1. overall needs no per-platform tweaks
# here: the drag-&-drop entitlement is a macOS sandbox concept, and the
# live-reload device push carries its bytes over the VM Service rather than
# reading a host path, so nothing in the generated runner has to be edited.
#
# Run from anywhere:  pwsh examples/overall/scripts/setup-mobile.ps1
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '../../scripts/setup-mobile.ps1') 'overall' @args
