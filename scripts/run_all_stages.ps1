# Wrapper to run the three staged scripts in order
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Dot-source the function library first
. "$ScriptDir/post_clone_windows_setup.ps1"

# Run pre-k3s
Write-Host '=== Running pre-k3s stage ===' -ForegroundColor Yellow
. "$ScriptDir/pre_k3s_setup.ps1"

# Run k3s bootstrap stage
Write-Host '=== Running k3s bootstrap stage ===' -ForegroundColor Yellow
. "$ScriptDir/k3s_setup.ps1"

# Run post-k3s verification stage
Write-Host '=== Running post-k3s verification stage ===' -ForegroundColor Yellow
. "$ScriptDir/post_k3s_samba_verification.ps1"

Write-Host 'All stages complete.' -ForegroundColor Green
