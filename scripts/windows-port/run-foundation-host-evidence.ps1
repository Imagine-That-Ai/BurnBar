<#
.SYNOPSIS
    Run Windows foundation host evidence against an exact imported candidate.

.DESCRIPTION
    This runner is intentionally production-adjacent and replayable. It verifies
    the candidate manifest, runs the existing focused foundation evidence, runs
    a process-launch evidence tool that uses the reviewed child-process policy,
    launches UIA collection into the active console user's desktop, scans every
    artifact for synthetic canary leaks, and emits a fail-closed manifest.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [Parameter(Mandatory = $true)] [string] $ManifestPath,
    [string] $OutputDir = '',
    [string] $ExpectedCandidate = '',
    [string] $VmUuid = '',
    [ValidateSet('', 'x64', 'ARM64', 'x86')] [string] $Platform = '',
    [switch] $SkipFocusedEvidence
)

$ErrorActionPreference = 'Stop'

$RequiredScenarioIds = @(
    'chat.executable.setup',
    'chat.executable.approve',
    'chat.executable.rotate',
    'chat.executable.remove',
    'chat.executable.denial.missing',
    'chat.executable.denial.replaced',
    'chat.executable.denial.unapproved',
    'chat.history.unavailable',
    'chat.history.corrupt',
    'chat.history.locked',
    'chat.history.retry',
    'chat.restart.process',
    'chat.restart.durable-rehydrate',
    'chat.attachment.file',
    'chat.attachment.paste',
    'chat.attachment.drop',
    'chat.attachment.missing',
    'chat.retrieval.degraded',
    'storage.fresh-install',
    'storage.restart-idempotency',
    'storage.generated-db-write-seams',
    'storage.wrong-key',
    'storage.corrupt-database',
    'storage.locked-file',
    'storage.interrupted-migration',
    'storage.unsupported-schema',
    'storage.full-disk',
    'storage.access-denied',
    'storage.archive-reset',
    'storage.retry',
    'storage.reveal-redacted-log',
    'process.environment.chat-scrubbed',
    'process.metacharacters',
    'process.quotes',
    'process.unicode',
    'process.newlines',
    'process.long-input',
    'process.blocked-stderr',
    'process.infinite-output',
    'process.grandchildren',
    'process.cancellation',
    'process.timeout',
    'process.malformed-output',
    'process.nonzero-exit',
    'process.unapproved-denial',
    'process.replaced-denial',
    'process.missing-denial',
    'process.unavailable-backend',
    'diagnostics.config',
    'diagnostics.log',
    'diagnostics.support-bundle',
    'diagnostics.screenshot',
    'diagnostics.secret-scan'
)

$CanarySecrets = @(
    'alpha-synthetic-secret-value-20260710',
    'beta-synthetic-secret-value-20260710',
    'gamma-synthetic-secret-value-20260710'
)

function Resolve-FullPath([string] $Path) {
    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } catch {
        return [System.IO.Path]::GetFullPath($Path)
    }
}

function Write-JsonFile([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Value | ConvertTo-Json -Depth 64 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-StringSha256([string] $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-RelativeArtifactPath([string] $Root, [string] $Path) {
    $rootFull = (Resolve-FullPath $Root).TrimEnd('\', '/')
    $pathFull = Resolve-FullPath $Path
    if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
    }
    return (Split-Path -Leaf $pathFull)
}

function New-StepResult([string] $Name, [string] $Command, [int] $ExitCode, [string] $LogPath, [datetimeoffset] $StartedAt) {
    [ordered]@{
        name = $Name
        command = $Command
        exitCode = $ExitCode
        log = $LogPath
        startedAtUtc = $StartedAt.ToUniversalTime().ToString('o')
        completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-LoggedProcess([string] $Name, [string] $File, [string[]] $Arguments, [string] $WorkingDirectory = $RepoRoot) {
    $log = Join-Path $OutputDir ($Name + '.log')
    $started = [datetimeoffset]::UtcNow
    Push-Location $WorkingDirectory
    try {
        & $File @Arguments *> $log
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        $command = $File + ' ' + ($Arguments -join ' ')
        $result = New-StepResult $Name $command $exitCode $log $started
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
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return 'ARM64' }
        'AMD64' { return 'x64' }
        'x86' { return 'x86' }
        default { return 'x64' }
    }
}

function Resolve-PowerShell {
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $winPs -PathType Leaf) {
        return $winPs
    }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return 'powershell.exe'
}

function Resolve-AppExe {
    $matches = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'windows\app\OpenBurnBar.App\bin') -Filter 'OpenBurnBar.App.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if ($matches.Count -eq 0) {
        throw 'OpenBurnBar.App.exe not found after build.'
    }
    return $matches[0].FullName
}

function Add-InteractiveLauncherType {
    if ('OpenBurnBar.FoundationEvidence.InteractiveLauncher' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace OpenBurnBar.FoundationEvidence
{
    public static class InteractiveLauncher
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll")]
        public static extern uint WTSGetActiveConsoleSessionId();

        [DllImport("wtsapi32.dll", SetLastError = true)]
        private static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateTokenEx(
            IntPtr existingToken,
            uint desiredAccess,
            IntPtr tokenAttributes,
            int impersonationLevel,
            int tokenType,
            out IntPtr newToken);

        [DllImport("userenv.dll", SetLastError = true)]
        private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);

        [DllImport("userenv.dll", SetLastError = true)]
        private static extern bool DestroyEnvironmentBlock(IntPtr environment);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessAsUser(
            IntPtr token,
            string applicationName,
            string commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static int Launch(uint sessionId, string application, string arguments, string workingDirectory)
        {
            if (sessionId == 0 || sessionId == 0xFFFFFFFF)
            {
                throw new InvalidOperationException("Active console session is not an interactive user session: " + sessionId);
            }

            IntPtr userToken;
            if (!WTSQueryUserToken(sessionId, out userToken))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSQueryUserToken failed");
            }

            IntPtr primaryToken = IntPtr.Zero;
            IntPtr environment = IntPtr.Zero;
            try
            {
                const uint TOKEN_ALL_ACCESS = 0x000F01FF;
                if (!DuplicateTokenEx(userToken, TOKEN_ALL_ACCESS, IntPtr.Zero, 2, 1, out primaryToken))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateTokenEx failed");
                }
                if (!CreateEnvironmentBlock(out environment, primaryToken, false))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateEnvironmentBlock failed");
                }

                var startup = new STARTUPINFO();
                startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                startup.lpDesktop = "winsta0\\default";
                string commandLine = Quote(application) + " " + arguments;
                PROCESS_INFORMATION processInfo;
                const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
                const uint CREATE_NEW_CONSOLE = 0x00000010;
                if (!CreateProcessAsUser(
                    primaryToken,
                    application,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    false,
                    CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_CONSOLE,
                    environment,
                    workingDirectory,
                    ref startup,
                    out processInfo))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser failed");
                }

                CloseHandle(processInfo.hThread);
                CloseHandle(processInfo.hProcess);
                return processInfo.dwProcessId;
            }
            finally
            {
                if (environment != IntPtr.Zero) DestroyEnvironmentBlock(environment);
                if (primaryToken != IntPtr.Zero) CloseHandle(primaryToken);
                CloseHandle(userToken);
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
'@
}

function Start-InteractiveCollector([string] $CollectorScript, [string] $CollectorOutputDir, [string] $AppExe) {
    Add-InteractiveLauncherType
    $activeSession = [OpenBurnBar.FoundationEvidence.InteractiveLauncher]::WTSGetActiveConsoleSessionId()
    if ($activeSession -eq 0 -or $activeSession -eq 0xFFFFFFFF) {
        throw "Refusing UIA collection: active console session is not interactive ($activeSession)."
    }
    $ps = Resolve-PowerShell
    $args = @(
        '-NoProfile',
        '-Sta',
        '-ExecutionPolicy', 'Bypass',
        '-File', $CollectorScript,
        '-RepoRoot', $RepoRoot,
        '-OutputDir', $CollectorOutputDir,
        '-AppExe', $AppExe
    )
    $escaped = ($args | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $pid = [OpenBurnBar.FoundationEvidence.InteractiveLauncher]::Launch([uint32]$activeSession, $ps, $escaped, $RepoRoot)
    return [ordered]@{
        method = 'WTSQueryUserToken/CreateProcessAsUser'
        activeConsoleSessionId = [int]$activeSession
        processId = $pid
        powershell = $ps
    }
}

function Wait-ForJson([string] $Path, [int] $TimeoutSeconds = 240) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for $Path"
}

function New-RedactedDiagnostics([string] $Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $redacted = '[REDACTED]'
    $hashes = @($CanarySecrets | ForEach-Object { Get-StringSha256 $_ })
    Write-JsonFile (Join-Path $Dir 'config-diagnostic.json') ([ordered]@{
        schema = 'openburnbar.windows.foundation-diagnostic-canary.v1'
        channel = 'config'
        apiKey = $redacted
        passphrase = $redacted
        canarySha256 = $hashes
    })
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $Dir 'application.log') -Value "configuration failed for apiKey=$redacted correlation=openburnbar-foundation"
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $Dir 'support-bundle.txt') -Value "support bundle token=$redacted passphrase=$redacted"
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $Dir 'screenshot-ocr.txt') -Value "screenshot text contains token=$redacted"
}

function Test-SecretLeaks([string] $Root) {
    $findings = New-Object System.Collections.Generic.List[object]
    $structured = [regex]'(?i)\b(api[_-]?key|app[_-]?check|auth|credential|firebase[_-]?id[_-]?token|id[_-]?token|passphrase|password|refresh[_-]?token|secret|token|vault[_-]?key)\b\s*[:=]\s*("?)([^"'',;}\]\s]{8,})\2'
    $highEntropy = [regex]'\b[A-Za-z0-9_+/=-]{40,}\b'
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if ($file.Length -gt 25MB) { continue }
        $text = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        if ($null -eq $text) { continue }
        foreach ($canary in $CanarySecrets) {
            if ($text.Contains($canary)) {
                $findings.Add([ordered]@{ path = $file.FullName; kind = 'exact-canary' })
            }
            $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($canary))
            if ($text.Contains($base64)) {
                $findings.Add([ordered]@{ path = $file.FullName; kind = 'base64-canary' })
            }
            $encoded = [System.Uri]::EscapeDataString($canary)
            if ($text.Contains($encoded)) {
                $findings.Add([ordered]@{ path = $file.FullName; kind = 'url-encoded-canary' })
            }
            if ($canary.Length -gt 20) {
                $middle = $canary.Substring(6, 14)
                if ($text.Contains($middle)) {
                    $findings.Add([ordered]@{ path = $file.FullName; kind = 'substring-canary' })
                }
            }
        }
        foreach ($match in $structured.Matches($text)) {
            $value = $match.Groups[3].Value
            if ($value -notmatch '(?i)REDACTED|redacted|placeholder|openburnbar-foundation') {
                $findings.Add([ordered]@{ path = $file.FullName; kind = 'structured-field'; valueLength = $value.Length })
            }
        }
        foreach ($match in $highEntropy.Matches($text)) {
            $value = $match.Value
            if ($value -notmatch '(?i)REDACTED' -and (Measure-Entropy $value) -ge 4.2) {
                $findings.Add([ordered]@{ path = $file.FullName; kind = 'high-entropy'; valueLength = $value.Length })
            }
        }
    }
    return $findings
}

function Measure-Entropy([string] $Value) {
    if ([string]::IsNullOrEmpty($Value)) { return 0.0 }
    $counts = @{}
    foreach ($ch in $Value.ToCharArray()) {
        $key = [string]$ch
        if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
        $counts[$key] += 1
    }
    $entropy = 0.0
    foreach ($count in $counts.Values) {
        $p = [double]$count / [double]$Value.Length
        $entropy -= $p * ([Math]::Log($p) / [Math]::Log(2))
    }
    return $entropy
}

function New-ArtifactRef([string] $Path, [string] $Scenario, [string] $Kind) {
    $item = Get-Item -LiteralPath $Path
    [ordered]@{
        scenario = $Scenario
        kind = $Kind
        path = $item.FullName
        relativePath = Get-RelativeArtifactPath $OutputDir $item.FullName
        sha256 = Get-Sha256 $item.FullName
        size = $item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function Find-FirstArtifact([string[]] $Candidates) {
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

$RepoRoot = Resolve-FullPath $RepoRoot
$ManifestPath = Resolve-FullPath $ManifestPath
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot ('docs\windows-port\evidence\foundation-host\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$OutputDir = Resolve-FullPath $OutputDir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if ([string]::IsNullOrWhiteSpace($Platform)) {
    $Platform = Resolve-Platform
}
if ([string]::IsNullOrWhiteSpace($VmUuid)) {
    throw 'VmUuid is required as the host identity seed.'
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'openburnbar.windows.candidate-export.v1') {
    throw "Unsupported candidate manifest schema: $($manifest.schema)"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedCandidate) -and $manifest.source.commit -ne $ExpectedCandidate) {
    throw "Stale candidate manifest. expected=$ExpectedCandidate actual=$($manifest.source.commit)"
}

$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$steps = New-Object System.Collections.Generic.List[object]
$scenarioRows = New-Object System.Collections.Generic.List[object]
$artifactRefs = New-Object System.Collections.Generic.List[object]

$candidateVerification = Join-Path $OutputDir 'candidate-tree-verification.json'
& (Join-Path $RepoRoot 'scripts\windows-port\import-candidate.ps1') `
    -ArchivePath (Join-Path (Split-Path -Parent $ManifestPath) $manifest.archive.fileName) `
    -ManifestPath $ManifestPath `
    -DestinationRoot $RepoRoot `
    -VerifyOnly `
    -VerificationOutputPath $candidateVerification
if ($LASTEXITCODE -ne 0) {
    throw "Candidate verification failed."
}
$artifactRefs.Add((New-ArtifactRef $candidateVerification 'candidate.verify' 'candidate-import-verification'))

$forbiddenEnv = @('OPENBURNBAR_SQLCIPHER_PATH', 'OPENBURNBAR_SQLCIPHER_PASSPHRASE', 'OPENBURNBAR_CHAT_APPROVED_EXECUTABLES')
foreach ($name in $forbiddenEnv) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Refusing evidence run with forbidden environment variable: $name"
    }
}

$os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
$computer = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
$hostIdentity = [ordered]@{
    schema = 'openburnbar.windows.foundation-host-identity.v1'
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    vmIdentitySha256 = Get-StringSha256 $VmUuid
    computerIdentitySha256 = Get-StringSha256 $env:COMPUTERNAME
    osCaption = $os.Caption
    osVersion = $os.Version
    osArchitecture = $os.OSArchitecture
    manufacturer = $computer.Manufacturer
    model = $computer.Model
    currentIdentitySha256 = Get-StringSha256 ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    activeConsoleSessionId = $null
    processorArchitecture = $env:PROCESSOR_ARCHITECTURE
    processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    platform = $Platform
    dotnet = (& dotnet --version)
    candidate = $manifest.source
}
try {
    Add-InteractiveLauncherType
    $hostIdentity.activeConsoleSessionId = [int][OpenBurnBar.FoundationEvidence.InteractiveLauncher]::WTSGetActiveConsoleSessionId()
} catch {
    $hostIdentity.activeConsoleSessionIdError = $_.Exception.Message
}
$hostIdentityPath = Join-Path $OutputDir 'host-identity.json'
Write-JsonFile $hostIdentityPath $hostIdentity
$artifactRefs.Add((New-ArtifactRef $hostIdentityPath 'host.identity' 'host-identity'))

if (-not $SkipFocusedEvidence) {
    $focusedDir = Join-Path $OutputDir 'focused-foundation'
    $ps = Resolve-PowerShell
    $steps.Add((Invoke-LoggedProcess 'focused-foundation-evidence' $ps @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $RepoRoot 'scripts\windows-port\run-candidate-evidence.ps1'),
        '-RepoRoot', $RepoRoot,
        '-ManifestPath', $ManifestPath,
        '-OutputDir', $focusedDir,
        '-Platform', $Platform
    )))
}

$processDir = Join-Path $OutputDir 'process-traces'
New-Item -ItemType Directory -Force -Path $processDir | Out-Null
$steps.Add((Invoke-LoggedProcess 'foundation-process-tool-build' 'dotnet' @(
    'build',
    'windows\tools\OpenBurnBar.FoundationHostEvidence\OpenBurnBar.FoundationHostEvidence.csproj',
    '--configuration', 'Debug'
)))
$toolExe = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'windows\tools\OpenBurnBar.FoundationHostEvidence\bin\Debug') -Filter 'OpenBurnBar.FoundationHostEvidence.exe' -Recurse |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if ($null -eq $toolExe) {
    throw 'Foundation process evidence executable was not built.'
}
$steps.Add((Invoke-LoggedProcess 'foundation-process-evidence' $toolExe.FullName @(
    '--output', $processDir,
    '--expected-candidate', $manifest.source.commit
)))
$processEvidencePath = Join-Path $processDir 'process-evidence.json'
$processEvidence = Get-Content -Raw -LiteralPath $processEvidencePath | ConvertFrom-Json
$artifactRefs.Add((New-ArtifactRef $processEvidencePath 'process.all' 'process-evidence'))
foreach ($scenario in $processEvidence.scenarios) {
    $scenarioRows.Add([ordered]@{
        id = $scenario.id
        status = $scenario.status
        source = 'foundation-process-tool'
        artifacts = @((New-ArtifactRef $processEvidencePath $scenario.id 'process-evidence'))
    })
}

$appExe = Resolve-AppExe
$interactiveDir = Join-Path $OutputDir 'interactive-uia'
New-Item -ItemType Directory -Force -Path $interactiveDir | Out-Null
$collectorLaunch = Start-InteractiveCollector `
    -CollectorScript (Join-Path $RepoRoot 'scripts\windows-port\foundation-host-uia-collector.ps1') `
    -CollectorOutputDir $interactiveDir `
    -AppExe $appExe
Wait-ForJson (Join-Path $interactiveDir 'interactive-result.json')
$interactiveResult = Get-Content -Raw -LiteralPath (Join-Path $interactiveDir 'interactive-result.json') | ConvertFrom-Json
if ($interactiveResult.actor.isSession0 -eq $true -or [int]$interactiveResult.actor.sessionId -eq 0) {
    throw 'Interactive UIA collector ran in session 0.'
}
$steps.Add([ordered]@{
    name = 'interactive-uia-collector'
    command = 'CreateProcessAsUser ' + $collectorLaunch.powershell
    exitCode = if (($interactiveResult.scenarios | Where-Object { $_.status -ne 'captured' }).Count -eq 0) { 0 } else { 1 }
    launch = $collectorLaunch
    completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
})

$interactiveResultPath = Join-Path $interactiveDir 'interactive-result.json'
$artifactRefs.Add((New-ArtifactRef $interactiveResultPath 'uia.all' 'interactive-uia-summary'))
foreach ($scenario in $interactiveResult.scenarios) {
    $refs = New-Object System.Collections.Generic.List[object]
    foreach ($path in $scenario.artifacts) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $refs.Add((New-ArtifactRef $path $scenario.id 'uia-or-screenshot'))
        }
    }
    $scenarioRows.Add([ordered]@{
        id = $scenario.id
        status = $scenario.status
        source = 'interactive-uia'
        actor = $scenario.actor
        artifacts = $refs
    })
    foreach ($ref in $refs) { $artifactRefs.Add($ref) }
}

$focusedRoot = Join-Path $OutputDir 'focused-foundation'
$storageMap = @{
    'storage.fresh-install' = @('storage-evidence\fresh-install\evidence.json')
    'storage.restart-idempotency' = @('storage-evidence\restart-idempotency\evidence.json')
    'storage.generated-db-write-seams' = @('storage-evidence\generated-db-write-seams\evidence.json')
    'storage.wrong-key' = @('storage-evidence\wrong-key-recovery\evidence.json')
    'storage.corrupt-database' = @('storage-evidence\corrupt-archive-reset\evidence.json')
    'storage.locked-file' = @('storage-evidence\fault-LockedFile\evidence.json')
    'storage.interrupted-migration' = @('storage-evidence\interrupted-retry\evidence.json')
    'storage.unsupported-schema' = @('storage-evidence\unsupported-schema-recovery\evidence.json')
    'storage.full-disk' = @('storage-evidence\fault-FullDisk\evidence.json')
    'storage.access-denied' = @('storage-evidence\fault-AccessDenied\evidence.json')
    'storage.archive-reset' = @('storage-evidence\corrupt-archive-reset\evidence.json')
    'storage.retry' = @('storage-evidence\interrupted-retry\evidence.json')
    'storage.reveal-redacted-log' = @('storage-evidence\wrong-key-recovery\openburnbar.sqlite.recovery.log', 'storage-evidence\corrupt-archive-reset\openburnbar.sqlite.recovery.log', 'storage-evidence\wrong-key-recovery\evidence.json', 'storage-evidence\corrupt-archive-reset\evidence.json')
    'chat.attachment.file' = @('chat-evidence\chat-storage.json', 'storage-tests.json')
    'chat.attachment.drop' = @('chat-evidence\chat-storage.json', 'storage-tests.json')
    'chat.attachment.missing' = @('chat-evidence\chat-storage.json', 'storage-tests.json')
    'chat.retrieval.degraded' = @('chat-evidence\chat-storage.json', 'storage-tests.json')
}
foreach ($entry in $storageMap.GetEnumerator()) {
    $candidates = @($entry.Value | ForEach-Object { Join-Path $focusedRoot $_ })
    $path = Find-FirstArtifact $candidates
    $refs = @()
    if ($null -ne $path) {
        $refs = @((New-ArtifactRef $path $entry.Key 'focused-foundation-artifact'))
        $artifactRefs.Add($refs[0])
    }
    $scenarioRows.Add([ordered]@{
        id = $entry.Key
        status = if ($refs.Count -gt 0) { 'captured' } else { 'missing' }
        source = 'focused-foundation-evidence'
        artifacts = $refs
    })
}

$diagnosticsDir = Join-Path $OutputDir 'diagnostics-canary'
New-RedactedDiagnostics $diagnosticsDir
$diagnosticFiles = @{
    'diagnostics.config' = 'config-diagnostic.json'
    'diagnostics.log' = 'application.log'
    'diagnostics.support-bundle' = 'support-bundle.txt'
    'diagnostics.screenshot' = 'screenshot-ocr.txt'
}
foreach ($entry in $diagnosticFiles.GetEnumerator()) {
    $path = Join-Path $diagnosticsDir $entry.Value
    $ref = New-ArtifactRef $path $entry.Key 'diagnostic-redacted-canary'
    $artifactRefs.Add($ref)
    $scenarioRows.Add([ordered]@{
        id = $entry.Key
        status = 'captured'
        source = 'diagnostic-canary'
        artifacts = @($ref)
    })
}

$leaks = Test-SecretLeaks $OutputDir
$scanPath = Join-Path $OutputDir 'artifact-secret-scan.json'
Write-JsonFile $scanPath ([ordered]@{
    schema = 'openburnbar.windows.foundation-secret-scan.v1'
    scannedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    root = $OutputDir
    canaryCount = $CanarySecrets.Count
    findings = $leaks
    status = if ($leaks.Count -eq 0) { 'passed' } else { 'failed' }
})
$scanRef = New-ArtifactRef $scanPath 'diagnostics.secret-scan' 'secret-scan'
$artifactRefs.Add($scanRef)
$scenarioRows.Add([ordered]@{
    id = 'diagnostics.secret-scan'
    status = if ($leaks.Count -eq 0) { 'captured' } else { 'failed' }
    source = 'artifact-secret-scan'
    artifacts = @($scanRef)
})

$scenarioById = @{}
foreach ($row in $scenarioRows) {
    if (-not $scenarioById.ContainsKey($row.id)) {
        $scenarioById[$row.id] = $row
    }
}
$missingRows = @($RequiredScenarioIds | Where-Object { -not $scenarioById.ContainsKey($_) -or $scenarioById[$_].status -in @('missing', 'failed') })
$failedSteps = @($steps | Where-Object { $_.exitCode -ne 0 })

$manifestOut = [ordered]@{
    schema = 'openburnbar.windows.foundation-host-evidence-manifest.v1'
    status = if ($missingRows.Count -eq 0 -and $failedSteps.Count -eq 0 -and $leaks.Count -eq 0) { 'passed' } else { 'failed' }
    startedAtUtc = $startedAt
    completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    vmIdentitySha256 = Get-StringSha256 $VmUuid
    repoRoot = $RepoRoot
    outputDir = $OutputDir
    candidate = $manifest.source
    candidateManifest = [ordered]@{
        path = $ManifestPath
        sha256 = Get-Sha256 $ManifestPath
        payloadSha256 = $manifest.manifestPayloadSha256
    }
    command = [ordered]@{
        script = $PSCommandPath
        boundParameters = $PSBoundParameters
    }
    host = $hostIdentity
    steps = $steps
    requiredScenarioIds = $RequiredScenarioIds
    missingScenarioIds = $missingRows
    scenarios = @($scenarioById.Keys | Sort-Object | ForEach-Object { $scenarioById[$_] })
    artifacts = $artifactRefs
    secretScan = [ordered]@{
        path = $scanPath
        findings = $leaks.Count
    }
    failClosedChecks = [ordered]@{
        missingRows = $missingRows.Count
        failedCommands = $failedSteps.Count
        secretFindings = $leaks.Count
        session0Ui = ($interactiveResult.actor.isSession0 -eq $true -or [int]$interactiveResult.actor.sessionId -eq 0)
        staleCandidate = (-not [string]::IsNullOrWhiteSpace($ExpectedCandidate) -and $manifest.source.commit -ne $ExpectedCandidate)
    }
}

$manifestOutPath = Join-Path $OutputDir 'foundation-host-evidence-manifest.json'
Write-JsonFile $manifestOutPath $manifestOut
Write-Host "Foundation host evidence manifest written to $manifestOutPath"
if ($manifestOut.status -ne 'passed') {
    throw "Foundation host evidence failed closed. See $manifestOutPath"
}
