param(
    [string]$TestDistroName = 'Ubuntu-contamination-test',
    [string[]]$Environments = @('Docker Desktop', 'Rancher Desktop', 'Podman', 'Colima', 'Minikube'),
    [switch]$ResetMarkers,
    [switch]$SkipCleanup,
    [bool]$CreatePerEnvironmentDistros = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    Write-Host "[marker-injector] $Message" -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$CaptureOutput,
        [int]$TimeoutSeconds = 600,
        [switch]$IgnoreErrors
    )

    $cmdLine = "$FilePath $($ArgumentList -join ' ')"
    Write-Log "Executing: $cmdLine (timeout: ${TimeoutSeconds}s)"

    if ($CaptureOutput) {
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and -not $IgnoreErrors) {
            $joined = ($output | Out-String).Trim()
            throw "Command failed with exit code $exitCode.`n$joined"
        }
        return ($output | Out-String).Trim()
    }

    & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $IgnoreErrors) {
        throw "Command failed with exit code $exitCode."
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

function Get-EnvironmentSlug {
    param([Parameter(Mandatory = $true)][string]$EnvironmentName)

    return (($EnvironmentName.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '^-+|-+$', '')
}

function Ensure-TestDistro {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $distrosRaw = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-q') -CaptureOutput
    $distros = Normalize-WslDistroNames -RawNames @($distrosRaw -split "`r?`n")

    if ($distros -contains $DistroName) {
        Write-Log "Test distro '$DistroName' already exists"
        return
    }

    Write-Log "Creating test distro '$DistroName'"
    $installDir = Join-Path $env:LOCALAPPDATA "wsl-distros\$DistroName"
    $null = New-Item -ItemType Directory -Path $installDir -Force

    if ($distros -contains 'Ubuntu') {
        Write-Log "Exporting existing 'Ubuntu' for test distro bootstrap"
        $exportPath = [System.IO.Path]::GetTempFileName() + '.tar'
        try {
            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--export', 'Ubuntu', $exportPath) -TimeoutSeconds 900
            Write-Log "Export completed; importing to '$DistroName'"
            Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--import', $DistroName, $installDir, $exportPath, '--version', '2') -TimeoutSeconds 900
            Write-Log "Import completed for '$DistroName'; resetting systemd user-session state"
            Invoke-PostImportUserSessionCleanup -DistroName $DistroName
        }
        finally {
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
        return
    }

    Write-Log "No local Ubuntu distro found; bootstrapping from project release base image"
    $releaseUrl = 'https://github.com/jesseash/Samba-Server-File-Share-Simulation/releases/download/Samba-dependencies/samba-ubuntu-depencies.tar'
    $stagingDir = Join-Path $env:TEMP ("samba-contamination-rootfs-" + [Guid]::NewGuid().ToString('N'))
    $releaseTarPath = Join-Path $stagingDir 'samba-ubuntu-depencies.tar'
    $rootfsRelativePath = 'ubuntu-base-image/ubuntu-24.04.tar'

    $null = New-Item -ItemType Directory -Path $stagingDir -Force
    Invoke-WebRequest -Uri $releaseUrl -OutFile $releaseTarPath -UseBasicParsing
    Invoke-Native -FilePath 'tar.exe' -ArgumentList @('-xf', $releaseTarPath, '-C', $stagingDir, $rootfsRelativePath)

    $rootfsPath = Join-Path $stagingDir $rootfsRelativePath
    if (-not (Test-Path -LiteralPath $rootfsPath)) {
        throw "Expected rootfs not found after extraction: $rootfsPath"
    }

    try {
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--import', $DistroName, $installDir, $rootfsPath, '--version', '2')
        Write-Log "Distro '$DistroName' imported; resetting systemd user-session state"
        Invoke-PostImportUserSessionCleanup -DistroName $DistroName
    }
    finally {
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PostImportUserSessionCleanup {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $cleanupCmd = "rm -rf /run/user/1000 /var/lib/systemd/linger 2>/dev/null || true; systemctl daemon-reexec 2>/dev/null || true"
    $args = @('-d', $DistroName, '--user', 'root', '--exec', '/bin/sh', '-c', $cleanupCmd)

    try {
        Write-Log "Running post-import cleanup in '$DistroName'"
        $output = & 'wsl.exe' @args 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $joined = ($output | Out-String).Trim()
            throw "Post-import cleanup command failed with exit code $exitCode. Output: $joined"
        }

        Write-Log "Systemd user-session state cleaned in '$DistroName'"
    }
    catch {
        throw "Post-import cleanup failed for '$DistroName': $($_.Exception.Message)"
    }
}

function Invoke-PreInjectionTestDistroCleanup {
    Write-Host "Cleaning up existing contamination test distros..." -ForegroundColor Cyan
    $distrosRaw = & 'wsl.exe' -l -q | Out-String
    $names = @(
        $distrosRaw -split "`r?`n" |
            ForEach-Object {
                $normalized = ($_ -replace "`0", "").Trim()
                $normalized = $normalized -replace '(?<=\w)\s+(?=\w)', ''
                $normalized
            } |
            Where-Object { $_ }
    )
    $targets = $names | Where-Object { $_ -like 'Ubuntu-contamination-test*' }

    Write-Host "Will remove:" -ForegroundColor Yellow
    if ($targets.Count -gt 0) {
        $targets | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
    else {
        Write-Host "  (none)" -ForegroundColor Green
    }

    foreach ($d in $targets) {
        try {
            Write-Log "Terminating distro '$d'"
            & 'wsl.exe' --terminate "$d" 2>$null

            Write-Log "Unregistering distro '$d'"
            $unregisterOutput = & 'wsl.exe' --unregister "$d" 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                $joined = ($unregisterOutput | Out-String).Trim()
                throw "Unregister failed with exit code $exitCode. Output: $joined"
            }
        }
        catch {
            throw "Failed during pre-injection cleanup for distro '$d': $($_.Exception.Message)"
        }
    }

    Write-Host "`nRemaining distros:" -ForegroundColor Cyan
    & 'wsl.exe' -l -q | ForEach-Object {
        $n = (($_ -replace "`0", "").Trim()) -replace '(?<=\w)\s+(?=\w)', ''
        if ($n) { Write-Host "  $n" }
    }
}

function Invoke-WslRootCommand {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$CaptureOutput
    )

    $args = @('-d', $DistroName, '--user', 'root', '--exec', '/bin/sh', '-c', $Command)
    Write-Log "Running in '$DistroName' as root"
    if ($CaptureOutput) {
        return Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args -CaptureOutput -TimeoutSeconds 60
    }

    Invoke-Native -FilePath 'wsl.exe' -ArgumentList $args -TimeoutSeconds 60
    return $true
}

function Invoke-WslMarkerResetSilent {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$MarkerPath
    )

    $command = "if [ -f '$MarkerPath' ]; then rm -f '$MarkerPath' && echo removed; else echo missing; fi"
    $attempts = @(
        @('-d', $DistroName, '--user', 'root', '--exec', '/bin/sh', '-c', $command),
        @('-d', $DistroName, '--exec', '/bin/sh', '-c', $command),
        @('-d', $DistroName, '--', 'bash', '-lc', $command)
    )

    foreach ($args in $attempts) {
        try {
            $output = & 'wsl.exe' @args 2>$null
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                return ($output | Out-String).Trim()
            }
        }
        catch {
        }
    }

    return ''
}

function Write-PlainListSection {
    param(
        [Parameter(Mandatory = $true)][string]$Header,
        [string[]]$Items = @()
    )

    if ($Items.Count -le 0) {
        return
    }

    [Console]::WriteLine($Header)
    foreach ($item in $Items) {
        [Console]::WriteLine(("  - {0}" -f $item))
    }
}

function Inject-Markers {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string[]]$EnvironmentNames,
        [Parameter(Mandatory = $true)][hashtable]$KnownMarkers
    )

    $markerDir = '/etc/samba-cifs-sim/contamination-markers'
    Invoke-WslRootCommand -DistroName $DistroName -Command "mkdir -p $markerDir"

    foreach ($envName in $EnvironmentNames) {
        $fileName = $KnownMarkers[$envName]
        $markerPath = "$markerDir/$fileName"
        $payload = "environment=$envName timestamp=$(Get-Date -Format o)"
        $safePayload = $payload.Replace("'", "'\\''")
        Write-Log "Injecting marker for '$envName' in '$DistroName' => $markerPath"
        Invoke-WslRootCommand -DistroName $DistroName -Command "printf '%s\n' '$safePayload' > '$markerPath'"
    }
}

$knownMarkers = @{
    'Docker Desktop' = 'docker-desktop.marker'
    'Rancher Desktop' = 'rancher-desktop.marker'
    'Podman' = 'podman.marker'
    'Colima' = 'colima.marker'
    'Minikube' = 'minikube.marker'
}

foreach ($envName in $Environments) {
    if (-not $knownMarkers.ContainsKey($envName)) {
        throw "Unsupported environment name '$envName'. Valid values: $($knownMarkers.Keys -join ', ')"
    }
}

$createdDistros = @()
$failedDistros = @()

if ($CreatePerEnvironmentDistros) {
    # Reset mode: directly remove markers for each environment
    if ($ResetMarkers) {
        Write-Host "Checking and removing contamination markers..." -ForegroundColor Cyan
        $markerDir = '/etc/samba-cifs-sim/contamination-markers'
        $distrosRaw = & 'wsl.exe' -l -q 2>&1
        $existingDistros = Normalize-WslDistroNames -RawNames @($distrosRaw -split "`r?`n")
        $removedMarkers = @()
        $notFoundMarkers = @()
        $unknownStatusMarkers = @()
        $missingDistros = @()

        foreach ($envName in $Environments) {
            $slug = Get-EnvironmentSlug -EnvironmentName $envName
            $distroName = "$TestDistroName-$slug"
            
            if ($distroName -notin $existingDistros) {
                $missingDistros += $distroName
                continue
            }

            $fileName = $knownMarkers[$envName]
            $markerPath = "$markerDir/$fileName"

            $result = Invoke-WslMarkerResetSilent -DistroName $distroName -MarkerPath $markerPath
            if ($result -match 'removed') {
                $removedMarkers += $distroName
            }
            elseif ($result -match 'missing') {
                $notFoundMarkers += $distroName
            }
            else {
                $unknownStatusMarkers += $distroName
            }
        }

        [Console]::WriteLine("")
        Write-PlainListSection -Header "Contamination markers removed from:" -Items $removedMarkers
        Write-PlainListSection -Header "No contamination markers found in:" -Items $notFoundMarkers
        Write-PlainListSection -Header "Could not check contamination status in:" -Items $unknownStatusMarkers
        Write-PlainListSection -Header "Distro not found (skipped):" -Items $missingDistros
        return
    }

    if (-not $SkipCleanup) {
        Invoke-PreInjectionTestDistroCleanup
    }

    # Normal injection mode
    $distrosRaw = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-l', '-q') -CaptureOutput
    $existingDistros = Normalize-WslDistroNames -RawNames @($distrosRaw -split "`r?`n")
    
    foreach ($envName in $Environments) {
        $slug = Get-EnvironmentSlug -EnvironmentName $envName
        $distroName = "$TestDistroName-$slug"
        
        # Only create if it doesn't exist
        if ($distroName -notin $existingDistros) {
            Ensure-TestDistro -DistroName $distroName
        }

        try {
            Inject-Markers -DistroName $distroName -EnvironmentNames @($envName) -KnownMarkers $knownMarkers
            $createdDistros += $distroName
        }
        catch {
            Write-Log "Failed to inject marker in '$distroName': $($_.Exception.Message)"
            $failedDistros += @{ Distro = $distroName; Error = $_.Exception.Message }
            throw "Stopping after first failure in '$distroName': $($_.Exception.Message)"
        }

        # Add delay between distro operations
        if ($envName -ne $Environments[-1]) {
            Write-Log "Pausing 5 seconds before next operation..."
            Start-Sleep -Seconds 5
        }
    }

    Write-Log "Completed marker injection for $($createdDistros.Count) successful distro(s)"
    Write-Host ""
    Write-Host "Distros with markers injected:" -ForegroundColor Green
    foreach ($name in $createdDistros) {
        Write-Host "  - $name" -ForegroundColor Green
    }
    
    if ($failedDistros.Count -gt 0) {
        Write-Host ""
        Write-Host "Distros that failed (broken systemd or inaccessible):" -ForegroundColor Yellow
        foreach ($entry in $failedDistros) {
            Write-Host "  - $($entry.Distro)" -ForegroundColor Yellow
            Write-Host "    Reason: $($entry.Error)" -ForegroundColor DarkYellow
        }
    }
}
else {
    if ($ResetMarkers) {
        Write-Host "Checking and removing contamination markers..." -ForegroundColor Cyan
        $markerDir = '/etc/samba-cifs-sim/contamination-markers'
        $removedMarkers = @()
        $notFoundMarkers = @()
        $unknownStatusMarkers = @()

        foreach ($envName in $Environments) {
            $markerFileName = $knownMarkers[$envName]
            $markerPath = "$markerDir/$markerFileName"

            $result = Invoke-WslMarkerResetSilent -DistroName $TestDistroName -MarkerPath $markerPath
            if ($result -match 'removed') {
                $removedMarkers += $envName
            }
            elseif ($result -match 'missing') {
                $notFoundMarkers += $envName
            }
            else {
                $unknownStatusMarkers += $envName
            }
        }

        [Console]::WriteLine("")
        Write-PlainListSection -Header "Contamination markers removed for:" -Items $removedMarkers
        Write-PlainListSection -Header "No contamination markers found for:" -Items $notFoundMarkers
        Write-PlainListSection -Header "Could not check contamination status for:" -Items $unknownStatusMarkers
        return
    }

    Ensure-TestDistro -DistroName $TestDistroName

    Inject-Markers -DistroName $TestDistroName -EnvironmentNames $Environments -KnownMarkers $knownMarkers
    Write-Host "Distros prepared:" -ForegroundColor Yellow
    Write-Host "  - $TestDistroName" -ForegroundColor Yellow
    Write-Log "Completed marker injection for $($Environments.Count) environment(s) in distro '$TestDistroName'"
}

Write-Host "Run detector with:" -ForegroundColor Yellow
Write-Host "  .\scripts\distro-contamination-detector.ps1 -AsJson -ScanAllDistrosForMarkers -ResolveK3sDistro -CreateDedicatedDistroWhenNeeded -DedicatedDistroName 'Ubuntu-k3s'" -ForegroundColor Yellow
