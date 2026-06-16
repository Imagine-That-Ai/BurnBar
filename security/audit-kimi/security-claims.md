# Security Claims Matrix

## A.4.1 Claims

| ID | Claim | Evidence Location | Current Verdict | Finding / Note |
|---|---|---|---|---|
| CLAIM-001 | Local agent logs are stored only on the user's device unless cloud sync is enabled. | `docs/THREAT_MODEL.md`, `AgentLens/Services/CloudSync/`, local-first design | **Holds** | Sync opt-in explicit |
| CLAIM-002 | Cloud sync is opt-in and encrypted. | `AgentLens/Services/CloudSync/`, Cloud Vault, Signal envelopes | **Holds with caveats** | Content sealed; metadata visible (FINDING-006) |
| CLAIM-003 | BurnBar servers cannot read private synced content. | `packages/signal-envelope-contracts/`, `OpenBurnBarCore/Crypto/`, tests | **Holds for sealed fields** | Design is E2EE-style |
| CLAIM-004 | Provider API tokens never leave the local keychain. | Keychain usage in app; no Firestore writes of plaintext tokens | **Mostly holds** | Check token input flows for accidental logs |
| CLAIM-005 | Firestore access is restricted to the authenticated owner. | `firestore.rules`, `functions/src/auth.ts` | **Holds in code** | App Check enforcement is console-dependent (FINDING-005) |
| CLAIM-006 | Paid features require valid entitlement verified server-side. | `functions/src/appstore/`, `functions/src/callables/stripe.ts` | **Holds in code** | Apple/Google key config is operational |
| CLAIM-007 | Computer Use actions require user approval. | `AgentLens/Services/ComputerUse/`, `docs/HERMES_COMPUTER_USE.md` | **Partially holds** | Adversarial test coverage incomplete (FINDING-003) |
| CLAIM-008 | Computer Use sessions can be killed instantly via multiple paths. | Kill-switch code, docs | **Holds** | Four independent paths exist |
| CLAIM-009 | Release binaries are signed, notarized, and attested. | `.github/workflows/release.yml`, cosign | **Holds** | CI compromise remains a residual risk (FINDING-010) |
| CLAIM-010 | Logs/telemetry do not contain PII. | `functions/src/logging.ts`, `OpenBurnBarMobile/App/MobileSentryScrubber.swift` | **Mostly holds** | Free-form crash context could leak fragments |
| CLAIM-011 | The app does not upload agent session content without user consent. | Sync opt-in UX | **Holds** | — |
| CLAIM-012 | MCP tool access is scoped to account and entitlement. | `services/hosted-mcp/src/`, `functions/src/callables/remoteMcp.ts` | **Mostly holds** | Local MCP lacks human gate (FINDING-008) |
| CLAIM-013 | Local database is encrypted at rest. | `DatabaseEncryptionService.swift`, SQLCipher references | **Not proven** | SQLCipher not active (FINDING-001) |
| CLAIM-014 | The app is sandboxed. | `project.yml`, README | **False / accepted risk** | Unsandboxed by design (FINDING-002) |

## A.4.2 Hard Caps Applied

| Cap | Condition | Applied? | Result |
|---|---|---|---|
| Catastrophic Cap | Critical severity issue in a core claim without remediation path | Considered | Not applied alone because the plaintext DB is accepted in docs and has a known remediation path; still drove top risk ranking. |
| Major Claim Cap | Multiple major claims depend on operational/console settings or lack complete evidence | **Yes** | Raw 67 → capped at 59 because of CLAIM-005, CLAIM-007, CLAIM-012, and CLAIM-013. |
