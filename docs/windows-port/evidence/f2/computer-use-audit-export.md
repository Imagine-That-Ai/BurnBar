# Windows Computer Use audit archive evidence

**Date:** 2026-07-13  
**Lane:** F2 Computer Use safety / audit forensics

Ledger row: computer-use-loop

## What this proves

The Windows Computer Use settings surface has a real, fail-closed audit
validation and export path instead of an unavailable placeholder.

## What is now composed

The production Computer Use settings host uses
`FileComputerUseAuditService` instead of the old unavailable placeholder. The
service reads the Windows audit layout under
`%LOCALAPPDATA%\\OpenBurnBar\\computer-use-audit` (or the explicit
`OPENBURNBAR_COMPUTER_USE_AUDIT_ROOT` override), validates the canonical
manifest hash and parent-linked `chain.jsonl`, and always supplies the terminal
`head.json` anchor to the portable verifier. If `signed_head.json` exists, its
Ed25519 signature and chain/head agreement are verified as well.

Exports are ZIP archives written atomically beneath `exports/`. They contain
the manifest, chain, head, optional signed head/OpenTimestamps proof, and
optionally the PNG screenshots. Session ids, archive size, required files, and
reparse-point paths are bounded/fail-closed; source screenshots are never
logged or copied unless the operator explicitly requests them.

OpenTimestamps notarization remains an explicit authenticated-account gate; the
Windows UI reports that unavailable state instead of claiming success.

## Validation

```text
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj --no-restore
```

Result: **132 passed, 0 failed, 0 skipped**. The focused audit tests cover:

- valid zero-entry sessions with a required terminal head anchor;
- missing-head and tampered-chain fail-closed behavior;
- atomic export with optional screenshot inclusion; and
- session-id path confinement.

The macOS authoring host compiles the managed app projects; WinUI's
Windows-only XAML compiler remains validated by the signed Windows workflow.

## Boundary

This closes the Windows audit-chain settings/export composition seam. It does
not claim physical UIA/SendInput/WGC capture, signed-driver input, live media
transfer, live staging account behavior, or public release certification.
