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
        $nonRunning = Invoke-WslCommand -AsRoot -CaptureOutput -Command "/usr/local/bin/k3s kubectl -n default get pods --no-headers 2>/dev/null | awk '\$3 != \"Running\" {print \$1 \" \$3\"}'"
        $nonRunning = $nonRunning.Trim()
        if (-not [string]::IsNullOrWhiteSpace($nonRunning)) {
            throw "Detected non-Running default pods after rollout:`n$nonRunning"
        }

        Write-Log 'Waiting for sustained stability window (90s with 10s checks)'
        $requiredStableChecks = 9
        $stableChecks = 0
        while ($stableChecks -lt $requiredStableChecks) {
            $nodeNotReady = Invoke-WslCommand -AsRoot -CaptureOutput -Command "/usr/local/bin/k3s kubectl get nodes --no-headers 2>/dev/null | awk '\$2 != \"Ready\" {print \$1 \" \$2}'"
            $nodeNotReady = $nodeNotReady.Trim()

            $nonRunningNow = Invoke-WslCommand -AsRoot -CaptureOutput -Command "/usr/local/bin/k3s kubectl -n default get pods --no-headers 2>/dev/null | awk '\$3 != \"Running\" {print \$1 \" \$3}'"
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

        $writeCommand = "/usr/local/bin/k3s kubectl -n default exec $clientPod -- sh -lc 'if [ -d /mnt/samba ]; then printf \"%s\\n\" \"$proofToken\" > /mnt/samba/$proofFile && sync && echo WRITE_OK; else echo MOUNT_MISSING; fi' 2>/dev/null || true"
        $writeResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command $writeCommand
        $writeResult = $writeResult.Trim()
        if ($writeResult -notmatch 'WRITE_OK') {
            throw "Client write probe failed. Result: $writeResult"
        }

        $verifyCommand = "/usr/local/bin/k3s kubectl -n default exec $sambaPod -c $sambaContainer -- sh -lc 'if [ -f /srv/shares/public_share/$proofFile ]; then cat /srv/shares/public_share/$proofFile; elif [ -f /data/samba/$proofFile ]; then cat /data/samba/$proofFile; else echo PROOF_FILE_NOT_FOUND; fi' 2>/dev/null || true"
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

    Write-Step 'Provisional reset of dedicated k3s distro'
    Reset-DedicatedDistro -DedicatedDistroName 'Ubuntu-k3s'

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
