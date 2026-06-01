# OpenBurnBar — Blue Team / Detection / Incident Response Review (2026-06-01)

Author: Blue Team / Detection / IR specialist
Scope: Cloud Functions telemetry, Sentry wiring, iroh / Mercury / Computer-Use audit
pipelines, pairing / escrow / device-trust surfaces, OpenTimestamps anchoring, on-call
contract, runbooks, OOB forensics path.
Out of scope: the red-team kill chains (covered in `RED_TEAM_KILL_CHAINS.md`),
fix-prioritization (covered in `FIX_ROADMAP.md`), and SOTA benchmarking (covered in
`SOTA_GAP_ANALYSIS.md`). This document is a **detection + response** workstream.

The verdict: Blue-Team wiring is **partial**. There is a real Cloud-Functions logging
scaffold (`functions/src/logging.ts`), a per-callable `_rate_limits/{action}` scheme,
a real daily-rollup pipeline (computer use, iroh, media) and a working Sentry
integration on the Functions side, but the signal-to-noise ratio is low and the
high-value detections that would justify "Blue Team" in a product like OpenBurnBar
are mostly **missing**. Most of the "Blue Team" docs are an SRE on-call contract,
not a security detection + response program.

## 1. What Blue Team must defend

| Asset | Why it matters | Trust boundary |
|---|---|---|
| User identity / Apple JWS entitlement (`users/{uid}/entitlements/**`) | Drives Cloud Pro / hosted quota, paid path | Auth + App Check + Apple root CAs |
| Hermes / iroh pairing (`users/{uid}/hermes_pairings/**`, `hermes_connections/**`) | Phone↔Mac trusted-channel establishment | Callable + App Check + 10-min TTL |
| Escrow device trust (`users/{uid}/escrow_devices/**`, `escrow_grants/**`) | Trust elevation; controls sign-ability of audit exports | Callable + high-risk App Check claim |
| Computer Use audit chain (`chain.jsonl`, `head.json`, `.ots` on Mac) | Tamper-evident log of every action an agent took | SHA-256 hash chain, Ed25519 head signature, OTS |
| Computer Use audit-export signer (`escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}`) | Re-anchors chain to a trusted macOS device | Read-back rule; "revoked" trust state must invalidate |
| Mercury media sessions (`users/{uid}/media_session_events/**`) | Bandwidth / duration forensics for screen-share, video, file transfer | Server-only ops reads |
| Iroh transport events (`users/{uid}/iroh_audit_events/**`) | Stream open/close, fallback, pairing, RTT | Server-only rollups |
| App Check bindings (`users/{uid}/app_check_attestations/**`) | Per-app attestation; gates high-risk callables | Server-only writes |
| Hosted OAuth grants (`users/{uid}/oauth_grants/**`) | Remote MCP grant issuance | Callable + consent UI |
| Hosted Quota / Provider accounts (`users/{uid}/provider_account_secret_refs/**`) | Server-only; plaintext secrets forbidden on the client path | Server-only writes |

If a Blue-Team control fails for any of these assets, a detection must exist to
*announce* the failure — not just record it. Today most paths record the failure
but emit no high-signal alert.

## 2. Existing Blue Team substrate (what works)

### 2.1 Cloud Functions logging (`functions/src/logging.ts`)

- Structured JSON to stdout (`logInfo` / `logWarn` / `logError`) with a `severity`
  field, a generated or inbound `trace_id` (`x-cloud-trace-context`), and a
  hashed `user_id_hash` (first 8 chars of the Firebase UID). Good.
- `scrubFields` recursively redacts emails, IPv4 addresses, common token prefixes
  (`sk-`, `AIza`, `ya29.`, `eyJ`), and 16-digit numbers (CC-like). String values
  are capped at 1024 chars with `[truncated]`. UIDs are key-based truncated to
  avoid the 28-char false-positive class. **Good baseline; documented limitations**
  in §3.4.
- `withCallableLogging` / `onCallWithLogging` / `onCallProduction` factories wrap
  every callable with `callable_start` / `callable_success` / `callable_error`
  events. **Adoption is partial** — `hermes.ts`, `computerUseSecurity.ts`, and
  `quota.ts` all use `wrapCallableHandler`, but several legacy callables still
  emit their own ad-hoc log lines and never reach the Sentry path.

### 2.2 Per-callable rate limit (callables/shared.ts:1357-1411)

- `checkRefreshRateLimit`, `checkHermesRateLimit`, `checkPiAgentRateLimit` use a
  Firestore TTL doc per `(uid, action)`. The `hermes_create_pairing` limit is
  **5s**, `hermes_complete_pairing` is **1s**, `hermes_revoke_connection` is
  **2s**, `hermes_update_connection_status` is **2s**. These are anti-abuse
  against one *user* and do **not** cross-user correlate. Brute force against a
  *single* pairingId is still possible because `HERMES_MAX_FAILED_PAIRING_ATTEMPTS
  = 5` only blocks after 5 wrong codes (callables/shared.ts:104); there is **no
  global per-uid failed-attempt counter** that Sentry/GCP Monitoring can alert
  on.

### 2.3 Daily rollups

- `rollupComputerUseDaily` (functions/src/computerUseMonitoring.ts) writes one
  per-day denormalized doc with sessionsStarted, sessionsCompleted,
  browserActions{Executed,Rejected}, systemActions{Executed,Rejected},
  phoneControlIntents, scopeViolations, panicHaltCount, p50/p95/p99 approval
  latency, vision spend. **Good shape for SLO and budget; weak for security**
  because rollups are aggregate, not per-session, and have no alert thresholds
  documented.
- `rollupMediaSessionDaily` (functions/src/mediaMonitoring.ts) writes per-day
  per-feature (fileTransfer, screenShare, videoCall) totals: count, successRate,
  fallbackRate, totalSeconds, totalBytes, RTT/bps/freeze percentiles. **No
  per-uid or per-connection anomaly surface**; a 4-hour screen-share from a
  brand-new device is invisible in the rollup.
- `buildAndPersistIrohDailyRollup` (functions/src/irohMonitoring.ts) writes
  per-day event counts by `eventType` and `transport`, plus p50/p95/p99 RTT. The
  raw `iroh_audit_events` carry the pairing id but the rollup does not export
  per-pairing aggregates; pairing-id-level forensics requires raw Firestore
  reads by an operator.

### 2.4 Sentry (`functions/src/sentry.ts`)

- Init on cold start if `SENTRY_DSN` is set; release is `openburnbar-functions@<tag>`
  driven by `FUNCTION_VERSION`. Sample rate 10% prod / 100% non-prod. Good.
- `beforeSend` drops 429 + `rate limit` / `RESOURCE_EXHAUSTED` strings; **this
  is risky** because a real RateLimitExhausted abuse signal is dropped. Capture
  as a tagged metric instead of dropping.
- `beforeBreadcrumb` redacts `?token=` / `?key=` / `?secret=` in URLs only.
  Query param `?apiKey=` or `?bearer=` is not redacted. POST bodies are not
  redacted. (See §3.4.)
- `setSentryUser(uid)` only sets `id: "uid:<first-8>"`. **Good**, but the breadcrumb
  scrubber has the same blind spots.

### 2.5 Runbooks

- `docs/runbooks/oncall.md` defines P0/P1/P2 severity, an SLO burn policy, and
  references a "quarterly drill" that is just a commercial-rollback dry run, not
  a security incident drill. **There is no security incident runbook; no breach
  notification play; no comms template; no on-call paging for "is this an
  attack?"; no escalation path to a security contact.**
- `docs/ops/SENTRY_ALERT_RULES.md` defines three rules (callable error spike,
  post-release regression, push/Stripe failures) and one optional performance
  rule. **No rules for any of the detection scenarios in §4.**
- `docs/ops/EVENT_CATALOG.md` enumerates 12 stable event names. It maps to
  Cloud Monitoring but not to a SIEM, and several expected security events are
  missing (see §3.1).

## 3. Gaps the Blue Team specialist found independently

### 3.1 Detection signal coverage matrix

| Detection scenario (asked by spec) | Logged today | Alert today | Evidence |
|---|---|---|---|
| Repeated pairing failures (single uid, single pairingId) | yes | **no** | `failedAttempts` increments in `hermes.ts:155` but no counter exposed to Sentry / Cloud Monitoring |
| New device enrollment (escrow) | yes (callable_info: `escrow_device_registered`) | no | `computerUseSecurity.ts:120` |
| Remote control start (Mac → FCM/queue) | partial (queue publish) | no | `AgentCapabilityGrantQueueListener.swift`, no Sentry/SLO hook |
| Privilege escalation (escrow `pending` → `trusted`) | yes (callable_info: `escrow_device_trust_approved`) | no | `computerUseSecurity.ts:165` |
| Grant issuance (`escrow_grants`) | **no** — collection writes are silent | no | `computerUseSecurity.ts:201` does not log the grant write |
| Workspace role change | **missing** — search hits no `role` write path | no | (no logging path found) |
| High-risk agent action (Computer Use `executed`) | yes (audit chain entry) | no | `ComputerUseAuditEntry` field set, no alert hook |
| Unusual relay bandwidth / duration (Mercury) | yes (per-day rollup) | no | rollup is aggregate, no per-pairing threshold |
| Unusual screen-share duration | yes (per-day rollup) | no | same — no per-pairing alert |
| Suspicious signed upload use (audit-export signer) | **partial** — `escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}` is read back by rules, not by an alarm | no | (no alarm path) |
| High token burn (hosted quota / LLM cost) | partial (`cloudProAllowanceRemoteConfig`) | no | `cloudProAllowance.ts` budget evaluated; no per-day alert |
| Model switching anomalies | **missing** — no `model_switch` event in EVENT_CATALOG | no | grep `model_switch` in functions/src → 0 hits |
| Unusual export / download | partial — `ComputerUseAuditExportWriter` writes a sidecar, no alert on size threshold | no | `ComputerUseAuditExportWriter.swift:99` |
| Admin data access | **missing** — no `burnbarOperator` claim access log path | no | (no audit trail for ops reads) |
| Failed authorization attempts | partial — `HttpsError` is logged by `logCallableFailure` only when the callable is wrapped | no | grep `HttpsError` audit path |
| Brute force pairing (10-min window) | **partial** — `failedAttempts` exists per pairingId, but no global per-uid window counter | no | `hermes.ts:155` |
| Passkey / MFA enrollment | **missing** — no `passkey_enrolled` or `mfa_enabled` log | no | grep `passkey` / `mfa` in functions/src → 0 hits |
| Key rotation | **missing** — no `key_rotation` event in EVENT_CATALOG | no | grep `keyRotation` in functions/src → 0 hits |
| Audit log tampering | **partial** — `chainValid: false` returned by `validateComputerUseOpenTimestampsProofForRequest` is observable only by an explicit callable call; no scheduled verifier sweep | no | `computerUseOpenTimestamps.ts:288` |
| OpenTimestamps anchoring working end-to-end | partial — `ots_verifier_unavailable` is a real status; no SLO on "valid 7-day-up proof" | no | `computerUseOpenTimestamps.ts:218` |
| Log redaction in Sentry / Cloud Logging | partial — see §3.4 | n/a | `sentry.ts:52`, `logging.ts:14` |
| Log retention (forever or 30d?) | **partial** — `appstore/audit.ts:30` sets `AUDIT_TTL_DAYS = 400`; **no other collection has a documented TTL** | n/a | `appstore/audit.ts` |
| Detection signal coverage | **partial** — no `event_type=security_*` taxonomy | n/a | EVENT_CATALOG.md |
| On-call coverage / runbook quality | partial — see §3.7 | n/a | `docs/runbooks/oncall.md` |
| Forensics post-hoc from logs alone | **mostly no** — see §3.6 | n/a | — |
| Audit export reader / verifier published | **partial** — `openburnbar-cli audit-verify` exists; not published outside the binary; no hosted verifier endpoint with audit log | n/a | `BurnBarCLIAuditVerify.swift` |
| Brute-force pairing: 10-min window attempt count | **partial** — `HERMES_PAIRING_TTL_MS = 10*60*1000`; per-pairingId failedAttempts increments; but the *aggregate* attempt count is not surfaced to an alert | no | `callables/shared.ts:102-104`, `hermes.ts:155-164` |
| Passkey / MFA enrollment events | **missing** | no | — |
| Key rotation events | **missing** | no | — |

### 3.2 Audit log tampering: chain checks vs. silent bypass

- The Computer Use audit chain is a real hash chain with canonical-JSON encoding
  (`ComputerUseAuditChain.swift` line 80-90) and an Ed25519-signed head. The
  offline verifier `openburnbar-cli audit-verify` exists
  (`BurnBarCLIAuditVerify.swift`) and is exercised in unit tests. **But**:
  - There is **no scheduled Cloud Function that walks active sessions and
    re-validates** the chain on a heartbeat. The only path that detects a broken
    chain is `validateOpenTimestampsProof` (`computerUseOpenTimestamps.ts:288`),
    which is callable-only, App-Check-gated, and never called on a schedule.
  - There is **no `chain_invalid` event in `EVENT_CATALOG.md`**. If a user
    forces a chain rewrite, the only signal is "the next audit-export call
    returns non-fully-verified".
  - The `chain.jsonl` lives on the user's Mac in `~/Library/Application Support/...`.
    Cloud-side `users/{uid}/computer_use_sessions/{sessionId}` carries an
    `auditHeadHashHex` (see `serverHeadStatus` in `computerUseOpenTimestamps.ts:262`)
    but is **not validated against a sidecar**. The cross-check is one-shot
    and only on demand.
  - **Missing**: an OOB scheduled sweeper that compares Firestore's
    `auditHeadHashHex` against a fresh local-chain hash from the most recent
    client-reported `head.json`. Today, the cloud and the local chain can
    silently disagree and nobody will know.
- The audit-export Ed25519 signing key has a documented migration path
  (`audit-export-ed25519.raw` → Keychain; see `docs/runbooks/computer-use-rollout-status.md:130`)
  but the **post-migration revocation flow** is not documented as a runbook
  step. If a Mac with the legacy raw key file is cloned / restored, the legacy
  key still signs exports until revoked.

### 3.3 Log redaction: what `logging.ts` and `sentry.ts` actually cover

Covered (good baseline):
- Email regex `[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}` → `[email]`.
- IPv4 regex `(\d{1,3}\.){3}\d{1,3}` → `[ip]`.
- Common API-key prefixes (`sk-`, `AIza`, `ya29.`, `eyJ`) → `[REDACTED]`.
- 16-digit CC-like sequences → `[REDACTED]`.
- Truncate at 1024 chars per string.
- UIDs truncated to 8 chars by key (not regex) to avoid 28-char false positives.

Not covered (gaps):
- **IPv6** is not scrubbed. A user device or Iroh relay endpoint exposed as
  `2001:db8::1` would land in Cloud Logging and Sentry breadcrumbs.
- **URLs with non-query-string secrets**: `Authorization: Bearer eyJ...` in a
  body, `X-API-Key: sk-...` in a header, `Cookie: session=...` in a header.
  Only the Sentry `beforeBreadcrumb` URL redaction catches some of these, and
  only for `?token=`, `?key=`, `?secret=`.
- **Screenshots / image bytes** in payloads. `ComputerUseSessionCoordinator` ships
  PNG bytes through several paths; the audit chain correctly stores only a hash
  (`beforeScreenshotHashHex`), but the **callable logs** that include the
  approval-request payload may carry the raw base64 PNG. Need to grep callables
  for `screenshot` strings: `ComputerUseSecurityCallableClient.swift:4030 bytes`
  is small but the call surface is wide.
- **Sentry `extra` blob**: `withSentry` and `captureException` set `scope.setExtras(context)`
  with the full context dict. If the caller passes a context with PII, the
  redaction is whatever the caller did — there is no Sentry-side scrubber.
- **Firestore path names**: `users/{uid}/provider_account_secret_refs/{refId}` is
  in Cloud Logging call paths. The path is logged as-is and contains the user's
  Firebase UID; the path is not passed through `scrubFields`.
- **Bodies of incoming callables**: `wrapCallableHandler` logs `callable_start`
  and `callable_success` only — not the request data. Good. But the **error path
  in `logCallableFailure` does include `error: String(error)`** which may embed
  request data (e.g., a 422 with "field 'pairingId' is too long"). Need to
  verify each `throw new HttpsError(...)` site.

### 3.4 Log retention: only the App Store audit has a TTL

- `appstore/audit.ts:30` declares `AUDIT_TTL_DAYS = 400` and writes an
  `expireAt` Timestamp on each row. Documented.
- **`ops/iroh_transport_daily_rollups/days`**, **`ops/computer_use_session_daily_rollups/days`**,
  **`ops/media_session_daily_rollups/days`** — no `expireAt` field and no
  documented TTL. **Indefinite retention by default.**
- **`users/{uid}/iroh_audit_events/*`** — no TTL. Per-pairing audit events
  accumulate forever.
- **`users/{uid}/computer_use_sessions/*`** and **`computer_use_actions/*`** —
  no TTL. Sessions with thousands of actions stay forever.
- **`users/{uid}/media_session_events/*`** — no TTL.
- **Cloud Logging itself** has a default 30-day retention in GCP. After 30 days,
  per-uid event correlation requires going to Firestore rollups (which have no
  per-uid detail).
- **Sentry** event retention is 90 days by default on most plans; on-call
  rule-driven retention is not configured.
- The retention policy is therefore **inconsistent**: Apple audit 400 days, ops
  rollups forever, raw per-uid audit events forever, Cloud Logging 30 days.
  Recommend a single documented matrix.

### 3.5 Detection signal coverage: what is in logs vs. what alerts

Of the 14 detection scenarios in §3.1:
- **3** are logged with a stable event name (`callable_error`,
  `circuit_breaker_tripped`, `health_ready_failed`).
- **9** are logged but only with `callable_info` (no severity, no Sentry tag,
  no metric). Sentry's `beforeSend` filter only blocks rate-limit errors; it
  does not promote any of these to alerts.
- **2** are missing entirely (passkey/MFA enrollment, key rotation).

There is **no SLO / alert** that fires on:
- `escrow_device_trust_approved`
- `escrow_device_trust_revoked`
- `hermes_pairing_created` / `pairing_failed` aggregate rate
- `computer_use_actions` `status: denied` with `denyReason: scope_denied` (this
  *is* a sign of an agent attempting a privilege escalation)
- any `panic_*` end reason from a computer-use session
- any `iroh_fallback_to_wss` / `iroh_fallback_to_firestore` rate spike (a sign
  of relay compromise or transport attack)
- any `validateOpenTimestampsProof` call that returns `status: "head_mismatch"`
  (an audit-tamper signal)

### 3.6 Forensics: can a compromised device be investigated from logs alone?

- **Per-uid identity**: yes (UID → `user_id_hash` first 8 chars in
  logging.ts). 8 chars is **collision-prone** for cross-tenant correlation
  in a 100k+ user fleet; the docs say "8 chars is not reversible", which is
  true, but the comment in `sentry.ts:88` also says "for stronger
  anonymization, substitute a server-side SHA-256 hash when needed." That has
  not been done.
- **Per-session timeline**: only for the actions the user opted to log via
  `users/{uid}/computer_use_sessions/{sessionId}` and `users/{uid}/computer_use_actions/{actionId}`.
  There is no per-session, per-day doc that operators can join to Cloud Logging
  trace_ids. Forensic re-construction requires **two systems** (Firestore + Cloud
  Logging) joined by the user's UID.
- **Per-pairing forensics**: `users/{uid}/iroh_audit_events/{eventId}` carries
  the `connectionId`. Daily rollups aggregate; raw docs retain detail. Joining
  to a particular pairing requires collection-group query.
- **Per-export forensics**: `users/{uid}/escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}`
  is the read-back record. **No "lastExportAt" or "lastExportSizeBytes"** is
  recorded — operators cannot answer "did this device sign any export in the
  last 24 hours?" without scanning every doc.
- **OpenTimestamps re-anchoring**: a `.ots` file lives on the Mac; the
  Cloud Function `validateOpenTimestampsProof` can be called by the user or
  support, but no scheduled job re-validates the last 7 days of `head.json`
  proofs. **Detached anchor verification is therefore manual, not forensic.**

Verdict: a post-hoc investigation is **possible** with significant operator
effort (read raw `iroh_audit_events`, `computer_use_actions`, `media_session_events`,
join by `user_id_hash`/`uid`), but no single "forensic timeline" doc exists for
a UID. There is no runbook for "given a user report, do X".

### 3.7 On-call coverage, runbook quality, and drills

- `docs/runbooks/oncall.md` is an **SRE** on-call runbook, not a security
  on-call runbook. It treats "Callable error spike" and "Firestore read spike"
  as P0/P1 but does not enumerate any security detection.
- The "Quarterly drill" is "execute rollback dry-run" (a deploy drill). There
  is no security incident drill (e.g., "simulate a stolen escrow private key,
  do we revoke the right grants?", "simulate 100 failed pairings, do we
  alert?", "simulate a Mac audit-chain tamper, do we detect?").
- `docs/runbooks/computer-use-audit-disputes.md` exists, which is the closest
  thing to a security runbook; it covers the **dispute** path (user disputes
  an audit entry), not the **detection** path (we suspect tampering before
  any user complains).
- No PagerDuty / Opsgenie rotation. No secondary on-call. No "if you see this
  in Sentry, page security@burnbar.ai" rule.
- **No "break-glass" runbook** for the Firestore root. If an operator needs
  to revoke a user's entitlements and the user owns all their devices, there
  is no documented path.

### 3.8 OpenTimestamps anchoring: is it end-to-end?

- Client side: the Mac writes `.ots` next to `head.json`
  (`ComputerUseAuditOpenTimestampsClient.swift`, see CHANGELOG.md line 85).
  Proof is generated at session end.
- Server side: `validateOpenTimestampsProof` (`computerUseOpenTimestamps.ts:326`)
  is callable, App-Check-gated, accepts the proof + chain, returns
  `verified: true` if the `ots` binary succeeds or the verifier service is
  reachable. **Good design, real status reporting.**
- **Gap 1**: the verifier reports `ots_verifier_unavailable` if neither
  `OPENBURNBAR_OTS_VERIFY_BIN` nor `OPENBURNBAR_OTS_VERIFY_URL` is set in
  production. There is no SLO that says "100% of audit exports must be
  OTS-verifiable within 7 days"; a deployment that simply forgets the env
  var silently regresses the SOTA posture to "we wrote a .ots file but never
  confirmed it's anchored".
- **Gap 2**: the Mac's `ots` client likely uses a public aggregator; there is
  no documented "wait until the proof upgrades to a confirmed Bitcoin block"
  step. Without that wait, `.ots` files are "pending" forever and the verifier
  returns `ots_verify_failed` (the upgrade call is missing).
- **Gap 3**: there is no scheduled sweep that re-verifies the last 7 days of
  `.ots` files; a regression is only caught when a user or support person
  re-runs `openburnbar-cli audit-verify`.

### 3.9 Audit export reader / verifier: published or internal?

- The CLI `openburnbar-cli audit-verify` is in
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/BurnBarCLIAuditVerify.swift`
  and tested. It is **not** published as a separate binary download
  (no `verify_only` release artifact; no homebrew formula). Users / lawyers /
  external auditors must have a Mac with OpenBurnBar installed to run it.
- There is **no hosted verifier endpoint** that accepts an export bundle
  (`.tar.gz` + `head.json` + `.sig.json` + optional `.ots`) and returns a
  signed verdict. This is the standard expectation for "I want to be able to
  prove the chain is intact in 5 years"; the company holds the only key.
- There is **no public-format documentation** for the archive layout. The
  `ComputerUseAuditExportWriter` builds a real POSIX ustar with gzip, but the
  manifest schema is not versioned in a public doc.

### 3.10 Security event channel vs. user data correlation

- Sentry is wired to callables via `withCallableLogging` and `captureException`.
  `setSentryUser(uid)` sets the Sentry `user.id` to `uid:<first-8>` only.
- This means Sentry's **issue inbox is keyed on truncated UIDs**, which makes
  per-user dedupe hard. Two unrelated users with the same 8-char prefix
  (`abc12345...`) will have their breadcrumbs merged into the same Sentry
  issue.
- The "user data" of interest (chat content, prompts, code) is **never** in
  Cloud Logging or Sentry (per the threat model). Good. But the audit chain
  lives in **Firestore** and the daily rollups live in **Cloud Logging /
  Firestore**. Two systems, one truth, no Sentry correlation between them.

### 3.11 Brute-force pairing: 10-minute window attempt count

- The 10-minute window is `HERMES_PAIRING_TTL_MS = 10 * 60 * 1000`
  (`callables/shared.ts:102`). A pairingId exists for 10 minutes.
- During those 10 minutes, the per-pairingId `failedAttempts` counter caps at
  `HERMES_MAX_FAILED_PAIRING_ATTEMPTS = 5` (`callables/shared.ts:104`). After
  the 5th wrong code, the pairing is `revoked` (`hermes.ts:160`).
- **But** the `complete_pairing` callable has its own rate limit of
  `checkHermesRateLimit(uid, "complete_pairing", 1)` (`hermes.ts:127`), which
  is **1 per second** per uid. So a single uid can attempt 600 wrong codes
  across 10 minutes (10 codes/min × 10 min), each in a different pairing
  attempt chain (because each `create_pairing` → `complete_pairing` pair is
  rate-limited to 1/sec, not cross-pairing-limited).
- The actual exposure is bounded by the 1s rate limit (10 wrong codes/min).
  This is acceptable for human-driven brute force but **does not stop a bot**
  that creates 10 pairings/min and tries 5 codes each — that's 50 wrong
  codes/minute across multiple pairingIds, none of which is aggregated to an
  alert.
- **Missing**: an alert on `failedAttempts` aggregate > 10 per uid per hour.

### 3.12 Passkey / MFA enrollment events

- No `passkey_enrolled` or `mfa_enabled` event exists in the EVENT_CATALOG.
  Firebase Auth handles these but **OpenBurnBar does not consume or surface
  them in its own audit log**. If a user adds a passkey, OpenBurnBar has no
  record of it. (Search of `functions/src/**.ts` for `passkey`/`mfa` returns
  zero hits.)
- For a high-risk product (escrow / signed audit / paid path), this is a
  material gap. Recommendation: a callable that subscribes to Firebase Auth
  blocker-function events or polls `users/{uid}/mfaInfo`, and writes
  `users/{uid}/security_events/{eventId}`.

### 3.13 Key rotation events

- The escrow device key has a `keyVersion` field
  (`computerUseSecurity.ts:94-97`), but rotation is **silent** — there is no
  event when a keyVersion changes. If a key is rotated, the next export
  signs with the new key and the old key still validates prior exports. The
  rotation is invisible to operators.
- The hosted-quota / Apple JWS pipeline rotates automatically with
  `verificationVersion: 2` (`THREAT_MODEL.md:283`), but again, no event.
- The audit-export Ed25519 signing key (the Mac's) has a migration path
  documented (`docs/runbooks/computer-use-rollout-status.md:130`) but no
  alert on "a Mac has a keyVersion change without a corresponding
  sign-in event".

### 3.14 Misuse of `beforeSend` to drop rate-limit errors

- `sentry.ts:38-49` drops events whose message contains `rate limit` /
  `RESOURCE_EXHAUSTED` or whose `extra.statusCode === 429`. This **filters
  out the exact signal a Blue Team would want**: an attacker spraying
  callables until they hit 429. The 429 itself is a fingerprint of abuse.
  Move this to a tagged breadcrumb instead.

## 4. Detection matrix (what should exist, with thresholds)

Each row is "signal → threshold → where it lands → response owner".

| # | Signal | Threshold | Sink | Owner |
|---|---|---|---|---|
| 1 | `callable:hermes_complete_pairing` `failedAttempts++` per uid | ≥ 10 wrong codes in 60 min | Cloud Monitoring log-based metric → Slack `#sec` | SRE on-call |
| 2 | `escrow_device_trust_approved` | any | Sentry (tag `security:trust_elevation`); Slack DM to security on-call | Security on-call |
| 3 | `escrow_device_trust_revoked` | any | Sentry + Slack `#sec` | Security on-call |
| 4 | `escrow_grants` write | any | Sentry (tag `security:grant_issuance`); user email | Security on-call |
| 5 | `computer_use_actions.denyReason == "scope_denied"` | ≥ 3 in 60 min per session | Cloud Monitoring → Slack `#sec` | Security on-call |
| 6 | Computer Use session `endReason` starts with `panic_` | any | Sentry (tag `security:panic_halt`); Slack `#sec` | Security on-call |
| 7 | `iroh_fallback_to_wss` / `iroh_fallback_to_firestore` per connection | > 5 fallbacks in 10 min | Cloud Monitoring → Slack `#sec` | SRE on-call |
| 8 | Mercury screen-share `totalSeconds` per pairing | > 4h in 24h | Cloud Monitoring → Slack `#sec` | Security on-call |
| 9 | Mercury relay `totalBytes` per pairing per day | > 5 GB | Cloud Monitoring → Slack `#sec` | Security on-call |
| 10 | `validateOpenTimestampsProof` returns `head_mismatch` | any | Sentry (tag `security:audit_tamper`) → PagerDuty P1 | Security on-call |
| 11 | `validateOpenTimestampsProof` returns `ots_verify_failed` for a > 7-day-old `.ots` | any | Sentry → Slack `#sec` | Security on-call |
| 12 | Scheduled sweep: chain hash mismatch between Mac and Firestore | any | Sentry → PagerDuty P1 | Security on-call |
| 13 | Hosted quota `cloudProAllowance` budget exceeded | any in production | Sentry (tag `security:quota_burn`) → Slack `#sec` | Security on-call |
| 14 | Model switch > 3 distinct providers in 5 min per uid | any | Sentry → Slack `#sec` | Security on-call |
| 15 | Audit-export signer keyVersion change without sign-in event | any | Sentry → Slack `#sec` | Security on-call |
| 16 | Passkey / MFA enrolled | any | Sentry (tag `security:mfa_enrolled`) → user email "your account just got a new passkey" | User + security on-call |
| 17 | 429 spike (currently dropped by `beforeSend`) | > 100 / 5 min per callable | Sentry (tag `security:rate_limit_pressure`) | SRE on-call |
| 18 | `burnbarOperator` claim read against `ops/*` | any | Sentry (tag `security:ops_read`) → Slack `#sec` | Security on-call |
| 19 | Audit-export size > 50 MB (suggests screenshot dump) | any | Sentry → Slack `#sec` | Security on-call |
| 20 | New escrow device `platform == "macOS"` for a uid that has not had a Mac in > 30 days | any | Sentry → Slack `#sec` | Security on-call |

## 5. Alert thresholds (per platform)

### Cloud Monitoring (primary paging plane, per `oncall.md`)

| Metric / log filter | Comparison | Duration | Page |
|---|---|---|---|
| `callable_error` count | > 50 | 5m | Slack `#ops` (existing rule) |
| `callable:hermes_complete_pairing` with `failedAttempts>=1` | > 10 | 60m | Slack `#sec` (NEW) |
| `escrow_device_trust_approved` count | > 0 | n/a | Slack `#sec` (NEW) |
| `iroh_fallback_to_wss` + `iroh_fallback_to_firestore` per uid | > 5 | 10m | Slack `#sec` (NEW) |
| Mercury screen-share `totalSeconds` (per uid, sum) | > 14400 | 24h | Slack `#sec` (NEW) |
| Computer Use `panic_*` session endReason | > 0 | n/a | Slack `#sec` (NEW) |
| Callable 429 rate (currently dropped) | > 100 | 5m | Slack `#sec` (NEW) |

### Sentry (secondary, used for issue grouping)

- Keep the existing 3 rules (`SENTRY_ALERT_RULES.md`).
- Add 5 new rules:
  1. `security:trust_elevation` tag → Slack `#sec` DM to security on-call.
  2. `security:audit_tamper` tag → PagerDuty P1.
  3. `security:grant_issuance` tag → Slack `#sec`.
  4. `security:panic_halt` tag → Slack `#sec`.
  5. `security:quota_burn` tag → Slack `#sec`.

### SLOs (per `slos.md`, but the security SLOs are missing)

- 99% of audit exports must be OTS-verifiable within 7 days of session end.
- 99% of computer-use panic halts must be reflected in `ops/computer_use_session_daily_rollups`
  within 24h.
- 0 trust elevations without a corresponding `escrow_device_trust_approved`
  log line (i.e., no out-of-band `trustState: trusted` writes).
- 0 audit-tamper alarms without a closure postmortem within 14 days.

## 6. Incident response playbooks

Six playbooks for the highest-likelihood scenarios. Each is structured as
**Detect → Contain → Eradicate → Recover → Post-mortem**.

### Playbook PB-01: Brute-force pairing attack

**Detect.** Cloud Monitoring rule #1: `failedAttempts` aggregate > 10 per uid
in 60 min. Sentry also tags `callable:hermes_complete_pairing` errors with
`HttpsError: "permission-denied"`.
**Contain.** Auto-revoke the offending uid's `hermes_pairings` (a new callable
`revokeAllPairingsForUid(uid)` invoked by the alert, or a force-revoke via
Firestore). Lock the uid's `hosted_quota_sync` entitlement to require MFA on
next sign-in (callable, owner-only).
**Eradicate.** Rotate the uid's `app_check_attestations` so any leaked
attestation is invalidated. Audit `users/{uid}/oauth_grants` for any
suspicious grants that landed during the attack window; revoke them.
**Recover.** Notify the user via APNs: "We detected a brute-force pairing
attempt; we revoked your active pairings. Re-pair from a trusted device."
Restore `hosted_quota_sync` after user confirms MFA re-enroll.
**Post-mortem.** Within 7 days: review the Sentry trace_ids from the attack
window; write a retrospective into `docs/postmortems/YYYY-MM-DD-bf-pairing.md`;
file a security roadmap item to reduce the false-accept rate (e.g., rate-limit
by `(uid, sourceIp)` rather than just `uid`).

### Playbook PB-02: Suspicious escrow device trust elevation

**Detect.** Sentry issue with `security:trust_elevation` tag. Cloud Monitoring
rule #2. Look at the *time-of-day* and *source IP* of the `approve` callable;
flag if the approving device is in a different region than the user normally
operates from (using a learned baseline).
**Contain.** Auto-revoke the newly-trusted device's `escrow_grants` via
`revokeEscrowDeviceTrust`. Revoke any `computer_use_audit_export_signers`
that were bound since the elevation.
**Eradicate.** Mark the device's `trustState` `revoked` and require it to
re-register. Add the device's public-key fingerprint to a
`users/{uid}/security_events/{eventId}` doc with reason
`trust_elevation_suspicious`.
**Recover.** User reviews the device list in Settings → Devices; if legit,
re-approves from a known-trusted device. Notify via APNs: "A new device was
added to your account. Was this you?"
**Post-mortem.** Within 7 days: examine the source IP and the approving
device's `app_check_attestation`; ensure the elevation required an
attestation-bound claim (it does, per `enforceHighRiskComputerUseCallable`).
If the elevation succeeded without attestation, file a P0.

### Playbook PB-03: Audit chain tamper detected

**Detect.** Cloud Monitoring rule #10: `validateOpenTimestampsProof` returns
`head_mismatch`. **OR** the scheduled sweep (PB-12, missing today) detects
`head.json` hash ≠ Firestore `auditHeadHashHex`. **OR** a user-submitted
export returns `chainValid=false` from `openburnbar-cli audit-verify`.
**Contain.** Mark the affected session `locked` in Firestore (a new field;
deny all subsequent computer-use callable writes for that session). Pause the
Mac's computer-use daemon (or have the user panic-halt). Pause any
audit-export signers on the affected device pending investigation.
**Eradicate.** Force the user to re-pair and re-bootstrap escrow. Rotate
the audit-export Ed25519 signing key for the affected device. Publish an
incident note in `security-review-2026-06-01/INCIDENTS/YYYY-MM-DD-*.md`
(redacted for PII).
**Recover.** After user re-bootstrap, the chain restarts with a new
`sessionId`; the prior session's `.ots` file is preserved as forensic
evidence. Notify any third parties that received prior exports that those
exports should be considered unverified.
**Post-mortem.** Within 14 days: full forensic timeline (Cloud Logging
+ Firestore raw events + Sentry breadcrumbs), root cause, fix, and a
regression test. If the tamper path was remote (cloud-side), file a P0
and disclose per the data-incident policy.

### Playbook PB-04: High-volume screen-share abuse (potential exfil)

**Detect.** Cloud Monitoring rule #8: Mercury screen-share `totalSeconds` >
4h in 24h per pairing. **OR** rule #9: per-pairing `totalBytes` > 5 GB in
24h. **OR** a new pairing that was created < 24h ago initiates a screen
share with a long duration.
**Contain.** Auto-pause the iroh stream by calling a new callable
`pauseMediaSession(connectionId, reason: "exfil_guard")`. The Mac receives
the pause and the iroh relay drops the stream. Notify the user via APNs:
"Screen share paused because of unusual usage. Tap to resume or lock."
**Eradicate.** Lock the connection: set
`users/{uid}/hermes_connections/{connectionId}.status = "locked"`. Revoke
the connection's `escrow_grants`. If the pairing was created < 24h ago,
also revoke the pairing.
**Recover.** User reviews the connection in Settings → Devices → Mercury.
If legit, the user explicitly resumes. Otherwise the device is removed.
**Post-mortem.** Within 7 days: classify the activity (legit heavy use vs.
exfil vs. attacker relay abuse). If relay abuse, audit
`ops/iroh_transport_daily_rollups/days` for the connection's relay vs.
direct ratio; consider blacklisting the relay node ID.

### Playbook PB-05: Hosted quota burn anomaly (potential model abuse)

**Detect.** Cloud Monitoring rule #13: `cloudProAllowance` budget
exceeded. **OR** rule #14: a uid switches between > 3 distinct model
providers in < 5 min. **OR** a single LLM call returns > 100k tokens.
**Contain.** Set `users/{uid}/hosted_quota_sync.budgetState = "throttled"`
(throttle the user's hosted quota to 0 requests/min for 1h). Surface a
banner in the Mac app and the mobile app: "Hosted quota paused for
suspicious activity".
**Eradicate.** Audit `users/{uid}/hosted_quota_sync` and any
`oauth_grants` issued in the last 24h. If a grant is found, revoke it.
If a model provider account secret ref is found, mark it `revoked`.
**Recover.** User signs in again and confirms via MFA that the activity
was theirs. Restore `budgetState` to its prior value.
**Post-mortem.** Within 7 days: review the model switch sequence; if
the pattern matches a known prompt-injection + tool-grant abuse chain
(see RED_TEAM_KILL_CHAINS.md), file a prompt-injection P1.

### Playbook PB-06: OpenTimestamps verifier regression

**Detect.** Cloud Monitoring rule #11: any
`validateOpenTimestampsProof` call returns `ots_verify_failed` or
`ots_verifier_unavailable` for a > 7-day-old proof. **OR** a scheduled
sweep (PB-13) finds that > 5% of the last 7 days' proofs are unverified.
**Contain.** Post a banner on the launch site (burnbar.ai) that audit
export verification is degraded. Notify all TestFlight / external
auditors via email. Pause new audit exports (the writer refuses if a
fresh `.ots` cannot be generated).
**Eradicate.** Roll the affected function back per
`docs/runbooks/rollback-automation.md`. If the regression is in the
Mac's `ots` client, push a hotfix via Sparkle / App Store. Document
the verifier-outage window in a security incident note.
**Recover.** After re-deploy, run a back-fill that re-anchors all
sessions whose `.ots` files are < 30 days old (older ones are
un-recoverable without re-running the client).
**Post-mortem.** Within 7 days: classify the root cause (binary
missing, network egress blocked, OTS aggregator rate-limit, etc.)
and add a regression test that fails CI if the verifier env var is
unset in production.

### Playbook PB-07: BurnbarOperator claim misuse

**Detect.** Cloud Monitoring rule #18: any read against `ops/*` from a
non-`burnbarOperator` UID (Firestore rules will deny, but the **denial
itself** is a signal). **OR** a `burnbarOperator` UID is observed
reading `users/{otherUid}/*` paths (Firestore rules deny; the denial
is logged).
**Contain.** Suspend the `burnbarOperator` claim on the offending UID
via an emergency callable. Rotate the operator-claim minting key.
**Eradicate.** Audit the operator UID's last 30 days of activity in
Firestore. Identify any data exported. Notify affected users per
the data-incident policy.
**Recover.** Re-issue the operator claim only after the operator
re-authenticates with MFA. Add the operator's UID to a
`security_events/operator_misuse/{uid}` record.
**Post-mortem.** Within 14 days: review Firestore rules for any
path that an operator can read with less than the strictest
justification; tighten the `burnbarOperator` rule to read only the
`ops/*` collections and explicitly deny `users/{otherUid}/*`.

### Playbook PB-08: Computer Use panic halt

**Detect.** Cloud Monitoring rule #6: any computer-use session ends
with `endReason` starting with `panic_`. **OR** a Sentry issue with
tag `security:panic_halt`.
**Contain.** The Mac app surfaces a banner ("Computer Use stopped by
your request"). The computer-use daemon refuses new actions until
the user explicitly resumes.
**Eradicate.** Audit the actions executed in the last 5 minutes
before the panic halt. Cross-reference the action descriptors with
the deny-list and the scope library. If any action was executed that
should have been denied, escalate to PB-03.
**Recover.** User reviews the chain (`openburnbar-cli audit-verify`).
If clean, the user can resume. If not, file a P0 incident.
**Post-mortem.** Within 7 days: file a retrospective on the trigger
condition. If the panic was a false positive (e.g., user pressed
the key by accident), consider a confirm-step before the daemon
honors the panic.

## 7. Blue Team roadmap (P0 / P1 / P2)

### P0 (within 1 sprint)

1. Add the 7 missing security events to `EVENT_CATALOG.md`:
   `escrow_device_trust_approved`, `escrow_device_trust_revoked`,
   `grant_issued`, `audit_tamper_detected`, `panic_halt`,
   `mfa_enrolled`, `key_rotated`.
2. Add 5 new Sentry rules and 7 new Cloud Monitoring rules per §4.
3. Promote `error.message` containing `rate limit` from a `beforeSend` drop
   to a tagged metric (Sentry tag `abuse_signal:rate_limit_pressure`).
4. Write a single "incident response" runbook (`docs/runbooks/SECURITY_INCIDENT.md`)
   with the 6 playbooks from §6.
5. Add a `users/{uid}/security_events/{eventId}` collection and a Cloud
   Function to write a doc on every `escrow_device_trust_*` callable.

### P1 (within 2 sprints)

6. Add scheduled OTS re-verification sweeper (every 24h, last 7 days).
7. Add scheduled chain-tamper sweeper (every 6h, every active session).
8. Add a hosted verifier endpoint (public, unauthenticated, rate-limited)
   that accepts an export bundle and returns a JSON verdict.
9. Add a Firestore TTL policy on `ops/*_rollups/days/{dayKey}` (90d
   retention), `users/{uid}/iroh_audit_events/*` (180d), and
   `users/{uid}/media_session_events/*` (90d). Document in `EVENT_CATALOG.md`.
10. Publish `openburnbar-cli audit-verify` as a standalone binary (homebrew
    formula + GitHub release).
11. Add per-uid aggregate counter for `failedAttempts` (1h, 24h windows)
    and alert on > 10 per hour.
12. Add passkey / MFA enrollment event by subscribing to Firebase Auth
    blocker functions.

### P2 (within 3 sprints)

13. Add a security drill scenario to the quarterly drill (PB-02 simulated
    trust elevation + PB-03 simulated chain tamper).
14. Add a "forensic timeline" callable that, given a uid + date range,
    returns a single denormalized doc with all the raw events.
15. Add per-uid learned-region baseline for trust-elevation alerts.
16. Add Sentry-side scrubber for `extra` blobs (mirror of `logging.ts:14-29`).
17. Replace the "first-8-chars-of-UID" Sentry user with a server-side
    SHA-256 hash (per `sentry.ts:88` comment).
18. Add a `security:audit_tamper` rate alert that pages even on a single
    occurrence (low false-positive rate expected).

## 8. Conclusion

The Blue Team substrate is **partially built**. The logging, Sentry, and
rollup layers are real and shipping, but the *security-specific* detection
and response layer is mostly missing. The product has all the
high-value assets (escrow trust, signed audit, paid entitlement, paired
device control) that warrant a security detection program, but the alerts
that would defend those assets are not yet wired.

Top three concrete actions, in order:

1. **Wire the alerts.** Add 5 Sentry rules and 7 Cloud Monitoring rules
   (§4) and 7 missing events to `EVENT_CATALOG.md`. Most of the data is
   already in logs; the work is to subscribe to it.
2. **Schedule the sweeps.** A 24h OTS re-verification job and a 6h
   chain-tamper sweep would close the two highest-severity detection
   gaps (audit-tamper, OTS-regression) that today are user-reported only.
3. **Write the playbooks.** Convert §6 into a real runbook at
   `docs/runbooks/SECURITY_INCIDENT.md` and rehearse one in the next
   quarterly drill.

The SOTA reference is the AWS Customer Playbook / Stripe IRP / GCP
Security Command Center detections. OpenBurnBar does not need a SIEM
on day one; it needs the alerts above and the runbook.

---

## Appendix A: file map (for follow-up engineers)

| Concern | File | Lines |
|---|---|---|
| Structured logging | `functions/src/logging.ts` | 1-202 |
| Sentry init / beforeSend | `functions/src/sentry.ts` | 20-63 |
| Computer-Use daily rollup | `functions/src/computerUseMonitoring.ts` | 31-114 |
| Iroh daily rollup | `functions/src/irohMonitoring.ts` | 194-223 |
| Mercury daily rollup | `functions/src/mediaMonitoring.ts` | 101-215 |
| OTS proof validation | `functions/src/computerUseOpenTimestamps.ts` | 288-342 |
| Pairing rate limit | `functions/src/callables/shared.ts` | 102-104, 1377-1393 |
| Pairing transaction | `functions/src/callables/hermes.ts` | 121-216 |
| Escrow trust elevation | `functions/src/callables/computerUseSecurity.ts` | 62-229 |
| Audit chain entry | `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditChain.swift` | 11-100 |
| Audit export writer | `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditExportWriter.swift` | 11-100+ |
| Offline CLI verifier | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/BurnBarCLIAuditVerify.swift` | 4-70 |
| On-call runbook | `docs/runbooks/oncall.md` | 1-64 |
| Sentry rules template | `docs/ops/SENTRY_ALERT_RULES.md` | 1-49 |
| Event catalog | `docs/ops/EVENT_CATALOG.md` | 1-22 |
| Threat model | `docs/THREAT_MODEL.md` | 1-288 |
| Apple audit TTL | `functions/src/appstore/audit.ts` | 25-75 |

## Appendix B: detection-to-asset matrix

| Detection | Asset defended | Today | Target |
|---|---|---|---|
| Pairing brute force | Hermes / iroh pairing | partial | aggregate alert + auto-revoke |
| Trust elevation | Escrow device trust | log-only | Sentry + APNs notify |
| Grant issuance | Escrow grants | missing | Sentry tag |
| Audit tamper | Computer Use chain | user-reported | scheduled sweep + Sentry tag |
| OTS regression | Audit anchor | user-reported | scheduled sweep + SLO |
| Screen-share exfil | Mercury media | log-only | per-pairing alert |
| Quota burn | Hosted quota | budget-only | model-switch anomaly |
| Operator misuse | `burnbarOperator` claim | rule-deny only | read-deny alert |
| Panic halt | Computer Use safety | log-only | Sentry tag |
| Passkey / MFA | Account security | missing | event + Sentry tag |
| Key rotation | Escrow / audit-export | missing | event + Sentry tag |
| 429 abuse | Pairing / callable | dropped | tagged metric |
