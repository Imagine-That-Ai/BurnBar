[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet("X64", "Arm64")]
    [string]$ExpectedArchitecture,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedPublisher,

    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath,

    [string]$PackageName = "ImagineThat.OpenBurnBar",
    [string]$ApplicationId = "OpenBurnBar",
    [string]$ProcessName = "OpenBurnBar.App",

    [ValidateRange(10, 300)]
    [int]$HoldSeconds = 20
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$package = [System.IO.Path]::GetFullPath($PackagePath)
$receipt = [System.IO.Path]::GetFullPath($ReceiptPath)
$startedAt = (Get-Date).ToUniversalTime()
$steps = [System.Collections.Generic.List[object]]::new()
$ownsRegistration = $false

if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
    throw "Signed MSIX is missing: $package"
}
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $receipt) -Force)

function Get-OpenBurnBarPackage {
    Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Stop-OpenBurnBar {
    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        $processes | Stop-Process -Force
        $processes | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    }
}

function Assert-PackageIdentity([object] $InstalledPackage, [string] $Stage) {
    if (-not $InstalledPackage) {
        throw "$Stage did not register $PackageName."
    }
    if ($InstalledPackage.Version.ToString() -cne $ExpectedVersion) {
        throw "$Stage registered version $($InstalledPackage.Version), expected $ExpectedVersion."
    }
    if ($InstalledPackage.Architecture.ToString() -cne $ExpectedArchitecture) {
        throw "$Stage registered architecture $($InstalledPackage.Architecture), expected $ExpectedArchitecture."
    }
    if ($InstalledPackage.Publisher -cne $ExpectedPublisher) {
        throw "$Stage registered publisher '$($InstalledPackage.Publisher)', expected '$ExpectedPublisher'."
    }
    if (-not (Test-Path -LiteralPath $InstalledPackage.InstallLocation -PathType Container)) {
        throw "$Stage install location is missing: $($InstalledPackage.InstallLocation)"
    }
    $resourcesPri = Join-Path $InstalledPackage.InstallLocation "resources.pri"
    if (-not (Test-Path -LiteralPath $resourcesPri -PathType Leaf)) {
        throw "$Stage package is missing package-root resources.pri."
    }
}

function Add-PackageStep([string] $Name, [object] $InstalledPackage) {
    $steps.Add([ordered]@{
        name = $Name
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        packageFullName = if ($InstalledPackage) { $InstalledPackage.PackageFullName } else { $null }
        version = if ($InstalledPackage) { $InstalledPackage.Version.ToString() } else { $null }
        architecture = if ($InstalledPackage) { $InstalledPackage.Architecture.ToString() } else { $null }
        publisher = if ($InstalledPackage) { $InstalledPackage.Publisher } else { $null }
        installLocation = if ($InstalledPackage) { $InstalledPackage.InstallLocation } else { $null }
    })
}

function Test-SustainedLaunch([object] $InstalledPackage, [string] $Stage) {
    Stop-OpenBurnBar
    $logPath = Join-Path $env:LOCALAPPDATA "OpenBurnBar\logs\winui-crash.log"
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    $launchStartedAt = Get-Date
    $appUserModelId = "$($InstalledPackage.PackageFamilyName)!$ApplicationId"
    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "shell:AppsFolder\$appUserModelId"

    $launchDeadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 500
        $launched = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    } while ($launched.Count -eq 0 -and (Get-Date) -lt $launchDeadline)
    $observedAt = Get-Date
    if ($launched.Count -gt 0) {
        Start-Sleep -Seconds $HoldSeconds
    }

    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Select-Object Id, ProcessName, StartTime, Responding, SessionId)
    $events = @(Get-WinEvent -FilterHashtable @{
            LogName = "Application"
            StartTime = $launchStartedAt
        } -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.ProviderName -match "Application Error|Windows Error Reporting|\.NET Runtime") -and
            ($_.Message -match "OpenBurnBar|ImagineThat\.OpenBurnBar")
        } |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName)
    $logLines = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        @(Get-Content -LiteralPath $logPath -Tail 100)
    } else {
        @()
    }
    $fatalLog = ($logLines -join "`n") -match "Application\.UnhandledException|XamlParseException|fatal"
    $responding = $processes.Count -gt 0 -and @($processes | Where-Object { -not $_.Responding }).Count -eq 0
    $passed = $responding -and $events.Count -eq 0 -and -not $fatalLog

    [ordered]@{
        name = $Stage
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        appUserModelId = $appUserModelId
        launchStartedAt = $launchStartedAt.ToUniversalTime().ToString("o")
        processObservedAt = $observedAt.ToUniversalTime().ToString("o")
        holdSeconds = $HoldSeconds
        passed = $passed
        processes = $processes
        crashEventCount = $events.Count
        crashEvents = $events
        crashLogExists = (Test-Path -LiteralPath $logPath -PathType Leaf)
        crashLogFatal = $fatalLog
        crashLogSha256 = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash.ToLowerInvariant()
        } else {
            $null
        }
    }
}

function Write-Receipt([string] $Status, [object] $ErrorRecord = $null) {
    [ordered]@{
        schema = "openburnbar.windows.signed-msix-lifecycle.v2"
        status = $Status
        startedAt = $startedAt.ToString("o")
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        workflowRunId = $env:GITHUB_RUN_ID
        workflowRunAttempt = $env:GITHUB_RUN_ATTEMPT
        commit = $env:GITHUB_SHA
        package = [System.IO.Path]::GetFileName($package)
        packageSha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
        expectedArchitecture = $ExpectedArchitecture
        holdSeconds = $HoldSeconds
        error = if ($ErrorRecord) { $ErrorRecord.Exception.Message } else { $null }
        steps = $steps
    } | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath $receipt
}

$preExisting = Get-OpenBurnBarPackage
if ($preExisting) {
    throw "Hosted runner is not clean: $($preExisting.PackageFullName) is already registered."
}

try {
    Add-AppxPackage -Path $package -ForceApplicationShutdown
    $ownsRegistration = $true
    $firstInstall = Get-OpenBurnBarPackage
    Assert-PackageIdentity $firstInstall "Clean install"
    Add-PackageStep "clean-install" $firstInstall

    $firstLaunch = Test-SustainedLaunch $firstInstall "clean-install-sustained-launch"
    $steps.Add($firstLaunch)
    if (-not $firstLaunch.passed) {
        throw "Clean-install launch failed sustained runtime checks."
    }

    Stop-OpenBurnBar
    Remove-AppxPackage -Package $firstInstall.PackageFullName
    $ownsRegistration = $false
    if (Get-OpenBurnBarPackage) {
        throw "Package is still registered after uninstall."
    }
    Add-PackageStep "uninstall" $null

    Add-AppxPackage -Path $package -ForceApplicationShutdown
    $ownsRegistration = $true
    $secondInstall = Get-OpenBurnBarPackage
    Assert-PackageIdentity $secondInstall "Reinstall"
    Add-PackageStep "reinstall" $secondInstall

    $secondLaunch = Test-SustainedLaunch $secondInstall "reinstall-sustained-launch"
    $steps.Add($secondLaunch)
    if (-not $secondLaunch.passed) {
        throw "Reinstall launch failed sustained runtime checks."
    }

    Write-Receipt "passed"
}
catch {
    Write-Receipt "failed" $_
    throw
}
finally {
    Stop-OpenBurnBar
    if ($ownsRegistration) {
        $installed = Get-OpenBurnBarPackage
        if ($installed) {
            Remove-AppxPackage -Package $installed.PackageFullName -ErrorAction SilentlyContinue
        }
    }
}
