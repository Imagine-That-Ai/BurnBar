# Google Play Billing RTDN

OpenBurnBar uses Google Play Real-time Developer Notifications (RTDN) as a
signal to reconcile Android subscriptions and top-up reversals against the
Google Play Developer API. RTDN payloads never directly grant an entitlement.

## Production contract

- Firebase project: `burnbar`
- Android package: `com.openburnbar`
- Pub/Sub topic:
  `projects/burnbar/topics/play-billing-notifications`
- Cloud Function: `googlePlayDeveloperNotifications`
- Google Play publisher principal:
  `google-play-developer-notifications@system.gserviceaccount.com`
- RTDN audit collection: `google_play_rtdn_events`
- Audit retention: 90 days through the `expireAt` Firestore TTL field

Purchase tokens are hashed before persistence. Subscription notifications are
resolved through `purchases.subscriptionsv2.get`; cancellations remain active
through their paid expiry. Voided purchases and refunded one-time products
reverse the associated top-up or deactivate the affected subscription.

## One-time Google Play Console setup

1. Open Google Play Console for `com.openburnbar`.
2. Go to **Monetize with Play → Monetization setup**.
3. Under **Real-time developer notifications**, enter:
   `projects/burnbar/topics/play-billing-notifications`.
4. Save the configuration.
5. Send a test notification.
6. Confirm a document with `testNotification: true` and
   `status: "processed"` appears in `google_play_rtdn_events`.

The topic must grant `roles/pubsub.publisher` to:

```text
serviceAccount:google-play-developer-notifications@system.gserviceaccount.com
```

## Deploy

Build first, then deploy only the RTDN function:

```bash
npm --prefix functions run build
firebase deploy \
  --project burnbar \
  --only functions:googlePlayDeveloperNotifications
```

Deploy the Firestore TTL override independently when it changes:

```bash
firebase deploy --project burnbar --only firestore:indexes
```

## Verification

The commercial launch gate checks all four live requirements:

- the Pub/Sub topic exists under the `burnbar` project;
- the Google Play notification service account can publish;
- the deployed function is active, targets the expected topic, and has
  `GOOGLE_PLAY_RTDN_TOPIC=play-billing-notifications`;
- `google_play_rtdn_events.expireAt` TTL is `ACTIVE`.

Run:

```bash
node scripts/test-commercial-launch-gate-commercial.mjs
node scripts/commercial-launch-gate.mjs
```

For an infrastructure-only pipeline smoke test, publish a Play-shaped test
message and then inspect Firestore:

```bash
gcloud pubsub topics publish \
  projects/burnbar/topics/play-billing-notifications \
  --project burnbar \
  --message='{"version":"1.0","packageName":"com.openburnbar","eventTimeMillis":"REPLACE_WITH_UNIX_MILLIS","testNotification":{"version":"1.0"}}'
```

That synthetic publish proves Pub/Sub → Eventarc → Cloud Functions → Firestore.
The Google Play Console test in the one-time setup remains required because it
also proves the external Play Console topic configuration.

## Failure handling

- Function failures are retried by the event trigger.
- Event IDs are deduplicated in `google_play_rtdn_events`.
- Invalid packages, notification shapes, and claim-kind mismatches are rejected.
- Notifications that arrive before a client token claim are safely recorded as
  ignored without persisting the raw purchase token.
- There is no server-side Play reconciliation sweep: raw purchase tokens are
  never persisted (privacy invariant), so the backend cannot re-query Google
  Play on a schedule. Exposure from a missed or delayed RTDN is still bounded
  because entitlements carry `expireAt` set to the verified paid-through date —
  an entitlement never outlives its last verified period, and renewals only
  extend it through a fresh verified signal (an RTDN redelivery or the client's
  next `verifyGooglePlayPurchase` call, which re-submits the token and repairs
  the entitlement).
