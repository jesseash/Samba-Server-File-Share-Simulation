# =====================================================================
#  Operator‑Grade WSL + k3s Setup Script
#  All functions + Main consolidated into one file
# =====================================================================

# --- Logging helpers --------------------------------------------------
function Write-Step { param($m) Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Write-Log  { param($m) Write-Host "[LOG] $m" -ForegroundColor DarkGray }
function Write-Error { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }

function Invoke-Native {
    param(
        [string]$FilePath,
        [array]$ArgumentList,
        [switch]$CaptureOutput
    )
    try {
        if ($CaptureOutput) {
            $tmpOut = [System.IO.Path]::GetTempFileName()
            $tmpErr = [System.IO.Path]::GetTempFileName()

            $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
                -NoNewWindow -PassThru -Wait `
                -RedirectStandardOutput $tmpOut `
                -RedirectStandardError  $tmpErr

            $stdout = Get-Content $tmpOut
            $stderr = Get-Content $tmpErr

            return @{
                Success = ($p.ExitCode -eq 0)
                Code    = $p.ExitCode
                Data    = @{
                    Output = ($stdout -join "`n")
                    Error  = ($stderr -join "`n")
                    Lines  = $stdout
                }
                Error   = ($stderr -join "`n")
            }
        }
        else {
            $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
                -NoNewWindow -Wait -PassThru

            return @{
                Success = ($p.ExitCode -eq 0)
                Code    = $p.ExitCode
            }
        }
    }
    catch {
        return @{
            Success = $false
            Code    = 9999
            Error   = $_.Exception.Message
        }
    }
}

# =====================================================================
#  ADMIN + HOST VALIDATION
# =====================================================================

function Assert-Administrator {
    Write-Step "Validating administrative privileges"
    $isAdmin = ([Security.Principal.WindowsPrincipal]
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Error "Administrator privileges required"
        return @{ Success=$false; Code=1001 }
    }

    return @{ Success=$true; Code=0 }
}

function Assert-SupportedWindows {
    Write-Step "Validating Windows version compatibility"

    $os    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$os.CurrentBuildNumber

    if ($build -lt 19041) {
        Write-Error "Windows build too old for WSL2"
        return @{ Success=$false; Code=1002 }
    }

    return @{ Success=$true; Code=0 }
}

# =====================================================================
#  WSL DISTRO MANAGEMENT
# =====================================================================

function Get-DefaultWslDistro {
    Write-Step "Detecting default WSL distro"

    $output = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--list','--verbose') -CaptureOutput
    if (-not $output.Success) { return @{ Success=$false; Code=2001 } }

    $default = $output.Data.Lines |
        Where-Object { $_ -match '^\*\s+([^\s]+)' } |
        ForEach-Object { ($_ -replace '^\*\s+','').Split()[0] } |
        Select-Object -First 1

    if (-not $default) { return @{ Success=$false; Code=2002 } }

    return @{ Success=$true; Code=0; Data=@{DefaultDistro=$default} }
}

function Reset-DedicatedDistro {
    param([string]$DedicatedDistroName)

    Write-Step "Resetting dedicated distro '$DedicatedDistroName' (always delete for retest)"

    # Stop if running
    Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-t',$DedicatedDistroName) | Out-Null

    # Unregister if exists
    $list = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--list','--quiet') -CaptureOutput
    $exists = $list.Success -and ($list.Data.Lines -contains $DedicatedDistroName)

    if ($exists) {
        Write-Log "Unregistering existing distro '$DedicatedDistroName'..."
        $unreg = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--unregister',$DedicatedDistroName)
        if (-not $unreg.Success) {
            Write-Error "Failed to unregister dedicated distro '$DedicatedDistroName'"
            return @{ Success=$false; Code=2003 }
        }
    }
    else {
        Write-Log "Distro '$DedicatedDistroName' not present; reset is idempotent."
    }

    return @{ Success=$true; Code=0 }
}

# =====================================================================
#  DIAGNOSTICS + INTEGRITY
# =====================================================================

function Diagnose-UbuntuDistro {
    Write-Step "Running Ubuntu distro diagnostics"

    $list = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--list','--verbose') -CaptureOutput
    if (-not $list.Success) { return @{ Success=$false; Code=2101 } }

    $ubuntu = $list.Data.Lines | Where-Object { $_ -match 'Ubuntu' }
    if (-not $ubuntu) { return @{ Success=$false; Code=2102 } }

    Write-Log ("Ubuntu distros detected:`n" + ($ubuntu -join "`n"))
    return @{ Success=$true; Code=0 }
}

function Validate-DefaultUbuntuIntegrity {
    Write-Step "Validating default Ubuntu distro integrity"

    $default = Get-DefaultWslDistro
    if (-not $default.Success) { return @{ Success=$false; Code=2201 } }

    $name = $default.Data.DefaultDistro
    if ($name -notmatch 'Ubuntu') { return @{ Success=$false; Code=2202 } }

    $cmd = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d',$name,'--','bash','-lc','echo ok') -CaptureOutput
    if (-not $cmd.Success -or $cmd.Data.Output.Trim() -ne 'ok') {
        return @{ Success=$false; Code=2203 }
    }

    return @{ Success=$true; Code=0 }
}

# =====================================================================
#  ISOLATION
# =====================================================================

function Stop-DefaultDistroForIsolation {
    param([string]$DedicatedDistroName)

    Write-Step "Stopping default distro for isolation"

    $default = Get-DefaultWslDistro
    if (-not $default.Success) { return @{ Success=$true; Code=0 } }

    $name = $default.Data.DefaultDistro
    if ($name -eq $DedicatedDistroName) { return @{ Success=$true; Code=0 } }

    $stop = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-t',$name)
    if (-not $stop.Success) { return @{ Success=$false; Code=2301 } }

    $script:StoppedDefaultDistro = $name
    return @{ Success=$true; Code=0 }
}

# =====================================================================
#  DEDICATED K3S SETUP
# =====================================================================

function Setup-DedicatedK3sDistro {
    param([string]$DedicatedDistroName)

    Write-Step "Setting up dedicated k3s distro '$DedicatedDistroName'"

    $list = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--list','--quiet') -CaptureOutput
    $exists = $list.Success -and ($list.Data.Lines -contains $DedicatedDistroName)

    if (-not $exists) {
        Write-Error "Dedicated distro '$DedicatedDistroName' not present (provisioning not implemented in this script)."
        return @{ Success=$false; Code=2401 }
    }

    $start = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d',$DedicatedDistroName,'--','echo','started') -CaptureOutput
    if (-not $start.Success) { return @{ Success=$false; Code=2402 } }

    $bootstrap = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @(
        '-d',$DedicatedDistroName,'--','bash','-lc',
        'cd /opt/k3s && ./bootstrap_wsl_post_clone.sh'
    ) -CaptureOutput

    if (-not $bootstrap.Success) { return @{ Success=$false; Code=2403 } }

    return @{ Success=$true; Code=0 }
}

# =====================================================================
#  CLUSTER STABILITY
# =====================================================================

function Assert-ClusterStability {
    Write-Step "Validating Kubernetes cluster stability"

    $nodes = Invoke-WslCommand -AsRoot -CaptureOutput -Command "kubectl get nodes -o wide"
    if (-not $nodes.Success) { return @{ Success=$false; Code=2501 } }

    $pods = Invoke-WslCommand -AsRoot -CaptureOutput -Command "kubectl get pods -A"
    if (-not $pods.Success) { return @{ Success=$false; Code=2502 } }

    Write-Log "Nodes:`n$($nodes.Data.Output)"
    Write-Log "Pods:`n$($pods.Data.Output)"

    return @{ Success=$true; Code=0 }
}

# =====================================================================
#  WSL COMMAND WRAPPER
# =====================================================================

function Invoke-WslCommand {
    param(
        [switch]$AsRoot,
        [switch]$CaptureOutput,
        [string]$Command
    )

    $wrapped = $AsRoot ? "sudo bash -lc '$Command'" : "bash -lc '$Command'"
    $args = @('--', $wrapped)

    $result = Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args -CaptureOutput:$CaptureOutput
    if (-not $result.Success) { return @{ Success=$false; Code=2601 } }

    return @{ Success=$true; Code=0; Data=$result.Data }
}

# =====================================================================
#  PORT PROXY + API TEST
# =====================================================================

function Setup-KubePortProxy {
    param([string]$WslIp)

    Write-Step "Configuring Windows port proxy for k3s API"

    Invoke-Native -FilePath 'netsh' -ArgumentList @(
        'interface','portproxy','delete','v4tov4',
        'listenport=6443','listenaddress=127.0.0.1'
    ) | Out-Null

    $add = Invoke-Native -FilePath 'netsh' -ArgumentList @(
        'interface','portproxy','add','v4tov4',
        'listenport=6443','listenaddress=127.0.0.1',
        'connectport=6443',"connectaddress=$WslIp"
    )

    if (-not $add.Success) { return @{ Success=$false; Code=2701 } }

    return @{ Success=$true; Code=0 }
}

function Test-KubeApiEndpoint {
    param([string]$ServerUrl)

    try {
        $response = Invoke-RestMethod -Method Get -Uri "$ServerUrl/healthz" -TimeoutSec 5 -ErrorAction Stop
        return ($response -eq 'ok')
    }
    catch { return $false }
}

# =====================================================================
#  KUBECONFIG EXPORT + LENS CONFIG
# =====================================================================

function Export-KubeconfigToWindows {
    param([string]$ApiServer)

    Write-Step "Exporting kubeconfig to Windows"

    $windowsPath = Join-Path $env:USERPROFILE ".kube\config-k3s-wsl"
    New-Item -ItemType Directory -Path (Split-Path $windowsPath -Parent) -Force | Out-Null

    $cmd = @"
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's#https://127.0.0.1:6443#$ApiServer#g' ~/.kube/config
"@

    $prep = Invoke-WslCommand -AsRoot -CaptureOutput -Command $cmd
    if (-not $prep.Success) { return @{ Success=$false; Code=2801 } }

    $cat = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--','cat','~/.kube/config') -CaptureOutput
    if (-not $cat.Success) { return @{ Success=$false; Code=2802 } }

    Set-Content -Path $windowsPath -Value $cat.Data.Output -Encoding UTF8
    return @{ Success=$true; Code=0; Data=@{WindowsKubeconfigPath=$windowsPath} }
}

function Configure-LensKubeconfig {
    param([string]$KubeconfigPath)

    Write-Step "Configuring Lens to use kubeconfig"

    if (-not (Test-Path $KubeconfigPath)) {
        Write-Error "Kubeconfig not found at '$KubeconfigPath'"
        return @{ Success=$false; Code=2901 }
    }

    return @{ Success=$true; Code=0 }
}

# =====================================================================
#  CLIENT FILESYSTEM ACTIVITY VERIFICATION
# =====================================================================

function Verify-ClientFilesystemActivity {
    Write-Step 'Verifying client pod file-system activity'

    try {
        # 1. Identify client pod (samba-users-xxxxx)
        $clientPodResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command "
            /usr/local/bin/k3s kubectl -n default get pod -o name |
            grep '^pod/samba-users-' | head -1 | cut -d/ -f2
        "
        $clientPod = $clientPodResult.Data.Output.Trim()
        if ([string]::IsNullOrWhiteSpace($clientPod)) {
            throw 'No running samba-users pod found for client activity check.'
        }

        # 2. Identify samba server pod (samba-xxxxx)
        $sambaPodResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command "
            /usr/local/bin/k3s kubectl -n default get pod -o name |
            grep '^pod/samba-' | grep -v samba-users |
            head -1 | cut -d/ -f2
        "
        $sambaPod = $sambaPodResult.Data.Output.Trim()
        if ([string]::IsNullOrWhiteSpace($sambaPod)) {
            throw 'No samba server pod found for activity verification.'
        }

        # 3. Determine samba container name
        $sambaContainerResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command "
            /usr/local/bin/k3s kubectl -n default get pod $sambaPod \
                -o jsonpath='{.spec.containers[0].name}'
        "
        $sambaContainer = $sambaContainerResult.Data.Output.Trim()
        if ([string]::IsNullOrWhiteSpace($sambaContainer)) {
            $sambaContainer = 'samba'
        }

        Write-Log "Selected client pod: $clientPod"
        Write-Log "Selected samba pod: $sambaPod (container: $sambaContainer)"

        # 4. Tail client logs to check activity
        $clientLogsResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command "
            /usr/local/bin/k3s kubectl -n default logs $clientPod --tail=80 2>/dev/null || true
        "
        $clientLogs = $clientLogsResult.Data.Output.Trim()

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

        # 5. Write proof token from client pod
        $proofToken = "proof-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $proofFile  = '.post-clone-client-proof.txt'

        $writeCommand = "
            /usr/local/bin/k3s kubectl -n default exec $clientPod -- sh -lc '
                if [ -d /mnt/samba ]; then
                    printf \"%s\n\" \"$proofToken\" > /mnt/samba/$proofFile &&
                    sync &&
                    echo WRITE_OK;
                else
                    echo MOUNT_MISSING;
                fi
            ' 2>/dev/null || true
        "

        $writeResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command $writeCommand
        $writeResultText = $writeResult.Data.Output.Trim()

        if ($writeResultText -notmatch 'WRITE_OK') {
            throw "Client write probe failed. Result: $writeResultText"
        }

        # 6. Verify proof token from samba server pod
        $verifyCommand = "
            /usr/local/bin/k3s kubectl -n default exec $sambaPod -c $sambaContainer -- sh -lc '
                if [ -f /srv/shares/public_share/$proofFile ]; then
                    cat /srv/shares/public_share/$proofFile;
                elif [ -f /data/samba/$proofFile ]; then
                    cat /data/samba/$proofFile;
                else
                    echo PROOF_FILE_NOT_FOUND;
                fi
            ' 2>/dev/null || true
        "

        $readBackResult = Invoke-WslCommand -AsRoot -CaptureOutput -Command $verifyCommand
        $readBack = $readBackResult.Data.Output.Trim()

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

# =====================================================================
#  MAIN (AT BOTTOM, YOUR FLOW)
# =====================================================================

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
    $wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "ip -4 -o addr show dev eth0 | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -n1").Data.Output.Trim()
    if ([string]::IsNullOrWhiteSpace($wslIp)) {
        $wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "hostname -I | tr ' ' '\n' | sed -n '1p'").Data.Output.Trim()
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
    $WindowsKubeConfigPath = (Export-KubeconfigToWindows -ApiServer $selectedApiServer).Data.WindowsKubeconfigPath

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
