# OpenBurnBar Accepted Risk Register

This register is the boundary between **accepted product risk** and **technical
debt**. A risk listed here is not "done forever"; it is a named decision with an
owner, compensating controls, and an annual review date. Anything not listed
here must be fixed, tracked in the active remediation plan, or explicitly added
with the same bar.

Review cadence: at least annually, and immediately before any public launch,
store submission, or material security claim that depends on the affected
surface.

| ID | Risk | Decision | Owner | Next review | Evidence | Compensating controls |
| --- | --- | --- | --- | --- | --- | --- |
| AR-001 | Direct-download macOS app is intentionally unsandboxed. | Accepted for the Developer ID direct-download channel because OpenBurnBar must read local AI-agent logs and coordinate local automation across user-selected workspaces. This is not accepted for the Mac App Store build. | Engineering owner | 2027-06-13 | `AgentLens/Resources/OpenBurnBar.entitlements`; `docs/THREAT_MODEL.md`; `docs/RELEASE_MACOS.md` | Developer ID signing, notarization, Gatekeeper, Keychain storage, explicit user grants for high-risk Computer Use, and a separate sandboxed MAS build with system-level Computer Use compiled out. |
| AR-002 | **Retired 2026-06-14:** user avatars were readable by any authenticated user. | No longer accepted: direct Storage SDK reads for `avatars/{uid}/profile.jpg` are owner-only. The current product only refreshes the signed-in user's own signed display URL; any future cross-user avatar sharing must use a relationship-scoped callable instead of reopening bucket reads. | Engineering owner | 2027-06-14 | `storage.rules`; `functions/src/callables/profileAvatar.ts`; `OpenBurnBarMobile/Services/ProfileAvatarService.swift`; `functions/src/accountDeletion.ts` | Owner-only read/write rules, bounded signed URL issuance for the current user, account deletion removes `avatars/{uid}`, and docs now prohibit direct bucket-read expansion for relationship display. |
| AR-003 | VS Code extension package is not signed/published by CI. | Accepted while the extension remains source-first / local-install oriented. This is not accepted for marketplace launch or enterprise distribution. | Engineering owner | 2027-06-13 | `docs/security/SECURITY_REMEDIATION_2026-06-09.md` L-5; `extensions/openburnbar/` | Extension code is in the public repo, dependency/security gates run in CI, and marketplace release requires replacing this entry with a signed `vsce package` + publish lane. |
| AR-004 | Legacy or reserved store product IDs must remain documented even when inactive. | Accepted because Apple/Google product IDs are immutable once used or reserved; deleting references can break receipt reconciliation, restore flows, or launch forensics. | Engineering owner | 2027-06-13 | `docs/runbooks/computer-use-asc-submission-status.md`; `docs/COMMERCIAL_ROLLBACK.md`; `docs/HERMES_COMPUTER_USE.md`; `functions/src/appstore/config.ts` | Active IDs are tested by store/reconciler tests and commercial launch gates; inactive IDs must stay labeled as legacy/reserved, not active SKUs. |
| AR-005 | Mac System Computer Use is direct-download only. | Accepted because Accessibility, CGEvent dispatch, helper installation, and privileged-input paths are incompatible with the Mac App Store sandbox. MAS must ship Path A/B only, with Path C compiled out. | Engineering owner | 2027-06-13 | `docs/runbooks/computer-use-app-store.md`; `docs/RELEASE_MACOS.md`; `AgentLens/Services/ComputerUse/Mac/MacInputController.swift`; `AgentLens/Views/ComputerUse/ComputerUseSettingsView.swift` | `DISTRIBUTION_MAS` compile guards, MAS build proof, direct-download notarization, LocalAuthentication for high-risk grants, audit trails, panic stops, and privileged-socket red-team coverage. |
| AR-006 | Cursor connector may use a Cloudflare quick tunnel for remote OpenAI-compatible routing. | Accepted for the opt-in developer connector while the product ships loopback-only secret brokering, per-session bearer tokens, fail-closed unauthenticated endpoint probes, and a C-5-pinned auditable gateway router. Named tunnels with Cloudflare Access are required before enterprise or untrusted-network positioning. | Engineering owner | 2027-06-13 | `docs/security/SECURITY_REMEDIATION_2026-06-09.md` H-4; `AgentLens/Services/CursorConnector/CursorConnectorManager.swift`; `third_party/hermes-agent/manifest.json`; [`PHASE1_SECURITY_REGISTER.md`](PHASE1_SECURITY_REGISTER.md) H-4 row | Secret broker listens on `127.0.0.1` only; tunnel rotation token is session-scoped; public URL probe rejects endpoints that return HTTP 200 without auth; gateway source is hash-pinned and verified in CI. |
| AR-007 | SOTA 10/10 human signoff is not yet signed. | Accepted until a named engineering owner and security reviewer sign `docs/security/SOTA_10_10_SIGNOFF.md`. Automated gates (`verify-phase1-security-gates.sh`, `verify-ops-readiness.sh`, security-pr, nightly red-team) are the interim compensating controls; they do not replace human attestation for investor or marketing claims. | Engineering owner | 2027-06-13 | [`docs/security/SOTA_10_10_SIGNOFF.md`](../security/SOTA_10_10_SIGNOFF.md); [`PHASE1_SECURITY_REGISTER.md`](PHASE1_SECURITY_REGISTER.md) AR-007 row | Do not claim “SOTA security” publicly until signatures land; commercial launch gate and security registers remain the enforcement surface until then. |

## Adding Or Retiring Entries

- Add a risk only when the product decision is intentional and the compensating
  controls are real today.
- Retire a risk when the underlying behavior is removed, fully mitigated, or
  converted into a normal remediation item.
- Do not use this register for temporary workarounds, failing gates, stale
  baselines, missing tests, or "we will fix it later" items. Those remain debt.
