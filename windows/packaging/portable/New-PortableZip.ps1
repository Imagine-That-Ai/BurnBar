#requires -Version 7.0
<#
.SYNOPSIS
    Stage and zip the OpenBurnBar portable (no-installer) distribution from a
    `dotnet publish` output folder, driven by portable-layout.json.

.DESCRIPTION
    Reproduces the direct-download portable channel from the master plan
    (MSIX + portable zip; winget + Chocolatey). Given a self-contained publish
    folder, this:
      1. reads portable-layout.json (the single source of truth for the layout),
      2. copies the included files (honouring exclude globs) into a staging tree
         rooted at <rootFolder>,
      3. writes the generated files (.portable marker, README.txt) and any repo
         extras (LICENSE, third-party notices),
      4. compresses the staging tree to OpenBurnBar-<version>-<arch>-portable.zip,
      5. emits a deterministic SHA256 sidecar the winget / Chocolatey manifests and
         the Ed25519-pinned update feed consume.

    Cross-platform: uses only PowerShell 7 built-ins (Compress-Archive,
    Get-FileHash), so it dry-runs on macOS/Linux CI and runs for real on Windows.

.PARAMETER PublishDir
    The `dotnet publish -r <rid> --self-contained true` output folder.

.PARAMETER Version
    Overrides the version in portable-layout.json (release pipeline supplies this).

.PARAMETER Arch
    x64 | arm64 | x86 — must be present in the layout's architectures list.

.PARAMETER OutputDir
    Where the .zip + .sha256 land. Defaults to ./dist.

.PARAMETER LayoutPath
    Path to portable-layout.json. Defaults to the file next to this script.

.EXAMPLE
    dotnet publish windows/app/OpenBurnBar.App -c Release -r win-x64 --self-contained true -o out/win-x64
    ./windows/packaging/portable/New-PortableZip.ps1 -PublishDir out/win-x64 -Arch x64 -Version 1.0.28
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $PublishDir,
    [Parameter(Mandatory = $true)] [ValidateSet('x64', 'arm64', 'x86')] [string] $Arch,
    [Parameter(Mandatory = $false)] [string] $Version,
    [Parameter(Mandatory = $false)] [string] $OutputDir = (Join-Path (Get-Location) 'dist'),
    [Parameter(Mandatory = $false)] [string] $LayoutPath = (Join-Path $PSScriptRoot 'portable-layout.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LayoutPath)) {
    throw "Layout manifest not found: $LayoutPath"
}
if (-not (Test-Path -LiteralPath $PublishDir)) {
    throw "Publish folder not found: $PublishDir"
}

$layout = Get-Content -LiteralPath $LayoutPath -Raw | ConvertFrom-Json

if (-not $Version) { $Version = $layout.version }
if ($layout.architectures.arch -notcontains $Arch) {
    throw "Arch '$Arch' is not declared in $LayoutPath (declared: $($layout.architectures.arch -join ', '))."
}

$artifactName = $layout.artifactNameTemplate.Replace('{version}', $Version).Replace('{arch}', $Arch)
$rootFolder = $layout.rootFolder
Write-Host "Staging $($layout.product) $Version ($Arch) -> $artifactName"

# ── Staging tree ─────────────────────────────────────────────────────────────
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("obb-portable-" + [System.Guid]::NewGuid().ToString('N'))
$root = Join-Path $staging $rootFolder
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    $publishFull = (Resolve-Path -LiteralPath $PublishDir).Path

    # exclude globs -> WildcardPattern list matched on the leaf name
    $excludePatterns = @()
    if ($layout.PSObject.Properties.Name -contains 'exclude' -and $layout.exclude) {
        $excludePatterns = $layout.exclude | ForEach-Object {
            [System.Management.Automation.WildcardPattern]::new($_, 'IgnoreCase')
        }
    }
    function Test-Excluded([string] $leaf) {
        foreach ($p in $excludePatterns) { if ($p.IsMatch($leaf)) { return $true } }
        return $false
    }

    # A self-contained publish IS the portable payload: ship every file except the
    # exclude globs (symbols / xml docs / crash dumper). The layout's `include` list
    # documents the expected shape; the copy is exclude-driven (matched on the leaf
    # name, so it is path-separator agnostic) so nothing ships broken.
    $copied = 0
    Get-ChildItem -LiteralPath $publishFull -Recurse -File | ForEach-Object {
        if (Test-Excluded $_.Name) { return }
        $rel = $_.FullName.Substring($publishFull.Length).TrimStart('\', '/')
        $dest = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        $copied++
    }
    Write-Host "  copied $copied file(s) from publish output (excludes applied)"

    $entry = Join-Path $root $layout.entryPoint
    if (-not (Test-Path -LiteralPath $entry)) {
        throw "Entry point '$($layout.entryPoint)' missing from staged output (is PublishDir a self-contained publish?)."
    }

    # Generated files (.portable marker, README.txt, ...).
    if ($layout.PSObject.Properties.Name -contains 'generatedFiles') {
        foreach ($g in $layout.generatedFiles) {
            $dest = Join-Path $root $g.path
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            Set-Content -LiteralPath $dest -Value $g.contents -NoNewline -Encoding utf8
            Write-Host "  wrote $($g.kind): $($g.path)"
        }
    }

    # Repo extras (LICENSE, third-party notices) resolved from the repo root.
    if ($layout.PSObject.Properties.Name -contains 'extraFilesFromRepo') {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..' '..')).Path
        foreach ($x in $layout.extraFilesFromRepo) {
            $src = Join-Path $repoRoot $x.from
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $root $x.to) -Force
                Write-Host "  bundled repo extra: $($x.from) -> $($x.to)"
            }
            elseif (-not $x.optional) {
                throw "Required repo extra not found: $($x.from)"
            }
        }
    }

    # ── Zip + checksum ───────────────────────────────────────────────────────
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $zipPath = Join-Path $OutputDir $artifactName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecarName = ($layout.checksumSidecarTemplate ?? "$artifactName.sha256").Replace('{version}', $Version).Replace('{arch}', $Arch)
    $sidecarPath = Join-Path $OutputDir $sidecarName
    $manifestLine = ($layout.checksum.manifestLine ?? '{sha256}  {artifactName}').Replace('{sha256}', $hash).Replace('{artifactName}', $artifactName)
    Set-Content -LiteralPath $sidecarPath -Value $manifestLine -Encoding ascii

    Write-Host ""
    Write-Host "Portable zip: $zipPath"
    Write-Host "SHA256      : $hash"
    Write-Host "Sidecar     : $sidecarPath"

    [pscustomobject]@{
        Artifact = $zipPath
        Sha256   = $hash
        Sidecar  = $sidecarPath
        Version  = $Version
        Arch     = $Arch
    }
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
