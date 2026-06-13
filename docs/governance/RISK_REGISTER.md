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
| AR-002 | User avatars are readable by any authenticated user. | Accepted only for user-visible identity surfaces where profile photos are intentionally shared across collaboration/linking flows. Private user content must not use this storage prefix. | Engineering owner | 2027-06-13 | `docs/security/SECURITY_REMEDIATION_2026-06-09.md` L-2; `functions/src/accountDeletion.ts`; `storage.rules` | Avatar objects are scoped under `avatars/{uid}`, account deletion removes the prefix, and any future private avatar mode must use owner-scoped reads or signed URLs from a callable. |
| AR-003 | VS Code extension package is not signed/published by CI. | Accepted while the extension remains source-first / local-install oriented. This is not accepted for marketplace launch or enterprise distribution. | Engineering owner | 2027-06-13 | `docs/security/SECURITY_REMEDIATION_2026-06-09.md` L-5; `extensions/openburnbar/` | Extension code is in the public repo, dependency/security gates run in CI, and marketplace release requires replacing this entry with a signed `vsce package` + publish lane. |
| AR-004 | Legacy or reserved store product IDs must remain documented even when inactive. | Accepted because Apple/Google product IDs are immutable once used or reserved; deleting references can break receipt reconciliation, restore flows, or launch forensics. | Engineering owner | 2027-06-13 | `docs/runbooks/computer-use-asc-submission-status.md`; `docs/COMMERCIAL_ROLLBACK.md`; `docs/HERMES_COMPUTER_USE.md`; `functions/src/appstore/config.ts` | Active IDs are tested by store/reconciler tests and commercial launch gates; inactive IDs must stay labeled as legacy/reserved, not active SKUs. |
| AR-005 | Mac System Computer Use is direct-download only. | Accepted because Accessibility, CGEvent dispatch, helper installation, and privileged-input paths are incompatible with the Mac App Store sandbox. MAS must ship Path A/B only, with Path C compiled out. | Engineering owner | 2027-06-13 | `docs/runbooks/computer-use-app-store.md`; `docs/RELEASE_MACOS.md`; `AgentLens/Services/ComputerUse/Mac/MacInputController.swift`; `AgentLens/Views/ComputerUse/ComputerUseSettingsView.swift` | `DISTRIBUTION_MAS` compile guards, MAS build proof, direct-download notarization, LocalAuthentication for high-risk grants, audit trails, panic stops, and privileged-socket red-team coverage. |

## Adding Or Retiring Entries

- Add a risk only when the product decision is intentional and the compensating
  controls are real today.
- Retire a risk when the underlying behavior is removed, fully mitigated, or
  converted into a normal remediation item.
- Do not use this register for temporary workarounds, failing gates, stale
  baselines, missing tests, or "we will fix it later" items. Those remain debt.
