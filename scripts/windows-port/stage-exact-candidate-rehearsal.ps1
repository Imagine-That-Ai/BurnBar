<#
.SYNOPSIS
    Stage and run an exact signed Windows candidate rehearsal.

.DESCRIPTION
    Expands a source archive and its shallow Git metadata, verifies the exact
    commit and signed MSIX identity, then invokes the fail-closed physical
    certification runner without asserting physical hardware. This is a VM or
    lab rehearsal helper; it cannot produce physical certification PASS claims.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SourceArchivePath,
    [Parameter(Mandatory = $true)] [string] $GitMetadataArchivePath,
    [Parameter(Mandatory = $true)] [string] $ArtifactPath,
    [Parameter(Mandatory = $true)] [string] $ArtifactManifestPath,
    [Parameter(Mandatory = $true)] [string] $ExpectedCommit,
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [Parameter(Mandatory = $true)] [string] $OutputDir,
    [ValidateSet('x64', 'ARM64')] [Parameter(Mandatory = $true)] [string] $Platform,
    [string] $RunnerScriptPath = (Join-Path $PSScriptRoot 'run-physical-release-certification.ps1'),
    [switch] $SkipAutomatedTests,
    [switch] $SkipUiAutomation
)

$ErrorActionPreference = 'Stop'

function Resolve-ExistingFile([string] $Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Required file not found: $resolved"
    }
    return $resolved
}

function Get-Sha256([string] $Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Remove-DirectoryWithRetry([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    for ($attempt = 1; $attempt -le 5; $attempt += 1) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 5) {
                throw "Unable to clear rehearsal directory after $attempt attempts: $Path. $($_.Exception.Message)"
            }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds $attempt
        }
    }
}

function Expand-ZipWithTar([string] $Archive, [string] $Destination) {
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
        throw "Windows tar.exe is unavailable: $tar"
    }
    & $tar -xf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed to extract $Archive (exit $LASTEXITCODE)."
    }
}

$sourceArchive = Resolve-ExistingFile $SourceArchivePath
$gitArchive = Resolve-ExistingFile $GitMetadataArchivePath
$artifact = Resolve-ExistingFile $ArtifactPath
$artifactManifest = Resolve-ExistingFile $ArtifactManifestPath
$runner = Resolve-ExistingFile $RunnerScriptPath
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$expectedCommitNormalized = $ExpectedCommit.Trim().ToLowerInvariant()

if ($expectedCommitNormalized -notmatch '^[a-f0-9]{40}$') {
    throw 'ExpectedCommit must be a full 40-character Git SHA.'
}

$manifest = Get-Content -Raw -LiteralPath $artifactManifest | ConvertFrom-Json
foreach ($field in @('artifactName', 'architecture', 'artifactSha256', 'signatureResult', 'signatureIdentity')) {
    if ([string]::IsNullOrWhiteSpace([string]$manifest.$field)) {
        throw "Artifact manifest missing ${field}: $artifactManifest"
    }
}
if ([string]$manifest.architecture -ne $Platform) {
    throw "Artifact architecture mismatch: expected $Platform, got $($manifest.architecture)"
}
if ([string]$manifest.signatureResult -ne 'verified') {
    throw 'Artifact manifest does not assert a verified signature.'
}
$observedArtifactSha = Get-Sha256 $artifact
if ($observedArtifactSha -ne ([string]$manifest.artifactSha256).ToLowerInvariant()) {
    throw "Artifact SHA-256 mismatch: expected $($manifest.artifactSha256), got $observedArtifactSha"
}

$signature = Get-AuthenticodeSignature -LiteralPath $artifact
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "Authenticode verification failed: $($signature.Status) $($signature.StatusMessage)"
}
if ([string]$signature.SignerCertificate.Subject -ne [string]$manifest.signatureIdentity) {
    throw "Authenticode signer mismatch: expected $($manifest.signatureIdentity), got $($signature.SignerCertificate.Subject)"
}

Remove-DirectoryWithRetry $RepoRoot
New-Item -ItemType Directory -Force -Path $RepoRoot | Out-Null
Expand-ZipWithTar $sourceArchive $RepoRoot
Expand-ZipWithTar $gitArchive $RepoRoot

$observedCommit = (& git -C $RepoRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $observedCommit -ne $expectedCommitNormalized) {
    throw "Exact source commit mismatch: expected $expectedCommitNormalized, got $observedCommit"
}
& git -C $RepoRoot reset --mixed HEAD | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to rebuild the exact-candidate Git index.'
}
& git -C $RepoRoot config core.fileMode false
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to configure Windows Git file-mode semantics.'
}
& git -C $RepoRoot config core.longpaths true
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to configure Windows Git long-path semantics.'
}
$dirty = @(& git -C $RepoRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Staged exact-candidate source tree is dirty.'
}

$runnerArguments = @{
    RepoRoot = $RepoRoot
    OutputDir = $OutputDir
    Platform = $Platform
    ArtifactManifestPath = $artifactManifest
}
if ($SkipAutomatedTests) { $runnerArguments.SkipAutomatedTests = $true }
if ($SkipUiAutomation) { $runnerArguments.SkipUiAutomation = $true }

& $runner @runnerArguments
if ($LASTEXITCODE -ne 0) {
    throw "Certification rehearsal runner exited $LASTEXITCODE."
}

[ordered]@{
    schema = 'openburnbar.windows.exact-candidate-rehearsal-stage.v1'
    status = 'passed'
    physicalCertificationClaimed = $false
    sourceCommit = $observedCommit
    sourceArchiveSha256 = Get-Sha256 $sourceArchive
    gitMetadataArchiveSha256 = Get-Sha256 $gitArchive
    artifactSha256 = $observedArtifactSha
    artifactSigner = [string]$signature.SignerCertificate.Subject
    certificationRunnerSha256 = Get-Sha256 $runner
    platform = $Platform
    outputDir = $OutputDir
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 8
