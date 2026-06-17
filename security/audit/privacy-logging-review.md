# Privacy, Logging, and Data Governance Review

## I.1 Data Governance Table

| Data type | Purpose | Collection point | Storage location | Retention | Deletion | Third parties | User visibility/control | Risk | Recommendation |
|---|---|---|---|---|---|---|---|---|---|
| Identity and email | account auth and support | Firebase Auth/client sign-in | Firebase Auth/Firestore | unknown production policy | account deletion dependent | Firebase | account UI | medium | document retention and support access |
| Usage and cost data | quota, billing, analytics | clients/Functions | Firestore | product-defined | data deletion domains | Firebase, possibly Stripe | visible in app/export | medium | keep data domain registry current |
| Conversation/session logs | product value and history | local app/imports/cloud sync | SQLCipher, Firestore, Storage ciphertext | unknown | export/delete domains | Firebase, hosted MCP metadata | export/delete | high | keep end-to-end field sanitizer enforced |
| Prompts/model outputs | session history | local/cloud sync | encrypted local/cloud records | unknown | export/delete domains | model/provider exposure depends on integrations | export/delete | high | never log raw prompt/output by default |
| Provider credentials | integrations | user settings/auth | Keychain/secret refs | until revoke/delete | delete/revoke | providers | settings | critical | maintain Keychain and server secret isolation |
| Billing data | subscription | Stripe flows | Stripe/Firestore IDs | Stripe policy | Stripe/account | Stripe | portal | high | fix redirect URL validation |
| Remote MCP tokens/grants | MCP access | grant callable | Firestore hash/local Keychain | 15m access, grant expiry | revoke paths | hosted MCP/Firebase | settings/revoke | high | document rotation and revoke UX |
| Computer Use evidence | approval/audit | app/mobile/daemon | audit chain/Firestore/local | unknown | not fully reviewed | Firebase/Sentry if logged | action history | high | ensure screenshots/evidence are redacted and retained intentionally |
| Logs/crash reports | operations/security | Functions/apps/services | Firebase logs/Sentry | processor policy | processor policy | Sentry/Firebase | generally not user controlled | high | document retention and access review |

## I.2 Sensitive Logging Review

| Surface | Classification | Evidence | Notes |
|---|---|---|---|
| Functions structured logs | safe with caveats | `functions/src/logging.ts:16-153` | recursive scrubber redacts tokens, email/IP strings, sensitive keys, UID paths |
| Functions callable wrapper | safe | `logging.ts:228-280` | Sentry capture goes through callable logging wrapper |
| Sentry macOS | safe with caveats | `AgentLens/App/AgentLensApp.swift:1842-1907` | crash consent, anonymized install ID, sensitive key fragments scrubbed |
| Android Sentry | safe with caveats | `android/app/src/main/java/com/openburnbar/SentryPrivacyScrubber.kt` | privacy scrubber exists; not deeply retested here |
| Hosted MCP audit | safe with caveats | `hosted-mcp/src/audit.ts:11-44`, `redaction.ts:1-30` | hashes client/IP/UA/token IDs and redacts token/ciphertext/body fields |
| Data deletion audit | risky | `dataDeletion.ts:105-113` | audit is best-effort for irreversible deletion |
| Computer Use audit | safe with caveats | `ComputerUseAuditChain.swift:81-180` | descriptor hash/audit chain exists; screenshot/evidence retention needs policy confirmation |

Search targets reviewed:

- passwords, tokens, cookies, API keys, authorization headers
- prompts/model outputs and body/ciphertext fields
- payment data and signed URLs
- database URLs and OAuth codes

No committed secret or broad sensitive log issue was confirmed in the inspected evidence. Continue to rely on gitleaks and log scrubber tests.

## I.3 Privacy Threat Model

| ID | Category | Scenario | User harm | Business harm | Existing control | Gap | Recommendation |
|---|---|---|---|---|---|---|---|
| PRIV-001 | Linking | Usage, billing, and session metadata link identities across surfaces | profiling | procurement/privacy risk | UID scoping, export domains | retention policy unknown | publish retention map |
| PRIV-002 | Identifying | Logs include account identifiers or raw paths | unwanted identification | breach notification scope | log scrubbers and UID path redaction | processor retention unknown | run periodic log sampling review |
| PRIV-003 | Non-repudiation | Audit chain preserves high-risk action history | user action traceability | compliance benefit/risk | tamper-evident audit | deletion audit best-effort | durable deletion audit intent |
| PRIV-004 | Detecting | Computer Use evidence may reveal screen contents | sensitive workspace disclosure | support/audit sensitivity | approvals/audit policy | evidence retention unknown | classify and minimize evidence |
| PRIV-005 | Data disclosure | Export/signed refs expose ciphertext objects | temporary access exposure | breach risk | high-risk proof, sealed field sanitizer, signed URL refs | signed URL lifetime not fully reviewed | document max TTL and test it |
| PRIV-006 | Unawareness | Broad E2EE wording could mislead users | false expectations | legal/procurement issue | claim register and this audit | Signal claim gap | use safe claim wording |
| PRIV-007 | Non-compliance | Deletion completes without audit record | evidence gap | compliance dispute | confirmation/domain registry | best-effort audit | pre-delete audit intent |

