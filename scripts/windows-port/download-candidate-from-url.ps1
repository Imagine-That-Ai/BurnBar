<#
.SYNOPSIS
    Download a candidate export from an HTTP base URL with resumable curl.

.DESCRIPTION
    Intended for UTM/VM transfer where guest-agent file push is unreliable for
    large archives. Downloads the manifest and archive, resumes partial archive
    bytes across attempts, verifies SHA-256 values, and writes transfer JSON.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BaseUrl,
    [Parameter(Mandatory = $true)] [string] $OutputDir,
    [Parameter(Mandatory = $true)] [string] $ManifestName,
    [Parameter(Mandatory = $true)] [string] $ArchiveName,
    [Parameter(Mandatory = $true)] [string] $ExpectedManifestSha256,
    [Parameter(Mandatory = $true)] [string] $ExpectedArchiveSha256,
    [int] $Attempts = 8
)

$ErrorActionPreference = 'Stop'

function Get-Sha256([string] $Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Invoke-CurlDownload([string] $Url, [string] $OutFile, [switch] $Resume) {
    $args = @('-L', '--fail', '--silent', '--show-error')
    if ($Resume -and (Test-Path -LiteralPath $OutFile)) {
        $args += @('-C', '-')
    }
    $args += @('--output', $OutFile, $Url)
    & curl.exe @args
    return $LASTEXITCODE
}

function Write-Result([object] $Value) {
    $Value | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $OutputDir 'download-result.json')
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$base = $BaseUrl.TrimEnd('/')
$manifestPath = Join-Path $OutputDir $ManifestName
$archivePath = Join-Path $OutputDir $ArchiveName
$attemptLog = New-Object System.Collections.Generic.List[object]

$manifestCode = Invoke-CurlDownload -Url "$base/$ManifestName" -OutFile $manifestPath
$manifestHash = if (Test-Path -LiteralPath $manifestPath) { Get-Sha256 $manifestPath } else { '' }
if ($manifestCode -ne 0 -or $manifestHash -ne $ExpectedManifestSha256.ToLowerInvariant()) {
    Write-Result ([ordered]@{
        status = 'failed'
        phase = 'manifest'
        manifestExitCode = $manifestCode
        manifestSha256 = $manifestHash
        expectedManifestSha256 = $ExpectedManifestSha256
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    })
    throw "Manifest download/hash failed."
}

for ($i = 1; $i -le $Attempts; $i += 1) {
    $code = Invoke-CurlDownload -Url "$base/$ArchiveName" -OutFile $archivePath -Resume
    $length = if (Test-Path -LiteralPath $archivePath) { (Get-Item -LiteralPath $archivePath).Length } else { 0 }
    $hash = if ($code -eq 0 -and (Test-Path -LiteralPath $archivePath)) { Get-Sha256 $archivePath } else { '' }
    $attemptLog.Add([ordered]@{
        attempt = $i
        exitCode = $code
        length = $length
        sha256 = $hash
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    })
    if ($code -eq 0 -and $hash -eq $ExpectedArchiveSha256.ToLowerInvariant()) {
        Write-Result ([ordered]@{
            status = 'downloaded'
            manifestSha256 = $manifestHash
            archiveSha256 = $hash
            archiveLength = $length
            attempts = $attemptLog.ToArray()
            completedAt = (Get-Date).ToUniversalTime().ToString('o')
        })
        exit 0
    }
    Start-Sleep -Seconds ([Math]::Min(10, $i * 2))
}

$finalLength = if (Test-Path -LiteralPath $archivePath) { (Get-Item -LiteralPath $archivePath).Length } else { 0 }
$finalHash = if (Test-Path -LiteralPath $archivePath) { Get-Sha256 $archivePath } else { '' }
Write-Result ([ordered]@{
    status = 'failed'
    phase = 'archive'
    archiveSha256 = $finalHash
    expectedArchiveSha256 = $ExpectedArchiveSha256
    archiveLength = $finalLength
    attempts = $attemptLog.ToArray()
    completedAt = (Get-Date).ToUniversalTime().ToString('o')
})
throw "Archive download/hash failed after $Attempts attempt(s)."
