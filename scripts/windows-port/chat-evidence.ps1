<#
.SYNOPSIS
    Produce Windows-host evidence for shell-free bounded chat and durable history.

.DESCRIPTION
    Run inside a Windows 11 x64 or ARM64 checkout. The script executes focused
    chat/runtime/storage/presentation checks, records host metadata, and writes
    an evidence summary. UIA process-table traces and ORACLE-CHAT-001
    differential artifacts must be attached by the Windows host runner before
    any parity ledger promotion.

.PARAMETER RepoRoot
    Path to the BurnBar checkout inside Windows.

.PARAMETER OutputDir
    Evidence output directory. Defaults to docs/windows-port/evidence/chat/<timestamp>.

.EXAMPLE
    pwsh scripts/windows-port/chat-evidence.ps1 -RepoRoot C:\src\BurnBar
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [string] $OutputDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $RepoRoot "docs\windows-port\evidence\chat\$stamp"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$env:OPENBURNBAR_CHAT_EVIDENCE_DIR = $OutputDir

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

Invoke-Step 'chat-runtime' @(
    'test',
    'windows\tests\chat\OpenBurnBar.App.Chat.Runtime.Tests.csproj',
    '--no-restore',
    '--nologo',
    '--logger',
    'trx;LogFileName=chat-runtime.trx'
)

Invoke-Step 'chat-storage' @(
    'test',
    'windows\tests\storage\OpenBurnBar.App.Storage.Tests.csproj',
    '--no-restore',
    '--nologo',
    '--logger',
    'trx;LogFileName=chat-storage.trx'
)

Invoke-Step 'chat-presentation' @(
    'test',
    'windows\tests\presentation\OpenBurnBar.App.Presentation.Tests.csproj',
    '--no-restore',
    '--nologo',
    '--filter',
    'FullyQualifiedName~Chat',
    '--logger',
    'trx;LogFileName=chat-presentation.trx'
)

$requiredHostArtifacts = @(
    'process-traces/image-argument-vector.json',
    'process-traces/metacharacters-quotes-unicode-newlines-long-payload.json',
    'process-traces/path-substitution-denial.json',
    'process-traces/executable-replacement-denial.json',
    'process-traces/infinite-output-byte-counts.json',
    'process-traces/blocked-stderr-concurrent-drain.json',
    'process-traces/grandchildren-cancellation-process-table.json',
    'ui/oracle-chat-001-differential.json',
    'ui/restart-rehydration-uia.json',
    'ui/attachment-paste-drop-uia.json',
    'storage/encrypted-byte-scan.json'
)

[ordered]@{
    status = 'focused-tests-passed'
    outputDir = $OutputDir
    budgets = [ordered]@{
        maxCombinedOutputBytes = 33554432
        maxLogicalRecordBytes = 1048576
        cancellationTreeAbsentMaxSeconds = 3
    }
    requiredHostArtifacts = $requiredHostArtifacts
    note = 'Attach the requiredHostArtifacts from Windows UIA/process-trace runners before target promotion.'
} | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'chat-evidence-summary.json')

Write-Host "Chat evidence written to $OutputDir" -ForegroundColor Green
Write-Host "Attach process-table/UIA/ORACLE-CHAT-001 artifacts listed in chat-evidence-summary.json before promotion." -ForegroundColor Yellow
