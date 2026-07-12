<#
.SYNOPSIS
    Run the fail-closed Windows physical release-certification evidence lane.

.DESCRIPTION
    This runner is the Windows-side collector for the certification bundle. It
    records exact source/artifact/device identity, runs the existing Windows
    build/test and UIA harnesses when available, and emits BLOCKED receipts for
    physical, live-staging, safety, or Store work that has not been exercised.
    A VM, hosted runner, source review, or unit test can never be promoted to a
    physical PASS by this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RepoRoot,
    [Parameter(Mandatory = $true)] [string] $OutputDir,
    [ValidateSet('x64', 'ARM64')] [Parameter(Mandatory = $true)] [string] $Platform,
    [string] $ArtifactManifestPath = '',
    [string] $HardwareAttestationPath = '',
    [string] $SupplementalReceiptDirectory = '',
    [switch] $PhysicalHardware,
    [switch] $SkipAutomatedTests,
    [switch] $SkipUiAutomation
)

$ErrorActionPreference = 'Stop'
$BundleSchema = 'openburnbar.windows.release-certification-bundle.v1'
$ReceiptSchema = 'openburnbar.windows.release-certification-receipt.v1'
$StartedAtUtc = [DateTimeOffset]::UtcNow

function Resolve-FullPath([string] $Path) {
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Write-JsonFile([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $Value | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Sha256([string] $Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-CommitSha {
    $value = (& git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Unable to resolve the candidate commit.' }
    return $value.Trim().ToLowerInvariant()
}

function Test-DirtyTree {
    $value = (& git -C $RepoRoot status --porcelain 2>$null)
    return -not [string]::IsNullOrWhiteSpace(($value -join "`n"))
}

function Sanitize-Text([string] $Text) {
    if ($null -eq $Text) { return '' }
    $redacted = $Text
    $secretPattern = '(?im)(["'']?)(authorization|bearer|access_token|refresh_token|id_token|client_secret|api_key|app_check|private_key|passphrase)\1(\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|(?:Bearer\s+)?[^\s,;]+)'
    $redacted = [regex]::Replace($redacted, $secretPattern, '$1$2$1$3[REDACTED]')
    $redacted = [regex]::Replace($redacted, '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{20,}\.?[A-Za-z0-9_.-]*', '[REDACTED_JWT]')
    return $redacted
}

function Invoke-LoggedProcess(
    [string] $Name,
    [string] $File,
    [string[]] $Arguments,
    [ValidateRange(1, 7200)] [int] $TimeoutSeconds = 1800
) {
    $logPath = Join-Path $OutputDir ("logs\" + $Name + '.log')
    $start = [DateTimeOffset]::UtcNow
    $output = @()
    $exitCode = 1
    $timedOut = $false
    $process = $null
    try {
        $processFile = $File
        $processArguments = [System.Collections.Generic.List[string]]::new()
        if ([System.IO.Path]::GetExtension($File) -ieq '.ps1') {
            $processFile = (Get-Process -Id $PID).Path
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $File)) {
                $processArguments.Add($argument)
            }
        }
        foreach ($argument in $Arguments) { $processArguments.Add($argument) }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $processFile
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $processArguments) { $startInfo.ArgumentList.Add($argument) }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "Failed to start $File." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try {
                $process.Kill($true)
            }
            catch {
                & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $process.Id /T /F | Out-Null
            }
            $process.WaitForExit()
        }
        $output = @(
            $stdoutTask.GetAwaiter().GetResult()
            $stderrTask.GetAwaiter().GetResult()
        )
        $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    }
    catch {
        $output += $_.Exception.ToString()
        $exitCode = 1
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
    (Sanitize-Text ($output -join "`n")) | Set-Content -LiteralPath $logPath -Encoding UTF8
    return [ordered]@{
        name = $Name
        command = $File + ' ' + ($Arguments -join ' ')
        exitCode = [int]$exitCode
        timedOut = $timedOut
        timeoutSeconds = $TimeoutSeconds
        log = ('logs/' + $Name + '.log')
        logSha256 = Get-Sha256 $logPath
        startedAtUtc = $start.ToUniversalTime().ToString('o')
        endedAtUtc = [DateTimeOffset]::UtcNow.ToUniversalTime().ToString('o')
    }
}

function Get-ArtifactIdentity {
    if ([string]::IsNullOrWhiteSpace($ArtifactManifestPath)) {
        return [ordered]@{
            name = 'no-release-artifact'
            architecture = $Platform
            availability = 'not-available'
            sha256 = $null
            workflowRunId = 'not-available'
            workflowRunUrl = 'not-available'
            signature = [ordered]@{ result = 'not-available'; identity = 'not-available' }
        }
    }
    $manifestPath = Resolve-FullPath $ArtifactManifestPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Artifact manifest not found: $manifestPath" }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    foreach ($field in @('artifactName', 'architecture', 'workflowRunId', 'workflowRunUrl', 'artifactSha256', 'signatureResult', 'signatureIdentity')) {
        if ($null -eq $manifest.$field -or [string]::IsNullOrWhiteSpace([string]$manifest.$field)) { throw "Artifact manifest missing ${field}: $manifestPath" }
    }
    if ($manifest.architecture -ne $Platform) { throw "Artifact architecture mismatch: expected $Platform, got $($manifest.architecture)" }
    if ($manifest.signatureResult -ne 'verified') { throw 'Refusing certification evidence for an artifact without a verified signature.' }
    if ([string]$manifest.artifactSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Artifact manifest sha256 must be a 64-character hex digest.' }
    return [ordered]@{
        name = [string]$manifest.artifactName
        architecture = [string]$manifest.architecture
        availability = 'recorded'
        sha256 = ([string]$manifest.artifactSha256).ToLowerInvariant()
        workflowRunId = [string]$manifest.workflowRunId
        workflowRunUrl = [string]$manifest.workflowRunUrl
        signature = [ordered]@{ result = [string]$manifest.signatureResult; identity = [string]$manifest.signatureIdentity }
    }
}

function Get-DeviceIdentity {
    $os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
    $enclosure = Get-CimInstance Win32_SystemEnclosure | Select-Object -First 1
    $systemProduct = Get-CimInstance Win32_ComputerSystemProduct | Select-Object -First 1
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object { [string]$_.Name })
    $storage = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { [ordered]@{ model = [string]$_.Model; mediaType = [string]$_.MediaType; sizeBytes = [int64]$_.Size } })
    $tpmState = 'unknown'
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmState = ('present={0};ready={1};managedAuthLevel={2}' -f $tpm.TpmPresent, $tpm.TpmReady, [string]$tpm.ManagedAuthLevel)
    } catch { $tpmState = 'unavailable' }
    $computerArch = [string]$os.OSArchitecture
    $processorPlatform = switch ([int]$cpu.Architecture) {
        9 { 'x64' }
        12 { 'ARM64' }
        default { '' }
    }
    $identity = "$($computer.Manufacturer) $($computer.Model)"
    if ($PhysicalHardware -and $identity -match '(?i)(VMware|VirtualBox|QEMU|UTM|Parallels|KVM|Virtual Machine|Hyper-V)') {
        throw "PhysicalHardware was asserted but the host identity looks virtualized: $identity"
    }
    if ($PhysicalHardware -and $processorPlatform -ne $Platform) {
        throw "Physical hardware architecture mismatch: expected $Platform, observed processor architecture $processorPlatform."
    }
    $assetTag = @([string]$enclosure.SMBIOSAssetTag, [string]$systemProduct.IdentifyingNumber) |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_ -notmatch '(?i)^(none|unknown|default string|to be filled by o\.e\.m\.|not specified|system asset tag)$'
        } |
        Select-Object -First 1
    if ($PhysicalHardware) {
        $liveIdentity = [ordered]@{
            manufacturer = [string]$computer.Manufacturer
            model = [string]$computer.Model
            assetTag = $assetTag
        }
        foreach ($field in $liveIdentity.Keys) {
            $liveValue = ([string]$liveIdentity[$field]).Trim()
            $attestedValue = ([string]$script:HardwareAttestation.$field).Trim()
            if ([string]::IsNullOrWhiteSpace($liveValue)) {
                throw "Physical hardware identity did not expose a live $field value."
            }
            if (-not [string]::Equals($liveValue, $attestedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Hardware attestation $field does not match the current device."
            }
        }
    }
    $result = [ordered]@{
        kind = if ($PhysicalHardware) { 'physical-windows' } else { 'windows-vm-or-hosted-runner' }
        manufacturer = [string]$computer.Manufacturer
        model = [string]$computer.Model
        assetTag = $assetTag
        architecture = $Platform
        osArchitecture = $computerArch
        osBuild = ('{0} {1} build {2}' -f $os.Caption, $os.Version, $os.BuildNumber)
        tpm = $tpmState
        cpu = [string]$cpu.Name
        ramBytes = [int64]$computer.TotalPhysicalMemory
        gpu = $gpu
        storage = $storage
        processorArchitecture = [string]$env:PROCESSOR_ARCHITECTURE
        capturedAtUtc = [DateTimeOffset]::UtcNow.ToUniversalTime().ToString('o')
    }
    if ($null -ne $script:HardwareAttestation) {
        $result['hardwareAttestation'] = [ordered]@{
            schema = [string]$script:HardwareAttestation.schema
            operator = [string]$script:HardwareAttestation.operator
            assetTag = [string]$script:HardwareAttestation.assetTag
            sha256 = [string]$script:HardwareAttestationSha256
        }
    }
    return $result
}

function New-BlockerFile([string] $Gate, [string] $Id, [string] $Missing, [string] $Recovery) {
    $path = Join-Path $OutputDir ("blockers\" + $Gate + '.md')
    @(
        "# $Gate blocker",
        '',
        "- id: $Id",
        '- status: BLOCKED',
        '- owner: Alberto',
        "- missing: $Missing",
        "- recovery: $Recovery",
        "- capturedAtUtc: $([DateTimeOffset]::UtcNow.ToUniversalTime().ToString('o'))"
    ) | Set-Content -LiteralPath $path -Encoding UTF8
    return [ordered]@{ path = ('blockers/' + $Gate + '.md'); sha256 = Get-Sha256 $path }
}

function New-Receipt(
    [string] $Gate,
    [string] $Target,
    [ValidateSet('PASS', 'FAIL', 'BLOCKED', 'NOT_RUN')] [string] $Status,
    [string] $Expected,
    [string] $Observed,
    [Nullable[int]] $ExitCode,
    [object[]] $Commands,
    [object[]] $ManualSteps,
    [object] $Blocker,
    [object[]] $EvidenceFiles,
    [object] $Device,
    [object] $Artifact
) {
    $end = [DateTimeOffset]::UtcNow
    $receipt = [ordered]@{
        schema = $ReceiptSchema
        status = $Status
        gate = $Gate
        target = $Target
        source = [ordered]@{ commitSha = Get-CommitSha; dirtyTree = Test-DirtyTree }
        artifact = $Artifact
        device = $Device
        protocol = [ordered]@{ commands = @($Commands); manualSteps = @($ManualSteps) }
        time = [ordered]@{
            startedAtUtc = $StartedAtUtc.ToUniversalTime().ToString('o')
            endedAtUtc = $end.ToUniversalTime().ToString('o')
            durationSeconds = [Math]::Max(0, ($end - $StartedAtUtc).TotalSeconds)
        }
        expected = $Expected
        observed = $Observed
        exitCode = $ExitCode
        evidence = [ordered]@{ files = @($EvidenceFiles) }
        blocker = $Blocker
    }
    $path = Join-Path $OutputDir ("receipts\" + $Gate + '.json')
    Write-JsonFile $path $receipt
    return [ordered]@{ path = ('receipts/' + $Gate + '.json'); sha256 = Get-Sha256 $path; status = $Status; gate = $Gate }
}

$RepoRoot = Resolve-FullPath $RepoRoot
$OutputDir = Resolve-FullPath $OutputDir
New-Item -ItemType Directory -Force -Path $OutputDir, (Join-Path $OutputDir 'receipts'), (Join-Path $OutputDir 'logs'), (Join-Path $OutputDir 'blockers') | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'windows\OpenBurnBar.sln'))) { throw "RepoRoot does not contain windows\OpenBurnBar.sln: $RepoRoot" }

$script:HardwareAttestation = $null
$script:HardwareAttestationSha256 = $null
if ($PhysicalHardware) {
    if ([string]::IsNullOrWhiteSpace($HardwareAttestationPath)) {
        throw 'PhysicalHardware requires -HardwareAttestationPath; a switch alone cannot certify physical hardware.'
    }
    $attestationPath = Resolve-FullPath $HardwareAttestationPath
    if (-not (Test-Path -LiteralPath $attestationPath -PathType Leaf)) { throw "Hardware attestation not found: $attestationPath" }
    $script:HardwareAttestation = Get-Content -Raw -LiteralPath $attestationPath | ConvertFrom-Json
    foreach ($field in @('schema', 'operator', 'assetTag', 'manufacturer', 'model', 'architecture', 'capturedAtUtc')) {
        if ($null -eq $script:HardwareAttestation.$field -or [string]::IsNullOrWhiteSpace([string]$script:HardwareAttestation.$field)) { throw "Hardware attestation missing $field" }
    }
    if ($script:HardwareAttestation.schema -ne 'openburnbar.windows.physical-hardware-attestation.v1') { throw 'Unsupported physical hardware attestation schema.' }
    if ($script:HardwareAttestation.physicalHardware -ne $true) { throw 'Hardware attestation does not assert physicalHardware=true.' }
    if ($script:HardwareAttestation.architecture -ne $Platform) { throw "Hardware attestation architecture mismatch: expected $Platform" }
    $script:HardwareAttestationSha256 = Get-Sha256 $attestationPath
}

$artifact = Get-ArtifactIdentity
$device = Get-DeviceIdentity
$steps = New-Object System.Collections.Generic.List[object]
$receiptEntries = New-Object System.Collections.Generic.List[object]

if ($SkipAutomatedTests) {
    $skipBlocker = New-BlockerFile 'local-automated-checks' 'LOCAL-AUTOMATION-SKIPPED' 'The operator supplied -SkipAutomatedTests.' 'Run this script without -SkipAutomatedTests on the target Windows host.'
    $receiptEntries.Add((New-Receipt 'local-automated-checks' 'Windows solution and focused test suites' 'BLOCKED' 'The Windows solution and focused test suites exit 0.' 'Automated tests were explicitly skipped.' $null @() @('Run dotnet restore/build/test on the exact candidate.') ([ordered]@{ id = 'LOCAL-AUTOMATION-SKIPPED'; owner = 'operator'; missing = 'automated test execution'; recovery = 'Run the script without -SkipAutomatedTests.' }) @($skipBlocker) $device $artifact))
} else {
    $steps.Add((Invoke-LoggedProcess 'dotnet-restore' 'dotnet' @('restore', 'windows\OpenBurnBar.sln', "-p:Platform=$Platform")))
    $steps.Add((Invoke-LoggedProcess 'dotnet-build' 'dotnet' @('build', 'windows\OpenBurnBar.sln', '-c', 'Release', '--no-restore', "-p:Platform=$Platform")))
    $steps.Add((Invoke-LoggedProcess 'dotnet-test' 'dotnet' @('test', 'windows\OpenBurnBar.sln', '-c', 'Release', '--no-build', '--nologo', "-p:Platform=$Platform", '--logger', 'trx;LogFileName=physical-certification.trx')))
    $failed = @($steps | Where-Object { $_.exitCode -ne 0 })
    $localLogRefs = @($steps | ForEach-Object { [ordered]@{ path = $_.log; sha256 = $_.logSha256 } })
    if ($failed.Count -eq 0) {
        $receiptEntries.Add((New-Receipt 'local-automated-checks' 'Windows solution build and test' 'PASS' 'Restore, Release build, and full solution test exit 0.' 'All automated Windows solution steps exited 0.' 0 @($steps.command) @('Automated proof is supporting evidence only; it is not physical certification.') $null $localLogRefs $device $artifact))
    } else {
        $receiptEntries.Add((New-Receipt 'local-automated-checks' 'Windows solution build and test' 'FAIL' 'Restore, Release build, and full solution test exit 0.' ("Failed steps: " + (($failed | ForEach-Object { $_.name }) -join ', ')) 1 @($steps.command) @() $null $localLogRefs $device $artifact))
    }
}

$uiEvidence = @()
if ($SkipUiAutomation) {
    $blockerId = 'UIA-SKIPPED'
    $blockerMissing = 'The operator supplied -SkipUiAutomation.'
    $blockerRecovery = 'Run the accessibility profile in the signed-in Windows desktop session.'
} else {
    $uiStep = Invoke-LoggedProcess 'ui-automation-accessibility' (Join-Path $RepoRoot 'scripts\windows-port\run-ui-automation.ps1') @('-RepoRoot', $RepoRoot, '-Platform', $Platform, '-CertificationProfile', 'all', '-OutputDirectory', (Join-Path $OutputDir 'ui-automation'))
    $steps.Add($uiStep)
    $uiEvidence = @([ordered]@{ path = $uiStep.log; sha256 = $uiStep.logSha256 })
    if ($uiStep.exitCode -eq 0) {
        $blockerId = 'ACCESSIBILITY-PHYSICAL-RECEIPT-MISSING'
        $blockerMissing = 'The UIA harness passed, but the required physical Narrator/manual keyboard/display receipt was not supplied.'
        $blockerRecovery = 'Run Narrator and keyboard-only protocol at 100%, 150%, and 200% DPI; high contrast; reduced motion/transparency; mixed-DPI multi-monitor; attach UIA trees and screenshots.'
    } else {
        $blockerId = 'UIA-HARNESS-FAILED'
        $blockerMissing = 'The accessibility UIA harness did not produce a passing result.'
        $blockerRecovery = 'Inspect logs/ui-automation-accessibility.log, fix the host/runtime defect, and rerun.'
    }
}
$blockerFile = New-BlockerFile 'accessibility-display' $blockerId $blockerMissing $blockerRecovery
$receiptEntries.Add((New-Receipt 'accessibility-display' 'Narrator, UIA, keyboard, DPI, themes, motion, transparency, and monitors' 'BLOCKED' 'Physical manual protocol and all required UIA/display scenarios pass.' 'The required physical/manual accessibility receipt was not supplied by this run.' $null @('scripts/windows-port/run-ui-automation.ps1 -CertificationProfile all') @('Run Narrator and keyboard-only protocol at 100%, 150%, and 200% DPI; high contrast; reduced motion/transparency; mixed-DPI multi-monitor; attach UIA trees and screenshots.') ([ordered]@{ id = $blockerId; owner = 'Alberto'; missing = $blockerMissing; recovery = $blockerRecovery }) (@($blockerFile) + $uiEvidence) $device $artifact))

$gateProtocols = @{
    'physical-performance-x64' = @('Run signed exact-candidate performance workload on physical Windows x64 hardware.', 'Capture cold/warm launch, tray/flyout, dashboard, search, settings, chat, scan, idle/active CPU, memory, GPU, disk, frame pacing, sleep/wake, Explorer restart, and soak traces.')
    'physical-performance-arm64' = @('Run signed exact-candidate performance workload on physical Windows ARM64 hardware.', 'Capture cold/warm launch, tray/flyout, dashboard, search, settings, chat, scan, idle/active CPU, memory, GPU, disk, frame pacing, sleep/wake, Explorer restart, and soak traces.')
    'staging-cloud' = @('Use staging only: OAuth loopback/PKCE, refresh/expiry/revocation/cancellation/malformed callback, offline recovery, App Check valid/invalid, physical TPM claim enforcement, CloudVault round trips, queue ordering/idempotency/conflict/replay, sign-out cleanup, and leak scans.')
    'media-computer-use-safety' = @('Use harmless fixtures: capture/camera/mic permissions, calls/share/transfer interruption and recovery, snapshot/quarantine/MOTW, UIA/SendInput capability and secure-desktop denial, approval downgrade, panic/watchdog/kill switches, audit tamper, phone auth/replay.')
    'store-update-lifecycle' = @('Use a private flight or controlled Store channel: clean install, upgrade, repair, rollback/recovery, uninstall/reinstall, activation, single-instance, valid/tampered/downgrade/offline feeds, Store/direct-download coexistence, and winget eligibility.')
}
$performanceArchitectureByGate = @{
    'physical-performance-x64' = 'x64'
    'physical-performance-arm64' = 'ARM64'
}
$supplementalGateIds = @('accessibility-display') + @($gateProtocols.Keys)
foreach ($gate in $gateProtocols.Keys) {
    if ($gate -like 'physical-performance-*' -and $gate -ne ('physical-performance-' + $Platform)) {
        $blockerId = 'ARCHITECTURE-NOT-UNDER-TEST'
        $missing = "This run targets $Platform; the $gate device lane requires a separate physical device."
        $recovery = 'Run the same script on the other physical architecture with the exact signed artifact.'
    } elseif (-not $PhysicalHardware) {
        $blockerId = 'PHYSICAL-WINDOWS-HARDWARE-MISSING'
        $missing = 'This invocation did not assert a physical Windows device; VM/hosted evidence is not certification proof.'
        $recovery = 'Run on the named physical Windows device and provide hardware identity, artifact, and raw trace receipts.'
    } elseif ($artifact.availability -ne 'recorded') {
        $blockerId = 'SIGNED-ARTIFACT-MANIFEST-MISSING'
        $missing = 'No recorded signed artifact manifest with workflow run, SHA-256, architecture, and signature identity was supplied.'
        $recovery = 'Supply the exact signed artifact manifest; never use an unsigned rehearsal for certification.'
    } else {
        $blockerId = 'SUPPLEMENTAL-LIVE-RECEIPT-MISSING'
        $missing = 'The operator did not supply the required live physical/manual receipt for this gate.'
        $recovery = 'Run the named protocol and pass a schema-validated supplemental receipt directory to the harness.'
    }
    $blockerFile = New-BlockerFile $gate $blockerId $missing $recovery
    $receiptEntries.Add((New-Receipt $gate $gate 'BLOCKED' 'All gate-specific physical/live/store assertions pass with complete raw evidence.' 'No defensible PASS evidence was available in this invocation.' $null @() $gateProtocols[$gate] ([ordered]@{ id = $blockerId; owner = 'Alberto'; missing = $missing; recovery = $recovery }) @($blockerFile) $device $artifact))
}

if (-not [string]::IsNullOrWhiteSpace($SupplementalReceiptDirectory)) {
    $supplementalRoot = Resolve-FullPath $SupplementalReceiptDirectory
    if (-not (Test-Path -LiteralPath $supplementalRoot -PathType Container)) { throw "Supplemental receipt directory not found: $supplementalRoot" }
    foreach ($sourceReceiptPath in @(Get-ChildItem -LiteralPath $supplementalRoot -Filter '*.json' -File -Recurse)) {
        if ($sourceReceiptPath.Name -eq 'certification-manifest.json') { continue }
        $candidate = Get-Content -Raw -LiteralPath $sourceReceiptPath.FullName | ConvertFrom-Json
        if ($candidate.schema -ne $ReceiptSchema -or $candidate.status -ne 'PASS') { continue }
        if ($candidate.source.commitSha -ne (Get-CommitSha) -or $candidate.source.dirtyTree -eq $true) { continue }
        if ($supplementalGateIds -notcontains [string]$candidate.gate) { continue }
        if ($candidate.artifact.availability -ne 'recorded' -or $candidate.artifact.signature.result -ne 'verified') { continue }
        $candidateGate = [string]$candidate.gate
        if ($performanceArchitectureByGate.ContainsKey($candidateGate)) {
            if ($candidate.artifact.architecture -ne $performanceArchitectureByGate[$candidateGate]) { continue }
        } elseif ($candidate.artifact.sha256 -ne $artifact.sha256 -or $candidate.artifact.architecture -ne $artifact.architecture) {
            continue
        }
        $candidateFiles = @()
        foreach ($sourceFile in @($candidate.evidence.files)) {
            $relativeSource = ([string]$sourceFile.path).Replace('/', '\')
            $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $supplementalRoot $relativeSource))
            $sourceRootWithSeparator = $supplementalRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            if (-not $sourcePath.StartsWith($sourceRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Supplemental evidence path escapes its root: $($sourceFile.path)" }
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Supplemental evidence file missing: $sourcePath" }
            $expectedSourceSha256 = ([string]$sourceFile.sha256).ToLowerInvariant()
            if ($expectedSourceSha256 -notmatch '^[a-f0-9]{64}$') { throw "Supplemental evidence hash is invalid: $($sourceFile.path)" }
            $observedSourceSha256 = Get-Sha256 $sourcePath
            if ($observedSourceSha256 -ne $expectedSourceSha256) { throw "Supplemental evidence hash mismatch: $($sourceFile.path)" }
            $destinationRelative = ('supplemental/' + [string]$candidate.gate + '/' + ([string]$sourceFile.path).Replace('\', '/'))
            $destinationPath = Join-Path $OutputDir ($destinationRelative.Replace('/', '\'))
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            $candidateFiles += [ordered]@{ path = $destinationRelative; sha256 = Get-Sha256 $destinationPath }
        }
        $candidate.evidence.files = $candidateFiles
        $destinationReceipt = Join-Path $OutputDir ('receipts\' + [string]$candidate.gate + '.json')
        Write-JsonFile $destinationReceipt $candidate
        foreach ($existing in @($receiptEntries | Where-Object { $_.gate -eq [string]$candidate.gate })) { [void]$receiptEntries.Remove($existing) }
        $receiptEntries.Add([ordered]@{ path = ('receipts/' + [string]$candidate.gate + '.json'); sha256 = Get-Sha256 $destinationReceipt; status = 'PASS'; gate = [string]$candidate.gate })
    }
}

$requiredGateIds = @(
    'local-automated-checks',
    'physical-performance-x64',
    'physical-performance-arm64',
    'accessibility-display',
    'staging-cloud',
    'media-computer-use-safety',
    'store-update-lifecycle'
)
$nonPassingRequiredGates = @($requiredGateIds | Where-Object {
    $gateId = $_
    @($receiptEntries | Where-Object {
        $_.gate -eq $gateId -and $_.status -eq 'PASS'
    }).Count -ne 1
})
$overallVerdict = if ($nonPassingRequiredGates.Count -eq 0) { 'GO' } else { 'NO-GO' }

$manifest = [ordered]@{
    schema = $BundleSchema
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToUniversalTime().ToString('o')
    source = [ordered]@{ commitSha = Get-CommitSha; dirtyTree = Test-DirtyTree }
    runner = [ordered]@{ script = 'scripts/windows-port/run-physical-release-certification.ps1'; platform = $Platform; physicalHardwareAsserted = [bool]$PhysicalHardware }
    overallVerdict = $overallVerdict
    receipts = @($receiptEntries | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.sha256 } })
    gates = @($receiptEntries | ForEach-Object { [ordered]@{ id = $_.gate; status = $_.status; receipts = @($_.path) } })
    notes = @('PASS is reserved for evidence observed on the declared surface.', 'VM, hosted runner, source review, unit tests, and package registration do not satisfy physical certification.')
}
Write-JsonFile (Join-Path $OutputDir 'certification-manifest.json') $manifest

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) { throw 'Node.js is required to validate and hash the evidence bundle.' }
& $node.Source (Join-Path $RepoRoot 'scripts\windows-port\validate-release-certification-evidence.mjs') $OutputDir --write-sums
if ($LASTEXITCODE -ne 0) { throw 'Evidence bundle validation failed.' }
Write-Host "Windows physical release-certification bundle written to $OutputDir" -ForegroundColor Yellow
