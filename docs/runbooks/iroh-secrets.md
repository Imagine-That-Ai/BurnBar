# Hermes iroh Secrets and Monitoring Runbook

## Scope

This runbook covers the credentials and operator telemetry needed for the
Hermes iroh transport rollout. It does not authorize production deploys by
itself; follow `docs/HERMES_IROH_PRODUCTION_HANDOFF.md` for phase gates.

## Credential Inventory

| Item | Verified state | Where it lives | Rotation |
| --- | --- | --- | --- |
| n0 / Iroh Services API secret | Present locally and in GitHub Actions. Local file mode is `600`; the loaded value is non-empty. | Local: `.secrets/iroh-services.env` as `IROH_SERVICES_API_SECRET`. CI: GitHub Actions secret `IROH_SERVICES_API_SECRET`. | Create a new API key in Iroh Services for the `burnbar` project, replace the local file value, run `gh secret set IROH_SERVICES_API_SECRET --repo Imagine-That-Ai/BurnBar --body "$IROH_SERVICES_API_SECRET"`, then run a read-only services status check. Revoke the old key only after the new key works. |
| Iroh hosted relay subscription | `burnbar` Iroh Services project is Pro/admin. US East relay deploy was started from the dashboard on 2026-05-15 at $199/month. Assigned URL: `https://use1-1.relay.alberto8793.burnbar.iroh.link/`; dashboard status is `running`. | Iroh Services dashboard: `services.iroh.computer/alberto8793/burnbar/relays`. | Deploy replacement relay in the target region, publish the new relay URL via Remote Config, verify Phase C round trips, then delete the old relay from Iroh Services. |
| Firebase project access | Logged in as `alberto8793@gmail.com`; production project confirmed as `burnbar` (`246956661961`). Remote Config is readable and currently returns an empty template. | Firebase CLI auth on this machine; `.firebaserc` default project `burnbar`. | Re-auth with `firebase login` if the account changes. Keep `.firebaserc` pinned to `burnbar` for this repo. |
| Firebase app configs | Present as GitHub Actions secrets. | `FIREBASE_PLIST_BASE64`, `GOOGLE_SERVICES_JSON_BASE64`. | Regenerate the Firebase app config from Firebase Console, update the matching GitHub secret, and run the iOS/Android config injection scripts before release builds. |
| App Store Connect API credentials | Present in Firebase Functions Secret Manager; key ID, issuer ID, and `.p8` body are all readable by the current Firebase principal. | Firebase Functions secrets: `APP_STORE_ASC_KEY_ID`, `APP_STORE_ASC_ISSUER_ID`, `APP_STORE_ASC_KEY_P8`. A local key file also exists under `~/.appstoreconnect/private_keys/`. | Create a replacement ASC API key with required app permissions, update the three Firebase secrets, run the appstore test suite, then revoke the old ASC key in App Store Connect. |
| Apple signing and notarization | GitHub Actions secrets exist for signing and notarization. Project team ID is `4Y367DF25B`. | GitHub Actions secrets: `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_NOTARY_API_KEY_P8`. | Import a new Developer ID / distribution certificate, update the base64 P12 and password secrets, then run the release workflow on a non-production tag before using it for a release. |

## Monitoring

Raw iroh telemetry is written by Mac and iOS clients to:

```text
users/{uid}/iroh_audit_events/{eventId}
```

The scheduled Cloud Function `rollupIrohTransportDaily` reads the prior UTC
day of audit events every day at 08:15 UTC and writes a single operator rollup:

```text
ops/iroh_transport_daily_rollups/days/{YYYY-MM-DD}
```

Each rollup includes:

- `successRate`: `iroh_stream_closed / (iroh_stream_closed + iroh_stream_failed + iroh_fallback_to_wss)`.
- `fallbackRate`: `iroh_fallback_to_wss / terminal events`.
- `directShare` and `relayShare`: split of `iroh-direct` versus `iroh-relay` events.
- `rttMillis.p50`, `p95`, and `p99`.
- `eventCounts.iroh_pairing_rejected`, which must stay zero for soak gates.

Use this document for Phase E/F gate checks. Do not trust a rollout gate until
the matching daily rollup exists for the full UTC day being evaluated.

## Verification Commands

```bash
ls -la .secrets/iroh-services.env
source scripts/ci/load-iroh-services-secret.sh >/dev/null
env | grep IROH_SERVICES_API_SECRET | wc -c

gh secret list --repo Imagine-That-Ai/BurnBar | rg '^IROH_SERVICES_API_SECRET|^APPLE_|^FIREBASE_PLIST_BASE64|^GOOGLE_SERVICES_JSON_BASE64'

firebase login:list
firebase projects:list
PROJECT_ID=burnbar firebase --project burnbar remoteconfig:get --output /tmp/openburnbar-remoteconfig.json

cd functions
npm run test:iroh-monitoring
```

## Incident Response

If `fallbackRate` rises above the active gate threshold, freeze rollout by
setting the Remote Config iroh default or percentage to zero and keep WSS
enabled. Export the affected day's raw `iroh_audit_events` and inspect
`detail.error` for the first failing `iroh_stream_failed` or
`iroh_fallback_to_wss` event before changing code.
