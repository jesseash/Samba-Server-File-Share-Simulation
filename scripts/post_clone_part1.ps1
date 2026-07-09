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
            '"' + ($arg -replace '(["\\])', '\$1') + '"'
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
