# OpenBurnBar Technical Readiness

One-page diligence snapshot for investors, operators, and senior engineers.

**Evidence snapshot (UTC):** 2026-05-31 — ops code + production 10/10 (`verify-production-ops-plane.sh` green; GCP alerts + health probes live in `burnbar`).

## Scorecard

Scores are **1–10 per category**, not aspirational targets.

| Category | Score | Evidence |
|----------|-------|----------|
| CI / Testing | **8/10** | PR harness runs empty-catch / try? ratchets + rules unit tests for CU + media budget split; full `make ci` remains the merge gate |
| Schema | **10/10** | **13** TypeSpec domains; `./tools/schema-sync/check-drift.sh` includes hand-maintained TS surface gate (PR2) |
| Security | **8/10** | App Check enforced on callables; budget public envelope exposes caps only (no USD); **97** empty catches baseline |
| Ops | **10/10** | Code: `verify-ops-readiness.sh` + `verify-resilience-wiring.sh`. Production: `verify-production-ops-plane.sh` green 2026-05-31 (`check-ops-alerts`, health probes live); [oncall.md](runbooks/oncall.md); ADR [007](architecture/007-ops-notification-plane.md) |
| Architecture | **8/10** | ADR 006 budget split; daemon RPC domain extraction in progress; top service LOC splits scheduled PR4 |
| Documentation | **8/10** | ADRs + automated debt metrics; readiness math matches cited numbers |

## Weighted diligence score

**~87/100** — `round(mean(8, 10, 8, 10, 8, 8) × 10) ≈ 87`. Ops verifiers: `bash scripts/ci/verify-ops-readiness.sh`.

**Not 100/100 because:** **783** `try?` in Services; **97** empty catches; App Check ENFORCED and branch protection are human-only gates; hand-maintained TS surface still **~2864** LOC in `legacy.ts` alone.

**Not counted toward /100:** [`docs/TECH_DEBT_METRICS.md`](TECH_DEBT_METRICS.md) is trend input for monthly reviews, not an auto-scored category.

## Ops production activation (human / CI with GCP auth)

Production **10/10** requires `bash scripts/ops/verify-production-ops-plane.sh` exit 0 in project `burnbar` (`node scripts/ops/check-ops-alerts.mjs` + prod health). One-time apply:

```bash
export GCLOUD_PROJECT=burnbar
export OPS_ALERT_CHANNELS="projects/burnbar/notificationChannels/..."
bash scripts/ops/activate-production-ops-plane.sh
bash scripts/ops/deploy-health-functions.sh
bash scripts/ops/verify-production-ops-plane.sh
```

| Checkpoint | Status (UTC 2026-05-31) |
|------------|-------------------------|
| GCP ops alerts (8 policies) | **PASS** — `check-ops-alerts.mjs` |
| Prod health gate | **PASS** — `healthLive`, `healthReady`, `healthCheck` deployed (`us-central1-burnbar.cloudfunctions.net`) |
| Full verify script | **PASS** — `verify-production-ops-plane.sh` (`ok: true`, `opsAlertsOk: true`) |

Record last **full** green `verify-production-ops-plane.sh` date here: **2026-05-31** (UTC). Weekly check: [ops-plane-verify.yml](../.github/workflows/ops-plane-verify.yml).

## Human-only operator steps

- Firestore App Check → **ENFORCED**: [FIREBASE_APP_CHECK_ENFORCEMENT.md](FIREBASE_APP_CHECK_ENFORCEMENT.md)
- GitHub branch protection + CodeQL: org admin per [GOVERNANCE.md](GOVERNANCE.md)

See [`docs/SOTA_REMEDIATION_PROGRESS.md`](SOTA_REMEDIATION_PROGRESS.md) for phase evidence.
