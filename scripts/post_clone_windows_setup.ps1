param(
    [string]$DistroName = "Ubuntu",
    [string]$WslRepoPath,
    [int]$BootstrapTimeoutSeconds = 3600
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
                & wsl.exe --terminate $DistroName *> $null
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
    # Write a robust bash script to a temp file
    $tempScript = [System.IO.Path]::GetTempFileName() + ".sh"
    $bashScript = @"
set -e
if [ -f /etc/wsl.conf ] \
    && grep -Eq '^\[boot\][[:space:]]*$' /etc/wsl.conf \
    && grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf; then
    echo unchanged
else
    echo -e '[boot]\nsystemd=true' > /etc/wsl.conf
    echo changed
fi
"@
    Set-Content -Path $tempScript -Value $bashScript -Encoding UTF8 -NoNewline

    $wslScript = "/tmp/ensure_systemd.sh"
    Invoke-WslCommand -AsRoot -Command "rm -f $wslScript" | Out-Null
    & wsl.exe -d $DistroName -- bash -c "cat > $wslScript" < $tempScript
    Invoke-WslCommand -AsRoot -Command "chmod +x $wslScript" | Out-Null
    $result = Invoke-WslCommand -AsRoot -Command "bash $wslScript" -CaptureOutput

    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    Invoke-WslCommand -AsRoot -Command "rm -f $wslScript" | Out-Null

    if ($result -match 'changed') {
        Write-Log 'Enabled systemd in /etc/wsl.conf'
        Write-Log 'Restarting WSL so systemd becomes active'
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--shutdown')
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

    if ($proxyList -match '127\.0\.0\.1.*6443') {
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

    Write-Log "Setting up Windows port proxy: 127.0.0.1:6443 -> ${WslIp}:6443"

    # Validate WSL IP
    if ($WslIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Invalid WSL IP address: $WslIp"
    }

    # Remove stale proxy if any
    Write-Log 'Removing any existing port proxy rule on 127.0.0.1:6443'
    try {
        Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
            'interface', 'portproxy', 'delete', 'v4tov4',
            'listenport=6443', 'listenaddress=127.0.0.1'
        )
    } catch {
        Write-Log 'No existing rule to remove'
    }

    # Add fresh proxy to current WSL IP
    Write-Log "Adding port proxy: 127.0.0.1:6443 -> ${WslIp}:6443"
    Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
        'interface', 'portproxy', 'add', 'v4tov4',
        'listenport=6443', 'listenaddress=127.0.0.1',
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
    
    if ($proxyList -match '127\.0\.0\.1\s+6443.*6443\s+' + [regex]::Escape($WslIp)) {
        Write-Log "[OK] Port proxy is correctly configured"
    } else {
        Write-Log "WARNING: Port proxy may not be correctly configured. Current config:`n$proxyList"
    }

    Write-Log "Port proxy setup complete: 127.0.0.1:6443 -> ${WslIp}:6443"
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

    Set-Content -Path $standardConfig -Value $updatedContent -Encoding utf8

    Write-Log "Successfully exported kubeconfig to: $standardConfig"
    return $standardConfig
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
}

function Main {
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
            $script:WslRepoPath = "/root/$RepoName"
        }
        else {
            $script:WslRepoPath = "/home/$primaryUser/$RepoName"
        }
    }
    Write-Log "Primary WSL user: $primaryUser"
    Write-Log "WSL repo path: $WslRepoPath"

    Write-Step 'Copying cloned repo into the WSL filesystem'
    Copy-RepoIntoWsl -DestinationPath $WslRepoPath -OwnerUser $primaryUser

    Write-Step 'Installing Ubuntu dependencies, k3s, and building images'
    Run-WslBootstrap -DestinationPath $WslRepoPath

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

    Write-Step 'Completed'
    Write-Host "WSL post-clone setup is complete." -ForegroundColor Green
    Write-Host "Repo mirrored to: $WslRepoPath" -ForegroundColor Green
    Write-Host "Windows kubeconfig: $WindowsKubeConfigPath" -ForegroundColor Green
}

Main
