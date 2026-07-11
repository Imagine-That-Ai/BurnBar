<#
.SYNOPSIS
    Import and verify a deterministic OpenBurnBar candidate export.

.DESCRIPTION
    Expands the history-independent tar produced by export-candidate.mjs into a
    disposable destination and verifies the archive hash plus every tracked file
    hash from the manifest. This intentionally does not use Git history.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ArchivePath,
    [Parameter(Mandatory = $true)] [string] $ManifestPath,
    [Parameter(Mandatory = $true)] [string] $DestinationRoot,
    [switch] $CleanDestination,
    [switch] $VerifyOnly,
    [string] $VerificationOutputPath = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-SafeDestination([string] $Path) {
    $full = Resolve-FullPath $Path
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root) {
        throw "Refusing unsafe destination root: $Path"
    }
    if ($full.Length -lt 8) {
        throw "Refusing suspiciously short destination root: $full"
    }
    return $full
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-JsonFile([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Value | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

$archiveFull = Resolve-FullPath $ArchivePath
$manifestFull = Resolve-FullPath $ManifestPath
$destinationFull = Assert-SafeDestination $DestinationRoot

if (-not (Test-Path -LiteralPath $archiveFull)) { throw "Archive not found: $archiveFull" }
if (-not (Test-Path -LiteralPath $manifestFull)) { throw "Manifest not found: $manifestFull" }

$manifest = Get-Content -Raw -LiteralPath $manifestFull | ConvertFrom-Json
if ($manifest.schema -ne 'openburnbar.windows.candidate-export.v1') {
    throw "Unsupported candidate manifest schema: $($manifest.schema)"
}

if ($env:OS -eq 'Windows_NT') {
    $longest = $manifest.files |
        ForEach-Object {
            $relative = ([string]$_.path) -replace '/', [System.IO.Path]::DirectorySeparatorChar
            [pscustomobject]@{ path = [string]$_.path; length = (Join-Path $destinationFull $relative).Length }
        } |
        Sort-Object length -Descending |
        Select-Object -First 1
    if ($null -ne $longest -and $longest.length -ge 260) {
        throw "Destination path is too long for the Windows tar/import toolchain ($($longest.length) chars): $($longest.path). Choose a shorter DestinationRoot such as C:\obb\candidate."
    }
}

$actualArchiveHash = Get-Sha256 $archiveFull
if ($actualArchiveHash -ne $manifest.archive.sha256) {
    throw "Archive SHA-256 mismatch. expected=$($manifest.archive.sha256) actual=$actualArchiveHash"
}

if (-not $VerifyOnly) {
    $destinationParent = Split-Path -Parent $destinationFull
    if ([string]::IsNullOrWhiteSpace($destinationParent)) {
        throw "Destination parent could not be resolved for $destinationFull"
    }
    if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    }

    $extractRoot = Join-Path $destinationParent ('.candidate-extract-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

    try {
        & tar -xf $archiveFull -C $extractRoot
        if ($LASTEXITCODE -ne 0) {
            throw "tar extraction failed with exit code $LASTEXITCODE"
        }

        $prefix = [string]$manifest.archive.prefix
        if ($prefix.EndsWith('/')) {
            $prefix = $prefix.Substring(0, $prefix.Length - 1)
        }
        $extractedRoot = Join-Path $extractRoot ($prefix -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $extractedRoot)) {
            throw "Archive did not contain expected prefix root: $($manifest.archive.prefix)"
        }

        if ((Test-Path -LiteralPath $destinationFull) -and $CleanDestination) {
            Remove-Item -LiteralPath $destinationFull -Recurse -Force
        } elseif (Test-Path -LiteralPath $destinationFull) {
            throw "Destination already exists. Pass -CleanDestination for a disposable validation checkout: $destinationFull"
        }

        Move-Item -LiteralPath $extractedRoot -Destination $destinationFull
    }
    finally {
        if (Test-Path -LiteralPath $extractRoot) {
            try {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not remove temporary extract root ${extractRoot}: $($_.Exception.Message)"
            }
        }
    }
} elseif (-not (Test-Path -LiteralPath $destinationFull -PathType Container)) {
    throw "VerifyOnly destination does not exist: $destinationFull"
}

$mismatches = New-Object System.Collections.Generic.List[object]
$checked = 0
foreach ($file in $manifest.files) {
    $relative = ([string]$file.path) -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $path = Join-Path $destinationFull $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $mismatches.Add([ordered]@{ path = $file.path; kind = 'missing' })
        continue
    }
    $item = Get-Item -LiteralPath $path
    $actualHash = Get-Sha256 $path
    if ($actualHash -ne $file.sha256 -or $item.Length -ne [int64]$file.size) {
        $mismatches.Add([ordered]@{
            path = $file.path
            kind = 'hash-or-size'
            expectedSha256 = $file.sha256
            actualSha256 = $actualHash
            expectedSize = [int64]$file.size
            actualSize = $item.Length
        })
    }
    $checked += 1
}

$result = [ordered]@{
    schema = 'openburnbar.windows.candidate-import-verification.v1'
    verifiedAt = (Get-Date).ToUniversalTime().ToString('o')
    destinationRoot = $destinationFull
    manifestPath = $manifestFull
    manifestSha256 = Get-Sha256 $manifestFull
    archivePath = $archiveFull
    archiveSha256 = $actualArchiveHash
    source = $manifest.source
    checkedFiles = $checked
    expectedFiles = $manifest.files.Count
    mismatches = $mismatches.ToArray()
    status = if ($mismatches.Count -eq 0) { 'passed' } else { 'failed' }
}

if ([string]::IsNullOrWhiteSpace($VerificationOutputPath)) {
    $VerificationOutputPath = Join-Path $destinationFull 'candidate-import-verification.json'
}
Write-JsonFile $VerificationOutputPath $result

if ($mismatches.Count -ne 0) {
    throw "Candidate verification failed with $($mismatches.Count) mismatch(es). See $VerificationOutputPath"
}

Write-Host "Candidate import verified: $($manifest.source.commit) -> $destinationFull ($checked files)" -ForegroundColor Green
