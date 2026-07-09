# Preamble: configure port-proxy, export kubeconfig and verify samba deployment

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir/post_clone_windows_setup.ps1"

Write-Step 'Post-k3s: export kubeconfig, setup port proxy, and verify samba'

if ([string]::IsNullOrWhiteSpace($script:WslRepoPath)) {
    throw 'WSL repo path not set. Run pre_k3s_setup.ps1 then k3s_setup.ps1 first.'
}

# Determine WSL IP
$wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "ip -4 -o addr show dev eth0 | sed -n 's/.* inet \([0-9.]*\)\/.*$/\1/p' | head -n1").Trim()
if ([string]::IsNullOrWhiteSpace($wslIp)) {
    $wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "hostname -I | tr ' ' '\n' | sed -n '1p'").Trim()
}

if (-not [string]::IsNullOrWhiteSpace($wslIp)) {
    Setup-KubePortProxy -WslIp $wslIp
}

$selectedApiServer = 'https://127.0.0.1:6443'
if (Test-KubeApiEndpoint -ServerUrl $selectedApiServer) {
    Write-Log 'Using localhost API endpoint through Windows port proxy'
} elseif (Test-KubeApiEndpoint -ServerUrl ("https://$wslIp:6443")) {
    $selectedApiServer = "https://$wslIp:6443"
    Write-Log "Falling back to direct WSL API endpoint: $selectedApiServer"
} else {
    Write-Log 'Could not verify Kubernetes API endpoint on either localhost proxy or direct WSL IP'
}

$WindowsKubeConfigPath = Export-KubeconfigToWindows -ApiServer $selectedApiServer

Configure-LensKubeconfig -KubeconfigPath $WindowsKubeConfigPath

Assert-ClusterStability

Verify-ClientFilesystemActivity

Write-Host 'Post-k3s samba verification complete.' -ForegroundColor Green
