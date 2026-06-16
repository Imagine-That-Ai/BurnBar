# Cloud, Infrastructure, and Operations Review

## J.1 Cloud Asset Inventory

| Resource | Environment | Purpose | Exposed | Data Stored | IAM | Encryption | Backup | Evidence |
|----------|-------------|---------|---------|-------------|-----|------------|--------|----------|
| Cloud Functions | us-central1 | Callable endpoints, triggers, scheduled jobs | HTTPS (authenticated) | None (stateless) | WIF (id-token) | N/A | N/A | `functions/src/index.ts` |
| Firestore | us-central1 | Primary database | Rules-enforced | User data (E2E encrypted) | Admin SDK | Google-managed at rest | Point-in-time recovery | `firestore.rules` |
| Cloud Storage | us-central1 | Encrypted blobs | Rules-enforced | Encrypted session blobs | Admin SDK | Google-managed + client AEAD | Multi-region | `storage.rules` |
| Cloud KMS | us-central1 | Provider credential encryption | No | Key material | Separate key ring | HSM-backed | Google-managed | `.env.burnbar.production:KMS_KEY_NAME` |
| Secret Manager | us-central1 | API secrets | No | Provider credentials | WIF | Google-managed | Google-managed | `functions/src/secrets.ts` |
| App Check | Firebase | Client attestation | No | Attestation tokens | Console-managed | N/A | N/A | `appCheckAttestation.ts` |

## J.2 Production Access Model

- **Deploy:** GitHub Actions with Workload Identity Federation (`id-token: write` + `google-github-actions/auth`). No long-lived service account keys.
- **Functions deploy:** Tag-gated; emulator-tested rules; `check-firestore-deploy-drift.mjs` detects drift
- **Rules deploy:** `deploy-firebase-rules-releases.mjs` with release tagging
- **Rollback:** `scripts/rollback.sh` reads `functions/.env.burnbar.production` for source-safe rollback
- **Break-glass:** Firebase Console / gcloud (documented in `docs/runbooks/`)
- **Admin data access:** Firebase Console only (no admin callables in code)
- **Secret access:** Secret Manager via WIF only
- **Logging:** Cloud Logging (scrubbed), Sentry (scrubbed)
- **Gap (UNKNOWN-008):** Branch protection on main not verified live

## J.3 Detection and Response

| Threat | Log Source | Detection | Alert | Gap |
|--------|-----------|-----------|-------|-----|
| Cross-tenant access | Firestore audit logs | Rules deny + BOLA tests | Console alerts | No real-time alerting configured in code |
| Unauthorized callable | Functions logs | Auth failure logs | Sentry captureException | Adequate |
| Agent action abuse | Audit chain | SHA-256 tamper detection | App UI warning | No server-side monitoring of audit anomalies |
| Kill switch activation | Local filesystem | OS event monitoring | App notification | Adequate |
| Vault key rotation | Firestore rotation job | Job status tracking | App notification | Adequate |
| Payment fraud | Stripe webhook | Signature verification | Stripe dashboard | Adequate |
| Supply chain compromise | CI logs, dependency scan | OSV-Scanner, npm audit, cargo-audit | CI failure | Adequate |
| Push token abuse | Firestore device docs | Invalidation on failure | N/A | Adequate |

## J.4 Post-Deploy Health Gates

- `post-deploy-health-gate.sh` — post-deploy health verification + auto-rollback trigger
- `verify-ops-readiness.sh` — pre-release ops gate
- `verify-production-ops-plane.sh` — production plane verification
- `verify-firestore-ttl-state.mjs` — deploy-time TTL state readback (I6 gate)
- `check-firestore-deploy-drift.mjs` — rules drift detection

## J.5 Single Region Risk (Accepted)

- **Current:** Single `us-central1` for all Cloud Functions and Firestore
- **Accepted rationale:** US-heavy user base pre-launch (documented in `SECURITY.md`)
- **Revisit trigger:** Sustained non-US traffic or cross-region latency
- **Realtime transport:** iroh P2P with Firestore fallback (former Cloud Run WebSocket relay retired 2026-05-28)
