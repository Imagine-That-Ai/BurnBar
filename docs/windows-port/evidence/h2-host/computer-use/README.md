# Ledger row: computer-use-loop

## Windows Computer Use ARM64 Host Evidence

**What this proves:** The composed lower-privilege Computer Use runtime passed
an exact-candidate interactive Windows ARM64 host run.

**Status:** Passed on 2026-07-10.
**Candidate:** `08e425a0dec691fa1d8d657674bf5a9bdd04580b`
**Tree:** `23af5df0dc45c9188ff045c941184e63975c54ff`
**Host:** Windows 11 Pro ARM64 VM, active interactive console session 1.

## Exact-candidate boundary

The history-independent candidate archive was transferred to the Windows host
and verified before build or execution:

- Archive SHA-256:
  `1b3bdde2c62bb247b17342e59d7912d5b82e5e82b832ac80be025450443ea112`
- Manifest SHA-256:
  `8abee7370403ff65f12a0e41f1500b4540579bccf0957aa4b4a0f5a3c1f4eeb0`
- Files: `10,265 / 10,265`, zero mismatches.

The ARM64 WinUI app build completed with 27 existing warnings and zero errors.
The ARM64 host harness build completed with zero warnings and zero errors.

## Live checks

The interactive harness passed all 15 checks:

- UI Automation allows a normal target and denies a password target.
- `SendInput` focus, Unicode typing, shortcut, key, click, pointer move/click,
  drag/drop, and wheel injection were observed on the live certification window.
- The production runtime refuses signed-driver-required input through the
  advisory adapter with `SignatureFailure`; the target text remained unchanged.
- The runtime denies the secure text field, and the watchdog kill switch blocks
  dispatch until cleared.
- The four-entry audit chain verifies against its pinned head.
- Windows Graphics Capture produced the committed nonblank PNG.

The compact receipt records the Windows host as ARM64. Its top-level
`processArchitecture: X64` describes the PowerShell compatibility runner; the
content-addressed host summary records the actual harness as ARM64 on .NET
10.0.9.

## Evidence files

- [`candidate-import-verification.json`](candidate-import-verification.json)
- [`computer-use-host-receipt.json`](computer-use-host-receipt.json)
- [`computer-use-host-summary.json`](computer-use-host-summary.json)
- [`computer-use-wgc.png`](computer-use-wgc.png), SHA-256
  `d563ec6ad466505376e2ecc8271162a57f13c885454bb248301ca9f0afe0f46d`

The run was launched in the signed-in Windows session with:

```powershell
scripts/windows-port/run-computer-use-host-evidence.ps1 `
  -RepoRoot C:\obb\cu08e4 `
  -OutputDirectory C:\Users\Public\openburnbar-cu-08e425a0\computer-use `
  -CandidateManifestPath C:\OpenBurnBarCandidates\08e425a0dec6\openburnbar-candidate-08e425a0dec6.manifest.json
```

## Remaining release boundary

This closes the Windows ARM64 VM proof for the composed lower-privilege desktop
loop. It does not claim a signed non-bypassable virtual HID driver, secure
desktop or lock-screen injection, or physical x64/ARM64 device certification.
The product reports the unsigned adapter as not ready for signed-driver-required
actions and fails those actions closed.
