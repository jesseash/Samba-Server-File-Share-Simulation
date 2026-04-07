param(
    [string]$DistroName = "Ubuntu",
    [string]$WslRepoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$RepoName = Split-Path $RepoRoot -Leaf
$RestartRequired = $false

function Write-Log {
    param([string]$Message)
    Write-Host "[post-clone] $Message" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Yellow
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }
}

function Assert-SupportedWindows {
    $currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $editionId = [string]$currentVersion.EditionID
    $productName = [string]$currentVersion.ProductName
    $buildNumber = [int]$currentVersion.CurrentBuildNumber

    $supportedEditions = @(
        'Professional',
        'ProfessionalN',
        'ProfessionalEducation',
        'ProfessionalWorkstation',
        'Enterprise',
        'EnterpriseN',
        'Education',
        'EducationN',
        'ServerStandard',
        'ServerDatacenter'
    )

    if ($buildNumber -lt 19041) {
        throw "Windows build 19041 or newer is required for this installer. Current build: $buildNumber ($productName)."
    }

    if ($supportedEditions -notcontains $editionId) {
        throw "Windows 10/11 Pro or greater is required. Detected edition: $productName ($editionId)."
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$ArgumentList = @(),

        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $joined = ($output | Out-String).Trim()
            throw "Command failed ($FilePath $($ArgumentList -join ' ')) with exit code $exitCode.`n$joined"
        }
        return ($output | Out-String).Trim()
    }

    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed ($FilePath $($ArgumentList -join ' ')) with exit code $exitCode."
    }
}

function ConvertTo-BashLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + ($Value -replace "'", "'\"'\"'") + "'"
}

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [switch]$AsRoot,
        [switch]$CaptureOutput
    )

    $args = @('-d', $DistroName)
    if ($AsRoot) {
        $args += @('--user', 'root')
    }
    $args += @('--', 'bash', '-lc', $Command)

    if ($CaptureOutput) {
        return Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args -CaptureOutput
    }

    Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args
}

function Ensure-WindowsFeature {
    param([Parameter(Mandatory = $true)][string]$FeatureName)

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName
    if ($feature.State -eq 'Enabled') {
        Write-Log "$FeatureName is already enabled"
        return
    }

    Write-Log "Enabling Windows feature: $FeatureName"
    Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart | Out-Null
    $script:RestartRequired = $true
}

function Ensure-WslPlatform {
    Ensure-WindowsFeature -FeatureName 'Microsoft-Windows-Subsystem-Linux'
    Ensure-WindowsFeature -FeatureName 'VirtualMachinePlatform'

    if ($script:RestartRequired) {
        throw 'WSL features were enabled. Restart Windows, then rerun this script.'
    }

    Write-Log 'Updating WSL components'
    try {
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--update')
    }
    catch {
        Write-Log 'WSL update returned a non-fatal error; continuing.'
    }

    Write-Log 'Setting WSL default version to 2'
    Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--set-default-version', '2')
}

function Ensure-DistroInstalled {
    $distrosRaw = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-q') -CaptureOutput
    $distros = @($distrosRaw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($distros -contains $DistroName) {
        Write-Log "WSL distro '$DistroName' is already installed"
    }
    else {
        Write-Log "Installing WSL distro '$DistroName'"
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $DistroName, '--no-launch')
    }

    Write-Log "Starting distro '$DistroName'"
    Invoke-WslCommand -AsRoot -Command 'echo WSL distro is ready'

    $versionTable = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -CaptureOutput
    $escapedName = [regex]::Escape($DistroName)
    $match = [regex]::Match($versionTable, "(?m)^\s*\*?\s*$escapedName\s+\S+\s+(\d+)\s*$")
    if ($match.Success -and $match.Groups[1].Value -ne '2') {
        Write-Log "Converting distro '$DistroName' to WSL2"
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--set-version', $DistroName, '2')
    }
}

function Ensure-SystemdEnabled {
    $command = @'
set -e
if grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
  echo unchanged
  exit 0
fi

tmp_file="$(mktemp)"
if [ -f /etc/wsl.conf ]; then
  awk '
    BEGIN { in_boot=0; saw_boot=0; wrote_systemd=0 }
    /^\[boot\][[:space:]]*$/ {
      saw_boot=1
      in_boot=1
      print
      next
    }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_boot && !wrote_systemd) {
        print "systemd=true"
        wrote_systemd=1
      }
      in_boot=0
      print
      next
    }
    {
      if (in_boot && $0 ~ /^[[:space:]]*systemd[[:space:]]*=/) {
        if (!wrote_systemd) {
          print "systemd=true"
          wrote_systemd=1
        }
        next
      }
      print
    }
    END {
      if (!saw_boot) {
        print ""
        print "[boot]"
        print "systemd=true"
      } else if (in_boot && !wrote_systemd) {
        print "systemd=true"
      }
    }
  ' /etc/wsl.conf > "$tmp_file"
else
  printf '[boot]\nsystemd=true\n' > "$tmp_file"
fi
cat "$tmp_file" > /etc/wsl.conf
rm -f "$tmp_file"
echo changed
'@

    $result = Invoke-WslCommand -AsRoot -Command $command -CaptureOutput
    if ($result -match 'changed') {
        Write-Log 'Enabled systemd in /etc/wsl.conf'
        Write-Log 'Restarting WSL so systemd becomes active'
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--shutdown')
        Start-Sleep -Seconds 5
        Invoke-WslCommand -AsRoot -Command 'echo WSL restarted with systemd'
    }
    else {
        Write-Log 'systemd is already enabled in /etc/wsl.conf'
    }
}

function Get-WslPrimaryUser {
    $userName = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'getent passwd 1000 | cut -d: -f1 || true'
    $userName = $userName.Trim()

    if ([string]::IsNullOrWhiteSpace($userName)) {
        return 'root'
    }

    return $userName
}

function Convert-LinuxPathToUnc {
    param([Parameter(Mandatory = $true)][string]$LinuxPath)

    $trimmed = $LinuxPath.TrimStart('/') -replace '/', '\\'
    return "\\wsl$\$DistroName\$trimmed"
}

function Copy-RepoIntoWsl {
    param([Parameter(Mandatory = $true)][string]$DestinationPath)

    $destinationLiteral = ConvertTo-BashLiteral -Value $DestinationPath
    Invoke-WslCommand -AsRoot -Command "mkdir -p $destinationLiteral"

    $uncDestination = Convert-LinuxPathToUnc -LinuxPath $DestinationPath
    Write-Log "Mirroring repo into WSL path: $DestinationPath"
    $null = New-Item -ItemType Directory -Path $uncDestination -Force

    $roboArgs = @(
        $RepoRoot,
        $uncDestination,
        '/MIR',
        '/R:2',
        '/W:2',
        '/FFT',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP'
    )

    & robocopy.exe @roboArgs | Out-Host
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "robocopy failed with exit code $code"
    }
}

function Run-WslBootstrap {
    param([Parameter(Mandatory = $true)][string]$DestinationPath)

    $destinationLiteral = ConvertTo-BashLiteral -Value $DestinationPath
    $command = "cd $destinationLiteral && bash scripts/bootstrap_wsl_post_clone.sh"
    Invoke-WslCommand -AsRoot -Command $command
}

Write-Step 'Validating Windows host'
Assert-Administrator
Assert-SupportedWindows

Write-Step 'Preparing WSL2'
Ensure-WslPlatform
Ensure-DistroInstalled
Ensure-SystemdEnabled

Write-Step 'Preparing target repo path inside WSL'
$primaryUser = Get-WslPrimaryUser
if ([string]::IsNullOrWhiteSpace($WslRepoPath)) {
    if ($primaryUser -eq 'root') {
        $WslRepoPath = "/root/$RepoName"
    }
    else {
        $WslRepoPath = "/home/$primaryUser/$RepoName"
    }
}
Write-Log "Primary WSL user: $primaryUser"
Write-Log "WSL repo path: $WslRepoPath"

Write-Step 'Copying cloned repo into the WSL filesystem'
Copy-RepoIntoWsl -DestinationPath $WslRepoPath

Write-Step 'Installing Ubuntu dependencies, k3s, and building images'
Run-WslBootstrap -DestinationPath $WslRepoPath

function Export-KubeconfigToWindows {
    $windowsKubeDir = Join-Path $env:USERPROFILE '.kube'
    $windowsKubeConfig = Join-Path $windowsKubeDir 'samba-cifs-sim-k3s.yaml'
    $linuxKubeConfig = '/etc/rancher/k3s/k3s.yaml'

    if (-not (Test-Path $windowsKubeDir)) {
        $null = New-Item -ItemType Directory -Path $windowsKubeDir -Force
    }

    Write-Log "Exporting k3s kubeconfig to $windowsKubeConfig"
    $kubeConfig = Invoke-WslCommand -AsRoot -CaptureOutput -Command "cat $(ConvertTo-BashLiteral -Value $linuxKubeConfig)"
    Set-Content -Path $windowsKubeConfig -Value $kubeConfig -Encoding utf8

    Write-Log 'Verifying kubeconfig server endpoint for Windows access'
    $kubeConfigContent = Get-Content -Path $windowsKubeConfig -Raw
    if ($kubeConfigContent -notmatch 'server:\s+https://127\.0\.0\.1:6443') {
        $updatedContent = [regex]::Replace($kubeConfigContent, 'server:\s+https://[^\s]+:6443', 'server: https://127.0.0.1:6443')
        Set-Content -Path $windowsKubeConfig -Value $updatedContent -Encoding utf8
    }

    return $windowsKubeConfig
}

Write-Step 'Copying kubeconfig to Windows'
$WindowsKubeConfigPath = Export-KubeconfigToWindows

Write-Step 'Completed'
Write-Host "WSL post-clone setup is complete." -ForegroundColor Green
Write-Host "Repo mirrored to: $WslRepoPath" -ForegroundColor Green
Write-Host "Windows kubeconfig: $WindowsKubeConfigPath" -ForegroundColor Green
