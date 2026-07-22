# Windows v1.0.31 Physical x64 Handoff

Run this protocol in a signed-in desktop session on physical Windows 11 x64
hardware. Do not run it in a VM or hosted runner. Do not modify the candidate
checkout, publish a public release, touch production systems, or mark an
unobserved protocol `PASS`.

## Exact candidate

| Field | Required value |
|---|---|
| Repository | `Imagine-That-Ai/BurnBar` |
| Protected tag | `windows-v1.0.31` |
| Commit | `9a280a7d36c52276bba083e6d6906a31d698bee1` |
| Workflow run | `29423558731` |
| Artifact | `windows-release-v1.0.31` |
| x64 MSIX | `OpenBurnBar-1.0.31-x64.msix` |
| x64 MSIX SHA-256 | `fd5e8215cd2f6d0f01b971e843742ca9ab1cb049e6e0eef317fa87bde85fe585` |
| Artifact manifest | `signed-artifact-x64.json` |

## Staging

Use a new empty directory if any path below already contains data.

```powershell
$ErrorActionPreference = 'Stop'
$Root = 'C:\BurnBar-cert\windows-v1.0.31'
$Repo = Join-Path $Root 'repo'
$Release = Join-Path $Root 'release'
$Evidence = Join-Path $Root 'physical-x64'
$Attestation = Join-Path $Root 'hardware-attestation.json'

New-Item -ItemType Directory -Force -Path $Root, $Release | Out-Null
git clone https://github.com/Imagine-That-Ai/BurnBar.git $Repo
git -C $Repo checkout --detach windows-v1.0.31
if ((git -C $Repo rev-parse HEAD) -ne '9a280a7d36c52276bba083e6d6906a31d698bee1') {
    throw 'Candidate commit mismatch.'
}
if (git -C $Repo status --porcelain) { throw 'Candidate checkout is dirty.' }

gh run download 29423558731 `
    --repo Imagine-That-Ai/BurnBar `
    --name windows-release-v1.0.31 `
    --dir $Release

$Msix = Join-Path $Release 'OpenBurnBar-1.0.31-x64.msix'
$Manifest = Join-Path $Release 'signed-artifact-x64.json'
$ExpectedHash = 'fd5e8215cd2f6d0f01b971e843742ca9ab1cb049e6e0eef317fa87bde85fe585'
if ((Get-FileHash -Algorithm SHA256 $Msix).Hash.ToLowerInvariant() -ne $ExpectedHash) {
    throw 'x64 MSIX hash mismatch.'
}
$Signature = Get-AuthenticodeSignature -FilePath $Msix
if ($Signature.Status -ne 'Valid' -or
    $Signature.SignerCertificate.Subject -ne 'CN=Imagine That AI LLC, O=Imagine That AI LLC, L=Little Rock, S=Arkansas, C=US') {
    throw 'x64 MSIX signature or signer mismatch.'
}

$ExistingPackage = Get-AppxPackage -Name 'ImagineThat.OpenBurnBar'
if ($null -ne $ExistingPackage) {
    throw 'An OpenBurnBar package is already installed. Record it and obtain operator approval before removing or replacing it.'
}
Add-AppxPackage -Path $Msix
```

After the package registers, confirm its version is `1.0.31.0`, launch it from
the Start menu, and keep it open long enough to prove that the process remains
responsive and produces no Windows Error Reporting crash. Remove only the
package installed by this run, and only after all evidence has been captured.

## Hardware attestation and prescribed runner

Generate the hardware attestation on the target device. Never hand-author it.

```powershell
pwsh (Join-Path $Repo 'scripts\windows-port\new-physical-hardware-attestation.ps1') `
    -Operator Alberto `
    -ExpectedArchitecture x64 `
    -OutputPath $Attestation

pwsh (Join-Path $Repo 'scripts\windows-port\run-physical-release-certification.ps1') `
    -RepoRoot $Repo `
    -OutputDir $Evidence `
    -Platform x64 `
    -ArtifactManifestPath $Manifest `
    -HardwareAttestationPath $Attestation `
    -PhysicalHardware
```

Do not pass `-SkipAutomatedTests` or `-SkipUiAutomation`. The first run is a
fail-closed baseline. It may emit `BLOCKED` receipts for protocols that require
manual or external observation.

## Supplemental protocols

Perform each applicable protocol against the installed, exact signed artifact:

1. `physical-performance-x64`: cold/warm launch, tray/flyout, dashboard,
   search, settings, chat, scan, idle/active CPU, memory, GPU, disk, frame
   pacing, sleep/wake, Explorer restart, and soak traces.
2. `accessibility-display`: Narrator, complete keyboard-only navigation, focus
   order/visibility, live announcements, 100/150/200% DPI, high contrast,
   reduced motion/transparency, narrow/wide windows, and multi-monitor behavior.
3. `staging-cloud`: staging-only OAuth PKCE, callback cancellation/malformed
   input, token refresh/expiry/revocation, offline recovery, App Check
   valid/invalid, physical TPM claims, CloudVault round trips and conflict
   handling, sign-out cleanup, and secret-leak scans.
4. `media-computer-use-safety`: harmless capture/camera/mic, call/share/transfer
   interruption, snapshot and MOTW/quarantine handling, protected-target denial,
   exact approval, trust downgrade, panic/watchdog/kill paths, audit tamper, and
   phone authorization/replay denial.
5. `store-update-lifecycle`: private-flight or controlled Store clean install,
   upgrade, repair, rollback/recovery, uninstall/reinstall, activation,
   single-instance behavior, valid/tampered/downgrade/offline feeds,
   Store/direct-download coexistence, and winget eligibility.

Create a supplemental `PASS` receipt only when every required observation for
that gate has fresh raw evidence. Follow
`openburnbar.windows.release-certification-receipt.v1`, bind every receipt to
the generated hardware attestation and exact signed artifact, and hash every
listed evidence file. Use the receipt fixtures and validator tests in
`scripts/windows-port/test-validate-release-certification-evidence.mjs` as the
executable contract. Keep any unavailable gate `BLOCKED` with a named owner,
missing prerequisite, and recovery action. Physical ARM64 must remain
`BLOCKED` as the declared beta limitation.

Rerun the prescribed runner with the supplemental directory:

```powershell
$Supplemental = Join-Path $Root 'supplemental'
$Evidence = Join-Path $Root ('physical-x64-final-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
pwsh (Join-Path $Repo 'scripts\windows-port\run-physical-release-certification.ps1') `
    -RepoRoot $Repo `
    -OutputDir $Evidence `
    -Platform x64 `
    -ArtifactManifestPath $Manifest `
    -HardwareAttestationPath $Attestation `
    -SupplementalReceiptDirectory $Supplemental `
    -PhysicalHardware

node (Join-Path $Repo 'scripts\windows-port\validate-release-certification-evidence.mjs') `
    $Evidence `
    --write-sums
```

## Deliverable

Create a content-addressed ZIP without deleting the validated directory:

```powershell
$Zip = Join-Path $Root 'windows-v1.0.31-physical-x64-evidence.zip'
Compress-Archive -Path (Join-Path $Evidence '*') -DestinationPath $Zip -Force
$ZipHash = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
$Manifest = Get-Content -Raw (Join-Path $Evidence 'certification-manifest.json') | ConvertFrom-Json
[pscustomobject]@{
    evidenceZip = $Zip
    evidenceZipSha256 = $ZipHash
    commit = $Manifest.source.commitSha
    artifactSha256 = $Manifest.artifact.sha256
    verdict = $Manifest.overallVerdict
    gates = $Manifest.gates
} | ConvertTo-Json -Depth 8
```

Return the ZIP path and SHA-256, validator result, exact commit and artifact
hash, device identity/architecture, overall verdict, and every gate status.
