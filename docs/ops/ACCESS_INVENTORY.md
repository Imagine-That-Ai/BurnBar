# Access inventory

Public inventory of the access ownership slots required to operate and release
OpenBurnBar. This document names systems and the approved documentation path;
it intentionally contains no usernames, credentials, private keys, tokens,
recovery codes, or personal device identifiers.

**Schema status:** each value is populated or exactly `UNSET`.
**Last schema review:** 2026-09-01.

## Inventory rules

1. Store secrets only in the provider's approved secret manager or password
   vault. This file stores ownership and verification state, not secret values.
2. Replace `UNSET` only after a human owner verifies the access path and scope.
3. Record live readbacks in the private operations log; link only to a
   committed public runbook here.

## Required access slots

| System / capability | Owner or group | Public procedure | Last verified |
| --- | --- | --- | --- |
| GitHub repository administration | UNSET | `GOVERNANCE.md` | UNSET |
| GitHub Actions and protected environments | UNSET | `.github/workflows/` | UNSET |
| Apple Developer and App Store Connect | UNSET | `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md` | UNSET |
| Google Play Console | UNSET | `docs/runbooks/google-play-publishing.md` | UNSET |
| Firebase and GCP production | UNSET | `docs/runbooks/production-deploy-boundaries.md` | UNSET |
| Sentry project administration | UNSET | `docs/runbooks/oncall.md` | UNSET |
| macOS signing and notarization | UNSET | `docs/RELEASE_MACOS.md` | UNSET |
| Windows signing and distribution | UNSET | `docs/windows-port/WINDOWS_PORT_OPERATIONS_RUNBOOK.md` | UNSET |
| Linux package signing and publication | UNSET | `docs/linux-port/cloud-security-runbook.md` | UNSET |
| VS Code Marketplace / Open VSX publication | UNSET | `extensions/openburnbar/README.md` | UNSET |
| Emergency break-glass approval | UNSET | `docs/runbooks/functions-break-glass.md` | UNSET |

## Verification cadence

- Review this inventory at each release handover and after an ownership change.
- A live verification requires the appropriate provider credentials and is
  intentionally not performed by the repository schema check.
