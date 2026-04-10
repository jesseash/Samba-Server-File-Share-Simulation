param(
    [string]$DistroName = "Ubuntu"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Log {
    param([string]$Message)
    Write-Host "[freelens-kubeconfig] $Message" -ForegroundColor Cyan
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

    Write-Step 'Configuring Windows port proxy for k3s API'
    Write-Log "Setting up Windows port proxy: 127.0.0.1:6443 -> ${WslIp}:6443"

    if ($WslIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Invalid WSL IP address: $WslIp"
    }

    try {
        Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
            'interface', 'portproxy', 'delete', 'v4tov4',
            'listenport=6443', 'listenaddress=127.0.0.1'
        )
    }
    catch {
        Write-Log 'No existing rule to remove'
    }

    Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
        'interface', 'portproxy', 'add', 'v4tov4',
        'listenport=6443', 'listenaddress=127.0.0.1',
        'connectport=6443', "connectaddress=$WslIp"
    )

    try {
        Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
            'advfirewall', 'firewall', 'delete', 'rule',
            'name=k3s API 6443'
        )
    }
    catch {
        Write-Log 'No existing firewall rule to remove'
    }

    Invoke-Native -FilePath 'netsh.exe' -ArgumentList @(
        'advfirewall', 'firewall', 'add', 'rule',
        'name=k3s API 6443', 'protocol=TCP', 'dir=in',
        'localport=6443', 'action=allow'
    )

    Write-Log 'Port proxy setup complete'
}

function Export-KubeconfigToWindows {
    param([string]$ApiServer = 'https://127.0.0.1:6443')

    Write-Step 'Copying kubeconfig to Windows'

    $windowsKubeDir = Join-Path $env:USERPROFILE '.kube'
    $standardConfig = Join-Path $windowsKubeDir 'config'
    $linuxKubeConfig = '/etc/rancher/k3s/k3s.yaml'

    if (-not (Test-Path $windowsKubeDir)) {
        $null = New-Item -ItemType Directory -Path $windowsKubeDir -Force
    }

    Write-Log 'Checking k3s service status in WSL'
    $k3sStatus = Invoke-WslCommand -AsRoot -CaptureOutput -Command 'systemctl is-active k3s 2>/dev/null || echo inactive'
    if ($k3sStatus.Trim() -ne 'active') {
        throw "k3s service is not active in WSL (status: $($k3sStatus.Trim()))."
    }

    $kubeConfig = Invoke-WslCommand -AsRoot -CaptureOutput -Command "cat $(ConvertTo-BashLiteral -Value $linuxKubeConfig)"
    if ([string]::IsNullOrWhiteSpace($kubeConfig)) {
        throw "kubeconfig file is empty or unreachable at $linuxKubeConfig"
    }

    Set-Content -Path $standardConfig -Value $kubeConfig -Encoding utf8

    $kubeConfigContent = Get-Content -Path $standardConfig -Raw
    $updatedContent = [regex]::Replace(
        $kubeConfigContent,
        '(?m)^\s*server:\s*https://[^\s]+\s*$',
        "    server: $ApiServer"
    )

    Set-Content -Path $standardConfig -Value $updatedContent -Encoding utf8
    Write-Log "Kubeconfig updated: $standardConfig"

    return $standardConfig
}

function Configure-FreelensKubeconfig {
    param([Parameter(Mandatory = $true)][string]$KubeconfigPath)

    Write-Step 'Configuring Freelens integration'

    if (-not (Test-Path -LiteralPath $KubeconfigPath)) {
        throw "Kubeconfig path does not exist: $KubeconfigPath"
    }

    $env:KUBECONFIG = $KubeconfigPath
    try {
        Invoke-Native -FilePath 'setx.exe' -ArgumentList @('KUBECONFIG', $KubeconfigPath) | Out-Null
    }
    catch {
        Write-Log 'WARNING: Could not persist KUBECONFIG with setx.exe; continuing.'
    }

    $freelensRoots = @()
    foreach ($candidateRoot in @(
            (Join-Path $env:APPDATA 'Freelens'),
            (Join-Path $env:LOCALAPPDATA 'Freelens')
        )) {
        if (Test-Path -LiteralPath $candidateRoot) {
            $freelensRoots += $candidateRoot
        }
    }

    $freelensRoots = @($freelensRoots | Select-Object -Unique)
    if ($freelensRoots.Count -eq 0) {
        Write-Log 'Freelens profile folder not found yet; kubeconfig is still ready at %USERPROFILE%\.kube\config'
    }
    else {
        foreach ($rootPath in $freelensRoots) {
            Write-Log "Freelens root detected: $rootPath"
        }
    }

    $proc = Get-Process -Name 'Freelens' -ErrorAction SilentlyContinue
    if ($null -ne $proc) {
        Write-Log 'Stopping running Freelens process'
        Stop-Process -Name 'Freelens' -Force -ErrorAction SilentlyContinue
    }

    $freelensExe = Join-Path $env:LOCALAPPDATA 'Programs\Freelens\Freelens.exe'
    if (Test-Path -LiteralPath $freelensExe) {
        Write-Log 'Starting Freelens'
        Start-Process -FilePath $freelensExe | Out-Null
    }
    else {
        Write-Log 'Freelens.exe not found in default install path; start it manually to pick up kubeconfig.'
    }

    Write-Log "Freelens now uses KUBECONFIG=$KubeconfigPath"
}

function Main {
    Assert-Administrator

    Write-Step 'Resolving WSL k3s API endpoint'
    $wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "ip -4 -o addr show dev eth0 | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -n1").Trim()
    if ([string]::IsNullOrWhiteSpace($wslIp)) {
        $wslIp = (Invoke-WslCommand -AsRoot -CaptureOutput -Command "hostname -I | tr ' ' '\n' | sed -n '1p'").Trim()
    }

    $selectedApiServer = 'https://127.0.0.1:6443'

    if ([string]::IsNullOrWhiteSpace($wslIp)) {
        Write-Log 'WARNING: Could not determine WSL IP; keeping localhost endpoint'
    }
    else {
        Setup-KubePortProxy -WslIp $wslIp

        if (Test-KubeApiEndpoint -ServerUrl 'https://127.0.0.1:6443') {
            $selectedApiServer = 'https://127.0.0.1:6443'
        }
        elseif (Test-KubeApiEndpoint -ServerUrl ("https://$wslIp:6443")) {
            $selectedApiServer = "https://$wslIp:6443"
            Write-Log "WARNING: Falling back to direct WSL API endpoint: $selectedApiServer"
        }
    }

    $windowsKubeConfigPath = Export-KubeconfigToWindows -ApiServer $selectedApiServer
    Configure-FreelensKubeconfig -KubeconfigPath $windowsKubeConfigPath

    Write-Step 'Completed'
    Write-Host 'Freelens kubeconfig setup is complete.' -ForegroundColor Green
    Write-Host "Windows kubeconfig: $windowsKubeConfigPath" -ForegroundColor Green
}

Main
