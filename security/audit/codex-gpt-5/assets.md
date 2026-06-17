# Asset and Data Inventory

| ID | Name | Location at rest | In transit | C/I/A | Privacy | Controls | Gaps | Evidence |
|---|---|---|---|---|---|---|---|---|
| ASSET-001 | User identity | Firebase Auth, Firestore, local auth cache | HTTPS/Firebase SDK | high/high/high | high | Firebase Auth, passkey verification, owner rules | production IAM unknown | `functions/src/auth.ts`, `passkey.ts` |
| ASSET-002 | Local encryption keys | Keychain, local shim Keychain | local memory/IPC | critical/high/high | high | ThisDeviceOnly Keychain, recovery bundle | SQLCipher persistence fail-open | `DatabaseEncryptionService.swift`, `vaultStore.ts` |
| ASSET-003 | Provider/API credentials | Keychain, server secret refs | local/client/server APIs | critical/high/medium | high | Keychain, rules read/write false | admin access unknown | `firestore.rules:1373-1374` |
| ASSET-004 | Conversations, prompts, outputs, session logs | SQLCipher, Firestore, Storage ciphertext | Firebase/MCP/local | critical/high/medium | high | AES-GCM AAD, export sanitizer | universal Signal/E2EE claim unsafe | `CloudVaultCrypto.swift`, `dataExport.ts` |
| ASSET-005 | Usage, quota, entitlement | Firestore, Stripe | HTTPS/Firebase/Stripe | medium/high/high | medium | owner rules, server computed entitlement | retention SLA unknown | `firestore.rules`, `stripe.ts` |
| ASSET-006 | Remote MCP tokens/grants | Firestore hash, local Keychain | HTTPS bearer | high/high/high | medium | Ed25519/HMAC posture, refresh rotation, scopes | signer rotation runbook unknown | `hosted-mcp/src/auth.ts`, `oauthToken.ts` |
| ASSET-007 | Daemon tokens | token file/local process config | loopback/Unix socket | high/high/high | low | constant-time compare, fail-closed config | rotation UX unknown | `OpenBurnBarDaemonServer.swift` |
| ASSET-008 | Computer Use approvals/audit | Firestore/local audit chain | Firebase/local RPC | critical/critical/high | high | capability gate, phone authority, audit chain | daemon proof and context gaps | `ComputerUseCapabilityGate.swift`, `ComputerUseService.swift` |
| ASSET-009 | Firestore/Storage user data | Firestore/Storage | Firebase SDK/HTTPS | high/high/high | high | owner rules, server-only paths | App Check deployment state unknown | `firestore.rules`, `storage.ts` |
| ASSET-010 | CI secrets/artifacts | GitHub secrets/artifacts | GitHub/GCP/Firebase | critical/critical/high | low | scans, pinned actions, provenance | long-lived deploy fallback | `.github/workflows/` |
| ASSET-011 | Device/push tokens | Firestore/platform stores | Firebase/APNs/FCM | medium/high/medium | medium | owner scoping/schema validation | retention unknown | mobile/device rule paths |
| ASSET-012 | Billing data | Stripe, Firestore IDs | HTTPS/Stripe webhook | high/high/high | high | webhook signature, idempotency | return URL validation bug | `stripe.ts` |
| ASSET-013 | Logs, crash reports, audit telemetry | Firebase logs, Sentry, Firestore audit logs | HTTPS | high/high/medium | high | recursive scrubbers, Sentry beforeSend, audit chain | access/retention unknown | `logging.ts`, `auditLog.ts` |

