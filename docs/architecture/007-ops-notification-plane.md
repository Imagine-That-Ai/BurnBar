# ADR 007: Ops notification plane

**Status:** Accepted (2026-05-31)  
**Scope:** Cloud Functions, GCP Monitoring, Sentry, CI deploy gates

## Context

OpenBurnBar had resilience policies, structured logging, and billing alert definitions in-repo, but production call paths did not consistently use them, and paging was documented without verification in CI or launch gate.

## Decision

1. **Repo-owned policy manifest** — [`functions/scripts/ops-alert-policy-definitions.mjs`](../../functions/scripts/ops-alert-policy-definitions.mjs) merges SLO + billing policies; apply via [`apply-ops-alert-policies.mjs`](../../functions/scripts/apply-ops-alert-policies.mjs).
2. **GCP Monitoring primary** — log-based user metrics + Cloud Run metrics route to notification channels (`OPS_ALERT_CHANNELS`).
3. **Sentry secondary** — `captureException` at callable choke point in [`logging.ts`](../../functions/src/logging.ts); operators configure mirror alerts in Sentry UI ([oncall.md](../runbooks/oncall.md)).
4. **Deploy gate** — `v*` tags run [deploy-production.yml](../../.github/workflows/deploy-production.yml) with blocking [`post-deploy-health-gate.sh`](../../scripts/ci/post-deploy-health-gate.sh).
5. **CI enforcement** — [`verify-ops-readiness.sh`](../../scripts/ci/verify-ops-readiness.sh) runs callable logging + resilience wiring checks.

## Consequences

- Adding a new alert requires updating the manifest, log metric (if needed), launch gate, and [EVENT_CATALOG.md](../ops/EVENT_CATALOG.md).
- PagerDuty can be added without code changes by registering a GCP notification channel ID in `OPS_ALERT_CHANNELS`.

## References

- [OBSERVABILITY.md](../OBSERVABILITY.md)
- [slos.md](../runbooks/slos.md)
- [006 or prior ADRs](README.md)
