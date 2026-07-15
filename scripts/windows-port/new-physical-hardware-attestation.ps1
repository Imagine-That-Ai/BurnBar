<#
.SYNOPSIS
    Capture a fail-closed physical Windows hardware attestation.

.DESCRIPTION
    Reads the live Windows computer, enclosure, system-product, processor, and
    operating-system identities. Consumer systems frequently expose a generic
    chassis asset tag, so the stable system-product identifying number is used
    only when the OEM asset tag is absent or a known placeholder. The selected
    identifier source is recorded for independent verification by the physical
    release-certification runner.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Operator,
    [Parameter(Mandatory = $true)] [string] $OutputPath,
    [ValidateSet('x64', 'ARM64')] [string] $ExpectedArchitecture,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Test-UsableInventoryIdentifier([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $candidate = $Value.Trim()
    if ($candidate.Length -gt 128 -or $candidate -match '[\x00-\x1f\x7f]') { return $false }
    return $candidate -notmatch '(?i)^(none|unknown|default string|to be filled by o\.e\.m\.|not specified|system asset tag|chassis asset tag)$'
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Physical hardware attestation must be captured on Windows.'
}

$operatorName = $Operator.Trim()
if ([string]::IsNullOrWhiteSpace($operatorName) -or $operatorName.Length -gt 128 -or $operatorName -match '[\x00-\x1f\x7f]') {
    throw 'Operator must be a non-empty printable value no longer than 128 characters.'
}

$computer = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
$enclosure = Get-CimInstance Win32_SystemEnclosure | Select-Object -First 1
$systemProduct = Get-CimInstance Win32_ComputerSystemProduct | Select-Object -First 1
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1

$manufacturer = ([string]$computer.Manufacturer).Trim()
$model = ([string]$computer.Model).Trim()
if ([string]::IsNullOrWhiteSpace($manufacturer) -or [string]::IsNullOrWhiteSpace($model)) {
    throw 'Physical hardware identity did not expose manufacturer and model.'
}
$hostIdentity = "$manufacturer $model"
if ($hostIdentity -match '(?i)(VMware|VirtualBox|QEMU|UTM|Parallels|KVM|Virtual Machine|Hyper-V)') {
    throw "Refusing physical hardware attestation for a virtualized host identity: $hostIdentity"
}

$architecture = switch ([int]$cpu.Architecture) {
    9 { 'x64' }
    12 { 'ARM64' }
    default { throw "Unsupported processor architecture code: $($cpu.Architecture)" }
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedArchitecture) -and $architecture -ne $ExpectedArchitecture) {
    throw "Physical hardware architecture mismatch: expected $ExpectedArchitecture, observed $architecture."
}

$identifierCandidates = @(
    [ordered]@{
        value = [string]$enclosure.SMBIOSAssetTag
        source = 'Win32_SystemEnclosure.SMBIOSAssetTag'
    },
    [ordered]@{
        value = [string]$systemProduct.IdentifyingNumber
        source = 'Win32_ComputerSystemProduct.IdentifyingNumber'
    }
)
$selectedIdentifier = $identifierCandidates |
    Where-Object { Test-UsableInventoryIdentifier ([string]$_.value) } |
    Select-Object -First 1
if ($null -eq $selectedIdentifier) {
    throw 'Physical hardware identity exposed neither a usable OEM asset tag nor a usable system-product identifying number.'
}

$output = Resolve-FullPath $OutputPath
if ((Test-Path -LiteralPath $output) -and -not $Force) {
    throw "Refusing to overwrite existing hardware attestation without -Force: $output"
}
$parent = Split-Path -Parent $output
if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

$attestation = [ordered]@{
    schema = 'openburnbar.windows.physical-hardware-attestation.v1'
    operator = $operatorName
    physicalHardware = $true
    architecture = $architecture
    manufacturer = $manufacturer
    model = $model
    assetTag = ([string]$selectedIdentifier.value).Trim()
    assetTagSource = [string]$selectedIdentifier.source
    capturedAtUtc = [DateTimeOffset]::UtcNow.ToUniversalTime().ToString('o')
    processor = [ordered]@{
        name = [string]$cpu.Name
        manufacturer = [string]$cpu.Manufacturer
        architectureCode = [int]$cpu.Architecture
        addressWidth = [int]$cpu.AddressWidth
    }
    operatingSystem = [ordered]@{
        caption = [string]$os.Caption
        version = [string]$os.Version
        buildNumber = [string]$os.BuildNumber
        architecture = [string]$os.OSArchitecture
    }
}

$temporaryPath = $output + '.tmp-' + [Guid]::NewGuid().ToString('N')
try {
    $json = $attestation | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $output -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

$sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash.ToLowerInvariant()
Write-Output "Hardware attestation: $output"
Write-Output "Identifier source: $($attestation.assetTagSource)"
Write-Output "SHA-256: $sha256"
