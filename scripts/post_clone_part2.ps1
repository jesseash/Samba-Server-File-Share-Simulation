
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

function Convert-LinuxPathToUnc {
    param([Parameter(Mandatory = $true)][string]$LinuxPath)

    $trimmed = $LinuxPath.TrimStart('/') -replace '/', '\\'
    return "\\wsl$\$DistroName\$trimmed"
}

function Copy-RepoIntoWsl {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$OwnerUser
    )

    $destinationLiteral = ConvertTo-BashLiteral -Value $DestinationPath
    if ($OwnerUser -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw "Invalid Linux username for ownership: $OwnerUser"
    }

    if ($OwnerUser -eq 'root') {
        Invoke-WslCommand -AsRoot -Command "mkdir -p $destinationLiteral"
    }
    else {
        Invoke-WslCommand -AsRoot -Command "mkdir -p $destinationLiteral && chown -R $OwnerUser`:$OwnerUser $destinationLiteral"
    }

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

function Setup-KubePortProxy {
    param([Parameter(Mandatory = $true)][string]$WslIp)

    Write-Log "Setting up Windows port proxy: 0.0.0.0:6443 -> ${WslIp}:6443"

    # Validate WSL IP
    if ($WslIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Invalid WSL IP address: $WslIp"
    }

    # Remove stale proxy if any (clean up both 127.0.0.1 and 0.0.0.0 variants)
    Write-Log 'Removing any existing port proxy rules on port 6443'
    foreach ($addr in @('127.0.0.1', '0.0.0.0')) {
        try {
            Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
                'interface', 'portproxy', 'delete', 'v4tov4',
                'listenport=6443', "listenaddress=$addr"
            )
        } catch {
            # No rule to remove for this address - that's fine
        }
    }

    # Add fresh proxy to current WSL IP (listen on 0.0.0.0 so loopback traffic is intercepted)
    Write-Log "Adding port proxy: 0.0.0.0:6443 -> ${WslIp}:6443"
    Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
        'interface', 'portproxy', 'add', 'v4tov4',
        'listenport=6443', 'listenaddress=0.0.0.0',
        'connectport=6443', "connectaddress=$WslIp"
    )

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
    
    Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
        'advfirewall', 'firewall', 'add', 'rule',
        'name=k3s API 6443', 'protocol=TCP', 'dir=in',
        'localport=6443', 'action=allow'
    )

    # Verify the port proxy was created
    Write-Log 'Verifying port proxy setup'
    $proxyList = Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
        'interface', 'portproxy', 'show', 'v4tov4'
    ) -CaptureOutput
    
    if ($proxyList -match '0\.0\.0\.0\s+6443.*6443\s+' + [regex]::Escape($WslIp)) {
        Write-Log "[OK] Port proxy is correctly configured"
    } else {
        Write-Log "WARNING: Port proxy may not be correctly configured. Current config:`n$proxyList"
    }

    Write-Log "Port proxy setup complete: 0.0.0.0:6443 -> ${WslIp}:6443"
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
