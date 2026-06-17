# Privacy, Logging, and Data Governance Review

## Data Governance

| Data type | Purpose | Storage | Deletion/export | Third parties | Risk | Recommendation |
|---|---|---|---|---|---|---|
| Identity/email | account auth | Firebase Auth/Firestore | account deletion dependent | Firebase | medium | document support/admin access |
| Usage/cost | quota and billing | Firestore/Stripe | data domains | Firebase/Stripe | medium | keep domain registry current |
| Conversations/session logs | product history | SQLCipher, Firestore, Storage ciphertext | export/delete domains | Firebase/hosted MCP metadata | high | keep sealed field sanitizer enforced |
| Prompts/model outputs | session history | local/cloud encrypted records | export/delete domains | provider exposure depends on integration | high | never log raw prompt/output by default |
| Provider credentials | integrations | Keychain/secret refs | revoke/delete | providers | critical | maintain Keychain and server secret isolation |
| Billing data | subscription | Stripe/Firestore IDs | Stripe/account | Stripe | high | fix redirect URL validation |
| Remote MCP tokens/grants | MCP access | Firestore hash/local Keychain | revoke paths | hosted MCP/Firebase | high | document rotation |
| Computer Use evidence | approval/audit | audit chain/Firestore/local | retention unknown | Firebase/Sentry if logged | high | classify and minimize evidence |
| Logs/crash reports | ops/security | Firebase logs/Sentry | processor policy | Sentry/Firebase | high | document retention and access review |

## Sensitive Logging Review

| Surface | Classification | Evidence | Notes |
|---|---|---|---|
| Functions structured logs | safe with caveats | `functions/src/logging.ts:16-153` | recursive scrubber redacts tokens, emails/IPs, sensitive keys, UID paths |
| Functions callable wrapper | safe | `logging.ts:228-280` | wrapper uses scrubbed logging and Sentry capture |
| macOS Sentry | safe with caveats | `AgentLens/App/AgentLensApp.swift:1842-1907` | crash consent and sensitive key fragments scrubbed |
| Hosted MCP audit | safe with caveats | `hosted-mcp/src/audit.ts:11-44`, `redaction.ts:1-30` | hashes client/IP/UA/token IDs and redacts token/ciphertext/body fields |
| Data deletion audit | risky | `dataDeletion.ts:105-113` | audit is best-effort for irreversible deletion |
| Computer Use audit | safe with caveats | `ComputerUseAuditChain.swift:81-180` | descriptor hash/audit chain exists; evidence retention policy unknown |

## LINDDUN-Style Privacy Threats

| ID | Category | Scenario | Existing control | Gap | Recommendation |
|---|---|---|---|---|---|
| PRIV-001 | Linking | usage, billing, and session metadata link identities | UID scoping | retention policy unknown | publish retention map |
| PRIV-002 | Identifying | logs include account identifiers | scrubbers and UID path redaction | processor retention unknown | periodic log sampling |
| PRIV-003 | Non-repudiation | audit chain preserves action history | audit chain | deletion audit best-effort | durable deletion audit intent |
| PRIV-004 | Detecting | Computer Use evidence reveals screen contents | approval/audit policy | evidence retention unknown | classify/minimize evidence |
| PRIV-005 | Data disclosure | export signed refs expose ciphertext objects | high-risk proof, sanitizer | signed URL lifetime review | document and test TTL |
| PRIV-006 | Unawareness | broad E2EE wording misleads users | claim register | Signal claim gap | use safe wording |
| PRIV-007 | Non-compliance | deletion completes without audit | confirmation/domain registry | best-effort audit | pre-delete audit intent |

