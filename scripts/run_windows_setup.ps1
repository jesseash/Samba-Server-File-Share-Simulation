param(
    [string]$DistroName = "Ubuntu",
    [string]$WslRepoPath,
    [int]$BootstrapTimeoutSeconds = 3600
)

$installerScript = Join-Path $PSScriptRoot 'post_clone_windows_setup.ps1'
if (-not (Test-Path -LiteralPath $installerScript)) {
    throw "Installer script not found: $installerScript"
}

$invokeParams = @{
    DistroName = $DistroName
    BootstrapTimeoutSeconds = $BootstrapTimeoutSeconds
}

if ($PSBoundParameters.ContainsKey('WslRepoPath')) {
    $invokeParams.WslRepoPath = $WslRepoPath
}

& $installerScript @invokeParams
