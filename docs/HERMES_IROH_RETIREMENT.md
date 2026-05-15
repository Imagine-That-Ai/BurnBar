# Hermes Realtime Relay → iroh: Phase 7 retirement runbook

> **Phase 7** is the final milestone of the iroh transport migration. It
> retires the Cloud Run WebSocket relay and the Memorystore Redis instance
> that powered Phases 1-6. The runbook is intentionally conservative:
> retirement only happens after 14 consecutive days of iroh carrying
> 100% of relay traffic with zero fallback-to-WSS events.

See [`HERMES_IROH_TRANSPORT.md`](HERMES_IROH_TRANSPORT.md) for the
overall architecture and Phase 1-6 milestones.

---

## Pre-retirement gates

All four gates must be green for **14 consecutive UTC days**. The Cloud
Functions hosted runner emits these metrics into BigQuery; the
`router-brand-coherent-rail` dashboard surfaces them on the Pi.

| Gate | Source | Threshold |
| --- | --- | --- |
| iroh stream success rate | `iroh_audit_events.eventType == "iroh_stream_closed"` / total opens | ≥ 99.5% |
| WSS fallback rate | `iroh_audit_events.eventType == "iroh_fallback_to_wss"` per day | ≤ 0 |
| iroh-direct (vs. iroh-relay) usage | `iroh_audit_events.transport == "iroh-direct"` / all iroh closes | ≥ 75% |
| iroh hosted-relay budget | n0 services API `actual_cost / budgeted_cost` | ≤ 1.0 |

If any gate slips, **abort** the retirement and re-enable WSS by:

```bash
# 1. Flip the feature flag globally
firebase remoteconfig:templates:set scripts/remoteconfig/templates/wss-fallback.json --project openburnbar-prod

# 2. Confirm the Cloud Run service is healthy
gcloud run services describe hermes-realtime-relay --region us-central1
```

---

## Retirement steps

### 1. Freeze new iroh writes
Turn off `hermesIrohTransportEnabled` for new device installs via Remote
Config (existing installs are unaffected — the flag is sticky-on once
they've successfully used iroh).

```bash
firebase remoteconfig:templates:set scripts/remoteconfig/templates/iroh-frozen.json --project openburnbar-prod
```

### 2. Decommission Cloud Run service
After T+24h with no inbound WSS traffic:

```bash
gcloud run services delete hermes-realtime-relay \
  --region us-central1 \
  --project openburnbar-prod \
  --quiet
```

### 3. Decommission Memorystore Redis
After T+72h to allow the Cloud Run job logs to drain:

```bash
gcloud redis instances delete hermes-realtime-relay-redis-prod-secure \
  --region us-central1 \
  --project openburnbar-prod \
  --quiet
```

### 4. Tear down the VPC connector
Required only if no other Cloud Run service uses the connector:

```bash
gcloud compute networks vpc-access connectors delete hermes-relay-connector \
  --region us-central1 \
  --project openburnbar-prod \
  --quiet
```

### 5. Remove the Cloud Functions adapter
The WSS-fallback path inside `HermesCompositeRelayTransport` becomes
unreachable. Open a PR that:

1. Deletes `services/hermes-realtime-relay/`.
2. Removes `HermesRealtimeRelayTransport` from `HermesCompositeRelayTransport` — the chain becomes iroh → Firestore (the last-resort long-poll transport stays for emergencies).
3. Marks `hermesRealtimeRelayURL` as deprecated in `ChatBackendSettings.swift`.
4. Adds a `CHANGELOG.md` retirement entry.

Keep `FirestoreHermesRelayTransport` — it's the universal fallback that
still works when both Mac and iOS can sign in to Firebase but iroh
holepunching is blocked.

### 6. Decommission App Check enforcement keys
The Cloud Run service had a dedicated App Check key. After the service is
gone:

```bash
gcloud firebase appcheck keys delete hermes-relay-app-check-prod \
  --project openburnbar-prod \
  --quiet
```

---

## Rollback playbook

If a regression surfaces post-retirement, restore traffic in this order:

1. **Re-deploy Cloud Run service** from the last good tag:
   ```bash
   gcloud run services replace services/hermes-realtime-relay/cloudrun.yaml --region us-central1
   ```
2. **Re-provision Memorystore Redis** from the last available backup
   (Memorystore keeps 35-day point-in-time recovery on prod).
3. **Re-enable WSS** in Remote Config:
   ```bash
   firebase remoteconfig:templates:set scripts/remoteconfig/templates/wss-fallback.json --project openburnbar-prod
   ```
4. Push an `OpenBurnBarMobile` build that reverts the
   `HermesCompositeRelayTransport` change so WSS is back in the chain.

The Firestore long-poll transport never gets retired and continues to
serve as the last-resort fallback regardless of iroh / WSS state.

---

## Post-retirement audits

Run these monthly until the team is satisfied iroh is the canonical
transport:

* `scripts/cutover-n0-hosted-relay.sh status` — confirm the hosted tier
  is healthy and within budget.
* `firebase firestore:query` on `users/{uid}/iroh_audit_events` to
  sample latency + failure distributions per user.
* Search the App Store + Play Store reviews for "Mac unreachable",
  "Hermes offline", or "could not verify Mac" — those map to the three
  iroh pairing failure modes documented in `HERMES_IROH_TRANSPORT.md`.

---

## Estimated savings

Once retired:

| Component | Monthly cost (prod) | Status after Phase 7 |
| --- | --- | --- |
| Cloud Run `hermes-realtime-relay` | ~$140 | Deleted |
| Memorystore Redis prod-secure | ~$80 | Deleted |
| VPC connector | ~$15 | Deleted |
| Cloud Functions WSS adapter | ~$10 | Deleted |
| **Total saved** | **~$245/mo** | — |
| n0 hosted relay (team-200 tier) | $200 | Added Phase 6 |
| **Net delta** | **−$45/mo** | — |

The savings are small in absolute dollars; the real win is the operational
collapse: one transport to monitor instead of three, holepunched
peer-to-peer latency for the 75%+ of users on the same network, and one
fewer Cloud Run service to keep App Check + IAM honest.
