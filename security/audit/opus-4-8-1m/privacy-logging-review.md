# Privacy, Logging & Data Governance Review — Opus 4.8 1M lane

Verdict: **run-09 privacy-invariant finding class is defensibly closed (I1–I5) and structurally closed (I6).** Both gates pass locally and non-vacuously. Residual Lows only.

## I.1 Privacy invariants (run-09)

| ID | Enforced | Tested | CI gate | Evidence | Residual |
|---|---|---|---|---|---|
| I1 TTL overrides on ephemeral PII/token collections | yes | yes | yes | `firestore.indexes.json:1893-1909`; `check-privacy-invariants.mjs:47-55` | — |
| I2 Writer stamps TTL field | yes | yes | yes | `callables/voipPush.ts:22-27,76,90`; `agentNotifications.ts:322` | — |
| I3 No raw `firebase-functions/logger` import in prod | yes | yes | yes + eslint no-restricted-imports | gate `:245-262`; `eslint.config.mjs:32-43`; grep = 0 hits | — |
| I4 `redactUidPaths()` applied | yes | yes | yes | `logging.ts:69-74,103`; `loggingScrubber.test.ts:46-87` | path-shaped only; mitigated by source guard |
| I5 voip push omits stable correlators | yes | yes | yes | `voipPush.ts:69-100`; `voipPushMetadata.test.ts:62-98` | 3rd builder `buildFcmMessage` un-gated (OPUS-F-006) |
| I6 Declared TTLs are LIVE policies | deploy-readback | n/a | yes | `verify-firestore-ttl-state.mjs:69-122`; `deploy-firestore.yml:109` | live state unverified (OPUS-U-001) |

Gates executed locally: `check-privacy-invariants.mjs` (14 checks ✓) + `check-privacy-invariants.test.mjs` (9/9 positive controls ✓) — the self-test proves the gate catches the regression (non-vacuous).

## I.2 Sensitive logging review
- Functions: 127/127 log sites route through scrubbing `logInfo/logWarn/logError`; 0 raw `console.*` in prod **except** `accountDeletion.ts` (OPUS-F-005). UIDs truncate to 8-char hash; tokens/secrets redacted (`logging.ts:16-44,76-105`).
- Client: OSLog hashes private values (`.private(mask:.hash)`, `AppLogger.swift:185`); Sentry breadcrumbs pass through `sanitizeMetadata`.
- **Classification:** mostly **safe**; one **risky** path (OPUS-F-005, full UID on error branch).

## I.3 Client crash telemetry (F-RR09-003)
Opt-in + scrubbed before egress: `sendDefaultPii=false`, `MacSentryScrubber`/`MobileSentryScrubber`, consent gate, non-PII per-install id (macOS random UUID; iOS IDFV). `resolveSentryDSN` reads Info.plist first. **Test gap (OPUS-F-002):** macOS scrubber + install-id untested. **Deployment readback (OPUS-U-006):** whether DSN ships + org PII settings.

## I.4 Data governance (LINDDUN highlights)
- **Linking/Identifying:** ephemeral push queues co-locate uid + push tokens, bounded by TTL (15 min) + immediate account-erase sweep (`accountDeletion.ts:124-139`). `thread_id` to APNs/FCM is a residual cross-session correlator (OPUS-F-006).
- **Disclosure:** Firestore intentionally sees routing/count metadata; cannot read sealed chat/session/mission content. **But** shared collaboration artifacts are plaintext (OPUS-F-001) and local DB is plaintext (OPUS-F-004).
- **Non-compliance (GDPR Art.17):** deletion covers PII-bearing collections incl. root push queues + storage objects; complete for today's schema (forward-maintenance risk OPUS-F-014). Export path: `scheduledExports.ts`.
- **Retention:** TTL contract (field stamp + live policy) enforced by I2 + I6; live-state unverified (OPUS-U-001).

## I.5 Threat-model anchor (honest non-claim)
Per `docs/security/PRIVACY_INVARIANTS.md` + `BurnBar-threat-model.md`, BurnBar does **not** claim universal cloud blindness; cloud + push/telemetry processors intentionally see routing metadata. The invariants bound that exposure to exactly that stated position (no full UIDs in logs, no stable cross-processor correlators in push, no unbounded uid+token retention, no unscrubbed crash egress). OPUS-F-005/006 are bounded deviations from that bound.
