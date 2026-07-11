# Ledger row: mercury-media

## Windows Mercury WGC Capture ARM64 Host Evidence

**What this proves:** The production Windows Mercury screen-capture source
captured a real window through Windows Graphics Capture and copied its nonblank
BGRA buffer on an exact-candidate ARM64 host. The uncertified Media Foundation
transport encoder also failed closed instead of emitting an empty media frame.

**Status:** Passed on 2026-07-10.
**Candidate:** `c0f9c8fdfcf5a3d746aced99c5c3745aa0984cc1`
**Tree:** `0447f037a6158217afc481103f70129fa27f0ea9`
**Host:** Windows 11 ARM64 VM, native ARM64 .NET process, interactive session 1.

## Exact-candidate boundary

The history-independent candidate archive was downloaded over the private VM
bridge, hash-checked, imported to a clean short path, and verified before build
or execution:

- Archive SHA-256:
  `e6952e4ed34bea2b9598f9d7ed167e1d2f78d9e576172de23aeab61ce0993c0e`
- Manifest SHA-256:
  `318bc0c318e4d4f2932ed614eb4498cb82f1de2a0c28438981f3a44a0fd6b10c`
- Files: `10,290 / 10,290`, zero mismatches.

The ARM64 shipping WinUI app build completed with 27 existing warnings and zero
errors. The ARM64 host harness build completed with zero warnings and zero
errors.

## Live checks

All six checks passed:

- Windows Graphics Capture returned positive dimensions: `962 x 632`.
- The copied buffer contained exactly `2,431,936` BGRA bytes.
- The probe measured 67 sampled colors, a luma range of 230, and 20,267
  nonzero-RGB samples.
- The production capture adapter recorded no asynchronous error.
- The captured PNG was written and independently inspected as a visible,
  correctly framed high-contrast probe.
- The unfinished Media Foundation transport encoder threw
  `PlatformNotSupportedException` rather than producing fabricated media.

The raw BGRA SHA-256 is
`d5b2f7ce3e55a20d2544624a7ebe73c489f42802363c0b2d3cc3fabe26e7b837`.
The PNG SHA-256 is
`b7d935ef772aab70450de9c2792ec135a3fa47373c015fb2fa642fbe329c8d0c`.

## Evidence files

- [`candidate-import-verification.json`](candidate-import-verification.json)
- [`mercury-capture-host-receipt.json`](mercury-capture-host-receipt.json)
- [`mercury-capture-host-summary.json`](mercury-capture-host-summary.json)
- [`mercury-capture-wgc.png`](mercury-capture-wgc.png)

The committed summary replaces the private VM machine name with
`WINDOWS-ARM64-HOST`. Its SHA-256 is
`6ad2195dfe790672e2d734929f1ea42b3427aa51ceee6a6ce1b50824c92e8eb8`;
the receipt separately retains the raw summary SHA-256
`f256e813197a324cf54dd9360e4ddce287d1d2cde3024c55601f7bc34b661005`.

## Replay

```powershell
scripts/windows-port/run-mercury-capture-host-evidence.ps1 `
  -RepoRoot C:\mcapc0f9 `
  -OutputDirectory C:\Users\Public\mercury-capture-evidence-c0f9 `
  -CandidateManifestPath C:\Users\Public\candidate-c0f9c8fdfcf5-run\openburnbar-candidate-c0f9c8fdfcf5.manifest.json
```

## Remaining release boundary

This closes Windows ARM64 VM proof for WGC window capture and real BGRA
readback. AudioGraph and MediaCapture now copy real buffers in source, but this
run had no physical microphone or camera and does not certify those device
paths. Media Foundation sample I/O, calls, WNS delivery, cross-device RFB, and
physical x64/ARM64 hardware also remain open and visibly unavailable.
