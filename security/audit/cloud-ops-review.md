# Cloud, Infrastructure, and Operations Review

## J.1 Cloud Asset Inventory

| ID | Resource | Environment | Purpose | Exposed externally | Data stored | IAM permissions | Encryption | Logging | Backup | Owner | Evidence | Gaps |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| CLOUD-001 | Firebase Auth | production/staging likely | identity provider | yes | auth users/tokens | Firebase IAM | provider-managed | provider logs | provider-managed | Cloud/Ops | app and Functions auth code | access review unknown |
| CLOUD-002 | Firebase Functions | production | callable APIs, HTTP/webhooks | yes | transient and logs | service account | provider-managed | structured logs/Sentry | n/a | Backend | `functions/src`, `firebase.json` | edge rate limits incomplete |
| CLOUD-003 | Firestore | production | user data, audit, grants | yes via SDK/rules | user/account/cloud data | rules/admin SDK | provider-managed | Firebase logs | provider-managed | Backend | `firestore.rules` | App Check deployment state unknown |
| CLOUD-004 | Cloud Storage | production | encrypted objects and exports | yes via signed URLs/rules | ciphertext objects | rules/admin SDK | provider-managed plus app crypto | Firebase logs | provider-managed | Backend | `storage.ts:25-93`, `storage.rules` | signed URL TTL review needed |
| CLOUD-005 | Hosted MCP Node service | production | remote MCP gateway | yes | metadata/audit via Firestore | service account | provider/TLS | app audit/logs | platform | Platform | `services/hosted-mcp/src` | deployment/IAM not fully visible |
| CLOUD-006 | Stripe | production | billing | yes | customer/subscription/payment data | Stripe dashboard/API keys | Stripe-managed | Stripe events | Stripe-managed | Business/Ops | `stripe.ts` | dashboard access unknown |
| CLOUD-007 | Sentry | production | crash/error monitoring | yes client/server SDK | scrubbed events | Sentry access | provider-managed | Sentry | provider | Ops | `logging.ts`, `AgentLensApp.swift` | retention/access unknown |
| CLOUD-008 | GitHub Actions | CI/CD | build, scan, deploy | yes | logs/artifacts/secrets | repo/environment perms | GitHub-managed | workflow logs | artifacts retention | Platform | `.github/workflows` | branch protection live state not verified |

## J.2 Production Access Model

Repository evidence:

- Production deploy workflow uses GitHub environment and OIDC permission, but still supports service-account JSON and legacy Firebase token fallback: `.github/workflows/deploy-production.yml:3-6,109-119,193-201`.
- Functions use Firebase params/secrets for Stripe and security config.
- Hosted MCP production posture refuses unsafe HMAC-only token config: `services/hosted-mcp/src/config.ts:29-52`.
- Firestore server-only collections block client access through rules.

Not repo-verifiable:

- Human Firebase/GCP IAM membership.
- Stripe dashboard users and roles.
- Sentry organization access.
- GitHub branch protection and environment reviewers.
- Firebase App Check enforcement state for Firestore.
- Cloud Armor or edge rate-limit policies.
- Break-glass process and access review cadence.

## J.3 Detection and Response

| Threat | Log source | Detection opportunity | Alert | Owner | Containment | Recovery | Missing telemetry |
|---|---|---|---|---|---|---|---|
| THREAT-001 daemon local agent abuse | daemon logs, Computer Use audit | Computer Use action without valid local-auth proof | high-severity local/security alert | Computer Use | halt session, revoke daemon token | rotate local tokens, review audit | proof-required production telemetry |
| THREAT-004 Firestore App Check drift | Firebase config verifier | App Check enforcement off/unknown | release-blocking | Cloud/Ops | disable release, re-enable App Check | rerun verifier | verifier not implemented |
| THREAT-005 public endpoint abuse | Functions logs, edge logs | high request rate, cost spike | rate/cost alert | Cloud/Ops | throttle/block source | tune limit, review logs | edge config not inventoried |
| THREAT-006 deletion without audit | audit log and deletion callable logs | deletion completion missing intent/completion | privacy incident alert | Privacy | pause deletion endpoint | reconstruct from logs if possible | durable intent missing |
| THREAT-007 deploy credential compromise | GitHub audit logs, Firebase deploy logs | unexpected deploy or token use | production deploy alert | Platform | revoke secrets, rollback | rotate keys, attest known-good | WIF-only not enforced |
| THREAT-012 sensitive log leak | Sentry/Firebase log sampling | scrubber miss or raw token pattern | security alert | Ops/Security | disable capture, purge event | patch scrubber, notify if needed | periodic sampling proof |

## Release Ops Readiness

Before production release, run:

- `bash scripts/ci/verify-ops-readiness.sh`
- production App Check deployment verifier once implemented
- public endpoint rate-limit inventory
- deploy workflow secret fallback policy check
- smoke health gate and rollback drill from `.github/workflows/deploy-production.yml`

