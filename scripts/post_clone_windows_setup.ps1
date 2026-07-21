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

# Inlined utility helper functions (previously in postclone-utilities.ps1)
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

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Yellow
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

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }
}

function Assert-SupportedWindows {
    # Ensure we're running on Windows
    if ($env:OS -ne 'Windows_NT') {
        throw 'This script must be run on Windows.'
    }

    # Require PowerShell 5.1+ or PowerShell Core with sufficient version
    if ($PSVersionTable -and $PSVersionTable.PSVersion) {
        if ($PSVersionTable.PSVersion.Major -lt 5) {
            throw 'PowerShell 5.0 or newer is required to run this script.'
        }
    }

    # Ensure required native commands are available
    foreach ($cmd in @('wsl.exe','netsh.exe','robocopy.exe','curl.exe')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "Required executable '$cmd' was not found in PATH. Install or add it to PATH."
        }
    }
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
                return ($line -split '\\s+')[0]
            }
        }
    }
    catch {
        Write-Log "Error getting default distro: $_"
    }

    return $null
}

function ConvertTo-BashLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    $replacement = "'" + '"' + "'" + '"' + "'"
    $escapedValue = $Value.Replace("'", $replacement)
    return "'" + $escapedValue + "'"
}

function Convert-LinuxPathToUnc {
    param([Parameter(Mandatory = $true)][string]$LinuxPath)

    $trimmed = $LinuxPath.TrimStart('/') -replace '/', '\\'
    # Build UNC as: \\wsl$\<DistroName>\<path>
    $unc = '\\wsl$\' + $DistroName + '\\' + $trimmed
    return $unc
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Run-WslBootstrap {
    param([Parameter(Mandatory = $true)][string]$DestinationPath)

    if ($BootstrapTimeoutSeconds -lt 60) {
        throw "BootstrapTimeoutSeconds must be at least 60 seconds."
    }

    $destinationLiteral = ConvertTo-BashLiteral -Value $DestinationPath
    $markerLinuxPath = "$DestinationPath/.post_clone_bootstrap_success"
    $markerLiteral = ConvertTo-BashLiteral -Value $markerLinuxPath
    $markerWindowsPath = Convert-LinuxPathToUnc -LinuxPath $markerLinuxPath

    if (Test-Path -LiteralPath $markerWindowsPath) {
        Remove-Item -LiteralPath $markerWindowsPath -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Running WSL bootstrap with timeout ${BootstrapTimeoutSeconds}s"
    $command = "rm -f $markerLiteral && cd $destinationLiteral && find . -type f -name '*.sh' -exec sed -i 's/\r$//' {} + && find . -type f -name '*.sh' -exec chmod +x {} + && if command -v timeout >/dev/null 2>&1; then timeout --foreground $BootstrapTimeoutSeconds bash scripts/bootstrap_wsl_post_clone.sh && touch $markerLiteral; else echo 'timeout command not found in WSL'; exit 124; fi"
    Invoke-WslCommandStreaming -AsRoot -Command $command -TimeoutSeconds ($BootstrapTimeoutSeconds + 120) -SuccessMarkerWindowsPath $markerWindowsPath
}

function Copy-RepoIntoWsl {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [string]$OwnerUser
    )

    $destinationLiteral = ConvertTo-BashLiteral -Value $DestinationPath
    # Ensure directory exists inside WSL
    Invoke-WslCommand -AsRoot -Command "mkdir -p $destinationLiteral"

    $uncDestination = Convert-LinuxPathToUnc -LinuxPath $DestinationPath
    Write-Log "Mirroring repo into WSL path: $DestinationPath"
    $null = New-Item -ItemType Directory -Path $uncDestination -Force

    # If provided, attempt to set ownership inside WSL before copying so Windows can write
    if (-not [string]::IsNullOrWhiteSpace($OwnerUser)) {
        if ($OwnerUser -notmatch '^[a-z_][a-z0-9_-]*$') {
            throw "Invalid Linux username for ownership: $OwnerUser"
        }

        if ($OwnerUser -ne 'root') {
            $destLit = ConvertTo-BashLiteral -Value $DestinationPath
            Write-Log "Attempting to set ownership of $DestinationPath to $OwnerUser inside WSL"
            try {
                Invoke-WslCommand -AsRoot -Command "mkdir -p $destLit && chown -R $OwnerUser`:$OwnerUser $destLit"
            }
            catch {
                Write-Log "WARNING: could not set ownership in WSL: $_"
            }
        }
    }

    $roboArgs = @(
        $RepoRoot,
        $uncDestination,
        '/MIR',
        '/XF',
        'curl-probe.log',
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
        Write-Log "robocopy failed with exit code $code; attempting backup-mode retry (/B)"

        $roboArgsBackup = $roboArgs + '/B'
        & robocopy.exe @roboArgsBackup | Out-Host
        $code2 = $LASTEXITCODE

        if ($code2 -gt 7) {
            throw "robocopy failed after backup-mode retry with exit code $code2"
        }
    }

    # Ensure ownership after copy
    if (-not [string]::IsNullOrWhiteSpace($OwnerUser) -and $OwnerUser -ne 'root') {
        $destLit = ConvertTo-BashLiteral -Value $DestinationPath
        Invoke-WslCommand -AsRoot -Command "chown -R $OwnerUser`:$OwnerUser $destLit"
    }
}

function Write-Log {
    param([string]$Message)
    Write-Host "[post-clone] $Message" -ForegroundColor Cyan
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

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AsRoot,
        [switch]$CaptureOutput,
        [switch]$SuppressStderr
    )

    $cmd = $Command
    if ($SuppressStderr) {
        $cmd = "$Command 2>/dev/null || true"
    }

    $args = @('-d', $DistroName)
    if ($AsRoot) {
        $args += @('--user', 'root')
    }
    $args += @('--', 'bash', '-lc', $cmd)

    if ($CaptureOutput) {
        return Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args -CaptureOutput
    }

    Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args
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

function Diagnose-SystemdUserSession {
    param([string]$UserName)

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

function Diagnose-UbuntuDistro {
    Write-Step 'Diagnosing WSL and Ubuntu distro health'
    
    try {
        Write-Log "Getting WSL distro list..."
        $distros = @(Get-WslDistroList)
        
        Write-Log "Distro list:"
        if ($distros.Count -eq 0) {
            Write-Log "  [WARNING] No distros found!"
        }
        else {
            foreach ($distro in $distros) {
                Write-Log "    $distro"
            }
        }
        
        Write-Log "`nGetting detailed distro version table..."
        $versionTable = ConvertFrom-WslOutput -Raw (Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -CaptureOutput)
        Write-Log "Version info:"
        $versionLines = $versionTable -split "`n"
        foreach ($line in $versionLines) {
            if ($line.Trim()) {
                Write-Log "    $($line.Trim())"
            }
        }
        
        if ($distros.Count -eq 0) {
            Write-Log "`n[WARNING] No WSL distros are installed!"
            Write-Log "To install Ubuntu, run: wsl.exe --install -d Ubuntu"
            return
        }
        
        $defaultDistro = Get-DefaultWslDistro
        if ([string]::IsNullOrWhiteSpace($defaultDistro)) {
            Write-Log "`n[INFO] Default distro marker not found, using first available: $($distros[0])"
        }
        else {
            Write-Log "`n[OK] Default distro: $defaultDistro"
        }
        
        # Check if Ubuntu distro exists (not necessarily default)
        $ubuntuFound = $false
        foreach ($distro in $distros) {
            if ($distro -match 'Ubuntu') {
                $ubuntuFound = $true
                break
            }
        }
        
        if (-not $ubuntuFound) {
            Write-Log "[WARNING] Ubuntu distro not found in WSL list"
            Write-Log "  Available distros: $($distros -join ', ')"
            return
        }
        
        Write-Log "[OK] Ubuntu distro is installed"
        Write-Log "`nChecking Ubuntu distro connectivity..."
        
        try {
            # Suppress systemd warnings - they're non-critical
            $testOutput = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'whoami'
            Write-Log "[OK] Ubuntu responds to commands as: $($testOutput.Trim())"
        }
        catch {
            Write-Log "[ERROR] Cannot run commands in Ubuntu: $_"
            Write-Log "  This indicates the distro may be corrupted or inaccessible"
            return
        }
        
        # Check /etc files
        Write-Log "`nChecking /etc directory integrity..."
        try {
            $etcCheck = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'test -f /etc/passwd && echo PASSWD_OK || echo PASSWD_MISSING'
            if ($etcCheck -match 'PASSWD_OK') {
                Write-Log "[OK] /etc/passwd exists"
            }
            else {
                Write-Log "[ERROR] /etc/passwd is missing - distro may be corrupted!"
            }
        }
        catch {
            Write-Log "[ERROR] Could not check /etc files: $_"
        }
        
        # Check main user exists
        Write-Log "`nChecking for user 'jesse'..."
        try {
            $userCheck = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'getent passwd jesse || echo USER_NOT_FOUND'
            if ($userCheck -match 'USER_NOT_FOUND') {
                Write-Log "[WARNING] User 'jesse' not found in Ubuntu distro"
                Write-Log "  Available users:"
                $users = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'cut -d: -f1 /etc/passwd | grep -v "^root$" | head -10'
                $users -split "`n" | Where-Object { $_ } | ForEach-Object { Write-Log "    - $_" }
            }
            else {
                Write-Log "[OK] User 'jesse' exists"
            }
        }
        catch {
            Write-Log "[ERROR] User check failed: $_"
        }
        
        # Check sudo configuration
        Write-Log "`nChecking sudo configuration..."
        try {
            $sudoCheck = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'test -f /etc/sudoers && echo SUDOERS_OK || echo SUDOERS_MISSING'
            if ($sudoCheck -match 'SUDOERS_MISSING') {
                Write-Log "[WARNING] /etc/sudoers configuration is missing"
            }
            else {
                Write-Log "[OK] /etc/sudoers present"
            }
        }
        catch {
            Write-Log "[ERROR] Sudo check failed: $_"
        }
        
        Diagnose-SystemdUserSession -UserName 'jesse'

        Write-Log "`n[OK] Ubuntu distro diagnostics complete - distro appears healthy"
    }
    catch {
        Write-Log "[ERROR] Diagnostics failed: $_"
    }
}

function Validate-DefaultUbuntuIntegrity {
    Write-Step 'Validating default Ubuntu distro integrity'
    
    try {
        $defaultDistro = Get-DefaultWslDistro
        Write-Log "Checking default distro: $defaultDistro"
        
        if ($defaultDistro -ne 'Ubuntu') {
            Write-Log "[WARNING] Default distro is not 'Ubuntu' - it's '$defaultDistro'"
            Write-Log "  This is OK if you have intentionally changed it"
        }
        
        # Check distro is still installed and accessible
        Write-Log "`nChecking Ubuntu distro accessibility..."
        $distros = @(Get-WslDistroList)
        
        if ($distros -notcontains 'Ubuntu') {
            Write-Host "[ERROR] Ubuntu distro is MISSING from WSL list!" -ForegroundColor Red
            Write-Host "  This indicates serious damage. Available distros: $($distros -join ', ')" -ForegroundColor Red
            return $false
        }
        Write-Log "[OK] Ubuntu is still in WSL distro list"
        
        # Check distro can be started
        Write-Log "`nAttempting to start Ubuntu and verify basic functionality..."
        try {
            $testCmd = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'uname -a'
            Write-Log "[OK] Ubuntu kernel: $($testCmd.Substring(0, [Math]::Min(80, $testCmd.Length)))"
        }
        catch {
            Write-Host "[ERROR] Cannot execute commands in Ubuntu: $_" -ForegroundColor Red
            return $false
        }
        
        # Check critical system files
        Write-Log "`nVerifying critical system files..."
        $criticalFiles = @('/etc/passwd', '/etc/shadow', '/etc/group', '/etc/hosts', '/etc/hostname')
        $allFilesOk = $true
        foreach ($file in $criticalFiles) {
            try {
                $checkCmd = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command "test -f $file && echo OK || echo MISSING"
                if ($checkCmd -match 'MISSING') {
                    Write-Log "[ERROR] Critical file missing: $file"
                    $allFilesOk = $false
                }
                else {
                    Write-Log "[OK] $file exists"
                }
            }
            catch {
                Write-Log "[ERROR] Could not check $file : $_"
                $allFilesOk = $false
            }
        }
        
        if (-not $allFilesOk) {
            Write-Host "[ERROR] Some critical system files are missing!" -ForegroundColor Red
            return $false
        }
        
        # Check filesystem
        Write-Log "`nChecking filesystem..."
        try {
            $fsCheck = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'df -h / | tail -1'
            Write-Log "  Disk usage: $($fsCheck.Trim())"
        }
        catch {
            Write-Log "[WARNING] Could not check filesystem: $_"
        }
        
        # Check users are intact
        Write-Log "`nVerifying user accounts..."
        try {
            $userCount = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'wc -l < /etc/passwd'
            Write-Log "  User accounts: $($userCount.Trim())"
            
            $jesseExists = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'getent passwd jesse >/dev/null 2>&1 && echo YES || echo NO'
            if ($jesseExists -match 'NO') {
                Write-Log "[WARNING] User 'jesse' not found"
            }
            else {
                Write-Log "[OK] User 'jesse' exists"
            }
        }
        catch {
            Write-Log "[ERROR] Could not verify users: $_"
        }
        
        # Check systemd is working
        Write-Log "`nVerifying systemd..."
        try {
            $systemdCheck = Invoke-WslCommand -AsRoot -CaptureOutput -SuppressStderr -Command 'systemctl status | head -1'
            if ($systemdCheck -match 'running|active' -or $systemdCheck.Length -gt 0) {
                Write-Log "[OK] Systemd is responsive"
            }
        }
        catch {
            Write-Log "[WARNING] Systemd status check attempted"
        }
        
        Write-Log "`n[OK] Ubuntu distro integrity check complete"
        Write-Host "`n=== INTEGRITY CHECK PASSED ===" -ForegroundColor Green
        Write-Host "Default Ubuntu distro is healthy and was NOT modified" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "`n=== INTEGRITY CHECK FAILED ===" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        return $false
    }
}

function Ensure-DistroInstalled {
    $distros = @(Get-WslDistroList)

    if ($distros -contains $DistroName) {
        Write-Log "WSL distro '$DistroName' is already installed"
    }
    else {
        # DistroName is a custom name like "Ubuntu-k3s", need to create it
        # Always create it as a separate clone; do not rename or modify existing distros
        $defaultDistro = Get-DefaultWslDistro
        Write-Log "Default distro: $(if ($defaultDistro) { $defaultDistro } else { 'none' })"

        if ($distros.Count -eq 0) {
            throw "Dedicated distro '$DistroName' is missing and no existing WSL distro is available to clone. This script will not install or modify user distros. Install a source distro manually, then rerun."
        }

        $sourceDistro = if (-not [string]::IsNullOrWhiteSpace($defaultDistro)) { $defaultDistro } else { $distros[0] }
        if ($sourceDistro -eq $DistroName) {
            throw "Source distro resolved to '$DistroName'. Refusing to clone over itself."
        }
        Write-Log "Creating dedicated distro '$DistroName' by cloning source distro '$sourceDistro'"

        $tempExportPath = [System.IO.Path]::GetTempFileName() + ".tar"
        $importRoot = Join-Path $env:LOCALAPPDATA 'WSL\distros'
        $importPath = Join-Path $importRoot $DistroName

        try {
            if (-not (Test-Path -LiteralPath $importRoot)) {
                $null = New-Item -ItemType Directory -Path $importRoot -Force
            }

            if (Test-Path -LiteralPath $importPath) {
                Write-Log "Removing stale import path: $importPath"
                Remove-Item -LiteralPath $importPath -Recurse -Force -ErrorAction SilentlyContinue
            }

            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--export', $sourceDistro, $tempExportPath)
            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--import', $DistroName, $importPath, $tempExportPath, '--version', '2')
            Write-Log "Successfully created dedicated distro '$DistroName' without modifying '$sourceDistro'"
        }
        finally {
            if (Test-Path -LiteralPath $tempExportPath) {
                Remove-Item -LiteralPath $tempExportPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log "Starting distro '$DistroName'"
    Invoke-WslCommand -AsRoot -Command 'echo WSL distro is ready'

    $versionTable = ConvertFrom-WslOutput -Raw (Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-v') -CaptureOutput)
    $escapedName = [regex]::Escape($DistroName)
    $match = [regex]::Match($versionTable, "(?m)^\s*\*?\s*$escapedName\s+\S+\s+(\d+)\s*$")
    if ($match.Success -and $match.Groups[1].Value -ne '2') {
        Write-Log "Converting distro '$DistroName' to WSL2"
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--set-version', $DistroName, '2')
    }
}

function Ensure-SystemdEnabled {#test2
    # Write a robust bash script to a temp file
    $tempScript = [System.IO.Path]::GetTempFileName() + ".sh"
    $bashScript = @"
#!/usr/bin/env bash
set -e
if [[ -f /etc/wsl.conf ]] && \
   grep -Eq '^\[boot\][[:space:]]*$' /etc/wsl.conf && \
   grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf; then
    echo unchanged
else
    echo -e '[boot]\nsystemd=true' > /etc/wsl.conf
    echo changed
fi
"@

    $bashScriptLf = $bashScript -replace "`r`n?", "`n"
    Write-Host "==== DEBUG: Script to send to WSL ====" -ForegroundColor Yellow
    Write-Host $bashScriptLf
    Write-Host "==== END DEBUG ====" -ForegroundColor Yellow

    $wslScript = "/tmp/ensure_systemd.sh"
    Invoke-WslCommand -AsRoot -Command "rm -f $wslScript" | Out-Null
    # Write the script directly inside WSL to avoid CRLF issues
    $escapedScript = $bashScriptLf.Replace("'", "'\\''")
    $echoCmd = "echo '$escapedScript' > $wslScript"
    & wsl.exe -d $DistroName -- bash -c $echoCmd
    Invoke-WslCommand -AsRoot -Command "chmod +x $wslScript" | Out-Null
    $result = Invoke-WslCommand -AsRoot -Command "/usr/bin/env bash $wslScript" -CaptureOutput

    Invoke-WslCommand -AsRoot -Command "rm -f $wslScript" | Out-Null

    if ($result -match 'changed') {
        Write-Log 'Enabled systemd in /etc/wsl.conf'
        Write-Log "Restarting dedicated distro '$DistroName' so systemd becomes active"
        Stop-WslDistroSafe -TargetDistro $DistroName -Reason 'apply systemd change'
        Start-Sleep -Seconds 5
        Invoke-WslCommand -AsRoot -Command 'echo WSL restarted with systemd' | Out-Null
    } else {
        Write-Log 'systemd is already enabled in /etc/wsl.conf'
    }
}

function Reset-DedicatedDistro {
    param([Parameter(Mandatory = $true)][string]$DedicatedDistroName)

    $distros = @(Get-WslDistroList)
    $defaultDistro = Get-DefaultWslDistro

    if ($defaultDistro -eq $DedicatedDistroName) {
        throw "Safety check failed: dedicated distro name '$DedicatedDistroName' matches the default distro. Refusing to remove it."
    }

    if ($distros -contains $DedicatedDistroName) {
        Write-Log "Removing existing dedicated distro '$DedicatedDistroName' for a clean rebuild"
        try {
            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--terminate', $DedicatedDistroName)
        }
        catch {
            Write-Log "Could not terminate '$DedicatedDistroName' before unregister; continuing"
        }

        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--unregister', $DedicatedDistroName)
        Write-Log "Dedicated distro '$DedicatedDistroName' removed"
    }
    else {
        Write-Log "Dedicated distro '$DedicatedDistroName' not present; nothing to remove"
    }
}

function Stop-DefaultDistroForIsolation {
    param([Parameter(Mandatory = $true)][string]$DedicatedDistroName)

    $defaultDistro = Get-DefaultWslDistro
    if ([string]::IsNullOrWhiteSpace($defaultDistro)) {
        Write-Log 'Default distro could not be identified; skipping default-distro isolation stop'
        return
    }

    if ($defaultDistro -eq $DedicatedDistroName) {
        Write-Log "Default distro is '$defaultDistro' which matches dedicated distro; skipping isolation stop"
        return
    }

    $distros = @(Get-WslDistroList)
    if ($distros -notcontains $defaultDistro) {
        Write-Log "Default distro '$defaultDistro' not present in WSL list; skipping isolation stop"
        return
    }

    Write-Log "Stopping default distro '$defaultDistro' to reduce cross-distro CRE conflicts during dedicated k3s setup"
    Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--terminate', $defaultDistro)
    $script:StoppedDefaultDistro = $defaultDistro
    Write-Host "`n[ISOLATION] Default distro '$defaultDistro' has been stopped." -ForegroundColor Yellow
    Write-Host "  To restart it later, run:  wsl -d $defaultDistro" -ForegroundColor Yellow
}

function Get-WslPrimaryUser {
    $userName = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'getent passwd 1000 | cut -d: -f1 || true'
    $userName = $userName.Trim()

    if ([string]::IsNullOrWhiteSpace($userName)) {
        return 'root'
    }

    return $userName
}

function Test-KubeConnection {
    Write-Step 'Verifying kubeconfig and connectivity'
    
    $kubeConfigPath = Join-Path $env:USERPROFILE '.kube\config'
    if (-not (Test-Path $kubeConfigPath)) {
        Write-Log "ERROR: kubeconfig not found at $kubeConfigPath"
        return $false
    }

    $kubeConfig = Get-Content -Path $kubeConfigPath -Raw
    
    # Check server endpoint in kubeconfig
    $serverMatch = [regex]::Match($kubeConfig, 'server:\s*(https://[^\s]+)')
    if ($serverMatch.Success) {
        $server = $serverMatch.Groups[1].Value
        Write-Log "  Kubeconfig server: $server"
        if ($server -notmatch '127\.0\.0\.1:6443') {
            Write-Log "  WARNING: Server is not 127.0.0.1:6443. Update may be needed."
        }
    } else {
        Write-Log "  ERROR: Could not parse server endpoint from kubeconfig"
    }

    # Check port proxy
    Write-Log '  Checking Windows port proxy status'
    $proxyList = Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
        'interface', 'portproxy', 'show', 'v4tov4'
    ) -CaptureOutput

    if ($proxyList -match '6443') {
        Write-Log "  [OK] Port proxy is configured"
    } else {
        Write-Log "  ERROR: Port proxy not found. Run port proxy setup again."
        return $false
    }

    # Test connectivity to 127.0.0.1:6443
    Write-Log '  Testing TCP connection to 127.0.0.1:6443'
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $tcpClient.Connect('127.0.0.1', 6443)
        $tcpClient.Close()
        Write-Log "  [OK] TCP connection successful"
    } catch {
        Write-Log "  ERROR: Cannot connect to 127.0.0.1:6443: $_"
        Write-Log "         Check that k3s is running in WSL with: wsl -d Ubuntu -u root -- systemctl status k3s"
        return $false
    }

    Write-Log '[OK] All checks passed'
    return $true
}

function Test-KubeApiEndpoint {
    param([Parameter(Mandatory = $true)][string]$ServerUrl)

    $testUrl = "$ServerUrl/version"
    Write-Log "  Probing Kubernetes API endpoint: $testUrl"

    try {
        $response = Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-k', '-sS', '--max-time', '8', $testUrl) -CaptureOutput
        if ([string]::IsNullOrWhiteSpace($response)) {
            Write-Log "  WARNING: Endpoint probe returned empty response: $testUrl"
            return $false
        }

        if ($response -match 'gitVersion|major|minor') {
            Write-Log "  [OK] Endpoint probe succeeded: $testUrl"
            return $true
        }

        Write-Log "  WARNING: Endpoint probe returned unexpected body for $testUrl"
        return $false
    }
    catch {
        Write-Log "  WARNING: Endpoint probe failed for ${testUrl}: $_"
        return $false
    }
}

function Setup-KubePortProxy {
    param([Parameter(Mandatory = $true)][string]$WslIp)
    Write-Log "Setting up Windows port proxy: 127.0.0.1:6443 -> ${WslIp}:6443"

    # Validate WSL IP
    if ($WslIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Invalid WSL IP address: $WslIp"
    }

    # Ensure we are running elevated because netsh portproxy requires admin
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Administrator privileges are required to configure portproxy. Run PowerShell as Administrator."
        }
    } catch {
        throw "Failed to determine elevation status: $_"
    }

    $maxRebindAttempts = 3
    $overallSuccess = $false
    for ($rebindAttempt = 1; $rebindAttempt -le $maxRebindAttempts; $rebindAttempt++) {
        Write-Log "Portproxy bind attempt $rebindAttempt/$maxRebindAttempts"

        # Remove stale proxy if any (clean up both 127.0.0.1 and 0.0.0.0 variants)
        Write-Log 'Removing any existing port proxy rules on port 6443'
        foreach ($addr in @('127.0.0.1', '0.0.0.0')) {
            try {
                Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
                    'interface', 'portproxy', 'delete', 'v4tov4',
                    'listenport=6443', "listenaddress=$addr"
                )
            } catch {
                # No rule to remove for this address - not fatal
            }
        }

        # Add fresh proxy to current WSL IP (listen on localhost only)
        Write-Log "Adding port proxy: 127.0.0.1:6443 -> ${WslIp}:6443"
        try {
            Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
                'interface', 'portproxy', 'add', 'v4tov4',
                'listenport=6443', 'listenaddress=127.0.0.1',
                'connectport=6443', "connectaddress=$WslIp"
            )
        } catch {
            Write-Log "WARNING: Failed to add portproxy: $_"
        }

        # Add firewall rule (idempotent - delete first then add)
        Write-Log 'Adding Windows Firewall rule for port 6443'
        try {
            Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
                'advfirewall', 'firewall', 'delete', 'rule',
                'name=k3s API 6443'
            )
        } catch {
            Write-Log 'No existing firewall rule to remove'
        }
        try {
            Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
                'advfirewall', 'firewall', 'add', 'rule',
                'name=k3s API 6443', 'protocol=TCP', 'dir=in',
                'localport=6443', 'action=allow'
            )
        } catch {
            Write-Log "WARNING: Failed to add firewall rule: $_"
        }

        # Verify the port proxy was created
        Write-Log 'Verifying port proxy setup'
        $proxyList = ''
        try {
            $proxyList = Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
                'interface', 'portproxy', 'show', 'v4tov4'
            ) -CaptureOutput
        } catch {
            Write-Log "Could not query portproxy: $_"
        }

        if ($proxyList -match '127\.0\.0\.1\s+6443.*6443\s+' + [regex]::Escape($WslIp)) {
            Write-Log "[OK] Port proxy is configured to ${WslIp}"
        } else {
            Write-Log "WARNING: Port proxy configuration unexpected. Current config:`n$proxyList"
        }

        # Probe the API over the new localhost proxy with retries to ensure TLS is ready
        Write-Log '  Probing Kubernetes API endpoint: https://127.0.0.1:6443/version'
        $probeSuccess = $false
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            Write-Log "  Probe attempt $attempt/12"
            try {
                $probeOut = Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-k','-sS','--max-time','5','https://127.0.0.1:6443/version') -CaptureOutput
            } catch {
                $probeOut = ''
            }
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($probeOut)) {
                Write-Log "  [OK] Endpoint probe returned content"
                $probeSuccess = $true
                break
            }
            Start-Sleep -Seconds ([math]::Min(8, 1 + $attempt))
        }

        if ($probeSuccess) {
            $overallSuccess = $true
            break
        }

        Write-Log "Probe failed after bind attempt $rebindAttempt; will retry rebind if attempts remain"
        Start-Sleep -Seconds 2
    }

    if (-not $overallSuccess) {
        Write-Log "ERROR: API probe failed after $maxRebindAttempts rebind attempts; last known WSL IP: ${WslIp}"
    } else {
        Write-Log "Port proxy ready and API reachable via 127.0.0.1:6443 -> ${WslIp}:6443"
    }
}

function Export-KubeconfigToWindows {
    param([string]$ApiServer = 'https://127.0.0.1:6443')

    $windowsKubeDir = Join-Path $env:USERPROFILE '.kube'
    $standardConfig = Join-Path $windowsKubeDir 'config'
    $linuxKubeConfig = '/etc/rancher/k3s/k3s.yaml'

    if (-not (Test-Path $windowsKubeDir)) {
        $null = New-Item -ItemType Directory -Path $windowsKubeDir -Force
    }

    # Clean up any old k3s-related configs to avoid Lens duplication
    @('samba-cifs-sim-k3s.yaml', 'k3s.yaml', 'k3s-config.yaml') | ForEach-Object {
        $oldPath = Join-Path $windowsKubeDir $_
        if (Test-Path $oldPath) {
            Write-Log "Removing old kubeconfig: $oldPath"
            Remove-Item $oldPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Check if k3s is running in WSL
    Write-Log 'Checking k3s service status in WSL'
    $k3sStatus = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'systemctl is-active k3s 2>/dev/null || echo inactive'
    if ($k3sStatus.Trim() -ne 'active') {
        Write-Log "WARNING: k3s is not active. Status: $($k3sStatus.Trim()). Retrying in 5 seconds..."
        Start-Sleep -Seconds 5
        $k3sStatus = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'systemctl is-active k3s 2>/dev/null || echo inactive'
        if ($k3sStatus.Trim() -ne 'active') {
            Write-Log "ERROR: k3s is still not running! Check k3s logs in WSL with: journalctl -u k3s -n 50"
            throw "k3s service is not active in WSL. Cannot export kubeconfig."
        }
    }
    Write-Log 'k3s service is active'

    Write-Log "Exporting k3s kubeconfig from $linuxKubeConfig to $standardConfig"
    $kubeConfig = Invoke-WslCommand -AsRoot -CaptureOutput -Command "cat $(ConvertTo-BashLiteral -Value $linuxKubeConfig)"
    
    if ([string]::IsNullOrWhiteSpace($kubeConfig)) {
        throw "kubeconfig file is empty or unreachable at $linuxKubeConfig"
    }

    Set-Content -Path $standardConfig -Value $kubeConfig -Encoding utf8

    Write-Log "Updating kubeconfig server endpoint to $ApiServer"
    $kubeConfigContent = Get-Content -Path $standardConfig -Raw
    
    # Extract current server endpoint for logging
    $currentServer = [regex]::Match($kubeConfigContent, 'server:\s*(https://[^\s]+)').Groups[1].Value
    Write-Log "  Current server in kubeconfig: $currentServer"

    # Replace any kube-apiserver endpoint with selected endpoint.
    $updatedContent = [regex]::Replace(
        $kubeConfigContent,
        '(?m)^\s*server:\s*https://[^\s]+\s*$',
        "    server: $ApiServer"
    )
    
    # Preserve original k3s context/user names so Lens can validate user objects reliably.
    # We only force the server endpoint to localhost for Windows port proxy routing.

    # Verify the replacement was made
    $verifyServer = [regex]::Match($updatedContent, 'server:\s*(https://[^\s]+)').Groups[1].Value
    Write-Log "  Updated server endpoint to: $verifyServer"
    
    if ($verifyServer -ne $ApiServer) {
        throw "Failed to set kubeconfig server endpoint to $ApiServer. Current endpoint: $verifyServer"
    }

    # Replace certificate-authority-data with insecure-skip-tls-verify so Freelens/Lens
    # can connect via 127.0.0.1 without needing the k3s cert to include 127.0.0.1 as a SAN.
    Write-Log "  Setting insecure-skip-tls-verify (k3s cert SANs do not cover 127.0.0.1)"
    $updatedContent = [regex]::Replace(
        $updatedContent,
        '(?m)^\s*certificate-authority-data:.*$',
        '    insecure-skip-tls-verify: true'
    )

    Set-Content -Path $standardConfig -Value $updatedContent -Encoding utf8

    Write-Log "Successfully exported kubeconfig to: $standardConfig"
    return $standardConfig
}

function Setup-DedicatedK3sDistro {
    param(
        [Parameter(Mandatory = $true)][string]$DedicatedDistroName
    )

    Write-Step "Creating dedicated k3s distro: $DedicatedDistroName"
    
    try {
        Write-Log "Initializing dedicated distro setup"
        $script:DistroName = $DedicatedDistroName
        Write-Log "Target distro name: $script:DistroName"

        Write-Log "Preparing WSL2 platform..."
        Ensure-WslPlatform
        Write-Log "[OK] WSL2 platform ready"

        Write-Log "Ensuring distro is installed..."
        Ensure-DistroInstalled
        Write-Log "[OK] Distro installed and running"

        Write-Log "Enabling systemd..."
        Ensure-SystemdEnabled
        Write-Log "[OK] systemd enabled"

        Write-Log "Detecting primary user..."
        $primaryUser = Get-WslPrimaryUser
        Write-Log "Primary user: $primaryUser"

        if ([string]::IsNullOrWhiteSpace($script:WslRepoPath)) {
            if ($primaryUser -eq 'root') {
                $script:WslRepoPath = "/root/$RepoName"
            }
            else {
                $script:WslRepoPath = "/home/$primaryUser/$RepoName"
            }
        }
        Write-Log "WSL repo path: $script:WslRepoPath"

        Write-Log "Copying repository into WSL..."
        Copy-RepoIntoWsl -DestinationPath $script:WslRepoPath -OwnerUser $primaryUser
        Write-Log "[OK] Repository copied"

        Write-Log "Running bootstrap (installing k3s and dependencies)..."
        try {
            Run-WslBootstrap -DestinationPath $script:WslRepoPath
            Write-Log "[OK] Bootstrap completed successfully"
        }
        catch {
            Write-Log "[ERROR] Bootstrap failed: $_"
            Write-Log "Collecting k3s diagnostics..."
            
            try {
                $k3sStatus = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'systemctl status k3s 2>&1 || true'
                Write-Host "[k3s-status]`n$k3sStatus" -ForegroundColor Red
            }
            catch {
                Write-Log "Could not retrieve k3s status: $_"
            }

            try {
                $k3sLog = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'journalctl -u k3s -n 100 2>&1 || true'
                Write-Host "[k3s-journal]`n$k3sLog" -ForegroundColor Red
            }
            catch {
                Write-Log "Could not retrieve k3s logs: $_"
            }

            throw "K3s installation failed. Review diagnostics above."
        }

        Write-Host "`n=== Dedicated k3s Distro Setup Successful ===" -ForegroundColor Green
        Write-Host "Distro name: $script:DistroName" -ForegroundColor Green
        Write-Host "Primary user: $primaryUser" -ForegroundColor Green
        Write-Host "Repo path in WSL: $script:WslRepoPath" -ForegroundColor Green
        Write-Host "K3s is now active in the dedicated distro" -ForegroundColor Green
    }
    catch {
        Write-Host "`n=== Dedicated k3s Distro Setup Failed ===" -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        throw
    }
}

function Configure-LensKubeconfig {
    param([Parameter(Mandatory = $true)][object]$KubeconfigPath)

    Write-Step 'Configuring Lens/OpenLens integration'

    $resolvedKubeconfigPath = if ($KubeconfigPath -is [array]) {
        [string]$KubeconfigPath[0]
    }
    else {
        [string]$KubeconfigPath
    }

    if ([string]::IsNullOrWhiteSpace($resolvedKubeconfigPath)) {
        throw 'Kubeconfig path is empty; cannot configure Lens/OpenLens.'
    }

    if (-not (Test-Path -LiteralPath $resolvedKubeconfigPath)) {
        throw "Kubeconfig path does not exist: $resolvedKubeconfigPath"
    }

    $kubeItem = Get-Item -LiteralPath $resolvedKubeconfigPath -ErrorAction Stop
    Write-Log "Kubeconfig source path: $resolvedKubeconfigPath"
    Write-Log "Kubeconfig size(bytes): $($kubeItem.Length)"
    try {
        $kubeHash = Get-FileHash -LiteralPath $resolvedKubeconfigPath -Algorithm SHA256
        Write-Log "Kubeconfig sha256: $($kubeHash.Hash)"
    }
    catch {
        Write-Log "WARNING: Could not compute kubeconfig hash: $_"
    }

    try {
        $serverLine = (Get-Content -LiteralPath $resolvedKubeconfigPath | Where-Object { $_ -match '^\s*server:\s*' } | Select-Object -First 1)
        $contextLine = (Get-Content -LiteralPath $resolvedKubeconfigPath | Where-Object { $_ -match '^\s*current-context:\s*' } | Select-Object -First 1)
        Write-Log "Kubeconfig server line: $serverLine"
        Write-Log "Kubeconfig current-context line: $contextLine"
    }
    catch {
        Write-Log "WARNING: Could not read kubeconfig content markers: $_"
    }

    $lensRoots = @()
    $candidateLensRoots = @(
        (Join-Path $env:APPDATA 'Lens'),
        (Join-Path $env:APPDATA 'OpenLens'),
        (Join-Path $env:LOCALAPPDATA 'Lens'),
        (Join-Path $env:LOCALAPPDATA 'OpenLens')
    )

    foreach ($candidateRoot in $candidateLensRoots) {
        if (Test-Path -LiteralPath $candidateRoot) {
            $lensRoots += $candidateRoot
        }
    }

    if ($lensRoots.Count -eq 0) {
        $defaultLensDir = Join-Path $env:APPDATA 'Lens'
        if (-not (Test-Path -LiteralPath $defaultLensDir)) {
            $null = New-Item -ItemType Directory -Path $defaultLensDir -Force
        }
        $lensRoots += $defaultLensDir
    }

    $lensRoots = @($lensRoots | Select-Object -Unique)
    Write-Log "Lens/OpenLens roots discovered: $($lensRoots.Count)"
    foreach ($rootPath in $lensRoots) {
        Write-Log "  root: $rootPath"
    }

    $runningProcesses = @('Lens', 'OpenLens')
    foreach ($processName in $runningProcesses) {
        $proc = Get-Process -Name $processName -ErrorAction SilentlyContinue
        if ($null -ne $proc) {
            Write-Log "Stopping running process: $processName"
            Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
        }
    }

    $env:KUBECONFIG = $resolvedKubeconfigPath
    try {
        Invoke-Native -FilePath 'setx.exe' -ArgumentList @('KUBECONFIG', $resolvedKubeconfigPath) | Out-Null
    }
    catch {
        Write-Log "WARNING: Could not persist KUBECONFIG with setx.exe; continuing."
    }

    $configuredAny = $false

    foreach ($rootPath in $lensRoots) {
        if (-not (Test-Path -LiteralPath $rootPath)) {
            Write-Log "Skipping missing Lens/OpenLens root: $rootPath"
            continue
        }

        $managedKubeDir = Join-Path $rootPath 'kubeconfigs'
        if (Test-Path -LiteralPath $managedKubeDir) {
            foreach ($staleFile in @('samba-cifs-sim-local', 'samba-cifs-sim-local.yaml', 'lens-demo-cluster')) {
                $stalePath = Join-Path $managedKubeDir $staleFile
                if (Test-Path -LiteralPath $stalePath) {
                    Remove-Item -LiteralPath $stalePath -Force -ErrorAction SilentlyContinue
                    Write-Log "  Removed stale managed kubeconfig: $stalePath"
                }
            }
        }

        Write-Log '  Using only %USERPROFILE%\.kube\config for Lens/OpenLens discovery'
        Write-Log '  Skipping direct edits to Lens/OpenLens JSON stores for compatibility'

        $configuredAny = $true
    }

    if (-not $configuredAny) {
        Write-Log 'WARNING: Lens/OpenLens config directory not found; kubeconfig was still prepared at %USERPROFILE%\.kube\config'
    }
    else {
        Write-Log "Lens/OpenLens roots configured: $($lensRoots.Count)"
    }

    Write-Log 'Skipping Lens CLI import commands (not required for recovery mode)'

    $lensExePaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Lens\Lens.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\OpenLens\OpenLens.exe')
    )

    $selectedLensExe = $null
    foreach ($exePath in $lensExePaths) {
        if (Test-Path -LiteralPath $exePath) {
            $selectedLensExe = $exePath
            break
        }
    }

    if ($null -ne $selectedLensExe) {
        Write-Log "Starting $(Split-Path -Leaf $selectedLensExe)"
        Start-Process -FilePath $selectedLensExe | Out-Null
    }

    Start-Sleep -Seconds 3
    $lensProcessCheck = Get-Process -Name @('Lens', 'OpenLens') -ErrorAction SilentlyContinue
    if ($null -eq $lensProcessCheck -and $null -ne $selectedLensExe) {
        Write-Log 'WARNING: Lens process not found after startup attempt'
        Write-Log 'Attempting automatic Lens/OpenLens safe-state reset and one restart'

        foreach ($rootPath in $lensRoots) {
            if (-not (Test-Path -LiteralPath $rootPath)) {
                continue
            }

            $backupStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupDir = Join-Path $rootPath ("recovery-backup-$backupStamp")
            $null = New-Item -ItemType Directory -Path $backupDir -Force

            foreach ($stateFile in @('lens-user-store.json', 'lens-cluster-store.json', 'config.json')) {
                $sourcePath = Join-Path $rootPath $stateFile
                if (-not (Test-Path -LiteralPath $sourcePath)) {
                    continue
                }

                $destPath = Join-Path $backupDir $stateFile
                try {
                    Move-Item -LiteralPath $sourcePath -Destination $destPath -Force
                    Write-Log "  Backed up potentially incompatible file: $sourcePath"
                }
                catch {
                    Write-Log "WARNING: Could not back up ${sourcePath}: $_"
                }
            }

            # Back up and clear Lens/OpenLens/Freelens cache entries to avoid stale certificates or cached kubeconfigs
            foreach ($cacheName in @('kubeconfigs','lens-cluster-store','clusters','kube-cache')) {
                $cachePath = Join-Path $rootPath $cacheName
                if (-not (Test-Path -LiteralPath $cachePath)) {
                    Write-Log "  Cache not present: $cachePath"
                    continue
                }

                Write-Log "  Found cache path: $cachePath"
                $cacheDest = Join-Path $backupDir $cacheName

                try {
                    $item = Get-Item -LiteralPath $cachePath -ErrorAction Stop
                    if ($item.PSIsContainer) {
                        Move-Item -LiteralPath $cachePath -Destination $cacheDest -Force
                        Write-Log "  Backed up and removed cache directory: $cachePath"
                    }
                    else {
                        Move-Item -LiteralPath $cachePath -Destination $cacheDest -Force
                        Write-Log "  Backed up file: $cachePath"
                    }
                }
                catch {
                    Write-Log "WARNING: Could not move cache entry ${cachePath}: $($_) - attempting delete"
                    try {
                        if (Test-Path -LiteralPath $cachePath) {
                            Remove-Item -LiteralPath $cachePath -Recurse -Force -ErrorAction SilentlyContinue
                            Write-Log "  Deleted cache entry: ${cachePath}"
                        }
                    }
                    catch {
                        Write-Log "WARNING: Failed to clear cache entry ${cachePath}: $($_)"
                    }
                }
            }
        }

        Start-Process -FilePath $selectedLensExe | Out-Null
        Start-Sleep -Seconds 4
        $lensProcessCheck = Get-Process -Name @('Lens', 'OpenLens') -ErrorAction SilentlyContinue
    }

    if ($null -ne $lensProcessCheck) {
        $lensPidValues = @($lensProcessCheck | ForEach-Object { $_.Id })
        Write-Log "Lens/OpenLens process running: PID=$($lensPidValues -join ', ')"
    }
    else {
        Write-Log 'WARNING: Lens process still not running after recovery attempt'
    }

    Write-Step 'Lens diagnostics summary'
    Write-Log "User KUBECONFIG env (process): $env:KUBECONFIG"
    $userKubeconfig = [Environment]::GetEnvironmentVariable('KUBECONFIG', 'User')
    Write-Log "User KUBECONFIG env (user profile): $userKubeconfig"

    $lensLogRoots = @(
        (Join-Path $env:APPDATA 'Lens\logs'),
        (Join-Path $env:LOCALAPPDATA 'Lens\logs'),
        (Join-Path $env:APPDATA 'OpenLens\logs'),
        (Join-Path $env:LOCALAPPDATA 'OpenLens\logs')
    )

    foreach ($logRoot in $lensLogRoots) {
        if (-not (Test-Path -LiteralPath $logRoot)) {
            continue
        }

        Write-Log "Inspecting log folder: $logRoot"
        $recentLog = Get-ChildItem -Path $logRoot -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -eq $recentLog) {
            Write-Log '  No log files found'
            continue
        }

        Write-Log "  Latest log: $($recentLog.FullName)"
        try {
            $logTail = Get-Content -LiteralPath $recentLog.FullName -Tail 40 -ErrorAction Stop
            Write-Log '  Last 40 log lines:'
            foreach ($line in $logTail) {
                Write-Host "[lens-log] $line" -ForegroundColor DarkCyan
            }

            $errorMatches = Select-String -Path $recentLog.FullName -Pattern 'REJECTED|error|failed|storage-initialization|uncaught|exception' -CaseSensitive:$false -ErrorAction SilentlyContinue |
                Select-Object -Last 20
            if ($null -ne $errorMatches -and @($errorMatches).Count -gt 0) {
                Write-Log '  Recent Lens error-like lines:'
                foreach ($match in $errorMatches) {
                    Write-Host "[lens-err] $($match.Line)" -ForegroundColor Magenta
                }
            }
            else {
                Write-Log '  No error-like lines found in latest log scan'
            }
        }
        catch {
            Write-Log "  Could not read log tail: $_"
        }
    }

    # --- Lens / Windows connectivity diagnostics ---
    Write-Step 'Lens & Windows connectivity diagnostics'
    try {
        Write-Log 'Querying Windows portproxy status'
        $proxyList = Invoke-Native -FilePath 'netsh.exe' -ArgumentList @('interface','portproxy','show','v4tov4') -CaptureOutput
        Write-Log "Portproxy list:\n$proxyList"
    }
    catch {
        Write-Log "Could not query portproxy: $_"
    }

    try {
        Write-Log 'Testing Kubernetes API via localhost from Windows (curl.exe)'
        $curlLocal = Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-k','-sS','--max-time','8','https://127.0.0.1:6443/version') -CaptureOutput
        if ([string]::IsNullOrWhiteSpace($curlLocal)) { Write-Log 'curl to https://127.0.0.1:6443 returned empty response' } else { Write-Log "curl localhost returned (truncated): $($curlLocal.Substring(0,[Math]::Min(400,$curlLocal.Length)))" }
    }
    catch {
        Write-Log "curl localhost failed: $_"
    }

    try {
        Write-Log 'Testing Kubernetes API via kubeconfig server entry (from Windows)'
        $serverLine = (Get-Content -LiteralPath $resolvedKubeconfigPath | Where-Object { $_ -match '^\s*server:\s*' } | Select-Object -First 1)
        $serverUrl = ($serverLine -replace '^\s*server:\s*','').Trim()
        if (-not [string]::IsNullOrWhiteSpace($serverUrl)) {
            $curlServer = Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-k','-sS','--max-time','8',$serverUrl) -CaptureOutput
            if ([string]::IsNullOrWhiteSpace($curlServer)) { Write-Log "curl to $serverUrl returned empty response" } else { Write-Log "curl $serverUrl returned (truncated): $($curlServer.Substring(0,[Math]::Min(400,$curlServer.Length)))" }
        }
        else {
            Write-Log 'No server URL found in kubeconfig for server-side curl test'
        }
    }
    catch {
        Write-Log "curl serverUrl failed: $_"
    }

    try {
        Write-Log 'Checking Windows firewall rule for k3s API (k3s API 6443)'
        $fw = Invoke-Native -FilePath 'netsh.exe' -ArgumentList @('advfirewall','firewall','show','rule','name=k3s API 6443') -CaptureOutput
        Write-Log "Firewall rule output:\n$fw"
    }
    catch {
        Write-Log "Firewall query failed: $_"
    }

    try {
        Write-Log 'Reporting KUBECONFIG environment and sample kubeconfig contents (first 40 lines)'
        $userKube = [Environment]::GetEnvironmentVariable('KUBECONFIG','User')
        Write-Log "User KUBECONFIG env: $userKube"
        if (Test-Path -LiteralPath $resolvedKubeconfigPath) {
            $head = Get-Content -LiteralPath $resolvedKubeconfigPath -TotalCount 40 -ErrorAction SilentlyContinue | Out-String
            Write-Log "Kubeconfig (head):\n$head"
        }
    }
    catch {
        Write-Log "Could not read kubeconfig sample: $_"
    }
}

function Show-K3sFailureDiagnostics {
    Write-Log 'Collecting k3s diagnostics after stability check failure'

    try {
        $nodeStatus = Invoke-WslCommand -AsRoot -CaptureOutput -Command '/usr/local/bin/k3s kubectl get nodes -o wide || true'
        Write-Host "[diag] kubectl get nodes -o wide`n$nodeStatus" -ForegroundColor DarkYellow
    }
    catch {
        Write-Log "  Could not collect node status: $_"
    }

    try {
        $podStatus = Invoke-WslCommand -AsRoot -CaptureOutput -Command '/usr/local/bin/k3s kubectl -n default get pods -o wide || true'
        Write-Host "[diag] kubectl -n default get pods -o wide`n$podStatus" -ForegroundColor DarkYellow
    }
    catch {
        Write-Log "  Could not collect default pod status: $_"
    }

    try {
        $k3sLog = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'journalctl -u k3s -n 120 --no-pager || true'
        Write-Host "[diag] journalctl -u k3s -n 120`n$k3sLog" -ForegroundColor DarkYellow
    }
    catch {
        Write-Log "  Could not collect k3s journal: $_"
    }

    try {
        $containerdLog = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'journalctl -u containerd -n 120 --no-pager || true'
        Write-Host "[diag] journalctl -u containerd -n 120`n$containerdLog" -ForegroundColor DarkYellow
    }
    catch {
        Write-Log "  Could not collect containerd journal: $_"
    }
}

function Assert-ClusterStability {
    Write-Step 'Verifying cluster stability'

    try {
        Write-Log 'Waiting for node readiness'
        Invoke-WslCommand -AsRoot -Command '/usr/local/bin/k3s kubectl wait --for=condition=Ready node --all --timeout=240s'

        Write-Log 'Waiting for samba deployment rollout'
        Invoke-WslCommand -AsRoot -Command '/usr/local/bin/k3s kubectl -n default rollout status deployment/samba --timeout=240s'

        Write-Log 'Waiting for samba-users deployment rollout'
        Invoke-WslCommand -AsRoot -Command '/usr/local/bin/k3s kubectl -n default rollout status deployment/samba-users --timeout=300s'

        Write-Log 'Checking for non-Running pods in default namespace'
        $cmd = @'
    /usr/local/bin/k3s kubectl -n default get pods --field-selector=status.phase!=Running -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers 2>/dev/null
'@
        $nonRunning = Invoke-WslCommand -AsRoot -CaptureOutput -Command $cmd
        $nonRunning = $nonRunning.Trim()
        if (-not [string]::IsNullOrWhiteSpace($nonRunning)) {
            throw "Detected non-Running default pods after rollout:`n$nonRunning"
        }

        Write-Log 'Waiting for sustained stability window (90s with 10s checks)'
        $requiredStableChecks = 9
        $stableChecks = 0
        while ($stableChecks -lt $requiredStableChecks) {
            $cmd = @'
/usr/local/bin/k3s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -v True || true
'@
            $nodeNotReady = Invoke-WslCommand -AsRoot -CaptureOutput -Command $cmd
            $nodeNotReady = $nodeNotReady.Trim()

            $cmd = @'
/usr/local/bin/k3s kubectl -n default get pods --field-selector=status.phase!=Running -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers 2>/dev/null
'@
            $nonRunningNow = Invoke-WslCommand -AsRoot -CaptureOutput -Command $cmd
            $nonRunningNow = $nonRunningNow.Trim()

            if ([string]::IsNullOrWhiteSpace($nodeNotReady) -and [string]::IsNullOrWhiteSpace($nonRunningNow)) {
                $stableChecks += 1
                Write-Log "  Stability check $stableChecks/$requiredStableChecks passed"
            }
            else {
                $stableChecks = 0
                if (-not [string]::IsNullOrWhiteSpace($nodeNotReady)) {
                    Write-Log "  Node not Ready during stability window:`n$nodeNotReady"
                }
                if (-not [string]::IsNullOrWhiteSpace($nonRunningNow)) {
                    Write-Log "  Non-Running pods during stability window:`n$nonRunningNow"
                }
            }

            if ($stableChecks -lt $requiredStableChecks) {
                Start-Sleep -Seconds 10
            }
        }

        Write-Log '[OK] Cluster stability checks passed'
    }
    catch {
        Show-K3sFailureDiagnostics
        throw "Cluster stability verification failed: $_"
    }
}

function Verify-ClientFilesystemActivity {
    Write-Step 'Verifying client pod file-system activity'

    try {
        $clientPod = Invoke-WslCommand -AsRoot -CaptureOutput -Command "/usr/local/bin/k3s kubectl -n default get pod -o name | grep '^pod/samba-users-' | head -1 | cut -d/ -f2"
        $clientPod = $clientPod.Trim()
        if ([string]::IsNullOrWhiteSpace($clientPod)) {
            throw 'No running samba-users pod found for client activity check.'
        }

        $sambaPod = Invoke-WslCommand -AsRoot -CaptureOutput -Command "/usr/local/bin/k3s kubectl -n default get pod -o name | grep '^pod/samba-' | grep -v samba-users | head -1 | cut -d/ -f2"
        $sambaPod = $sambaPod.Trim()
        if ([string]::IsNullOrWhiteSpace($sambaPod)) {
            throw 'No samba server pod found for activity verification.'
        }

        $sambaContainer = Invoke-WslCommand -AsRoot -CaptureOutput -Command "/usr/local/bin/k3s kubectl -n default get pod $sambaPod -o jsonpath='{.spec.containers[0].name}'"
        $sambaContainer = $sambaContainer.Trim()
        if ([string]::IsNullOrWhiteSpace($sambaContainer)) {
            $sambaContainer = 'samba'
        }

        Write-Log "Selected client pod: $clientPod"
        Write-Log "Selected samba pod: $sambaPod (container: $sambaContainer)"

        $clientLogs = Invoke-WslCommand -AsRoot -CaptureOutput -Command "/usr/local/bin/k3s kubectl -n default logs $clientPod --tail=80 2>/dev/null || true"
        $clientLogs = $clientLogs.Trim()
        if ([string]::IsNullOrWhiteSpace($clientLogs)) {
            Write-Log 'WARNING: Client logs were empty or unavailable at this time'
        }
        else {
            Write-Log 'Recent client pod logs (tail=80):'
            foreach ($line in ($clientLogs -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Write-Host "[client-log] $line" -ForegroundColor DarkCyan
                }
            }
        }

        $proofToken = "proof-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $proofFile = '.post-clone-client-proof.txt'

        $writeCommand = @"
    /usr/local/bin/k3s kubectl -n default exec $clientPod -- sh -lc 'if [ -d /mnt/samba ]; then printf "%s" "$proofToken" > /mnt/samba/$proofFile && sync && echo WRITE_OK; else echo MOUNT_MISSING; fi' 2>/dev/null || true
"@.Trim()
        $writeResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command $writeCommand
        $writeResult = $writeResult.Trim()
        if ($writeResult -notmatch 'WRITE_OK') {
            throw "Client write probe failed. Result: $writeResult"
        }

        $verifyCommand = @"
    /usr/local/bin/k3s kubectl -n default exec $sambaPod -c $sambaContainer -- sh -lc 'if [ -f /srv/shares/public_share/$proofFile ]; then cat /srv/shares/public_share/$proofFile; elif [ -f /data/samba/$proofFile ]; then cat /data/samba/$proofFile; else echo PROOF_FILE_NOT_FOUND; fi' 2>/dev/null || true
"@.Trim()
        $readBack = Invoke-WslCommand -AsRoot -CaptureOutput -Command $verifyCommand
        $readBack = $readBack.Trim()

        if ($readBack -eq $proofToken) {
            Write-Log "[OK] Client file-system updates are working (token '$proofToken' verified on samba volume)."
        }
        else {
            throw "Client write token was not found on samba volume. Expected '$proofToken', got '$readBack'."
        }
    }
    catch {
        throw "Client file-system activity verification failed: $_"
    }
}

function Main {
    Write-Step 'Validating Windows host'
    Assert-Administrator
    Assert-SupportedWindows

    $defaultDistroAtStart = Get-DefaultWslDistro
    Write-Log "Default distro at start: $defaultDistroAtStart"

    Write-Step 'Ensuring dedicated k3s distro exists'
    Write-Log "Skipping unconditional removal of 'Ubuntu-k3s'; the script will create it if missing"

    if ($DiagnosticsOnly) {
        Write-Step 'Running diagnostics only'
        Diagnose-UbuntuDistro
        Write-Host "`nDiagnostics complete. Use without -DiagnosticsOnly to run full setup." -ForegroundColor Cyan
        return
    }

    if ($IntegrityCheckOnly) {
        Write-Step 'Running integrity check only'
        $result = Validate-DefaultUbuntuIntegrity
        if ($result) {
            Write-Host "`nIntegrity check passed. Default Ubuntu distro is safe." -ForegroundColor Green
        }
        else {
            Write-Host "`nIntegrity check FAILED! Default Ubuntu distro may be damaged." -ForegroundColor Red
        }
        return
    }

    Diagnose-UbuntuDistro
    Validate-DefaultUbuntuIntegrity

    if ($StopDefaultForIsolation) {
        Write-Step 'Stopping default distro for isolation'
        Stop-DefaultDistroForIsolation -DedicatedDistroName 'Ubuntu-k3s'
    }
    else {
        Write-Log 'Default-distro isolation stop is disabled by parameter'
    }

    Setup-DedicatedK3sDistro -DedicatedDistroName 'Ubuntu-k3s'

    Write-Step 'Starting dedicated k3s distro'
    Write-Log "Ensuring 'Ubuntu-k3s' is running..."
    Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', 'Ubuntu-k3s', '--', 'echo', 'distro ready')
    Write-Host "[OK] Dedicated distro 'Ubuntu-k3s' is now active." -ForegroundColor Green
    Write-Host "  To open a shell inside it, run:  wsl -d Ubuntu-k3s" -ForegroundColor Green

    Assert-ClusterStability

    Write-Step 'Configuring Windows port proxy for k3s API (required for Lens)'
    $wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "ip -4 -o addr show dev eth0 | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -n1").Trim()
    if ([string]::IsNullOrWhiteSpace($wslIp)) {
        $wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "hostname -I | tr ' ' '\n' | sed -n '1p'").Trim()
    }

    $selectedApiServer = 'https://127.0.0.1:6443'
    if ([string]::IsNullOrWhiteSpace($wslIp)) {
        Write-Log 'WARNING: Could not determine WSL IP; Lens may not connect automatically'
    } else {
        Setup-KubePortProxy -WslIp $wslIp

        if (Test-KubeApiEndpoint -ServerUrl 'https://127.0.0.1:6443') {
            $selectedApiServer = 'https://127.0.0.1:6443'
            Write-Log 'Using localhost API endpoint through Windows port proxy'
        }
        elseif (Test-KubeApiEndpoint -ServerUrl ("https://$wslIp:6443")) {
            $selectedApiServer = "https://$wslIp:6443"
            Write-Log "WARNING: Falling back to direct WSL API endpoint: $selectedApiServer"
        }
        else {
            Write-Log 'WARNING: Could not verify Kubernetes API endpoint on either localhost proxy or direct WSL IP'
        }
    }

    Write-Step 'Copying kubeconfig to Windows'
    $WindowsKubeConfigPath = Export-KubeconfigToWindows -ApiServer $selectedApiServer

    Configure-LensKubeconfig -KubeconfigPath $WindowsKubeConfigPath

    Verify-ClientFilesystemActivity

    Write-Step 'Completed'
    # Attempt to start the persistent WSL session helper on Windows (if present)
    <#try {
        $startCmdPath = Join-Path $PSScriptRoot 'start_ubuntu_k3s.cmd'
        if (Test-Path -LiteralPath $startCmdPath) {
            Write-Log "Starting persistent WSL session helper: $startCmdPath"
            try {
                # Launch via cmd.exe /c start "" so the helper runs in a detached Windows cmd window
                $cmdArgs = "/c start "" `"$startCmdPath`""
                Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WindowStyle Normal -ErrorAction Stop | Out-Null
                Write-Log 'Launched start_ubuntu_k3s.cmd in a new Windows command window'
            }
            catch {
                Write-Log "WARNING: Could not start start_ubuntu_k3s.cmd: $_"
            }
        }
        else {
            Write-Log "start_ubuntu_k3s.cmd not found at: $startCmdPath (skipping)"
        }
    }
    catch {
        Write-Log "WARNING: Unexpected error while attempting to start persistent WSL helper: $_"
    }#>
    $defaultDistroAtEnd = Get-DefaultWslDistro
    Write-Log "Default distro at end: $defaultDistroAtEnd"
    Write-Host "`n======================================================" -ForegroundColor Green
    Write-Host " WSL post-clone setup is complete." -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  Repo mirrored to    : $script:WslRepoPath" -ForegroundColor Green
    Write-Host "  Windows kubeconfig  : $WindowsKubeConfigPath" -ForegroundColor Green
    Write-Host "  Active k3s distro   : wsl -d Ubuntu-k3s" -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($script:StoppedDefaultDistro)) {
        Write-Host "`n  NOTE: Your default distro '$($script:StoppedDefaultDistro)' was stopped for isolation." -ForegroundColor Yellow
        Write-Host "        To restart it, run:  wsl -d $($script:StoppedDefaultDistro)" -ForegroundColor Yellow
    }
    Write-Host "======================================================`n" -ForegroundColor Green
}

Main
