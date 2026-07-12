<#
.SYNOPSIS
    Run current-candidate Windows foundation evidence from a verified export.

.DESCRIPTION
    This script is meant to run inside a Windows x64/ARM64 host after
    import-candidate.ps1 has verified the history-independent export. It records
    host identity, candidate provenance, restore/build/test commands, storage
    and chat evidence-script output, protected-inventory metadata, and a canary
    artifact scan summary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [Parameter(Mandatory = $true)] [string] $ManifestPath,
    [string] $OutputDir = '',
    [ValidateSet('', 'x64', 'ARM64', 'x86')] [string] $Platform = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } catch {
        $parent = Split-Path -Parent $Path
        $leaf = Split-Path -Leaf $Path
        if ([string]::IsNullOrWhiteSpace($parent)) {
            return [System.IO.Path]::GetFullPath($Path)
        }
        $resolvedParent = Resolve-FullPath $parent
        return Join-Path $resolvedParent $leaf
    }
}

function New-StepResult([string] $Name, [string] $Command, [int] $ExitCode, [string] $LogPath) {
    [ordered]@{
        name = $Name
        command = $Command
        exitCode = $ExitCode
        log = $LogPath
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Write-JsonFile([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Value | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Invoke-LoggedProcess([string] $Name, [string] $File, [string[]] $Arguments) {
    $log = Join-Path $OutputDir ($Name + '.log')
    Push-Location $RepoRoot
    try {
        & $File @Arguments *> $log
        $exitCode = $LASTEXITCODE
        $command = $File + ' ' + ($Arguments -join ' ')
        $result = New-StepResult $Name $command $exitCode $log
        Write-JsonFile (Join-Path $OutputDir ($Name + '.json')) $result
        if ($exitCode -ne 0) {
            throw "$Name failed with exit code $exitCode. See $log"
        }
        return $result
    }
    finally {
        Pop-Location
    }
}

function Resolve-Platform {
    try {
        $os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
        if ($os.OSArchitecture -match 'ARM') { 'ARM64'; return }
        if ($os.OSArchitecture -match '64') { 'x64'; return }
        if ($os.OSArchitecture -match '32' -or $os.OSArchitecture -match 'x86') { 'x86'; return }
    }
    catch {
        # Fall back to the process environment below.
    }

    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'ARM64'; break }
        'AMD64' { 'x64'; break }
        'x86' { 'x86'; break }
        default { 'x64' }
    }
}

function Resolve-PowerShellHost {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return 'powershell.exe'
}

function Test-ArtifactSecretLeaks([string] $Root, [string[]] $Canaries) {
    $findings = New-Object System.Collections.Generic.List[object]
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if ($file.Length -gt 10MB) { continue }
        $text = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        if ($null -eq $text) { continue }
        foreach ($canary in $Canaries) {
            if ($text.IndexOf($canary, [StringComparison]::Ordinal) -ge 0) {
                $findings.Add([ordered]@{
                    path = $file.FullName
                    kind = 'exact-canary'
                    canary = $canary
                })
            }
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($canary))
            if ($text.IndexOf($encoded, [StringComparison]::Ordinal) -ge 0) {
                $findings.Add([ordered]@{
                    path = $file.FullName
                    kind = 'base64-canary'
                    canary = $canary
                })
            }
        }
    }
    return $findings
}

$RepoRoot = Resolve-FullPath $RepoRoot
$ManifestPath = Resolve-FullPath $ManifestPath
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'windows\OpenBurnBar.sln'))) {
    throw "RepoRoot does not contain windows\OpenBurnBar.sln: $RepoRoot"
}
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}
if ([string]::IsNullOrWhiteSpace($Platform)) {
    $Platform = Resolve-Platform
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $RepoRoot "docs\windows-port\evidence\foundation-current-candidate\$stamp-$Platform"
}
$OutputDir = Resolve-FullPath $OutputDir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
$candidateVerificationPath = Join-Path $OutputDir 'candidate-tree-verification.json'
& (Join-Path $RepoRoot 'scripts\windows-port\import-candidate.ps1') `
    -ArchivePath (Join-Path (Split-Path -Parent $ManifestPath) $manifest.archive.fileName) `
    -ManifestPath $ManifestPath `
    -DestinationRoot $RepoRoot `
    -VerifyOnly `
    -VerificationOutputPath $candidateVerificationPath

$forbiddenEnv = @(
    'OPENBURNBAR_SQLCIPHER_PATH',
    'OPENBURNBAR_SQLCIPHER_PASSPHRASE',
    'OPENBURNBAR_CHAT_APPROVED_EXECUTABLES'
)
foreach ($name in $forbiddenEnv) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Refusing evidence run with forbidden developer credential/catalog environment variable: $name"
    }
}

$os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
$computer = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
$hostInfo = [ordered]@{
    schema = 'openburnbar.windows.foundation-host.v1'
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    computerName = $env:COMPUTERNAME
    osCaption = $os.Caption
    osVersion = $os.Version
    osArchitecture = $os.OSArchitecture
    manufacturer = $computer.Manufacturer
    model = $computer.Model
    processorArchitecture = $env:PROCESSOR_ARCHITECTURE
    processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    platform = $Platform
    repoRoot = $RepoRoot
    outputDir = $OutputDir
    dotnet = (& dotnet --version)
    candidate = $manifest.source
}
try {
    $tpm = Get-Tpm -ErrorAction Stop
    $hostInfo['tpm'] = [ordered]@{ present = $tpm.TpmPresent; ready = $tpm.TpmReady; managedAuthLevel = [string]$tpm.ManagedAuthLevel }
} catch {
    $hostInfo['tpm'] = [ordered]@{ present = $false; error = $_.Exception.Message }
}
Write-JsonFile (Join-Path $OutputDir 'host-identity.json') $hostInfo

$steps = New-Object System.Collections.Generic.List[object]
$solution = 'windows\OpenBurnBar.sln'
$powerShellHost = Resolve-PowerShellHost
$steps.Add((Invoke-LoggedProcess 'dotnet-restore' 'dotnet' @('restore', $solution, "-p:Platform=$Platform")))
$steps.Add((Invoke-LoggedProcess 'dotnet-build' 'dotnet' @('build', $solution, '--configuration', 'Debug', '--no-restore', "-p:Platform=$Platform")))
$steps.Add((Invoke-LoggedProcess 'configuration-tests' 'dotnet' @('test', 'windows\tests\configuration\OpenBurnBar.App.Configuration.Tests.csproj', '--configuration', 'Debug', '--no-build', '--nologo', '--logger', 'trx;LogFileName=configuration.trx')))
$steps.Add((Invoke-LoggedProcess 'chat-runtime-tests' 'dotnet' @('test', 'windows\tests\chat\OpenBurnBar.App.Chat.Runtime.Tests.csproj', '--configuration', 'Debug', '--no-build', '--nologo', '--logger', 'trx;LogFileName=chat-runtime.trx')))
$steps.Add((Invoke-LoggedProcess 'storage-tests' 'dotnet' @('test', 'windows\tests\storage\OpenBurnBar.App.Storage.Tests.csproj', '--configuration', 'Debug', '--no-build', '--nologo', '--logger', 'trx;LogFileName=storage.trx')))
$steps.Add((Invoke-LoggedProcess 'sqlcipher-storage-tests' 'dotnet' @('test', 'windows\storage\OpenBurnBar.Storage.Tests\OpenBurnBar.Storage.Tests.csproj', '--configuration', 'Debug', '--no-build', '--nologo', '--logger', 'trx;LogFileName=sqlcipher-storage.trx')))
$steps.Add((Invoke-LoggedProcess 'chat-presentation-tests' 'dotnet' @('test', 'windows\tests\presentation\OpenBurnBar.App.Presentation.Tests.csproj', '--configuration', 'Debug', '--no-build', '--nologo', '--filter', 'FullyQualifiedName~Chat', '--logger', 'trx;LogFileName=chat-presentation.trx')))

$storageDir = Join-Path $OutputDir 'storage-evidence'
$chatDir = Join-Path $OutputDir 'chat-evidence'
$steps.Add((Invoke-LoggedProcess 'storage-evidence' $powerShellHost @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\windows-port\storage-evidence.ps1', '-RepoRoot', $RepoRoot, '-OutputDir', $storageDir)))
$steps.Add((Invoke-LoggedProcess 'chat-evidence' $powerShellHost @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\windows-port\chat-evidence.ps1', '-RepoRoot', $RepoRoot, '-OutputDir', $chatDir)))

$protectedRoot = Join-Path $env:LOCALAPPDATA 'OpenBurnBar\protected-secrets'
$protectedInventory = @()
if (Test-Path -LiteralPath $protectedRoot) {
    $protectedInventory = Get-ChildItem -LiteralPath $protectedRoot -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            [ordered]@{
                name = $_.Name
                length = $_.Length
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
                lastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            }
        }
}
Write-JsonFile (Join-Path $OutputDir 'protected-inventory-metadata.json') ([ordered]@{
    root = $protectedRoot
    files = $protectedInventory
    note = 'Metadata only; secret plaintext is never emitted.'
})

$canaries = @(
    'DIAGNOSTIC_CANARY_SECRET_openburnbar_20260709',
    'OPENBURNBAR_SQLCIPHER_PASSPHRASE_CANARY'
)
$leaks = Test-ArtifactSecretLeaks $OutputDir $canaries
Write-JsonFile (Join-Path $OutputDir 'artifact-secret-scan.json') ([ordered]@{
    scannedAt = (Get-Date).ToUniversalTime().ToString('o')
    root = $OutputDir
    canaryCount = $canaries.Count
    findings = $leaks
    status = if ($leaks.Count -eq 0) { 'passed' } else { 'failed' }
})
if ($leaks.Count -ne 0) {
    throw "Artifact secret scan found $($leaks.Count) canary leak(s)."
}

Write-JsonFile (Join-Path $OutputDir 'evidence-summary.json') ([ordered]@{
    schema = 'openburnbar.windows.foundation-current-candidate-evidence.v1'
    status = 'passed'
    completedAt = (Get-Date).ToUniversalTime().ToString('o')
    candidate = $manifest.source
    host = [ordered]@{
        computerName = $env:COMPUTERNAME
        osCaption = $os.Caption
        osVersion = $os.Version
        processorArchitecture = $env:PROCESSOR_ARCHITECTURE
        platform = $Platform
    }
    candidateVerification = $candidateVerificationPath
    steps = $steps
    requiredExternalArtifacts = @(
        'Windows UIA screenshots/trees for chat setup, approval, rotate/remove, denial, storage unavailable, retry/restart, durable rehydrate',
        'Process image/path/ArgumentList traces for approved and denied chat launches',
        'Native x64 hosted-runner artifact bundle when this script is not itself run on x64'
    )
})

Write-Host "Current-candidate Windows evidence written to $OutputDir" -ForegroundColor Green
