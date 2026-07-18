# Windows v1.0.37 Physical Intel x64 Certification

Run this from a normal signed-in PowerShell 7 desktop session on the physical
Intel HP laptop. Do not use a Codex sandbox, service identity, VM, compatibility
layer, or remote non-interactive session for physical/manual observations.

## Safety and honesty boundary

- Do not repartition, format, erase, or clean any disk.
- Do not touch production, publish an update feed, or submit to the Store.
- Preserve any pre-existing OpenBurnBar package and stop before replacing it.
- Do not hand-author PASS receipts.
- A missing prerequisite stays `BLOCKED`; VM evidence is never physical proof.
- Physical ARM64 is out of scope and remains an explicit beta limitation.

## Exact candidate preflight

```powershell
$ErrorActionPreference = 'Stop'
$Root = 'C:\BurnBar-cert\windows-v1.0.37'
$Repo = Join-Path $Root 'candidate'
$Harness = Join-Path $Root 'harness'
$Release = Join-Path $Root 'release'
$Evidence = Join-Path $Root ('physical-x64-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Attestation = Join-Path $Root 'hardware-attestation-x64.json'
$ExpectedCommit = '2757652e89440eb647d21721895fc61ec89935d3'
$ExpectedHarnessCommit = '2757652e89440eb647d21721895fc61ec89935d3'
$ExpectedPerformanceBudgetHash = '0824f341d0a7dea318a831e6ce67de016c9589d909e6982a678102130078fa92'
$ExpectedMsixHash = '63a9c374bb8d817f4642ddbcbc1c4847d5bcc0388d40fdac4c45b202e7e64bd9'
$ExpectedSigner = 'CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US'
$InstalledByRun = $false

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw "Expected native AMD64/x64 PowerShell, got $env:PROCESSOR_ARCHITECTURE"
}
if (Test-Path -LiteralPath $Root) {
    throw "Preserve the existing certification root and choose a new empty root: $Root"
}
New-Item -ItemType Directory -Path $Root, $Release | Out-Null

gh auth status
gh repo clone Imagine-That-Ai/BurnBar $Repo
gh repo clone Imagine-That-Ai/BurnBar $Harness
git -C $Repo fetch origin tag windows-v1.0.37 --force
git -C $Repo checkout --detach windows-v1.0.37
git -C $Harness fetch origin tag windows-v1.0.37 --force
git -C $Harness checkout --detach $ExpectedHarnessCommit
if ((git -C $Repo rev-parse HEAD) -ne $ExpectedCommit) { throw 'Candidate commit mismatch.' }
if ((git -C $Harness rev-parse HEAD) -ne $ExpectedHarnessCommit) { throw 'Harness commit mismatch.' }
if (git -C $Repo status --porcelain) { throw 'Candidate checkout is dirty.' }
if (git -C $Harness status --porcelain) { throw 'Harness checkout is dirty.' }

$PerformanceBudget = Join-Path $Harness 'scripts\windows-port\release-performance-budgets.json'
if ((Get-FileHash -Algorithm SHA256 $PerformanceBudget).Hash.ToLowerInvariant() -ne $ExpectedPerformanceBudgetHash) {
    throw 'Active release performance budget mismatch.'
}
```

Use the release already placed on the removable drive when available. This
finds only the exact handoff directory at drive roots; it does not crawl disks.
It falls back to GitHub Actions when the drive is absent.

```powershell
$FlashRelease = Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    Join-Path $_.Root 'BurnBar-cert\windows-v1.0.37\release-artifact'
} | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ 'signed-artifact-x64.json')
} | Select-Object -First 1

if ($null -ne $FlashRelease) {
    Copy-Item -Path (Join-Path $FlashRelease '*') -Destination $Release -Recurse -Force
}
else {
    gh run download 29650389335 `
        --repo Imagine-That-Ai/BurnBar `
        --name windows-release-v1.0.37 `
        --dir $Release
}

$Msix = Join-Path $Release 'OpenBurnBar-1.0.37-x64.msix'
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
if (Get-AppxPackage -Name 'ImagineThat.OpenBurnBar') {
    Get-AppxPackage -Name 'ImagineThat.OpenBurnBar' |
        ConvertTo-Json -Depth 6 |
        Set-Content (Join-Path $Root 'preexisting-package.json')
    throw 'OpenBurnBar is already installed. Preserve the receipt and obtain operator approval before replacement.'
}
```

## Install and baseline

```powershell
Add-AppxPackage -Path $Msix
$InstalledPackage = Get-AppxPackage -Name 'ImagineThat.OpenBurnBar'
if ($null -eq $InstalledPackage -or
    $InstalledPackage.Version.ToString() -cne '1.0.37.0' -or
    $InstalledPackage.Architecture.ToString() -cne 'X64') {
    throw 'The exact x64 package was not registered as version 1.0.37.0.'
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

The baseline may emit `BLOCKED` for unperformed manual/live protocols. That is
correct fail-closed behavior.

## Physical performance and accessibility

Initialize only the two protocols available on the Intel laptop. The 30-minute
performance soak is mandatory because `v1.0.35` failed its memory-growth
budget late in that interval.

```powershell
$Supplemental = Join-Path $Root 'supplemental'
$ProtocolWork = Join-Path $Root 'protocol-work'
$ReceiptTool = Join-Path $Harness 'scripts\windows-port\new-release-certification-supplemental-receipt.ps1'
New-Item -ItemType Directory -Force -Path $Supplemental, $ProtocolWork | Out-Null
$AvailableGates = @('physical-performance-x64', 'accessibility-display')

foreach ($Gate in $AvailableGates) {
    pwsh $ReceiptTool `
        -RepoRoot $Repo `
        -Gate $Gate `
        -ResultsPath (Join-Path $ProtocolWork ($Gate + '.json')) `
        -Initialize
}
```

Exercise every enumerated assertion using real observations and harmless test
fixtures. Performance evidence must contain complete numeric sample series for
all measurements, required sample/duration floors, tool/version, workload,
power/thermal state, display/GPU/driver/WebView2 state, and hashed raw files.
Accessibility evidence must cover the full UIA profile, Narrator,
keyboard/focus/announcements, 100/150/200% DPI, high contrast, reduced motion
and transparency, narrow/wide windows, and mixed-DPI monitors when available.
Leave anything not genuinely observed as `NOT_RUN` or `BLOCKED`.

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

## Final evidence

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

$Zip = Join-Path $Root 'windows-v1.0.37-physical-x64-evidence.zip'
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

Return the ZIP path and hash, validator output, hardware identity, exact commit
and artifact hash, overall verdict, and every gate status. Remove only the exact
package installed by this run after evidence capture:

```powershell
if ($InstalledByRun -and $null -ne $InstalledPackage) {
    Get-AppxPackage -Name 'ImagineThat.OpenBurnBar' |
        Where-Object PackageFullName -EQ $InstalledPackage.PackageFullName |
        Remove-AppxPackage
}
```
