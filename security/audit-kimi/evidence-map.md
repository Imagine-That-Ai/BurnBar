# Evidence Map

## Claims → Code / Tests / Docs

| Claim | Evidence File | Evidence Type | Notes |
|---|---|---|---|
| CLAIM-001 Local-first | `AgentLens/Services/CloudSync/` | Code | Sync service is opt-in |
| CLAIM-002 Cloud sync encrypted | `packages/signal-envelope-contracts/` | Code/Spec | Envelope format |
| CLAIM-003 Server cannot read content | `OpenBurnBarCore/Sources/OpenBurnBarCore/Crypto/` | Code + Tests | Sealing tests |
| CLAIM-004 Tokens never leave keychain | Keychain usage searches | Code | No Firestore writes of tokens |
| CLAIM-005 Owner-scoped Firestore | `firestore.rules`, `functions/src/auth.ts` | Code | App Check console-dependent |
| CLAIM-006 Paid entitlement verified | `functions/src/appstore/verifyAppleJWS.ts` | Code | Apple verification robust |
| CLAIM-007 Computer Use approval | `AgentLens/Services/ComputerUse/` | Code | Tests incomplete |
| CLAIM-008 Kill switches | `OpenBurnBarDaemon/.../KillSwitchWatchdog.swift` | Code | Four paths exist |
| CLAIM-009 Signed releases | `.github/workflows/release.yml` | Config | Strong pipeline |
| CLAIM-010 PII-free logs | `functions/src/logging.ts` | Code | Free-form risk remains |
| CLAIM-011 No upload without consent | Sync opt-in UX | UX | Holds |
| CLAIM-012 MCP scoped | `services/hosted-mcp/src/toolRegistry.ts` | Code | Local MCP gap |
| CLAIM-013 Local DB encrypted | `DatabaseEncryptionService.swift` | Code | Not active |
| CLAIM-014 Sandboxed | `docs/THREAT_MODEL.md` | Doc | Accepted unsandboxed |

## Threats → Controls / Tests

| Threat | Primary Control | Test Evidence | Gap |
|---|---|---|---|
| THREAT-001 | SQLCipher (planned) | `DatabaseEncryptionService.swift` unit tests | Codec not linked |
| THREAT-002 | Firestore owner rules | Firestore rule tests | App Check unverified |
| THREAT-003 | `assertOwnership` | Callable unit tests | BOLA fuzz tests missing |
| THREAT-004 | Delimiter wrappers | Parser tests | Not uniform |
| THREAT-005 | SQLCipher + file protection | — | Not active |
| THREAT-006 | Daemon auth token | — | No capability matrix |
| THREAT-007 | Hosted MCP tokens | `services/hosted-mcp/` tests | Local MCP no gate |
| THREAT-008 | Approval UI | UI tests | Adversarial tests missing |
| THREAT-009 | Escrow/capability tokens | Pairing tests | Binding weak |
| THREAT-010 | Browser scope | — | Origin checks missing |
| THREAT-011 | Signed releases | Release workflow | CI secrets broad |
| THREAT-012 | Rate limits | — | No global limiter |
| THREAT-013 | dataDeletion callable | — | E2E test missing |
| THREAT-014 | Keystore | — | Shared prefs suspected |
| THREAT-015 | Parser limits | — | No caps |
| THREAT-016 | AAD binding | Envelope tests | Partial |
| THREAT-017 | Notification scrubber | — | Verify body |
| THREAT-018 | Sentry scrubber | Mobile tests | Free-form risk |

## Findings → Acceptance Tests

| Finding | Test to Add |
|---|---|
| FINDING-001 | `PRAGMA cipher_version` in Release build; migration test |
| FINDING-002 | Documented acceptance; daemon capability matrix test |
| FINDING-003 | Adversarial Computer Use test suite |
| FINDING-004 | Prompt injection corpus + RAG provenance tests |
| FINDING-005 | Non-attested Firestore REST probe |
| FINDING-006 | Privacy policy diff test |
| FINDING-007 | Daemon RPC authorization matrix test |
| FINDING-008 | Local MCP user-gate test |
| FINDING-009 | Tunnel token entropy + TTL test |
| FINDING-010 | Release workflow two-person rule / OIDC test |
| FINDING-011 | Deployed Firestore rules diff in CI |
| FINDING-012 | Callable rate-limit test |
| FINDING-013 | End-to-end data deletion test |
| FINDING-014 | Android Keystore iroh key test |
| FINDING-015 | AAD tamper test for all envelope variants |
| FINDING-016 | session_logs schema + size validation test |
| FINDING-017 | Parser zip-bomb / max-size test |
| FINDING-018 | dataExport field audit test |
| FINDING-019 | Notification payload PII scan |
| FINDING-020 | HID capability token binding test |
| FINDING-021 | Sentry before-send sensitive data test |
| FINDING-022 | Daemon token rotation test |
