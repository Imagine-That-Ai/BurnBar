<#
.SYNOPSIS
    Prove a staging Remote Config fixture closes Windows privileged Computer Use.

.DESCRIPTION
    Runs only on a physical signed-in Windows session against burnbar-staging.
    The app must already hold a fresh authenticated remote-safety lease and the
    operator panic latch must be clear. The script publishes one approved
    fixture, observes the leaf-reaching lease and panic evidence for at most 60
    seconds, and always republishes the reviewed Baseline in a finally block.

    A successful safety halt does not terminate OpenBurnBar. The app remaining
    alive and responsive is required evidence that only privileged Computer Use
    was revoked.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ComputerKill', 'MalformedSystem')]
    [string] $Scenario,

    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    [Parameter(Mandatory = $true)]
    [switch] $ConfirmStagingMutation,

    [ValidateSet('burnbar-staging')]
    [string] $ProjectId = 'burnbar-staging',

    [ValidateRange(1, 60)]
    [int] $TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$publisherPath = Join-Path $PSScriptRoot 'publish-staging-remote-config-fixture.ps1'
$localRoot = Join-Path (
    [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
) 'OpenBurnBar'
$leasePath = Join-Path $localRoot 'privileged-input-remote-safety.flag'
$panicPath = Join-Path $localRoot 'privileged-input-kill.flag'
$diagnosticsPath = Join-Path $localRoot 'logs\winui-crash.log'
$allowPrefix = 'openburnbar-remote-safety-v1:allow-until:'
$expectedLease = 'openburnbar-remote-safety-v1:blocked:remote_system_disabled'
$expectedPanicReason = 'remote_config'
$startedAt = [DateTimeOffset]::UtcNow
$outputDirectory = Split-Path -Parent $OutputPath
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    $outputDirectory = (Get-Location).Path
    $OutputPath = Join-Path $outputDirectory $OutputPath
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Refusing to overwrite existing evidence: $OutputPath"
}
$result = [ordered]@{
    schema = 'openburnbar.windows.staging-runtime-safety-observation.v1'
    project = $ProjectId
    scenario = $Scenario
    startedAt = $startedAt.ToString('O')
    completedAt = $null
    timeoutSeconds = $TimeoutSeconds
    fixturePublish = $null
    baselineRestore = $null
    preconditions = [ordered]@{}
    observations = [ordered]@{}
    verdict = 'FAIL'
    error = $null
}
$failure = $null
$mutationAttempted = $false

function Get-Sha256Text([string] $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-AppObservation {
    $processes = @(Get-Process -Name 'OpenBurnBar.App' -ErrorAction SilentlyContinue)
    return [ordered]@{
        processCount = $processes.Count
        processIds = @($processes | ForEach-Object { $_.Id })
        alive = ($processes.Count -gt 0)
        responsive = ($processes.Count -gt 0 -and @($processes | Where-Object { -not $_.Responding }).Count -eq 0)
    }
}

try {
    if (-not $IsWindows) {
        throw 'This observer must run in a native Windows PowerShell 7 session.'
    }
    if (-not $ConfirmStagingMutation) {
        throw 'Pass -ConfirmStagingMutation after confirming this is the isolated staging project.'
    }
    if ($ProjectId -cne 'burnbar-staging') {
        throw 'This observer is hard-bound to burnbar-staging and refuses every other project.'
    }
    if (-not (Test-Path -LiteralPath $publisherPath -PathType Leaf)) {
        throw 'The committed staging fixture publisher is missing.'
    }
    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) {
        throw 'No remote-safety lease exists. Launch and authenticate the exact signed app first.'
    }

    $initialLease = [IO.File]::ReadAllText($leasePath).Trim()
    if (-not $initialLease.StartsWith($allowPrefix, [StringComparison]::Ordinal)) {
        throw 'The initial remote-safety lease is not an authenticated allow lease.'
    }
    $expiresText = $initialLease.Substring($allowPrefix.Length)
    $expiresAtMillis = 0L
    if (-not [long]::TryParse($expiresText, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$expiresAtMillis)) {
        throw 'The initial remote-safety lease expiry is malformed.'
    }
    $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds($expiresAtMillis)
    if ($expiresAt -le [DateTimeOffset]::UtcNow) {
        throw 'The initial remote-safety lease is expired.'
    }
    if (Test-Path -LiteralPath $panicPath) {
        throw 'The durable panic latch is already active. Explicitly start a fresh Computer Use session before this drill.'
    }
    $initialApp = Get-AppObservation
    if (-not $initialApp.alive -or -not $initialApp.responsive) {
        throw 'OpenBurnBar must be running and responsive before the staging drill.'
    }
    if (-not (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf)) {
        throw 'The signed app diagnostics log is missing.'
    }
    $initialDiagnostics = [IO.File]::ReadAllText($diagnosticsPath)
    $userStartMatches = [Text.RegularExpressions.Regex]::Matches(
        $initialDiagnostics,
        '(?m)^\[(?<timestamp>[^\]]+)\] computer-use\.panic-cleared(?: route=[^ ]+)? pid=\d+\r?\nuser_start\r?$'
    )
    if ($userStartMatches.Count -eq 0) {
        throw 'No operator-initiated Computer Use session start appears in app diagnostics.'
    }
    $lastUserStartAt = [DateTimeOffset]::Parse(
        $userStartMatches[$userStartMatches.Count - 1].Groups['timestamp'].Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    if ($lastUserStartAt -lt $startedAt.AddMinutes(-5)) {
        throw 'The operator-initiated Computer Use session start is stale. Start a fresh session immediately before this drill.'
    }
    $result.preconditions = [ordered]@{
        authenticatedAllowLease = $true
        allowLeaseExpiresAt = $expiresAt.ToString('O')
        panicLatchClear = $true
        operatorSessionStartedAt = $lastUserStartAt.ToString('O')
        app = $initialApp
        diagnosticsSha256 = Get-Sha256Text $initialDiagnostics
    }

    $mutationAttempted = $true
    $publishJson = & $publisherPath -Fixture $Scenario -ProjectId $ProjectId -ConfirmStagingMutation | Out-String
    $publish = $publishJson | ConvertFrom-Json
    if (-not $publish.parametersVerified -or -not $publish.restoreRequired) {
        throw 'The fixture publisher did not verify the non-baseline staging mutation.'
    }
    $publishedAt = [DateTimeOffset]::UtcNow
    $result.fixturePublish = [ordered]@{
        completedAt = $publishedAt.ToString('O')
        catalogSha256 = [string]$publish.catalogSha256
        fixturePayloadSha256 = [string]$publish.fixturePayloadSha256
        parametersVerified = [bool]$publish.parametersVerified
    }

    $deadline = $publishedAt.AddSeconds($TimeoutSeconds)
    $leaseObservedAt = $null
    $panicObservedAt = $null
    $diagnosticsObservedAt = $null
    $diagnosticDelta = ''
    do {
        if ($null -eq $leaseObservedAt -and (Test-Path -LiteralPath $leasePath)) {
            if ([IO.File]::ReadAllText($leasePath).Trim() -ceq $expectedLease) {
                $leaseObservedAt = [DateTimeOffset]::UtcNow
            }
        }
        if ($null -eq $panicObservedAt -and (Test-Path -LiteralPath $panicPath)) {
            if ([IO.File]::ReadAllText($panicPath).Trim() -ceq $expectedPanicReason) {
                $panicObservedAt = [DateTimeOffset]::UtcNow
            }
        }
        $currentDiagnostics = [IO.File]::ReadAllText($diagnosticsPath)
        if (-not $currentDiagnostics.StartsWith($initialDiagnostics, [StringComparison]::Ordinal)) {
            throw 'The app diagnostics log was replaced or truncated during the staging drill.'
        }
        $diagnosticDelta = $currentDiagnostics.Substring($initialDiagnostics.Length)
        $hasPanicEvent = $diagnosticDelta -match '(?m)^\[[^\]]+\] computer-use\.panic(?: route=[^ ]+)? pid=\d+\r?\nremote_config\r?$'
        $expectedRefresh = if ($Scenario -ceq 'ComputerKill') {
            'computer_kill=True;media_kill=False'
        } else {
            'computer_kill=False;media_kill=False'
        }
        $hasRefreshEvent = $diagnosticDelta.Contains($expectedRefresh, [StringComparison]::Ordinal)
        if ($null -eq $diagnosticsObservedAt -and $hasPanicEvent -and $hasRefreshEvent) {
            $diagnosticsObservedAt = [DateTimeOffset]::UtcNow
        }
        if ($null -ne $leaseObservedAt -and $null -ne $panicObservedAt -and $null -ne $diagnosticsObservedAt) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $finalApp = Get-AppObservation
    $observedTimes = @($leaseObservedAt, $panicObservedAt, $diagnosticsObservedAt) |
        Where-Object { $null -ne $_ }
    $haltObservedAt = @($observedTimes | Sort-Object | Select-Object -Last 1)
    $haltLatencyMilliseconds = if ($haltObservedAt.Count -eq 1) {
        [math]::Round(($haltObservedAt[0] - $publishedAt).TotalMilliseconds)
    } else { $null }
    $result.observations = [ordered]@{
        leaseBlocked = ($null -ne $leaseObservedAt)
        panicLatchActive = ($null -ne $panicObservedAt)
        diagnosticPanicEvent = ($null -ne $diagnosticsObservedAt)
        diagnosticRefreshExpected = $expectedRefresh
        diagnosticDeltaSha256 = Get-Sha256Text $diagnosticDelta
        leaseObservedAt = if ($null -eq $leaseObservedAt) { $null } else { $leaseObservedAt.ToString('O') }
        panicObservedAt = if ($null -eq $panicObservedAt) { $null } else { $panicObservedAt.ToString('O') }
        diagnosticsObservedAt = if ($null -eq $diagnosticsObservedAt) { $null } else { $diagnosticsObservedAt.ToString('O') }
        haltLatencyMilliseconds = $haltLatencyMilliseconds
        app = $finalApp
        mainAppTerminationExpected = $false
    }
    if ($null -eq $leaseObservedAt -or $null -eq $panicObservedAt -or $null -eq $diagnosticsObservedAt) {
        throw 'Privileged Computer Use did not produce every required fail-closed signal within the release bound.'
    }
    if (-not $finalApp.alive -or -not $finalApp.responsive) {
        throw 'OpenBurnBar did not remain alive and responsive after privileged Computer Use halted.'
    }
    $result.verdict = 'PASS'
}
catch {
    $failure = $_
    $result.error = $_.Exception.Message
}
finally {
    if ($mutationAttempted) {
        try {
            $restoreJson = & $publisherPath -Fixture Baseline -ProjectId $ProjectId -ConfirmStagingMutation | Out-String
            $restore = $restoreJson | ConvertFrom-Json
            if (-not $restore.parametersVerified -or $restore.restoreRequired) {
                throw 'The fixture publisher did not verify the reviewed Baseline restore.'
            }
            $result.baselineRestore = [ordered]@{
                completedAt = [DateTimeOffset]::UtcNow.ToString('O')
                catalogSha256 = [string]$restore.catalogSha256
                fixturePayloadSha256 = [string]$restore.fixturePayloadSha256
                parametersVerified = [bool]$restore.parametersVerified
            }
        }
        catch {
            $result.baselineRestore = [ordered]@{
                completedAt = [DateTimeOffset]::UtcNow.ToString('O')
                parametersVerified = $false
                error = $_.Exception.Message
            }
            $result.verdict = 'FAIL'
            if ($null -eq $failure) {
                $failure = $_
                $result.error = "Baseline restore failed: $($_.Exception.Message)"
            }
        }
    }
    $result.completedAt = [DateTimeOffset]::UtcNow.ToString('O')
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $temporaryOutput = "$OutputPath.tmp-$([guid]::NewGuid().ToString('N'))"
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryOutput -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporaryOutput -Destination $OutputPath
}

if ($null -ne $failure) {
    throw $failure
}
$result | ConvertTo-Json -Depth 12
