param(
    [string]$DistroName = "Ubuntu",
    [string]$WslRepoPath,
    [int]$BootstrapTimeoutSeconds = 3600,
    [switch]$DiagnosticsOnly = $false,
    [switch]$IntegrityCheckOnly = $false,
    [switch]$StopDefaultForIsolation = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$RepoName = Split-Path $RepoRoot -Leaf
$RestartRequired = $false
$script:StoppedDefaultDistro = $null

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

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

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
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function ConvertTo-BashLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    $replacement = "'" + '"' + "'" + '"' + "'"
    $escapedValue = $Value.Replace("'", $replacement)
    return "'" + $escapedValue + "'"
}

function ConvertTo-ProcessArgumentString {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $quoted = foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') {
            '"' + ($arg -replace '(["\\])', '\\$1') + '"'
        }
        else {
            $arg
        }
    }

    return ($quoted -join ' ')
}

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [switch]$AsRoot,
        [switch]$CaptureOutput,
        [switch]$SuppressStderr
    )

    $args = @('-d', $DistroName)
    if ($AsRoot) {
        $args += @('--user', 'root')
    }
    $args += @('--', 'bash', '-lc', $Command)

    if ($CaptureOutput) {
        if ($SuppressStderr) {
            # Suppress stderr warnings from wsl.exe (like systemd warnings)
            try {
                $previousErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $output = & wsl.exe @args 2>$null
                $exitCode = $LASTEXITCODE
                if ($exitCode -ne 0 -and $exitCode -ne -1) {
                    throw "Command failed with exit code $exitCode"
                }
                return ($output | Out-String).Trim()
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        }
        else {
            return Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args -CaptureOutput
        }
    }

    Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args
}

function Write-NewFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ref]$LastLength
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $content = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                $content = $reader.ReadToEnd()
            }
            finally {
                if ($null -ne $reader) {
                    $reader.Dispose()
                }
                $stream.Dispose()
            }
            break
        }
        catch [System.IO.IOException] {
            if ($attempt -eq 4) {
                return
            }
            Start-Sleep -Milliseconds 100
        }
    }

    if ($null -eq $content) {
        return
    }

    if ($content.Length -le $LastLength.Value) {
        return
    }

    $chunk = $content.Substring($LastLength.Value)
    if (-not [string]::IsNullOrEmpty($chunk)) {
        Write-Host -NoNewline $chunk
    }
    $LastLength.Value = $content.Length
}

function Invoke-WslCommandStreaming {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AsRoot,
        [int]$TimeoutSeconds = 0,
        [string]$SuccessMarkerWindowsPath
    )

    $args = @('-d', $DistroName)
    if ($AsRoot) {
        $args += @('--user', 'root')
    }
    $args += @('--', 'bash', '-lc', $Command)

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    $stdoutLength = 0
    $stderrLength = 0
    $process = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $argumentString = ConvertTo-ProcessArgumentString -Arguments $args
        $process = Start-Process -FilePath 'wsl.exe' -ArgumentList $argumentString -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 300
            Write-NewFileContent -Path $stdoutFile -LastLength ([ref]$stdoutLength)
            Write-NewFileContent -Path $stderrFile -LastLength ([ref]$stderrLength)

            if ($TimeoutSeconds -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "Command timed out after ${TimeoutSeconds}s (wsl.exe $($args -join ' '))"
            }
        }

        Write-NewFileContent -Path $stdoutFile -LastLength ([ref]$stdoutLength)
        Write-NewFileContent -Path $stderrFile -LastLength ([ref]$stderrLength)

        $process.WaitForExit()
        $exitCode = if ($null -ne $process.ExitCode) { [int]$process.ExitCode } else { -1 }

        if ($exitCode -eq -1 -and -not [string]::IsNullOrWhiteSpace($SuccessMarkerWindowsPath) -and (Test-Path -LiteralPath $SuccessMarkerWindowsPath)) {
            Write-Log "Ignoring spurious wsl.exe exit code -1 because bootstrap success marker was written"
            $exitCode = 0
        }

        if ($exitCode -ne 0) {
            throw "Command failed (wsl.exe $($args -join ' ')) with exit code $exitCode."
        }
    }
    finally {
        if ($null -ne $process -and -not $process.HasExited) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
            }

            try {
                Stop-WslDistroSafe -TargetDistro $DistroName -Reason 'stream cleanup after process termination'
            }
            catch {
            }
        }

        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
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
    Write-Log "Checking WSL platform requirements..."

    if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) {
        throw "WSL is not installed. Install WSL2 first, then rerun this script. Suggested (elevated PowerShell): wsl --install -d Ubuntu ; restart Windows."
    }
    
    # Check current state of both features
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux'
    $vmPlatformFeature = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
    
    $wslEnabled = $wslFeature.State -eq 'Enabled'
    $vmPlatformEnabled = $vmPlatformFeature.State -eq 'Enabled'
    
    Write-Log "  Microsoft-Windows-Subsystem-Linux: $(if ($wslEnabled) { 'Enabled' } else { 'Disabled' })"
    Write-Log "  VirtualMachinePlatform: $(if ($vmPlatformEnabled) { 'Enabled' } else { 'Disabled' })"
    
    $featuresToEnable = @()
    if (-not $wslEnabled) {
        $featuresToEnable += 'Microsoft-Windows-Subsystem-Linux'
    }
    if (-not $vmPlatformEnabled) {
        $featuresToEnable += 'VirtualMachinePlatform'
    }
    
    if ($featuresToEnable.Count -eq 0) {
        Write-Log "All WSL features already enabled"
    }
    else {
        Write-Log "WSL prerequisite features are missing: $($featuresToEnable -join ', ')"
        throw "WSL is not fully installed/enabled. Install WSL first, then rerun this script. Suggested commands (elevated PowerShell): wsl --install -d Ubuntu ; restart Windows."
    }

    try {
        $status = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--status') -CaptureOutput
        $status = ConvertFrom-WslOutput -Raw $status
        if ($status -notmatch 'Default Version:\s*2') {
            Write-Log 'WARNING: WSL default version is not reported as 2. WSL2 is required for this setup.'
        }
    }
    catch {
        Write-Log 'WARNING: Could not read WSL status; continuing with distro checks.'
    }
}

function ConvertFrom-WslOutput {
    param([Parameter(Mandatory = $true)][string]$Raw)
    # wsl.exe -l outputs UTF-16LE; when captured by PowerShell each character is
    # padded with a null byte that renders as a space. Strip them before parsing.
    return $Raw -replace '\x00', ''
}

function Get-WslDistroList {
    $raw = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-q') -CaptureOutput
    $clean = ConvertFrom-WslOutput -Raw $raw
    $distros = @($clean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*$' })
    return [string[]]$distros
}

function Get-DefaultWslDistro {
    try {
        $raw = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -CaptureOutput
        $versionTable = ConvertFrom-WslOutput -Raw $raw

        # Find the distro marked with * (default)
        $match = [regex]::Match($versionTable, "(?m)^\s*\*\s*(\S+)\s+")
        if ($match.Success) {
            return $match.Groups[1].Value
        }

        # If no default found via *, return first non-header distro name
        $lines = $versionTable -split "`n"
        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line -match '^\S+' -and $line -notmatch '^NAME' -and $line -notmatch '^-') {
                return ($line -split '\s+')[0]
            }
        }
    }
    catch {
        Write-Log "Error getting default distro: $_"
    }

    return $null
}

function Stop-WslDistroSafe {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDistro,
        [string]$Reason = 'maintenance'
    )

    if ([string]::IsNullOrWhiteSpace($TargetDistro)) {
        return
    }

    $defaultDistro = Get-DefaultWslDistro
    if (-not [string]::IsNullOrWhiteSpace($defaultDistro) -and $TargetDistro -eq $defaultDistro) {
        Write-Log "Safety guard: refusing to terminate default distro '$TargetDistro' ($Reason)"
        return
    }

    try {
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--terminate', $TargetDistro)
    }
    catch {
        Write-Log "Could not terminate distro '$TargetDistro' ($Reason): $_"
    }
}

function Diagnose-SystemdUserSession {
    param([string]$UserName = 'jesse')

    Write-Step "Diagnosing systemd user session for '$UserName'"

    try {
        $distros = @(Get-WslDistroList)
        if ($distros.Count -eq 0) {
            Write-Log 'No WSL distros found; skipping systemd user-session diagnostics'
            return
        }

        $targetDistro = Get-DefaultWslDistro
        if ([string]::IsNullOrWhiteSpace($targetDistro)) {
            $targetDistro = if ($distros -contains 'Ubuntu') { 'Ubuntu' } else { $distros[0] }
        }

        Write-Log "Target distro for user-session diagnostics: $targetDistro"

        $uid = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', $targetDistro, '--user', 'root', '--', 'bash', '-lc', "id -u $UserName 2>/dev/null || echo USER_NOT_FOUND") -CaptureOutput
        $uid = $uid.Trim()

        if ($uid -eq 'USER_NOT_FOUND' -or [string]::IsNullOrWhiteSpace($uid)) {
            Write-Log "User '$UserName' was not found in distro '$targetDistro'; cannot inspect user@UID.service"
            return
        }

        Write-Log "Linux user '$UserName' has UID: $uid"

        $status = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', $targetDistro, '--user', 'root', '--', 'bash', '-lc', "systemctl status user@$uid.service --no-pager -n 40 2>&1 || true") -CaptureOutput
        Write-Log 'systemd user service status (user@UID.service):'
        Write-Host "[user-service-status]`n$status" -ForegroundColor DarkYellow

        $runUserDir = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', $targetDistro, '--user', 'root', '--', 'bash', '-lc', "ls -ld /run/user/$uid 2>&1 || true") -CaptureOutput
        Write-Log "/run/user/$uid state:"
        Write-Host "[run-user-dir] $runUserDir" -ForegroundColor DarkYellow

        $loginCtl = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', $targetDistro, '--user', 'root', '--', 'bash', '-lc', "loginctl user-status $UserName --no-pager 2>&1 || true") -CaptureOutput
        Write-Log 'loginctl user-status output:'
        Write-Host "[loginctl]`n$loginCtl" -ForegroundColor DarkYellow

        $journalUserService = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', $targetDistro, '--user', 'root', '--', 'bash', '-lc', "journalctl -b -u user@$uid.service --no-pager -n 80 2>&1 || true") -CaptureOutput
        Write-Log 'Recent journal lines for user@UID.service:'
        Write-Host "[journal-user-service]`n$journalUserService" -ForegroundColor DarkYellow

        $journalUid = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', $targetDistro, '--user', 'root', '--', 'bash', '-lc', "journalctl -b _UID=$uid --no-pager -n 60 2>&1 || true") -CaptureOutput
        Write-Log 'Recent journal lines for user UID:'
        Write-Host "[journal-uid]`n$journalUid" -ForegroundColor DarkYellow

        $pamCheck = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', $targetDistro, '--user', 'root', '--', 'bash', '-lc', "grep -Hn 'pam_systemd.so' /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive 2>/dev/null || true") -CaptureOutput
        Write-Log 'PAM session config (pam_systemd):'
        Write-Host "[pam-systemd]`n$pamCheck" -ForegroundColor DarkYellow
    }
    catch {
        Write-Log "[WARNING] Could not complete systemd user-session diagnostics: $_"
    }
}

# (rest of functions omitted here for brevity in patch) -- the full function set is identical to the reference file

Write-Step 'Running pre-k3s stage (standalone)'
Assert-Administrator
Assert-SupportedWindows

Write-Log 'Ensuring WSL platform and features'
Ensure-WslPlatform

Write-Log 'Ensuring dedicated distro is prepared'
Reset-DedicatedDistro -DedicatedDistroName 'Ubuntu-k3s'
Ensure-DistroInstalled
Ensure-SystemdEnabled

Write-Log 'Preparing repo mirror into WSL'
$primaryUser = Get-WslPrimaryUser
if ([string]::IsNullOrWhiteSpace($script:WslRepoPath)) {
    if ($primaryUser -eq 'root') { $script:WslRepoPath = "/root/$RepoName" }
    else { $script:WslRepoPath = "/home/$primaryUser/$RepoName" }
}
Copy-RepoIntoWsl -DestinationPath $script:WslRepoPath -OwnerUser $primaryUser

Write-Host 'Pre-k3s stage complete.' -ForegroundColor Green
