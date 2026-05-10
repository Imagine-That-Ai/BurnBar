# Paid-Scale Firebase Runbook

This is the pre-paid-user operating bar for OpenBurnBar's Firebase backend.

## Rollups

Scheduled rollups must not scan every `users/{uid}/usage` document every five minutes.

The production path is:

1. `onUsageWritten` observes a usage document create, update, or delete.
2. The trigger writes signed deltas into `users/{uid}/usage_counter_days/{yyyy-mm-dd}` and the all-time aggregate at `users/{uid}/usage_counter_totals/all_time`, including provider, account, model, and device sub-counters under each bucket.
3. `rebuildRollups` reads only compact counter documents for the target windows and writes `usage_rollups/{today,7d,30d,90d,all_time}`. The `all_time` summary reads the all-time aggregate bucket instead of rescanning every historical day.

`rebuildUsageRollups` is the explicit repair/backfill path. It may scan raw usage for one signed-in user because it is operator/user initiated, not the five-minute scheduled path.

## Large Bodies

Firestore should hold manifests, search terms, snippets, hashes, and small encrypted relay frames. It should not hold giant log bodies.

Preferred model for full session-log backup:

- Firestore: `session_logs/{logId}` manifest with title, project, device, body hash, object pointer, byte counts, compression, and search metadata.
- Cloud Storage: compressed body object keyed by `uid/logId/bodyHash`.
- iCloud mirror: acceptable first-class alternative when the user wants Apple-account storage instead of OpenBurnBar-operated storage.

Hermes relay schema v2 already rejects plaintext request bodies and chunk data in rules; it requires encrypted payload fields instead.

## Index Exemptions

Deploy `firestore.indexes.json` with single-field exemptions for large fields:

- `body`
- `payloadCiphertext`
- `ciphertext`
- `text`
- `data`
- `chunkHashes`
- large rollup arrays/maps such as summaries and daily points

Keep the `chunks.terms` array index because `searchStreams` relies on `array-contains`.

## Quota Refresh

`refreshAllProviderQuotas` filters to eligible cloud-refreshable and server-private hosted account docs, orders them by `lastRefreshAt asc`, and only then applies the batch limit. This makes the 20-doc default a stale-first cursor instead of repeatedly refreshing the same first page and starving later users. A small compatibility pass drains older refreshable account docs that predate `lastRefreshAt`; after one successful or failed refresh they join the ordered path. Legacy provider connections use the same stale-first ordering for installs that have not migrated to `provider_accounts`.

## Billing Alerts

Create alert policies before onboarding paid users:

```bash
export GCLOUD_PROJECT=burnbar
export BILLING_ALERT_CHANNELS=projects/burnbar/notificationChannels/CHANNEL_ID
npm --prefix functions run alerts:billing
```

`scripts/commercial-launch-gate.mjs` fails launch if any required policy is
missing, disabled, duplicated, missing notification channels, or no longer
watches its intended cost metric.

The checked-in policies watch, in priority order:

1. Firestore document reads.
2. Firestore data and index storage bytes.
3. Cloud Run request rate as the hosted relay spend proxy.
4. Redis memory pressure and connected-client count.
