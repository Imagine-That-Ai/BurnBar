# On-call runbook

Operator contract for production incidents across macOS, daemon, Cloud Functions, and hosted sidecars.

## Notification plane

| Layer | Role | Setup |
|-------|------|--------|
| **GCP Cloud Monitoring** | Primary paging (SLO + cost) | `bash scripts/ops/activate-production-ops-plane.sh` (idempotent; sets metrics + policies) |
| **Sentry** | Exception grouping + release health | `SENTRY_DSN` on Functions; copy-paste rules in [SENTRY_ALERT_RULES.md](../ops/SENTRY_ALERT_RULES.md) |
| **GitHub** | Deploy + rollback | [deploy-production.yml](../../.github/workflows/deploy-production.yml), [rollback-automation.md](rollback-automation.md) |

Store notification channel resource names in GitHub secrets:

- `OPS_ALERT_CHANNELS` — comma-separated Monitoring channel IDs (Slack, email, or PagerDuty-via-GCP)
- `OPS_SLACK_CHANNEL_ID` / `OPS_EMAIL_CHANNEL_ID` — optional aliases documented for operators

## Severity matrix

| Tier | Signal | Action |
|------|--------|--------|
| **P0** | healthReady 503, mass callable_error, circuit breaker open | Stop deploys; rollback Functions if post-tag deploy; [COMMERCIAL_ROLLBACK.md](../COMMERCIAL_ROLLBACK.md) |
| **P1** | Firestore read spike, Hosted MCP 5xx | Triage dashboards; Remote Config kill switches |
| **P2** | Warning SLO burn (25% budget / 7d) | `#ops` thread; defer feature flags |

## Activation (one-time per project)

```bash
bash scripts/ops/discover-gcp-access.sh
export GCLOUD_PROJECT=burnbar
export OPS_ALERT_CHANNELS="projects/burnbar/notificationChannels/..."
bash scripts/ops/activate-production-ops-plane.sh
bash scripts/ops/deploy-health-functions.sh
```

## First 15 minutes

1. Grab `trace_id` from user report or Cloud Logging (`jsonPayload.trace_id`).
2. `bash scripts/ops/verify-production-ops-plane.sh` — JSON summary includes `opsAlertsOk`, `launchGateVerdict`, and step pass/fail.
3. Or ad hoc: `node scripts/ops/check-ops-alerts.mjs` then `bash scripts/ci/post-deploy-health-gate.sh`.

For faster local health loops: `HEALTH_GATE_RETRIES=3 HEALTH_GATE_SLEEP_SEC=5 bash scripts/ci/post-deploy-health-gate.sh`
4. If Functions regression: `./scripts/rollback.sh --dry-run` then rollback to last green tag.
5. Document timeline in incident notes; link [EVENT_CATALOG.md](../ops/EVENT_CATALOG.md) events.

## Sentry mirror alerts (project settings)

Configure in Sentry UI (production project):

1. **Issue alert:** event count > 50 in 5m, filter `transaction:callable:*` → Slack/email.
2. **Issue alert:** new regression after release, linked to deploy tag from `deploy-production` workflow.
3. **Performance:** p95 callable duration regression (optional).

## Related runbooks

- [slos.md](slos.md) — SLI targets and error budgets
- [RUNBOOK.md](../RUNBOOK.md) — macOS/daemon incidents
- [rollback-automation.md](rollback-automation.md) — Cloud Functions rollback
- [iroh-secrets.md](iroh-secrets.md) — relay deploy and health

## Quarterly drill

See [COMMERCIAL_ROLLBACK.md](../COMMERCIAL_ROLLBACK.md): execute rollback dry-run, redeploy previous tag, run launch gate, record date in [TECHNICAL_READINESS.md](../TECHNICAL_READINESS.md).
