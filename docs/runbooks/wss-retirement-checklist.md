# WSS Retirement Checklist

Companion to `docs/HERMES_IROH_RETIREMENT.md`. Phase 7 of the Mercury
media rollout (`plans/2026-05-15-mercury-media-master-plan.md`) lifts
the WSS retirement out of the iroh transport plan and folds it into the
broader media rollout because the operational gates align: by the time
Phase 5 + 6 have soaked, ≥ 99.5% iroh success / 0 WSS fallback / ≥ 75%
iroh-direct / hosted-relay budget < 100% should already be the steady
state.

## Gate (must hold for 14 consecutive days)

- [ ] `ops/iroh_transport_daily_rollups/days/*.successRate ≥ 0.995`.
- [ ] `ops/iroh_transport_daily_rollups/days/*.transportCounts.wss === 0`.
- [ ] `ops/iroh_transport_daily_rollups/days/*.directShare ≥ 0.75`.
- [ ] `ops/media_budget_status/current.projectedMonthEndUSD ≤ 600`.
- [ ] No P0/P1 incidents tagged `relay` in the prior 14 days.

## Decommission steps

1. Flip `hermesIrohTransportEnabled` Remote Config to 100%.
2. Wait 24 h. Confirm zero WSS dial attempts via
   `iroh_transport_daily_rollups`.
3. `gcloud run services delete hermes-realtime-relay
   --region=us-central1 --project=burnbar`.
4. `gcloud redis instances delete hermes-realtime-relay
   --region=us-central1 --project=burnbar`.
5. `firebase functions:delete hostedRelayProvision --region=us-central1
   --project=burnbar`.
6. Remove `services/hermes-realtime-relay/` from the repo.
7. Mark `docs/HERMES_REALTIME_RELAY.md` as historical (front-matter
   banner: "**Retired 2026-XX-XX. See `docs/HERMES_IROH_TRANSPORT.md`
   for the active path.**").
8. Update `docs/runbooks/iroh-rollout-status.md` with the retirement
   timestamp.
9. Audit `firebase remoteconfig:get` for any remaining
   `hostedRelayURL` parameter — delete.
10. Update `CHANGELOG.md` with the retirement entry.

## Rollback (within 7 days)

If a regression surfaces post-retirement:

1. `git revert` the Cloud Run + Memorystore deletion infrastructure
   change.
2. Redeploy `hermes-realtime-relay` from the prior tagged release.
3. Restore the Memorystore Redis instance from snapshot.
4. Flip `hermesIrohTransportEnabled` to a 50% cohort to bleed iroh
   traffic back to WSS.
5. Open an incident with the gate that broke; pause Phase 7 retirement
   until root cause is fixed and the 14-day soak restarts.

After 7 days post-decommission, the snapshot rollback path expires and
recovery requires a fresh provision (`scripts/cutover-n0-hosted-relay.sh`
in reverse — provision Cloud Run, point clients at it via Remote
Config). Document the deeper rollback once the 7-day window closes.
