<#
Post-clone utility functions extracted from post_clone_windows_setup.ps1
These are helper functions not directly invoked by `Main`.
#>

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

function Convert-LinuxPathToUnc {
    param([Parameter(Mandatory = $true)][string]$LinuxPath)

    $trimmed = $LinuxPath.TrimStart('/') -replace '/', '\\'
    return "\\wsl$\$DistroName\$trimmed"
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
    $escapedScript = $bashScriptLf.Replace("'", "'\''")
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

function Get-WslPrimaryUser {
    $userName = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'getent passwd 1000 | cut -d: -f1 || true'
    $userName = $userName.Trim()

    if ([string]::IsNullOrWhiteSpace($userName)) {
        return 'root'
    }

    return $userName
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

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
