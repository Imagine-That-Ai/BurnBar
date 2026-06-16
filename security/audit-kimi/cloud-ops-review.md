# Cloud Infrastructure and Operations Review

## A.9.1 Infrastructure

- **Platform**: Firebase (Cloud Functions v2, Firestore, Firebase Storage, Firebase Auth, App Check, Cloud Messaging, Remote Config).
- **Project structure**: Production project presumed; no source-of-truth IaC visible in repo.
- **Secrets**: Injected via GitHub Actions; no Secret Manager usage visible.
- **IAM**: Default service account used by Functions; no custom IAM constraints visible.

## A.9.2 Firestore Security

- `firestore.rules` is the primary tenant-isolation control.
- `firestore.rules` is deployed via `firebase deploy`; drift risk exists.
- `hasNoPlaintextSecretFields` validator prevents accidental plaintext secret writes.
- `ops/` collection gated by custom claim `operator`.

### Rule Gaps

- App Check enforcement is a console toggle.
- No rate-limiting or abuse budgets in rules.
- `session_logs` path shape must be carefully maintained.

## A.9.3 Monitoring and Alerting

- Sentry integrated for functions and clients.
- Cloud Logging with structured logs.
- Cloud Monitoring dashboards mentioned in docs/runbooks.
- No obvious alerting on auth anomaly, App Check failures, or Computer Use kill-switch usage.

## A.9.4 Incident Response

- `docs/runbooks/` contains SLOs, rollback, and incident runbooks.
- Remote Config kill switch for Computer Use.
- No documented secret-rotation runbook for leaked CI signing keys.

## A.9.5 Production Deploy

- `.github/workflows/deploy-production.yml` deploys functions.
- Release workflow (`release.yml`) signs and notarizes macOS binaries.
- Android/iOS CI uses injected Firebase configs and keystores.

## A.9.6 Prior Audit Items (Cloud/Ops)

| ID | Title | Status | Notes |
|---|---|---|---|
| M-017 | Rate limiting missing | Open | Add Cloud Armor / API gateway or function-level throttling |
