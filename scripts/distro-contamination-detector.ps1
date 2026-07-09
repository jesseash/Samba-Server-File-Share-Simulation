param(
    [switch]$AsJson,
    [string]$MarkerDistroName,
    [string[]]$MarkerDistroNames = @(),
    [switch]$ScanAllDistrosForMarkers,
    [switch]$ResolveK3sDistro,
    [switch]$CreateDedicatedDistroWhenNeeded,
    [string]$DedicatedDistroName = 'Ubuntu-k3s'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    Write-Host "[distro-detector] $Message" -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
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

function Normalize-WslDistroNames {
    param([string[]]$RawNames = @())

    return @(
        $RawNames |
            ForEach-Object {
                ($_ -replace "`0", "")
            } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

function Get-WslDistroNames {
    try {
        $raw = & wsl.exe -l -q 2>$null
        return Normalize-WslDistroNames -RawNames @($raw -split "`r?`n")
    }
    catch {
        return @()
    }
}

function Test-WslMarker {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$MarkerPath
    )

    function Get-ProbeErrorMessage {
        param(
            [Parameter(Mandatory = $true)][string]$ProbeLabel,
            [Parameter(Mandatory = $true)][hashtable]$ProbeResult
        )

        $stderr = "$($ProbeResult.StdErr)".Trim()
        $stdout = "$($ProbeResult.StdOut)".Trim()
        $statusParts = @(
            "started=$($ProbeResult.Started)",
            "timedOut=$($ProbeResult.TimedOut)",
            "exitCode=$($ProbeResult.ExitCode)"
        )

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $statusParts += "stderr='$stderr'"
        }

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $statusParts += "stdout='$stdout'"
        }

        return "$ProbeLabel failed: $($statusParts -join '; ')"
    }

    function Invoke-WslTestFile {
        param(
            [Parameter(Mandatory = $true)][string]$Args,
            [Parameter(Mandatory = $true)][string]$TimeoutLabel
        )

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo.FileName = 'wsl.exe'
        $proc.StartInfo.Arguments = $Args
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $proc.StartInfo.CreateNoWindow = $true

        if (-not $proc.Start()) {
            return @{ Started = $false; TimedOut = $false; ExitCode = -1; StdErr = 'Failed to start process'; StdOut = '' }
        }

        if (-not $proc.WaitForExit(15000)) {
            $proc.Kill()
            return @{ Started = $true; TimedOut = $true; ExitCode = -1; StdErr = "$TimeoutLabel timeout (15s)"; StdOut = '' }
        }

        return @{
            Started = $true
            TimedOut = $false
            ExitCode = $proc.ExitCode
            StdErr = $proc.StandardError.ReadToEnd()
            StdOut = $proc.StandardOutput.ReadToEnd()
        }
    }

    try {
        $defaultRun = Invoke-WslTestFile -Args "-d $DistroName -- test -f $MarkerPath" -TimeoutLabel 'Marker test'

        if ($defaultRun.Started -and -not $defaultRun.TimedOut -and $defaultRun.ExitCode -eq 0) {
            return @{ Found = $true; Accessible = $true; Error = $null }
        }

        $defaultStdErr = "$($defaultRun.StdErr)"
        if ($defaultRun.TimedOut) {
            return @{ Found = $false; Accessible = $false; Error = (Get-ProbeErrorMessage -ProbeLabel 'Marker test' -ProbeResult $defaultRun) }
        }

        if ($defaultRun.ExitCode -eq 1) {
            return @{ Found = $false; Accessible = $true; Error = $null }
        }

        if ($defaultStdErr -match 'permission denied' -or $defaultStdErr -match 'Failed to start the systemd user session' -or $defaultStdErr -match 'catastrophic failure' -or $defaultStdErr -match 'E_UNEXPECTED') {
            return @{ Found = $false; Accessible = $false; Error = (Get-ProbeErrorMessage -ProbeLabel 'Marker test' -ProbeResult $defaultRun) }
        }

        return @{ Found = $false; Accessible = $false; Error = (Get-ProbeErrorMessage -ProbeLabel 'Marker test' -ProbeResult $defaultRun) }
    }
    catch {
        return @{ Found = $false; Accessible = $false; Error = "Exception: $_" }
    }
}

function Get-EnvironmentSlug {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    return (($EnvironmentName.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '^-+|-+$', '')
}

function Get-EnvironmentMatchTokens {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    $slug = Get-EnvironmentSlug -EnvironmentName $EnvironmentName
    $parts = @($slug -split '-' | Where-Object { $_ })

    $tokens = @($slug)
    if ($parts.Count -gt 0) {
        $tokens += $parts[0]
    }

    return @($tokens | Where-Object { $_ } | Select-Object -Unique)
}

function Get-DistroContaminationReasons {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string[]]$DetectedContainerEnvironments
    )

    $reasons = @()
    $distroLower = $DistroName.ToLowerInvariant()

    foreach ($environmentName in $DetectedContainerEnvironments) {
        $tokens = Get-EnvironmentMatchTokens -EnvironmentName $environmentName
        $markerSlug = Get-EnvironmentSlug -EnvironmentName $environmentName
        $markerPath = "/etc/samba-cifs-sim/contamination-markers/$markerSlug.marker"

        $markerResult = Test-WslMarker -DistroName $DistroName -MarkerPath $markerPath
        if ($markerResult.Found) {
            $reasons += "$environmentName (marker file present)"
            continue
        }

        foreach ($token in $tokens) {
            if ($distroLower -like "*$token*") {
                $reasons += "$environmentName (distro name matches '$token')"
                break
            }
        }
    }

    return @($reasons | Select-Object -Unique)
}

function Get-DistroSelectionResult {
    param(
        [Parameter(Mandatory = $true)][string[]]$DetectedContainerEnvironments,
        [Parameter(Mandatory = $true)][string[]]$Distros
    )

    $contaminatedDistroMap = @{}
    if ($DetectedContainerEnvironments.Count -gt 0) {
        foreach ($distro in $Distros) {
            $reasons = Get-DistroContaminationReasons -DistroName $distro -DetectedContainerEnvironments $DetectedContainerEnvironments
            if ($reasons.Count -gt 0) {
                $contaminatedDistroMap[$distro] = $reasons
            }
        }
    }

    $preferredOrder = @('Ubuntu', 'Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu-20.04')

    foreach ($preferred in $preferredOrder) {
        if (($Distros -contains $preferred) -and (-not $contaminatedDistroMap.ContainsKey($preferred))) {
            return [pscustomobject]@{
                SelectedDistro = $preferred
                ContaminatedDistroMap = $contaminatedDistroMap
            }
        }
    }

    foreach ($distro in $Distros) {
        if (-not $contaminatedDistroMap.ContainsKey($distro)) {
            return [pscustomobject]@{
                SelectedDistro = $distro
                ContaminatedDistroMap = $contaminatedDistroMap
            }
        }
    }

    return [pscustomobject]@{
        SelectedDistro = $null
        ContaminatedDistroMap = $contaminatedDistroMap
    }
}

function Ensure-DedicatedK3sDistro {
    param(
        [Parameter(Mandatory = $true)][string]$DedicatedDistroName,
        [Parameter(Mandatory = $true)][string[]]$Distros
    )

    if ($Distros -contains $DedicatedDistroName) {
        Write-Log "Dedicated k3s distro '$DedicatedDistroName' already exists — skipping creation"
        return
    }

    Write-Log "Creating dedicated k3s distro '$DedicatedDistroName' to avoid port and namespace conflicts"

    $installDir = Join-Path $env:LOCALAPPDATA "wsl-distros\$DedicatedDistroName"
    $null = New-Item -ItemType Directory -Path $installDir -Force

    if ($Distros -contains 'Ubuntu') {
        Write-Log "Exporting existing 'Ubuntu' distro as base for '$DedicatedDistroName'"
        $exportPath = [System.IO.Path]::GetTempFileName() + '.tar'
        try {
            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--export', 'Ubuntu', $exportPath)
            Write-Log "Importing as '$DedicatedDistroName' (WSL2)"
            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--import', $DedicatedDistroName, $installDir, $exportPath, '--version', '2')
        }
        finally {
            Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Log "No existing Ubuntu distro found — downloading project base image archive"
        $releaseUrl = 'https://github.com/jesseash/Samba-Server-File-Share-Simulation/releases/download/Samba-dependencies/samba-ubuntu-depencies.tar'
        $stagingDir = Join-Path $env:TEMP ("samba-k3s-rootfs-" + [Guid]::NewGuid().ToString('N'))
        $releaseTarPath = Join-Path $stagingDir 'samba-ubuntu-depencies.tar'
        $rootfsRelativePath = 'ubuntu-base-image/ubuntu-24.04.tar'

        $null = New-Item -ItemType Directory -Path $stagingDir -Force
        Write-Log "Downloading: $releaseUrl"
        Invoke-WebRequest -Uri $releaseUrl -OutFile $releaseTarPath -UseBasicParsing

        Write-Log "Extracting $rootfsRelativePath from release archive"
        Invoke-Native -FilePath 'tar.exe' -ArgumentList @('-xf', $releaseTarPath, '-C', $stagingDir, $rootfsRelativePath)
        $rootfsPath = Join-Path $stagingDir $rootfsRelativePath
        if (-not (Test-Path -LiteralPath $rootfsPath)) {
            throw "Expected rootfs not found after extraction: $rootfsPath"
        }

        try {
            Write-Log "Importing as '$DedicatedDistroName' (WSL2)"
            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--import', $DedicatedDistroName, $installDir, $rootfsPath, '--version', '2')
        }
        finally {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log "Dedicated k3s distro '$DedicatedDistroName' created at: $installDir"
}

$wslDistroList = Get-WslDistroNames
$inaccessibleDistros = @()
$distroProbeStats = @{}
$details = @()

$checks = @(
    @{
        Name = 'Docker Desktop'
        MarkerPath = '/etc/samba-cifs-sim/contamination-markers/docker-desktop.marker'
        HostTest = {
            $dockerProc = Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue
            if ($dockerProc) { return 'running process' }
            if ($wslDistroList -match 'docker-desktop') { return 'docker-desktop WSL distro' }
            return $null
        }
    },
    @{
        Name = 'Rancher Desktop'
        MarkerPath = '/etc/samba-cifs-sim/contamination-markers/rancher-desktop.marker'
        HostTest = {
            $rancherProc = Get-Process -Name 'Rancher Desktop', 'rancher-desktop' -ErrorAction SilentlyContinue
            if ($rancherProc) { return 'running process' }
            if ($wslDistroList -match 'rancher-desktop') { return 'rancher-desktop WSL distro' }
            return $null
        }
    },
    @{
        Name = 'Podman'
        MarkerPath = '/etc/samba-cifs-sim/contamination-markers/podman.marker'
        HostTest = {
            $podmanProc = Get-Process -Name 'podman', 'Podman Desktop' -ErrorAction SilentlyContinue
            if ($podmanProc) { return 'running process' }
            $podmanExe = Get-Command 'podman.exe' -ErrorAction SilentlyContinue
            if ($podmanExe) { return 'podman.exe on PATH' }
            return $null
        }
    },
    @{
        Name = 'Colima'
        MarkerPath = '/etc/samba-cifs-sim/contamination-markers/colima.marker'
        HostTest = {
            $colimaExe = Get-Command 'colima.exe' -ErrorAction SilentlyContinue
            if ($colimaExe) { return 'colima.exe on PATH' }
            return $null
        }
    },
    @{
        Name = 'Minikube'
        MarkerPath = '/etc/samba-cifs-sim/contamination-markers/minikube.marker'
        HostTest = {
            $minikubeProc = Get-Process -Name 'minikube' -ErrorAction SilentlyContinue
            if ($minikubeProc) { return 'running process' }
            $minikubeExe = Get-Command 'minikube.exe' -ErrorAction SilentlyContinue
            if ($minikubeExe) { return 'minikube.exe on PATH' }
            return $null
        }
    }
)

$markerTargets = @()
if (-not [string]::IsNullOrWhiteSpace($MarkerDistroName)) {
    $markerTargets += $MarkerDistroName
}
if ($MarkerDistroNames.Count -gt 0) {
    $markerTargets += $MarkerDistroNames
}
if ($ScanAllDistrosForMarkers) {
    $markerTargets += $wslDistroList
}
$markerTargets = @($markerTargets | Where-Object { $_ } | Select-Object -Unique)
Write-Log "Scanning $($markerTargets.Count) distro(s) for $($checks.Count) CRE marker(s)"

foreach ($check in $checks) {
    Write-Log "Checking CRE: $($check.Name)"
    $reasons = @()

    $hostReason = & $check.HostTest
    if ($hostReason) {
        $reasons += "host: $hostReason"
    }

    foreach ($targetDistro in $markerTargets) {
        if ($wslDistroList -contains $targetDistro) {
            if (-not $distroProbeStats.ContainsKey($targetDistro)) {
                $distroProbeStats[$targetDistro] = [pscustomobject]@{
                    Attempts = 0
                    AccessibleSuccesses = 0
                    InaccessibleFailures = 0
                }
            }

            Write-Log "  Testing marker in distro '$targetDistro' (path: $($check.MarkerPath))"
            $result = Test-WslMarker -DistroName $targetDistro -MarkerPath $check.MarkerPath
            $stats = $distroProbeStats[$targetDistro]
            $stats.Attempts++
            
            if ($result.Error) {
                Write-Log "    [ERROR] $($result.Error)"
                if ($result.Accessible) {
                    $stats.AccessibleSuccesses++
                }
                else {
                    $stats.InaccessibleFailures++
                }
            }
            elseif ($result.Found) {
                $reasons += "marker: $($check.MarkerPath) in distro '$targetDistro'"
                $stats.AccessibleSuccesses++
                Write-Log "    [+] Marker found"
            }
            else {
                $stats.AccessibleSuccesses++
                Write-Log "    [-] Marker not found"
            }
        }
        else {
            $reasons += "marker-scan skipped: distro '$targetDistro' not found"
        }
    }

    $details += [pscustomobject]@{
        Name = $check.Name
        Detected = ($reasons.Count -gt 0)
        Reasons = $reasons
    }
    Write-Log "  CRE $($check.Name) scan complete: $($reasons.Count) reason(s)"
}

foreach ($entry in $distroProbeStats.GetEnumerator()) {
    $stats = $entry.Value
    if ($stats.Attempts -gt 0 -and $stats.AccessibleSuccesses -eq 0 -and $stats.InaccessibleFailures -gt 0) {
        $inaccessibleDistros += $entry.Key
    }
}
$inaccessibleDistros = @($inaccessibleDistros | Select-Object -Unique)

Write-Log "All CRE scans complete. Building result object..."

$detected = @($details | Where-Object { $_.Detected } | ForEach-Object { $_.Name } | Select-Object -Unique)

$selectionResult = $null
$selectedCleanDistro = $null
$shouldCreateDedicatedDistro = $false
$dedicatedDistroCreated = $false
$resolvedDistroName = $null
$contaminatedDistros = @()

if ($ResolveK3sDistro -and $detected.Count -gt 0) {
    $selectionResult = Get-DistroSelectionResult -DetectedContainerEnvironments $detected -Distros $wslDistroList
    $selectedCleanDistro = $selectionResult.SelectedDistro

    foreach ($entry in $selectionResult.ContaminatedDistroMap.GetEnumerator()) {
        $contaminatedDistros += [pscustomobject]@{
            Distro = $entry.Key
            Reasons = @($entry.Value)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($selectedCleanDistro)) {
        $resolvedDistroName = $selectedCleanDistro
    }
    else {
        $shouldCreateDedicatedDistro = $true
        $resolvedDistroName = $DedicatedDistroName

        if ($CreateDedicatedDistroWhenNeeded) {
            Ensure-DedicatedK3sDistro -DedicatedDistroName $DedicatedDistroName -Distros $wslDistroList
            $dedicatedDistroCreated = $true
        }
    }
}

Write-Log "Building result object..."
$result = [pscustomobject]@{
    Detected = $detected
    Details = $details
    InaccessibleDistros = @($inaccessibleDistros)
    HasErrors = ($inaccessibleDistros.Count -gt 0)
    Errors = @($inaccessibleDistros | ForEach-Object { "inaccessible distro: $_" })
    MarkerDistroChecked = $MarkerDistroName
    MarkerDistrosChecked = $markerTargets
    WslDistros = $wslDistroList
    ContaminatedDistros = @($contaminatedDistros)
    SelectedCleanDistro = $selectedCleanDistro
    ShouldCreateDedicatedDistro = $shouldCreateDedicatedDistro
    DedicatedDistroName = $DedicatedDistroName
    DedicatedDistroCreated = $dedicatedDistroCreated
    ResolvedDistroName = $resolvedDistroName
}
Write-Log "Result object built. Detected: [$($detected -join ', ')]. Inaccessible: [$($inaccessibleDistros -join ', ')]"

if ($AsJson) {
    Write-Log "Converting to JSON..."
    $json = $result | ConvertTo-Json -Depth 8 -Compress
    Write-Log "JSON conversion complete. Output length: $($json.Length) chars"
    $json
}
else {
    $result
}
