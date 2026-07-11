# WPD-0008: Host-gated F1 residuals pending Windows host + credentials

- **Status:** Accepted (goal driver, 2026-07-09)
- **Date:** 2026-07-09
- **Scope:** F1 surfaces that require Win11 host proofs, Desktop OAuth/Firebase,
  Trusted Signing, Partner Center, or branch-protection admin actions that cannot
  be completed on the macOS authoring host alone.
- **Consistent with:** master plan H1/H2 human gates; ledger laws forbidding
  synthetic Real claims without host evidence.

## Decision

The following capabilities remain **DeferredApproved** (not Real, not Blocked as
silent gaps) until their revive triggers fire. Product copy must disclose host
dependency; code may ship portable cores and fail-closed empty paths.

| Capability | Ledger rows | Revive trigger |
|---|---|---|
| Desktop OAuth + Firebase Web API key live | `firebase-oauth-windows` | Production Desktop OAuth loopback + ID token refresh proven on Win11 with secrets in expected path |
| App Check / vTPM claim mint | `appcheck-tpm` | R14-A `NCryptCreateClaim` + backend exchange + enforced callable on Windows VM |
| Computer Use live loop | `computer-use-loop` | SendInput/UIA/WGC + kill-switch/watchdog host evidence under `evidence/h2-host/computer-use/` |
| Win2D/ARM64 60fps particles | `particles-gpu-60fps` | Measured 60fps spike on target ARM GPU in `evidence/h2-host/particles/` |
| Signed MSIX + update | `dist-msix-signed` | Trusted Signing cert active + signed install/update evidence |
| PR Windows Full Gate required | `ci-windows-full-gate` | Branch protection makes `pr-windows-full` required on `main` |

## Computer Use trigger result - 2026-07-10

The Computer Use revive trigger fired for the lower-privilege desktop loop.
Exact candidate `08e425a0dec6` passed import verification and 15/15 interactive
SendInput/UIA/WGC/audit/watchdog checks on the Windows 11 ARM64 host. Evidence is
under `docs/windows-port/evidence/h2-host/computer-use/`.

This does not revive secure-desktop or lock-screen injection. Those actions
still require a signed non-bypassable virtual HID route and physical-device
certification; the current app denies signed-driver-required actions through
the advisory adapter.

## Revive process

1. Capture host runbook output under `docs/windows-port/evidence/h2-host/` or dist evidence.
2. Promote the matching ledger row to `Real` only with tests + evidence + clean blocking_paths scan.
3. Do not invent screenshots or host logs on macOS.
