# Cloud and Operations Threat Model

Repository evidence shows Firebase Functions, Firestore, Storage, KMS/Secret Manager, Sentry, APNs/FCM, GitHub Actions, and hosted MCP. Live cloud state was not verified.

## Cloud Asset Inventory

| Resource | Purpose | Environment | Exposed externally | Data stored | IAM/security | Encryption | Logs/backup | Owner | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Firebase Functions | Callables/HTTP APIs, Gateway, provider, MCP grants | prod/dev unknown | yes | metadata, request bodies, secret refs | Firebase Auth/App Check/code checks | TLS; app crypto for sealed content | Cloud logs/Sentry | Backend | `functions/src/index.ts`, `auth.ts` |
| Firestore | App metadata, device graph, envelopes, audit, encrypted search | prod/dev unknown | client SDK + Admin SDK | metadata/ciphertexts/indexes | rules for clients; Admin SDK bypass | GCP at rest; client sealing for selected data | GCP logs/backups unknown | Backend | `firestore.rules` |
| Firebase Storage | Attachments/session bodies/avatars | prod/dev unknown | signed URL/SDK | ciphertext blobs, avatars | rules and signed URLs | GCP at rest; client-side sealing for selected data | Storage logs/backups unknown | Backend | `storage.rules`, `encryptedSearch.ts` |
| KMS | Wrap provider credential DEKs | prod unknown | no direct public | encrypted DEKs | IAM unknown | KMS | Cloud audit unknown | Ops | `functions/src/secrets.ts` |
| Secret Manager | Store provider credential envelopes | prod unknown | no direct public | encrypted provider credentials | IAM unknown | KMS/envelope | version destroy | Ops | `functions/src/secrets.ts` |
| Hosted MCP service | Remote MCP API | unknown | yes | token/audit access to cloud resources | bearer/scopes/entitlements | TLS; sealed result bodies | hosted audit | Backend | `services/hosted-mcp/src/*` |
| Sentry | Error reporting | prod/dev | yes via SDK | sanitized errors | DSN/env | TLS/provider | provider retention | Ops | `functions/src/sentry.ts` |
| APNs/FCM | Push notifications | prod/dev | yes | push tokens/payload metadata | platform creds | TLS/provider | provider retention | Mobile | mobile notification code |
| GitHub Actions | CI/CD/release/deploy | GitHub | yes to repo collaborators | secrets/artifacts/logs | GitHub permissions/envs | GitHub | workflow logs/artifacts | Eng/Ops | `.github/workflows/*` |

## Production Access Model

Repository-supported facts:

- Functions enforce Firebase Auth/App Check and ownership in many callables.
- Production-looking configs fail closed if App Check or high-risk nonce enforcement is disabled.
- Provider credentials are stored through Secret Manager/KMS envelope code.
- Release/deploy workflows use GitHub environments/secrets and GCP auth; some legacy token fallbacks remain.

Unknown/live evidence required:

- Who has GCP project owner/editor/admin roles.
- Who can read Secret Manager versions or decrypt KMS keys.
- Who can deploy Functions, rules, Storage, or hosting.
- Whether break-glass access exists and is logged.
- Whether production support/admin data reads are audited and reviewed.
- Whether branch protection and environment approvals are enforced.
- Whether logs are immutable/tamper-resistant.
- Whether backups are encrypted, access-controlled, and restore-tested.

## NIST CSF 2.0 Mapping

| Function | Existing evidence | Gap |
| --- | --- | --- |
| Govern | Security claims docs, threat model docs, CI gates | Owner/risk acceptance process not proven |
| Identify | Assets and components inventoried in repo | Live cloud asset/IAM inventory missing |
| Protect | Auth/App Check, rules, KMS, sealing, CI gates | Complete least privilege and local sandboxing missing |
| Detect | Sentry/logging/audit, security-pr gates | Detection rules and alert owners incomplete |
| Respond | Panic/revocation flows, docs | Incident playbooks and drills not proven |
| Recover | Release/deploy workflows; some DR docs referenced | Backup/restore integrity not proven |

## Zero Trust Review

| Principle | Assessment |
| --- | --- |
| Identity-centered access | Strong in many callables; local daemon uses peer auth; hosted MCP scopes exist. |
| Least privilege | Partial; local MCP and YOLO/shell grants are broad; live IAM not proven. |
| Assume breach | Partial; sealed content limits cloud plaintext exposure, but metadata/admin risk remains. |
| Continuous evaluation | Partial; App Check/nonces/PoP replay; no full anomaly system proven. |
| Explicit authorization | Partial; full endpoint matrix still needed. |
| Device posture | App Check/trusted-device proof for high-risk cloud actions; local endpoint compromise remains residual. |

## Detection and Response

| Threat | Log source | Detection | Alert owner | Response | Forensics | Containment | User notice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Relay compromise | Gateway logs, Firestore writes, PoP replay errors | unusual message replay/drop/metadata access | Backend/Ops | rotate deploy creds, freeze Gateway writes, inspect logs | Firestore event docs, Cloud logs | revoke tokens, disable Gateway endpoints | likely if metadata/content risk |
| Provider credential compromise | Secret Manager/KMS audit, provider usage | secret read spikes, provider spend anomaly | Ops/Sec | rotate provider key, destroy secret version | KMS/Secret logs, provider logs | suspend provider account route | if user keys affected |
| Cross-user access bug | Function logs, rule test failures, Sentry | denied/allowed mismatch, IDOR test fail | Backend/Sec | patch authz, deploy rules, revoke sessions | request ids, uid/object ids | disable affected callable | likely |
| Rogue agent/tool misuse | local audit, daemon journals, hosted MCP audit | high-risk action pattern, shell/desktop bursts | Desktop/Sec | halt run, revoke grants, collect audit | parent-hash audit, run journal | kill daemon/session, disable tool | user-specific |
| Memory poisoning | memory audit/provenance (missing) | canary instruction retrieved or written | AI/Sec | quarantine memory, purge source | memory record provenance | disable memory ingestion | if sensitive/persistent |
| CI/CD compromise | GitHub audit/workflow logs, artifact attestation | unexpected workflow, unpinned action change | Eng/Ops | stop releases, rotate secrets | workflow logs, artifact hashes | revoke tokens, invalidate releases | if shipped artifact |
| KMS/IAM abuse | Cloud audit logs | admin secret/decrypt access outside deploy path | Ops/Sec | revoke role, rotate keys | audit logs | disable key, rotate secrets | if user/provider data affected |

## Minimum Ops Evidence Before Audit

1. Export GCP IAM role bindings for Firebase, KMS, Secret Manager, Storage, Firestore, Cloud Logging.
2. Export Firebase App Check enforcement status.
3. Export deployed Firestore and Storage rules hashes.
4. Export active Functions config and environment-sensitive flags.
5. Export GitHub branch protection, rulesets, environment reviewers, and secret access.
6. Provide incident-response runbooks and pager/owner mapping.
7. Provide backup/restore design and latest restore test evidence.
8. Provide production access review and break-glass process.
