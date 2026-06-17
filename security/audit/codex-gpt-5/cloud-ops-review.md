# Cloud, Infrastructure, and Operations Review

## Cloud Asset Inventory

| ID | Resource | Purpose | Exposed | Data stored | Evidence | Gaps |
|---|---|---|---|---|---|---|
| CLOUD-001 | Firebase Auth | identity | yes | auth users/tokens | app and Functions auth code | access review unknown |
| CLOUD-002 | Firebase Functions | callable APIs and HTTP/webhooks | yes | transient/logs | `functions/src`, `firebase.json` | edge rate limits incomplete |
| CLOUD-003 | Firestore | user data, audit, grants | yes via SDK/rules | user/account/cloud data | `firestore.rules` | App Check deployment state unknown |
| CLOUD-004 | Cloud Storage | encrypted objects and exports | yes via signed URLs/rules | ciphertext objects | `storage.ts`, `storage.rules` | signed URL TTL review needed |
| CLOUD-005 | Hosted MCP | remote MCP gateway | yes | metadata/audit via Firestore | `services/hosted-mcp/src` | deployment/IAM not fully visible |
| CLOUD-006 | Stripe | billing | yes | customer/subscription/payment data | `stripe.ts` | dashboard access unknown |
| CLOUD-007 | Sentry | crash/error monitoring | yes | scrubbed events | `logging.ts`, `AgentLensApp.swift` | retention/access unknown |
| CLOUD-008 | GitHub Actions | build, scan, deploy | yes | logs/artifacts/secrets | `.github/workflows` | branch protection live state not verified |

## Production Access Model

Repo-proven:

- Production deploy workflow has OIDC permissions and environment use.
- Hosted MCP production posture refuses unsafe HMAC-only token config.
- Firestore client rules block server-only secret paths.

Not repo-verifiable:

- Human Firebase/GCP IAM membership.
- Stripe/Sentry/GitHub dashboard access.
- GitHub branch protection and environment reviewers.
- Firebase App Check enforcement state for Firestore.
- Cloud Armor or edge rate-limit policies.
- Break-glass process and access review cadence.

## Detection and Response

| Threat | Log source | Detection | Missing telemetry |
|---|---|---|---|
| THREAT-001 | daemon logs and Computer Use audit | action without local-auth proof | proof-required production telemetry |
| THREAT-004 | Firebase config verifier | App Check enforcement off/unknown | verifier not implemented |
| THREAT-005 | Functions and edge logs | high request rate/cost spike | edge config not inventoried |
| THREAT-006 | audit log and deletion callable logs | deletion without intent/completion | durable intent missing |
| THREAT-007 | GitHub and Firebase deploy logs | unexpected deploy or secret use | WIF-only not enforced |
| THREAT-012 | Sentry/Firebase log sampling | scrubber miss or raw token pattern | periodic sampling proof |

