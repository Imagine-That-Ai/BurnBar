# Ledger row: mercury-media

## Windows Mercury File-Transfer ARM64 Host Evidence

**What this proves:** The production Windows file-transfer path passed an
exact-candidate ARM64 host run with immutable outbound snapshots, bounded
streaming chunks, NTFS Mark-of-the-Web, Microsoft Defender scanning,
approval-gated atomic promotion, threat-deny behavior, and snapshot cleanup.

**Status:** Passed on 2026-07-10.
**Candidate:** `c9a42ebfe7738f0160c9473b5a8a1474d2ab9e85`
**Tree:** `b5715f3488da7922bba879323da90a406a865e2f`
**Host:** Windows 11 ARM64 VM, native ARM64 .NET process.

## Exact-candidate boundary

The history-independent candidate archive was downloaded over the private VM
bridge, hash-checked, imported to a clean short path, and verified before build
or execution:

- Archive SHA-256:
  `b6d5cecda0907dd470f731c4d6f518055696e7fb14581175be997bc652054a11`
- Manifest SHA-256:
  `b606c3a870d1a247746c219f4062141f9771a6cd6ee7076e8b2832aa5dd5d272`
- Files: `10,281 / 10,281`, zero mismatches.

The ARM64 shipping WinUI app build completed with 27 existing warnings and zero
errors. The ARM64 host harness build completed with zero warnings and zero
errors.

## Live checks

All seven checks passed:

- Microsoft Defender `MpCmdRun` was present.
- A 1,048,613-byte source became a read-only, SHA-256-addressed immutable
  snapshot; changing the source did not change the transfer bytes.
- The snapshot streamed as 17 bounded chunks without loading the file as one
  transfer buffer.
- The receiver assembled the file in a same-volume hidden quarantine, preserved
  its full-file SHA-256, applied NTFS `Zone.Identifier`, and received a clean
  Defender result before becoming eligible for approval.
- Explicit approval promoted the file atomically without overwrite and preserved
  Mark-of-the-Web.
- A simulated threat result remained quarantined and could not be promoted.
- Explicit release removed the managed outbound snapshot.

The clean scan uses Defender's `-DisableRemediation` mode: the scanner observes
the quarantined file without mutating it, while a non-clean or unavailable
result fails closed.

## Evidence files

- [`candidate-import-verification.json`](candidate-import-verification.json)
- [`mercury-file-transfer-host-receipt.json`](mercury-file-transfer-host-receipt.json)
- [`mercury-file-transfer-host-summary.json`](mercury-file-transfer-host-summary.json)

The public summary replaces the private VM machine name with
`WINDOWS-ARM64-HOST`. The receipt retains the raw summary SHA-256 and separately
binds the committed sanitized summary.

## Replay

```powershell
scripts/windows-port/run-mercury-file-transfer-host-evidence.ps1 `
  -RepoRoot C:\mftc9a4 `
  -OutputDirectory C:\Users\Public\mercury-file-transfer-evidence-c9a42ebfe773 `
  -CandidateManifestPath C:\Users\Public\candidate-c9a42ebfe773-run\openburnbar-candidate-c9a42ebfe773.manifest.json
```

## Remaining release boundary

This closes the Windows ARM64 VM proof for Mercury file-transfer safety. It does
not certify screen/camera/audio capture, Media Foundation encode, calls, WNS,
RFB control between physical Windows and Mac devices, or physical x64/ARM64
hardware. Those capabilities remain visibly unavailable in the Windows Media
settings surface until their separate host and device evidence passes.
