# Privacy Invariants (run-09: privacy / logging / metadata)

This document is the canonical description of the **structural invariants** that
keep the run-09 privacy/logging/metadata findings closed. They are enforced
deterministically in CI by `scripts/ci/check-privacy-invariants.mjs` (with a
self-test, `check-privacy-invariants.test.mjs`) so the entire finding class
cannot silently regress in a future refactor.

The point-in-time fixes live in code + tests; *this* layer makes them permanent.

## Threat-model anchor

Per `docs/security/BurnBar-threat-model.md`, BurnBar is local-first and does
not claim universal user-held cloud blindness: the cloud and third-party
push/telemetry processors intentionally see routing metadata. The invariants
below bound that exposure to exactly the stated position — no full UIDs in logs,
no stable cross-processor correlators in push payloads, no unbounded retention
of uid+token docs, and no unscrubbed client crash egress.

## The invariants (gate IDs)

| ID | Invariant | Finding | Enforced by |
|---|---|---|---|
| **I1** | Every ephemeral PII/token collection (`voip_outbound`, `fcm_outbound`, `agent_notification_events`) declares a `ttl:true` field override in `firestore.indexes.json`. | F-RR09-001 / F-RR09-007 | static gate |
| **I2** | Every `ttl:true` override is backed by a Cloud Functions writer that stamps the field (no dead index; no writer without an index). | F-RR09-001 / F-RR09-007 | static gate |
| **I3** | No production Cloud Functions source imports the raw `firebase-functions/logger` (it bypasses the PII scrubber). | F-RR09-002 | static gate + eslint `no-restricted-imports` |
| **I4** | `functions/src/logging.ts` defines and applies `redactUidPaths()` so a UID embedded in any path/message/error string value is redacted. | F-RR09-002 | static gate + `loggingScrubber.test.ts` |
| **I5** | The outbound push payload builders (`buildVoipApnsPayload`, `buildFcmCallPayload`) never include `connection_id` / `pairedDeviceId` / a real display name. | F-RR09-008 | static gate + `voipPushMetadata.test.ts` |
| **I6** | Every declared `ttl:true` override is a **live** Firestore TTL policy (ACTIVE/CREATING) in the deployed project. | F-RR09-001 / F-RR09-007 | deploy gate (`verify-firestore-ttl-state.mjs`) |

## Where they run

- **Per-PR (fast):** `.github/workflows/fast-feedback.yml` → `no-suppressions` job self-tests then runs `check-privacy-invariants.mjs` (I1–I5).
- **Ops meta-gate:** `scripts/ci/verify-ops-readiness.sh` (run by `ops-confidence.yml`) self-tests then runs the gate (I1–I5).
- **On deploy:** `.github/workflows/deploy-firestore.yml` runs `verify-firestore-ttl-state.mjs` after the index deploy (I6) — the automated form of the "B3 deploy readback".

## Extending the gate

Adding coverage is a one-line edit in `scripts/ci/check-privacy-invariants.mjs`:

- A new ephemeral PII/token collection → add to `EPHEMERAL_PII_COLLECTIONS`
  (forces I1 + I2 + I6 for it automatically).
- A new banned push-payload key → add to `BANNED_PUSH_KEYS`.
- A new push payload builder → add to `PUSH_PAYLOAD_BUILDERS`.

Always add a matching positive control in `check-privacy-invariants.test.mjs`
so the gate is proven to catch the regression (it must never pass vacuously).

## Firestore TTL: a two-part contract

A TTL has two halves that must both hold:

1. **The field is stamped on write** (`expireAt`/`expiresAt`) — code, guarded by I2.
2. **A live TTL policy exists** on the deployed project — guarded by I6.

`firebase deploy --only firestore:indexes` (firebase-tools ≥ 11.5) applies the
policy from the `ttl:true` override, but a policy can fail to materialise
(`CREATING → NEEDS_REPAIR`) or be missing on a partial/older deploy. I6 reads the
live `ttlConfig.state` via the Firestore Admin API and **fails the deploy** if any
declared policy is not ACTIVE/CREATING. To (re)apply a policy manually:

```
gcloud firestore fields ttls update <field> \
  --collection-group=<collection> --enable-ttl --project=burnbar
```

## Client crash telemetry (F-RR09-003)

Client Sentry on macOS/iOS is opt-in and privacy-scrubbed before anything leaves
the device: `sendDefaultPii=false`, `beforeSend`/`beforeBreadcrumb` run
`MacSentryScrubber`/`MobileSentryScrubber`, a consent gate
(`Mac/MobileCrashReportingConsent`), and a non-PII per-install id (the macOS
`NSFullUserName()` seed was removed). `resolveSentryDSN(bundle:)` reads the DSN
from the app **Info.plist first**, then `GoogleService-Info.plist` as a fallback;
the XcodeGen post-build scripts land `sentry.dsn` into the Info.plist primary
path (see `project.yml`), and `AppLoggerSanitizationTests.swift` covers the
resolver. Whether the DSN ships in a given release, and Sentry org-level PII
settings, remain a deployment/build-artifact readback.
