<#
.SYNOPSIS
    Initialize or finalize a fail-closed supplemental Windows certification receipt.

.DESCRIPTION
    -Initialize writes the canonical assertion checklist for one external gate.
    Finalization accepts only a complete PASS result set, binds it to a
    validator-clean physical baseline, rechecks the live machine identity, copies
    every referenced raw evidence file, hashes the result, and validates the
    generated receipt. It never turns incomplete observations into PASS.
#>
[CmdletBinding(DefaultParameterSetName = 'Finalize')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'physical-performance-x64',
        'physical-performance-arm64',
        'accessibility-display',
        'staging-cloud',
        'media-computer-use-safety',
        'store-update-lifecycle'
    )]
    [string] $Gate,

    [Parameter(Mandatory = $true)] [string] $ResultsPath,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,

    [Parameter(Mandatory = $true, ParameterSetName = 'Initialize')]
    [switch] $Initialize,

    [Parameter(Mandatory = $true, ParameterSetName = 'Finalize')]
    [string] $BaselineBundle,

    [Parameter(Mandatory = $true, ParameterSetName = 'Finalize')]
    [string] $OutputDirectory,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ResultsSchema = 'openburnbar.windows.release-certification-protocol-results.v1'
$ReceiptSchema = 'openburnbar.windows.release-certification-receipt.v1'
$AttestationSchema = 'openburnbar.windows.physical-hardware-attestation.v1'
$VirtualHostPattern = '(?i)(VMware|VirtualBox|QEMU|UTM|Parallels|KVM|Virtual Machine|Hyper-V|Amazon EC2|Google Compute Engine|HVM domU|\bXen\b|OpenStack|Bochs|BHYVE|DigitalOcean)'
$TextEvidenceExtensions = @('.csv', '.har', '.html', '.json', '.jsonl', '.log', '.md', '.ndjson', '.text', '.trx', '.txt', '.xml', '.yaml', '.yml')
$SecretPattern = '(?i)(authorization|bearer|access_token|refresh_token|id_token|client_secret|api_key|app_check|private_key|passphrase)\s*["'']?\s*[:=]\s*["'']?(?!\[REDACTED(?:_JWT)?\]|none\b|null\b|not[- ]available\b)[^\s,"'';}]+'
$JwtPattern = '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{20,}\.?[A-Za-z0-9_.-]*'

function Resolve-FullPath([string] $Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Write-JsonNoBom([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 64
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-Sha256([string] $Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-PrintableText([string] $Value, [string] $Label, [int] $MaximumLength = 4096) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength -or $Value -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
        throw "$Label must be non-empty printable text no longer than $MaximumLength characters."
    }
}

function Assert-NoSecretMaterial([string] $Text, [string] $Label) {
    if ($Text -match $SecretPattern -or $Text -match $JwtPattern) {
        throw "$Label contains secret-like material. Redact the evidence before certification."
    }
}

function Test-UsableInventoryIdentifier([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $candidate = $Value.Trim()
    if ($candidate.Length -gt 128 -or $candidate -match '[\x00-\x1f\x7f]') { return $false }
    return $candidate -notmatch '(?i)^(none|unknown|default string|to be filled by o\.e\.m\.|not specified|system asset tag|chassis asset tag)$'
}

function Normalize-Architecture([string] $Value) {
    $normalized = $Value.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($normalized -in @('x64', 'amd64', 'x8664')) { return 'x64' }
    if ($normalized -in @('arm64', 'aarch64')) { return 'arm64' }
    return $normalized
}

function Get-RepositoryCommit([string] $Root, [string] $Label) {
    $value = (& git -C $Root rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Unable to resolve the $Label commit." }
    $commit = $value.Trim().ToLowerInvariant()
    if ($commit -notmatch '^[a-f0-9]{40}$') { throw "The $Label commit is not a full Git SHA." }
    return $commit
}

function Test-RepositoryDirty([string] $Root) {
    $value = (& git -C $Root status --porcelain 2>$null)
    return -not [string]::IsNullOrWhiteSpace(($value -join "`n"))
}

function Assert-IdentityMatch([string] $LiveValue, [string] $BaselineValue, [string] $Field) {
    if (-not [string]::Equals($LiveValue, $BaselineValue, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The live device $Field does not match the physical baseline."
    }
}

$repo = Resolve-FullPath $RepoRoot
$harness = Resolve-FullPath (Join-Path $PSScriptRoot '..\..')
$catalogPath = Join-Path $harness 'scripts\windows-port\release-certification-protocols.json'
if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "Certification protocol catalog is missing: $catalogPath"
}
$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
if ([string]$catalog.schema -ne 'openburnbar.windows.release-certification-protocols.v1') {
    throw 'Unsupported certification protocol catalog schema.'
}
$gateProperty = $catalog.gates.PSObject.Properties[$Gate]
if ($null -eq $gateProperty) { throw "Certification gate is absent from the catalog: $Gate" }
$profileName = [string]$gateProperty.Value.profile
$profileProperty = $catalog.profiles.PSObject.Properties[$profileName]
if ($null -eq $profileProperty) { throw "Certification profile is absent from the catalog: $profileName" }
$profile = $profileProperty.Value
$requiredAssertions = @($profile.assertions)

$resultsFile = Resolve-FullPath $ResultsPath
if ($Initialize) {
    if ((Test-Path -LiteralPath $resultsFile) -and -not $Force) {
        throw "Refusing to overwrite an existing protocol result without -Force: $resultsFile"
    }
    $template = [ordered]@{
        schema = $ResultsSchema
        gate = $Gate
        startedAtUtc = $null
        endedAtUtc = $null
        commands = @()
        manualSteps = @()
        observed = ''
        assertions = @($requiredAssertions | ForEach-Object {
            [ordered]@{
                id = [string]$_.id
                description = [string]$_.description
                status = 'NOT_RUN'
                observed = ''
                evidenceFiles = @()
            }
        })
    }
    Write-JsonNoBom $resultsFile $template
    Write-Output "Protocol template: $resultsFile"
    Write-Output "Gate: $Gate"
    Write-Output "Required assertions: $($requiredAssertions.Count)"
    return
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Supplemental physical certification receipts must be finalized on Windows.'
}
if (-not (Test-Path -LiteralPath (Join-Path $repo 'windows\OpenBurnBar.sln') -PathType Leaf)) {
    throw "RepoRoot is not an OpenBurnBar checkout: $repo"
}
$commit = (& git -C $repo rev-parse HEAD).Trim().ToLowerInvariant()
if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'Unable to resolve a full candidate commit.' }
if (& git -C $repo status --porcelain) { throw 'Refusing a supplemental receipt from a dirty source checkout.' }
$harnessCommit = Get-RepositoryCommit $harness 'certification harness'
if (Test-RepositoryDirty $harness) { throw 'Refusing a supplemental receipt from a dirty certification harness checkout.' }

$baseline = Resolve-FullPath $BaselineBundle
if (-not (Test-Path -LiteralPath $baseline -PathType Container)) {
    throw "Baseline bundle is missing: $baseline"
}
$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) { throw 'Node.js is required to validate certification evidence.' }
& $node.Source (Join-Path $harness 'scripts\windows-port\validate-release-certification-evidence.mjs') `
    $baseline --expected-commit $commit --expected-harness-commit $harnessCommit
if ($LASTEXITCODE -ne 0) { throw 'The physical baseline bundle is not validator-clean.' }

$baselineReceiptPath = Join-Path $baseline ("receipts\" + $Gate + '.json')
if (-not (Test-Path -LiteralPath $baselineReceiptPath -PathType Leaf)) {
    throw "The physical baseline has no receipt for $Gate."
}
$baselineReceipt = Get-Content -Raw -LiteralPath $baselineReceiptPath | ConvertFrom-Json
if ([string]$baselineReceipt.gate -ne $Gate) {
    throw 'The baseline receipt gate does not match the requested certification gate.'
}
if ([string]$baselineReceipt.source.commitSha -ne $commit -or $baselineReceipt.source.dirtyTree -eq $true) {
    throw 'The baseline receipt is not bound to the clean current commit.'
}
if ([string]$baselineReceipt.source.harness.commitSha -ne $harnessCommit -or
    $baselineReceipt.source.harness.dirtyTree -eq $true) {
    throw 'The baseline receipt is not bound to the clean current certification harness.'
}
if ([string]$baselineReceipt.device.kind -ne 'physical-windows') {
    throw 'The baseline receipt is not bound to physical Windows hardware.'
}
if ([string]$baselineReceipt.artifact.availability -ne 'recorded' -or [string]$baselineReceipt.artifact.signature.result -ne 'verified') {
    throw 'The baseline receipt is not bound to a verified signed artifact.'
}
if ([string]$baselineReceipt.artifact.sourceCommit -ne $commit) {
    throw 'The baseline signed artifact is not bound to the clean current commit.'
}

if (-not (Test-Path -LiteralPath $resultsFile -PathType Leaf)) {
    throw "Protocol results are missing: $resultsFile"
}
$resultsText = Get-Content -Raw -LiteralPath $resultsFile
Assert-NoSecretMaterial $resultsText 'Protocol results'
$results = $resultsText | ConvertFrom-Json
if ([string]$results.schema -ne $ResultsSchema -or [string]$results.gate -ne $Gate) {
    throw 'Protocol result schema or gate does not match the requested certification gate.'
}

$startedAt = [DateTimeOffset]::MinValue
$endedAt = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParse([string]$results.startedAtUtc, [ref]$startedAt) -or
    -not [DateTimeOffset]::TryParse([string]$results.endedAtUtc, [ref]$endedAt) -or
    $endedAt -lt $startedAt -or
    $endedAt -lt [DateTimeOffset]::UtcNow.AddHours(-24) -or
    $endedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
    throw 'Protocol results contain an invalid, stale, or future time interval.'
}
Assert-PrintableText ([string]$results.observed) 'Protocol observed summary'

$commands = @($results.commands)
$manualSteps = @($results.manualSteps)
if ($commands.Count -eq 0 -and $manualSteps.Count -eq 0) {
    throw 'Protocol results require at least one command or manual step.'
}
foreach ($value in @($commands) + @($manualSteps)) {
    Assert-PrintableText ([string]$value) 'Protocol command/manual step' 8192
}

$assertionById = @{}
foreach ($assertion in @($results.assertions)) {
    $assertionId = [string]$assertion.id
    if ([string]::IsNullOrWhiteSpace($assertionId) -or $assertionById.ContainsKey($assertionId)) {
        throw "Protocol results contain a missing or duplicate assertion id: $assertionId"
    }
    $assertionById[$assertionId] = $assertion
}
$requiredIds = @($requiredAssertions | ForEach-Object { [string]$_.id })
foreach ($assertionId in $assertionById.Keys) {
    if ($requiredIds -notcontains $assertionId) { throw "Unknown protocol assertion: $assertionId" }
}
foreach ($assertionId in $requiredIds) {
    if (-not $assertionById.ContainsKey($assertionId)) { throw "Required protocol assertion is missing: $assertionId" }
}

$computer = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
$enclosure = Get-CimInstance Win32_SystemEnclosure | Select-Object -First 1
$systemProduct = Get-CimInstance Win32_ComputerSystemProduct | Select-Object -First 1
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$operatingSystem = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
$manufacturer = ([string]$computer.Manufacturer).Trim()
$model = ([string]$computer.Model).Trim()
if ("$manufacturer $model" -match $VirtualHostPattern) { throw 'The current host identity looks virtualized.' }
$liveArchitecture = switch ([int]$cpu.Architecture) {
    9 { 'x64' }
    12 { 'arm64' }
    default { throw "Unsupported live processor architecture code: $($cpu.Architecture)" }
}
$selectedIdentifier = @(
    [ordered]@{ value = [string]$enclosure.SMBIOSAssetTag; source = 'Win32_SystemEnclosure.SMBIOSAssetTag' },
    [ordered]@{ value = [string]$systemProduct.IdentifyingNumber; source = 'Win32_ComputerSystemProduct.IdentifyingNumber' }
) | Where-Object { Test-UsableInventoryIdentifier ([string]$_.value) } | Select-Object -First 1
if ($null -eq $selectedIdentifier) { throw 'The current device has no usable physical inventory identifier.' }
$assetTag = ([string]$selectedIdentifier.value).Trim()
$assetTagSource = [string]$selectedIdentifier.source
$osBuild = ('{0} {1} build {2}' -f $operatingSystem.Caption, $operatingSystem.Version, $operatingSystem.BuildNumber)
$tpmState = 'unknown'
try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmState = ('present={0};ready={1};managedAuthLevel={2}' -f $tpm.TpmPresent, $tpm.TpmReady, [string]$tpm.ManagedAuthLevel)
} catch {
    $tpmState = 'unavailable'
}
Assert-IdentityMatch $manufacturer ([string]$baselineReceipt.device.manufacturer) 'manufacturer'
Assert-IdentityMatch $model ([string]$baselineReceipt.device.model) 'model'
Assert-IdentityMatch $assetTag ([string]$baselineReceipt.device.assetTag) 'assetTag'
Assert-IdentityMatch $assetTagSource ([string]$baselineReceipt.device.assetTagSource) 'assetTagSource'
Assert-IdentityMatch $osBuild ([string]$baselineReceipt.device.osBuild) 'osBuild'
Assert-IdentityMatch $tpmState ([string]$baselineReceipt.device.tpm) 'tpm'
Assert-IdentityMatch ([string]$cpu.Name) ([string]$baselineReceipt.device.cpu) 'cpu'
if ((Normalize-Architecture ([string]$baselineReceipt.device.architecture)) -ne $liveArchitecture) {
    throw 'The live device architecture does not match the physical baseline.'
}
$requiredArchitecture = [string]$gateProperty.Value.architecture
if (-not [string]::IsNullOrWhiteSpace($requiredArchitecture) -and
    (Normalize-Architecture $requiredArchitecture) -ne $liveArchitecture) {
    throw "$Gate requires $requiredArchitecture physical hardware."
}
if ((Normalize-Architecture ([string]$baselineReceipt.artifact.architecture)) -ne $liveArchitecture) {
    throw 'The signed artifact architecture does not match the live physical device.'
}

$attestationMetadata = $baselineReceipt.device.hardwareAttestation
if ($null -eq $attestationMetadata -or [string]$attestationMetadata.schema -ne $AttestationSchema) {
    throw 'The physical baseline has no supported hardware attestation metadata.'
}
$attestationSource = [System.IO.Path]::GetFullPath((Join-Path $baseline ([string]$attestationMetadata.evidencePath)))
$baselineWithSeparator = $baseline.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $attestationSource.StartsWith($baselineWithSeparator, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $attestationSource -PathType Leaf) -or
    (Get-Sha256 $attestationSource) -ne [string]$attestationMetadata.sha256) {
    throw 'The physical baseline hardware attestation file is missing, outside the bundle, or hash-mismatched.'
}
$attestation = Get-Content -Raw -LiteralPath $attestationSource | ConvertFrom-Json
$attestationCapturedAt = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParse([string]$attestation.capturedAtUtc, [ref]$attestationCapturedAt) -or
    $attestationCapturedAt -gt $endedAt -or
    $attestationCapturedAt -lt $startedAt.AddHours(-24)) {
    throw 'The hardware attestation is outside the allowed protocol time window.'
}

$outputRoot = Resolve-FullPath $OutputDirectory
$receiptPath = Join-Path $outputRoot ($Gate + '.json')
if ((Test-Path -LiteralPath $receiptPath) -and -not $Force) {
    throw "Refusing to overwrite an existing supplemental receipt without -Force: $receiptPath"
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$evidenceEntries = [System.Collections.Generic.List[object]]::new()
$attestationRelative = 'evidence/hardware-attestation-' + $liveArchitecture + '.json'
$attestationDestination = Join-Path $outputRoot ($attestationRelative.Replace('/', '\'))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $attestationDestination) | Out-Null
if (Test-Path -LiteralPath $attestationDestination) {
    if ((Get-Sha256 $attestationDestination) -ne (Get-Sha256 $attestationSource)) {
        throw "A different hardware attestation already exists: $attestationDestination"
    }
} else {
    Copy-Item -LiteralPath $attestationSource -Destination $attestationDestination
}
$attestationHash = Get-Sha256 $attestationDestination
$evidenceEntries.Add([ordered]@{ path = $attestationRelative; sha256 = $attestationHash })

$resultsRoot = Split-Path -Parent $resultsFile
$resultsRootWithSeparator = $resultsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$copiedEvidence = @{}
$assertionReceipts = [System.Collections.Generic.List[object]]::new()
$evidenceIndex = 0
foreach ($requiredAssertion in $requiredAssertions) {
    $assertionId = [string]$requiredAssertion.id
    $assertion = $assertionById[$assertionId]
    if ([string]$assertion.status -cne 'PASS') { throw "Assertion $assertionId did not PASS." }
    Assert-PrintableText ([string]$assertion.observed) "Assertion $assertionId observed result"
    $rawFiles = @($assertion.evidenceFiles)
    if ($rawFiles.Count -eq 0) { throw "Assertion $assertionId has no raw evidence file." }
    $assertionEvidence = [System.Collections.Generic.List[string]]::new()
    foreach ($rawFile in $rawFiles) {
        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $resultsRoot ([string]$rawFile)))
        if (-not $sourcePath.StartsWith($resultsRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Assertion $assertionId evidence is missing or escapes the result directory: $rawFile"
        }
        $extension = [System.IO.Path]::GetExtension($sourcePath).ToLowerInvariant()
        if ($TextEvidenceExtensions -contains $extension) {
            Assert-NoSecretMaterial (Get-Content -Raw -LiteralPath $sourcePath) "Assertion $assertionId evidence $rawFile"
        }
        if (-not $copiedEvidence.ContainsKey($sourcePath)) {
            $evidenceIndex += 1
            $fileName = [System.IO.Path]::GetFileName($sourcePath)
            $destinationRelative = 'evidence/' + $Gate + '/' + $evidenceIndex.ToString('000') + '-' + $fileName
            $destinationPath = Join-Path $outputRoot ($destinationRelative.Replace('/', '\'))
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force:$Force
            $entry = [ordered]@{ path = $destinationRelative; sha256 = Get-Sha256 $destinationPath }
            $copiedEvidence[$sourcePath] = $entry
            $evidenceEntries.Add($entry)
        }
        $assertionEvidence.Add([string]$copiedEvidence[$sourcePath].path)
    }
    $assertionReceipts.Add([ordered]@{
        id = $assertionId
        status = 'PASS'
        observed = [string]$assertion.observed
        evidence = @($assertionEvidence)
    })
}

$device = $baselineReceipt.device
$device.capturedAtUtc = [DateTimeOffset]::UtcNow.ToUniversalTime().ToString('o')
$device.hardwareAttestation.evidencePath = $attestationRelative
$device.hardwareAttestation.sha256 = $attestationHash
$receipt = [ordered]@{
    schema = $ReceiptSchema
    status = 'PASS'
    gate = $Gate
    target = [string]$profile.target
    source = $baselineReceipt.source
    artifact = $baselineReceipt.artifact
    device = $device
    protocol = [ordered]@{
        commands = @($commands | ForEach-Object { [string]$_ })
        manualSteps = @($manualSteps | ForEach-Object { [string]$_ })
        profileSchema = [string]$catalog.schema
        profile = $profileName
        assertions = @($assertionReceipts)
    }
    time = [ordered]@{
        startedAtUtc = $startedAt.ToUniversalTime().ToString('o')
        endedAtUtc = $endedAt.ToUniversalTime().ToString('o')
        durationSeconds = [Math]::Max(0, ($endedAt - $startedAt).TotalSeconds)
    }
    expected = [string]$profile.expected
    observed = [string]$results.observed
    exitCode = 0
    evidence = [ordered]@{ files = @($evidenceEntries) }
    blocker = $null
}
Write-JsonNoBom $receiptPath $receipt
& $node.Source (Join-Path $harness 'scripts\windows-port\validate-release-certification-receipt.mjs') `
    $receiptPath $outputRoot
if ($LASTEXITCODE -ne 0) { throw 'Generated supplemental receipt failed validation.' }

Write-Output "Supplemental receipt: $receiptPath"
Write-Output "Gate: $Gate"
Write-Output "Assertions: $($assertionReceipts.Count)/$($requiredAssertions.Count) PASS"
Write-Output "SHA-256: $(Get-Sha256 $receiptPath)"
