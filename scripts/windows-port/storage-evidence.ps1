<#
.SYNOPSIS
    Produce Windows-host evidence for encrypted storage provisioning and recovery.

.DESCRIPTION
    Run inside a Windows 11 x64 or ARM64 checkout. The script executes the app
    storage provisioning/recovery suite and the SQLCipher fixture/golden suite,
    writes host metadata, preserves per-case migration journals/recovery logs via
    OPENBURNBAR_STORAGE_EVIDENCE_DIR, and exits non-zero when any check fails.

.PARAMETER RepoRoot
    Path to the BurnBar checkout inside Windows.

.PARAMETER OutputDir
    Evidence output directory. Defaults to docs/windows-port/evidence/storage/<timestamp>.

.EXAMPLE
    pwsh scripts/windows-port/storage-evidence.ps1 -RepoRoot C:\src\BurnBar
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [string] $OutputDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $RepoRoot "docs\windows-port\evidence\storage\$stamp"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$env:OPENBURNBAR_STORAGE_EVIDENCE_DIR = $OutputDir

$forbiddenCredentialEnv = @('OPENBURNBAR_SQLCIPHER_PATH', 'OPENBURNBAR_SQLCIPHER_PASSPHRASE')
foreach ($name in $forbiddenCredentialEnv) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Release storage evidence refuses plaintext credential environment variable $name. Use protected storage composition."
    }
}

$hostInfo = [ordered]@{
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    computerName = $env:COMPUTERNAME
    processorArchitecture = $env:PROCESSOR_ARCHITECTURE
    os = (Get-CimInstance Win32_OperatingSystem | Select-Object -First 1 | ForEach-Object { "$($_.Caption) $($_.Version)" })
    repoRoot = $RepoRoot
    outputDir = $OutputDir
    dotnet = (& dotnet --version)
}
$hostInfo | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'host.json')

function Invoke-Step([string] $Name, [string[]] $Arguments) {
    $log = Join-Path $OutputDir ($Name + '.log')
    Push-Location $RepoRoot
    try {
        & dotnet @Arguments *> $log
        $exitCode = $LASTEXITCODE
        [ordered]@{
            name = $Name
            command = 'dotnet ' + ($Arguments -join ' ')
            exitCode = $exitCode
            log = $log
            completedAt = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $OutputDir ($Name + '.json'))

        if ($exitCode -ne 0) {
            throw "$Name failed with exit code $exitCode. See $log"
        }
    }
    finally {
        Pop-Location
    }
}

Invoke-Step 'app-storage-provisioning-recovery' @(
    'test',
    'windows\tests\storage\OpenBurnBar.App.Storage.Tests.csproj',
    '--logger',
    'trx;LogFileName=app-storage.trx'
)

Invoke-Step 'sqlcipher-fixture-golden' @(
    'test',
    'windows\storage\OpenBurnBar.Storage.Tests\OpenBurnBar.Storage.Tests.csproj',
    '--logger',
    'trx;LogFileName=sqlcipher-fixture.trx'
)

$cases = Get-ChildItem -Path $OutputDir -Directory | Select-Object -ExpandProperty Name
[ordered]@{
    status = 'passed'
    evidenceCases = $cases
    forbiddenCredentialEnv = $forbiddenCredentialEnv
    credentialPolicy = 'SQLCipher path/passphrase must come from protected configuration or generated protected storage, not environment variables.'
    requiredCases = @(
        'fresh-install',
        'restart-idempotency',
        'generated-db-write-seams',
        'wrong-key-recovery',
        'corrupt-archive-reset',
        'fault-LockedFile',
        'fault-FullDisk',
        'fault-AccessDenied',
        'interrupted-retry',
        'unsupported-schema-recovery'
    )
} | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'storage-evidence-summary.json')

Write-Host "Storage evidence written to $OutputDir" -ForegroundColor Green
