# Sentry alert rules (Functions + macOS)

Copy-paste templates for the Sentry UI. GCP Cloud Monitoring remains the **primary** paging plane; Sentry complements with exception grouping and release health.

## Prerequisites

- Functions release tag matches `FUNCTION_VERSION` (set by `deploy-production.yml`).
- Sentry release format: `openburnbar-functions@<tag>` (see `functions/src/sentry.ts`).

## Issue alert — callable error spike

| Field | Value |
|-------|-------|
| Name | OpenBurnBar callable error spike |
| When | Event count is **greater than 50** in **5 minutes** |
| Filter | `transaction` contains `callable:` |
| Action | Notify Slack / email on-call |

## Issue alert — new regression after deploy

| Field | Value |
|-------|-------|
| Name | OpenBurnBar regression after release |
| When | A new issue is created |
| Filter | `release` equals latest `openburnbar-functions@*` from deploy |
| Action | Notify Slack / email |

## Issue alert — push / Stripe tagged failures

| Field | Value |
|-------|-------|
| Name | OpenBurnBar push or billing failure |
| When | Event count **greater than 10** in **15 minutes** |
| Filter | `tags.provider` in `apns`, `fcm`, `stripe` OR message contains `push:` / `stripe:` |
| Action | Notify `#ops` |

## Performance (optional)

| Field | Value |
|-------|-------|
| Name | Callable p95 regression |
| When | p95 duration increases **25%** vs 7-day baseline |
| Filter | `transaction` contains `callable:` |

## Verification

After configuring rules, trigger a test issue in staging or confirm the rule dry-run in Sentry → Alerts → test notification.

Related: [oncall.md](../runbooks/oncall.md), [EVENT_CATALOG.md](EVENT_CATALOG.md).
