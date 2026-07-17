# Windows v1.0.35 Physical Intel x64 Certification

Run this from a normal, signed-in native PowerShell 7 session on the Intel x64
Windows machine. Do not run it in a Codex sandbox, service account, VM, or
compatibility layer. It downloads and certifies the exact signed candidate from
release run `29557726093`.

## Safety boundary

- Do not repartition, format, erase, or clean any disk.
- Do not touch production, publish an update feed, or submit to the Store.
- Do not remove an existing OpenBurnBar installation without recording it and
  obtaining operator approval.
- Physical ARM64 is out of scope and remains an explicit beta limitation.
- A blocked protocol stays `BLOCKED`; never manufacture a PASS receipt.

## Native preflight and artifact binding

```powershell
$ErrorActionPreference = 'Stop'
$Root = 'C:\BurnBar-cert\windows-v1.0.35'
$Repo = Join-Path $Root 'candidate'
$Harness = Join-Path $Root 'harness'
$Release = Join-Path $Root 'release'
$Evidence = Join-Path $Root ('physical-x64-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Attestation = Join-Path $Root 'hardware-attestation-x64.json'
$ExpectedCommit = '2cfa9db885dafef7f1f451a9e05a8ee775351d44'
$ExpectedHarnessCommit = 'f44ad39aee2129016a931a9bf40a913f2138fc4e'
$ExpectedPerformanceBudgetHash = '779abf7596911f8d255e0bc82e490e47c025ca3e4ef24842c65107081291f926'
$ExpectedMsixHash = '1d68c24f044a0247d49a5f2e4030a4d46844ce49c34016d3605f129bcd9a43e1'
$ExpectedSigner = 'CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US'
$InstalledByRun = $false

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw "Expected native AMD64/x64 PowerShell, got $env:PROCESSOR_ARCHITECTURE"
}
if (Test-Path -LiteralPath $Root) {
    throw "Certification root already exists. Preserve it and choose a new empty root: $Root"
}
New-Item -ItemType Directory -Path $Root, $Release | Out-Null

gh auth status
gh repo clone Imagine-That-Ai/BurnBar $Repo
gh repo clone Imagine-That-Ai/BurnBar $Harness
git -C $Repo fetch origin tag windows-v1.0.35 --force
git -C $Repo checkout --detach windows-v1.0.35
if ((git -C $Repo rev-parse HEAD) -ne $ExpectedCommit) {
    throw 'Candidate commit mismatch.'
}
if (git -C $Repo status --porcelain) {
    throw 'Candidate checkout is dirty.'
}
git -C $Harness checkout --detach $ExpectedHarnessCommit
if ((git -C $Harness rev-parse HEAD) -ne $ExpectedHarnessCommit) {
    throw 'Certification harness commit mismatch.'
}
if (git -C $Harness status --porcelain) {
    throw 'Certification harness checkout is dirty.'
}
$PerformanceBudget = Join-Path $Harness 'scripts\windows-port\release-performance-budgets.json'
if ((Get-FileHash -Algorithm SHA256 $PerformanceBudget).Hash.ToLowerInvariant() -ne $ExpectedPerformanceBudgetHash) {
    throw 'Active release performance budget mismatch.'
}

gh run download 29557726093 `
    --repo Imagine-That-Ai/BurnBar `
    --name windows-release-v1.0.35 `
    --dir $Release

$Msix = Join-Path $Release 'OpenBurnBar-1.0.35-x64.msix'
$ArtifactManifest = Join-Path $Release 'signed-artifact-x64.json'
if ((Get-FileHash -Algorithm SHA256 $Msix).Hash.ToLowerInvariant() -ne $ExpectedMsixHash) {
    throw 'x64 MSIX hash mismatch.'
}
$Signature = Get-AuthenticodeSignature -FilePath $Msix
if ($Signature.Status -ne 'Valid' -or
    $Signature.SignerCertificate.Subject -cne $ExpectedSigner -or
    $null -eq $Signature.TimeStamperCertificate) {
    throw 'x64 MSIX signature, signer, or RFC 3161 timestamp mismatch.'
}
$Manifest = Get-Content -Raw $ArtifactManifest | ConvertFrom-Json
if ($Manifest.sourceCommit -cne $ExpectedCommit -or
    $Manifest.artifactSha256 -cne $ExpectedMsixHash -or
    $Manifest.signatureResult -cne 'verified') {
    throw 'Signed artifact manifest is not bound to the exact candidate.'
}

$ExistingPackage = Get-AppxPackage -Name 'ImagineThat.OpenBurnBar'
if ($null -ne $ExistingPackage) {
    $ExistingPackage | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Root 'preexisting-package.json')
    throw 'OpenBurnBar is already installed. Preserve the receipt and obtain operator approval before replacement.'
}

Add-AppxPackage -Path $Msix
$InstalledPackage = Get-AppxPackage -Name 'ImagineThat.OpenBurnBar'
if ($null -eq $InstalledPackage -or
    $InstalledPackage.Version.ToString() -cne '1.0.35.0' -or
    $InstalledPackage.Architecture.ToString() -cne 'X64') {
    throw 'The exact x64 package was not registered as version 1.0.35.0.'
}
$InstalledByRun = $true

$Activation = "shell:AppsFolder\$($InstalledPackage.PackageFamilyName)!OpenBurnBar"
Start-Process explorer.exe $Activation
Start-Sleep -Seconds 20
$AppProcess = Get-Process -Name 'OpenBurnBar.App' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $AppProcess -or -not $AppProcess.Responding) {
    throw 'The exact signed installed app did not remain responsive for 20 seconds.'
}
$AppProcess | Stop-Process
```

## Prescribed baseline

Generate hardware identity from the machine and run the full baseline without
skipping automated or UI automation tests. Product builds and artifact binding
use the immutable candidate checkout. Collectors and validators run from the
separately pinned certification harness checkout:

```powershell
pwsh (Join-Path $Harness 'scripts\windows-port\new-physical-hardware-attestation.ps1') `
    -Operator Alberto `
    -ExpectedArchitecture x64 `
    -OutputPath $Attestation

pwsh (Join-Path $Harness 'scripts\windows-port\run-physical-release-certification.ps1') `
    -RepoRoot $Repo `
    -OutputDir $Evidence `
    -Platform x64 `
    -ArtifactManifestPath $ArtifactManifest `
    -HardwareAttestationPath $Attestation `
    -PhysicalHardware

node (Join-Path $Harness 'scripts\windows-port\validate-release-certification-evidence.mjs') `
    $Evidence `
    --write-sums `
    --expected-commit $ExpectedCommit `
    --expected-harness-commit $ExpectedHarnessCommit
```

The baseline may emit `BLOCKED` receipts for protocols requiring live manual or
external observations. That is expected and must remain fail-closed.

## Supplemental protocols

Perform every available protocol against the installed exact signed artifact:

1. `physical-performance-x64`: cold/warm launch, flyout, dashboard, search,
   settings, chat, scan, idle/active CPU, memory, GPU, disk, frame pacing,
   sleep/wake, Explorer restart, and soak traces.
2. `accessibility-display`: Narrator, keyboard-only navigation, focus order and
   visibility, announcements, 100/150/200% DPI, high contrast, reduced motion
   and transparency, narrow/wide windows, and multi-monitor behavior.
3. `staging-cloud`: only when the operator separately authorizes the named
   staging project and billing link; OAuth PKCE, callback failures, token
   refresh/revocation, offline recovery, App Check valid/invalid, physical TPM
   claims, CloudVault round trips/conflicts, sign-out cleanup, and secret scan.
4. `media-computer-use-safety`: harmless camera/mic/capture, call/share/transfer
   interruption, snapshot and MOTW handling, protected-target denial, exact
   approval, trust downgrade, panic/watchdog/kill paths, audit tamper, and phone
   authorization/replay denial.
5. `store-update-lifecycle`: only in an explicitly authorized private flight;
   clean install, upgrade, repair, rollback/recovery, uninstall/reinstall,
   activation, single instance, valid/tampered/downgrade/offline feeds,
   Store/direct-download coexistence, and winget eligibility.

Do not hand-author PASS receipts. Initialize the canonical checklist for each
gate that is actually authorized and available:

```powershell
$Supplemental = Join-Path $Root 'supplemental'
$ProtocolWork = Join-Path $Root 'protocol-work'
$ReceiptTool = Join-Path $Harness 'scripts\windows-port\new-release-certification-supplemental-receipt.ps1'
New-Item -ItemType Directory -Force -Path $Supplemental, $ProtocolWork | Out-Null

$AvailableGates = @(
    'physical-performance-x64',
    'accessibility-display'
)
# Add staging-cloud, media-computer-use-safety, or store-update-lifecycle only
# after its explicit authorization and prerequisites exist. Never add the
# physical ARM64 gate on this x64 device.
foreach ($Gate in $AvailableGates) {
    pwsh $ReceiptTool `
        -RepoRoot $Repo `
        -Gate $Gate `
        -ResultsPath (Join-Path $ProtocolWork ($Gate + '.json')) `
        -Initialize
}
```

Each generated result file enumerates every required assertion as `NOT_RUN`.
During the protocol, set the true UTC start/end times, record at least one
command or manual step, change an assertion to `PASS` only after observing it,
and list one or more raw evidence files relative to the result file's directory.
The physical-performance template also contains the immutable active-budget
identity, five required `performanceContext` fields, and 18 numeric
`performanceMeasurements`. Fill every measurement's `value`, `sampleCount`,
`durationSeconds`, `context`, and `evidenceFiles`; do not change its id,
assertion, unit, statistic, direction, limit, or minimums. Use WPR/WPA,
PresentMon, Performance Monitor, or an equivalently auditable source, and name
the tool/version, workload and dataset cardinality, power/thermal state,
display/GPU/driver/WebView2 state, sample interval, and percentile method.

The active release contract is
`scripts/windows-port/release-performance-budgets.json`. It requires repeated
cold/warm and interaction p95 samples, five minutes of idle CPU/disk samples,
one minute of active CPU/GPU sampling, at least 300 presented frames, and a
30-minute soak. The finalizer copies and hashes the raw files; the independent
validator rebinds the budget SHA-256, rejects missing/duplicate/unknown metrics,
checks sample and duration floors, re-evaluates all thresholds, and rejects a
measurement duration longer than the signed receipt interval.
Incomplete, failed, unknown, duplicate, unbound, unhashed, path-escaping, stale,
wrong-device, wrong-architecture, virtualized, or secret-bearing evidence fails
closed.

After every assertion for a gate has genuine raw evidence, finalize it against
the validator-clean physical baseline:

```powershell
foreach ($Gate in $AvailableGates) {
    pwsh $ReceiptTool `
        -RepoRoot $Repo `
        -Gate $Gate `
        -ResultsPath (Join-Path $ProtocolWork ($Gate + '.json')) `
        -BaselineBundle $Evidence `
        -OutputDirectory $Supplemental
}
```

Keep unavailable gates `BLOCKED` with their named prerequisite and recovery
action. A template, partial result, or manual JSON file is not PASS evidence.

## Final bundle

Rerun the prescribed runner with the supplemental directory, validate it, and
create a content-addressed ZIP without deleting the evidence directory:

```powershell
$FinalEvidence = Join-Path $Root ('physical-x64-final-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
pwsh (Join-Path $Harness 'scripts\windows-port\run-physical-release-certification.ps1') `
    -RepoRoot $Repo `
    -OutputDir $FinalEvidence `
    -Platform x64 `
    -ArtifactManifestPath $ArtifactManifest `
    -HardwareAttestationPath $Attestation `
    -SupplementalReceiptDirectory $Supplemental `
    -PhysicalHardware

node (Join-Path $Harness 'scripts\windows-port\validate-release-certification-evidence.mjs') `
    $FinalEvidence `
    --write-sums `
    --expected-commit $ExpectedCommit `
    --expected-harness-commit $ExpectedHarnessCommit

$Zip = Join-Path $Root 'windows-v1.0.35-physical-x64-evidence.zip'
Compress-Archive -Path (Join-Path $FinalEvidence '*') -DestinationPath $Zip -Force
$ZipHash = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
$Certification = Get-Content -Raw (Join-Path $FinalEvidence 'certification-manifest.json') | ConvertFrom-Json
[pscustomobject]@{
    evidenceZip = $Zip
    evidenceZipSha256 = $ZipHash
    commit = $Certification.source.commitSha
    harnessCommit = $Certification.source.harness.commitSha
    artifactSha256 = $Certification.artifact.sha256
    verdict = $Certification.overallVerdict
    gates = $Certification.gates
} | ConvertTo-Json -Depth 8
```

Return the ZIP path and SHA-256, validator result, exact commit and artifact
hash, hardware identity and architecture, overall verdict, and every gate
status. After all evidence is captured, remove only the exact package installed
by this run:

```powershell
if ($InstalledByRun -and $null -ne $InstalledPackage) {
    Get-AppxPackage -Name 'ImagineThat.OpenBurnBar' |
        Where-Object PackageFullName -EQ $InstalledPackage.PackageFullName |
        Remove-AppxPackage
}
```
