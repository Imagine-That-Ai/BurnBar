<#
.SYNOPSIS
    Build and run the Windows Mercury file-transfer safety certification.

.DESCRIPTION
    Builds the shipping ARM64 WinUI app and exact-candidate host harness, then
    proves immutable snapshots, streaming verification, NTFS MOTW, Microsoft
    Defender scanning, explicit promotion, and threat-deny behavior.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [Parameter(Mandatory = $true)] [string] $OutputDirectory,
    [string] $CandidateManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-FullPath([string] $Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-JsonFile([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Value | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

$repo = Resolve-FullPath $RepoRoot
$output = Resolve-FullPath $OutputDirectory
if (-not (Test-Path -LiteralPath $repo -PathType Container)) {
    throw "Repository root not found: $repo"
}

$computerSystem = Get-CimInstance Win32_ComputerSystem
$operatingSystem = Get-CimInstance Win32_OperatingSystem
if ($computerSystem.SystemType -notlike 'ARM64*' -and $operatingSystem.OSArchitecture -notlike 'ARM 64*') {
    throw "This certification lane requires the Windows ARM64 host. Actual: $($computerSystem.SystemType) / $($operatingSystem.OSArchitecture)"
}

New-Item -ItemType Directory -Force -Path $output | Out-Null
$appProject = Join-Path $repo 'windows\app\OpenBurnBar.App\OpenBurnBar.App.csproj'
$harnessProject = Join-Path $repo 'windows\tests\mercury-file-transfer-host\OpenBurnBar.Mercury.FileTransfer.HostHarness\OpenBurnBar.Mercury.FileTransfer.HostHarness.csproj'
$hostOutput = Join-Path $output 'host'

Push-Location $repo
try {
    & dotnet build $appProject -c Release -p:Platform=ARM64 -r win-arm64
    if ($LASTEXITCODE -ne 0) { throw "Shipping WinUI app build failed with exit code $LASTEXITCODE." }

    & dotnet build $harnessProject -c Release -p:Platform=ARM64 -r win-arm64
    if ($LASTEXITCODE -ne 0) { throw "Mercury file-transfer host harness build failed with exit code $LASTEXITCODE." }

    & dotnet run --project $harnessProject -c Release -p:Platform=ARM64 -r win-arm64 --no-build -- --output $hostOutput
    if ($LASTEXITCODE -ne 0) { throw "Mercury file-transfer host harness failed with exit code $LASTEXITCODE." }
}
finally {
    Pop-Location
}

$summaryPath = Join-Path $hostOutput 'mercury-file-transfer-host-summary.json'
if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { throw "Host summary missing: $summaryPath" }
$summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
if (-not $summary.Passed) { throw 'Mercury file-transfer host summary did not pass.' }

$source = $null
$candidateManifestHash = $null
if (-not [string]::IsNullOrWhiteSpace($CandidateManifestPath)) {
    $manifestPath = Resolve-FullPath $CandidateManifestPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Candidate manifest not found: $manifestPath" }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $source = $manifest.source
    $candidateManifestHash = Get-Sha256 $manifestPath
}

$appExe = Get-ChildItem -Path (Join-Path $repo 'windows\app\OpenBurnBar.App\bin\ARM64\Release') -Filter 'OpenBurnBar.App.exe' -Recurse |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if ($null -eq $appExe) { throw 'Built OpenBurnBar.App.exe was not found.' }

$receipt = [ordered]@{
    schema = 'openburnbar.windows.mercury-file-transfer-host-evidence.v1'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'passed'
    source = $source
    candidateManifestSha256 = $candidateManifestHash
    osArchitecture = $operatingSystem.OSArchitecture
    systemType = $computerSystem.SystemType
    app = [ordered]@{
        fileName = $appExe.Name
        sha256 = Get-Sha256 $appExe.FullName
        size = $appExe.Length
    }
    hostSummary = [ordered]@{
        fileName = 'host/mercury-file-transfer-host-summary.json'
        sha256 = Get-Sha256 $summaryPath
        checks = $summary.Checks.Count
        passed = $summary.Passed
        snapshotSha256 = $summary.SnapshotSha256
        promotedFileSha256 = $summary.PromotedFileSha256
    }
}

$receiptPath = Join-Path $output 'mercury-file-transfer-host-receipt.json'
Write-JsonFile $receiptPath $receipt
Write-Host "Mercury file-transfer host evidence passed: $receiptPath" -ForegroundColor Green
