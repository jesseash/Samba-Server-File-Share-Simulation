# Preamble: invoke WSL bootstrap script to install packages and k3s

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/post_clone_windows_setup.ps1"

Write-Step 'k3s setup: run bootstrap inside WSL'

if ([string]::IsNullOrWhiteSpace($script:WslRepoPath)) {
    throw 'WSL repo path not set. Run pre_k3s_setup.ps1 first.'
}

Run-WslBootstrap -DestinationPath $script:WslRepoPath

Write-Host "k3s bootstrap complete. Next: run post_k3s_samba_verification.ps1 to configure port-proxy and verify samba." -ForegroundColor Green
Write-Host "k3s bootstrap complete. Run post_k3s_samba_verification.ps1 next to configure port-proxy and verify samba." -ForegroundColor Cyan
