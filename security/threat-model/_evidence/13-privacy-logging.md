# Domain 13 — Privacy, Telemetry, Logging, Crash & Push Metadata (LINDDUN / Phase 11)

Auditor-grade evidence package. **Code is the source of truth.** File:line refs were verified with rg/Read at review time (repo state 2026-06-13). Confidence marked per item.

---

## Components & files reviewed

- `functions/src/logging.ts` — server structured-log PII scrubber (`scrubFields`, `scrubString`, `SCRUB_PATTERNS`, `isSensitiveLogKey`, callable logging wrappers).
- `functions/src/sentry.ts` — server-side Sentry init + `sanitizeSentryEvent` / `sanitizeSentryValue` scrubbers, `setSentryUser`/`sentryUserIdForUID`.
- `functions/src/agentNotifications.ts` — agent-reply notification events, `GENERIC_PREVIEW`, `latestAssistantReply`, `buildFcmMessage`, fan-out, sweeper.
- `functions/src/callables/voipPush.ts` — `triggerVoIPCall` callable; writes `voip_outbound` / `fcm_outbound` payloads.
- `functions/src/voipPush.ts` — `parseTriggerRequest`, `resolveFanOut`, entitlement gate.
- `functions/src/apnsSender.ts` — APNs HTTP/2 VoIP push sender, retry sweeper, `lastFailureReason` capture.
- `functions/src/fcmAndroidSender.ts` — Android FCM data-message sender, retry sweeper.
- `functions/src/callables/encryptedSearch.ts` — search index commit + `searchEncryptedSessionLogs` + `queryConversations` (facets/aggregates).
- `functions/src/callables/encryptedSearchIndex.ts` — `buildCloudSearchPostingEdges` (posting graph stored server-side).
- `functions/src/callables/conversationQuery.ts` — cleartext facet filters + `mapSessionLogManifestRow`.
- `functions/src/callables/shared.ts` — `requireSearchHashes` validation (32-hex), `sha256Hex`, hash bounds.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` — client token/semantic hash derivation (`searchIndexTokenHashes`, `searchQueryTokenHashes`, `tokenHashes(forTerms:)`, `semanticHashes`, `keyedHMACHex`).
- `functions/src/accountDeletion.ts` — `eraseUserCloudData` deletion tree.
- `functions/src/callables/dataDeletion.ts` — per-collection "delete my data".
- `OpenBurnBarMobile/App/AppDelegate.swift` — iOS Sentry init (`configureSentryIfAvailable`).
- `AgentLens/App/AgentLensApp.swift` — macOS Sentry init (`configureSentryIfAvailable`).
- `OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaAnalyticsEvent.swift` — media analytics event shape + `NoOpMediaAnalyticsSink`.
- `firestore.indexes.json` — TTL field overrides; `voip_outbound`/`fcm_outbound`/`agent_notification_events` indexes.
- `firestore.rules` — server-only collection notes.
- `docs/security/BurnBar-threat-model.md`, `SECURITY.md` — claims cross-checked.

---

## Data inventory (what the cloud / third parties observe)

| Data element | Where | Sealed? | Observed by |
|---|---|---|---|
| Agent prompts / outputs (bodies) | Storage `users/{uid}/session_logs/.../bodies/*.json.aesgcm`; sealed snippets/titles | Yes (AES-256-GCM, vault key) | nobody w/o vault key |
| Search token hashes | `users/{uid}/cloud_search_chunks.tokenHashes`, `cloud_search_postings` | Keyed HMAC-SHA256 trapdoor (128-bit truncation) | Firestore/operator sees hashes + co-occurrence |
| Search semantic hashes | `cloud_search_chunks.semanticHashes` | Keyed HMAC trapdoor | Firestore/operator sees buckets |
| Facets: provider, model, deviceId, sourceType, costUSD, totalTokens, startTime | `users/{uid}/session_logs` (cleartext) | **No** | Firestore/operator + `queryConversations` |
| Push tokens (APNs voip, FCM) | `users/{uid}/devices/*`, `voip_outbound`, `fcm_outbound` | No (must be cleartext) | BurnBar + APNs/FCM |
| Agent-reply push payload | FCM/APNs | Generic preview only | APNs/FCM see provider label + thread_id |
| **VoIP/call push payload: callId, connectionId, pairedDeviceId, displayName/caller_name, isVideo** | `voip_outbound`/`fcm_outbound` docs + APNs/FCM | **No (cleartext)** | **BurnBar + APNs (Apple) + FCM (Google)** |
| Device IDs / client IDs / thread IDs | events, devices, postings | No | Firestore/operator |
| Crash reports (client) | Sentry (3rd-party) | **No beforeSend scrubber on iOS/macOS** | Sentry SaaS |
| Crash reports (server) | Sentry | Scrubbed by `sanitizeSentryEvent` | Sentry SaaS |
| Hashed UID | logs (`user_id_hash` 8 chars), Sentry (`sha256[:16]`) | Truncated hash | logs/Sentry |

---

## Controls present

- **Server log PII scrubber** — `functions/src/logging.ts:48-99` (`scrubString`, `scrubFields`, `scrubValue`) — strength **moderate** — regex-scrubs email/IPv4/known-prefix keys/16-digit CC; key-based redaction for `token/secret/password/...`; UID truncated to 8 chars; 1024-char truncation. Pattern-based (see gaps).
- **Sensitive-key redaction** — `functions/src/logging.ts:32-45` (`isSensitiveLogKey`) — strength **moderate** — normalizes key, redacts `accesstoken/apikey/authorization/bearer/cookie/password/privatekey/secret/token`.
- **Callable-failure capture routes through Sentry** — `functions/src/logging.ts:186-195` (`withCallableLogging`) — strength **moderate** — `String(error)` is logged via `logError` → `scrubFields`, and `captureException` only sends `callable/trace_id/user_id_hash` as extras.
- **Server Sentry event sanitizer** — `functions/src/sentry.ts:82-152` (`sanitizeSentryEvent`, `sanitizeSentryValue`, `redactURLSecrets`) — strength **strong** — deletes `request.data/cookies/env/query_string`, redacts `body|rawBody|requestBody|requestData|data|payload` keys, redacts sensitive headers + URL secrets, `sendDefaultPii:false`.
- **Server Sentry UID hashing** — `functions/src/sentry.ts:175-183` (`setSentryUser`, `sentryUserIdForUID`) — strength **strong** — `sha256(uid)[:16]`, one-way, grouping-only.
- **Generic agent-reply preview** — `functions/src/agentNotifications.ts:22,310` (`GENERIC_PREVIEW`, `createEventFromThreadWrite`) — strength **strong** — push preview is the static string `"OpenBurnBar has a new agent reply."`; reply `text` from `latestAssistantReply` is **not** copied into `preview`. APNs `notification.body` + FCM `data.preview` both use the generic string (`buildFcmMessage` `agentNotifications.ts:226,234,257`).
- **Keyed search trapdoors** — `CloudVaultCrypto.swift:850-859` (`tokenHashes(forTerms:)`), `1075-1085` (`keyedHMACHex`), `1100-1110` (`searchKey`) — strength **strong (confidentiality of plaintext) / moderate (metadata)** — HMAC-SHA256 under HKDF(vaultKey)-derived key, per-user, truncated to 16 bytes (32 hex). Server never receives vault key; offline dictionary recovery of plaintext is infeasible without the key.
- **Search hash validation** — `functions/src/callables/shared.ts:324-342` (`requireSearchHashes`) — strength **moderate** — enforces `^[a-f0-9]{32}$`, dedupes, caps at 1024.
- **Media analytics is content-free + no-op by default** — `OpenBurnBarMedia/MediaAnalyticsEvent.swift:10-12,59` (header comment + `NoOpMediaAnalyticsSink`) — strength **strong** — event params are scalar counters; "hashes, peer NodeIds, and frame contents never appear"; default sink discards. No Firebase Analytics/Amplitude SDK wired (verified absent in `project.yml`).
- **Account-erase deletes user tree + storage + secrets** — `functions/src/accountDeletion.ts:93-133` (`eraseUserCloudData`) — strength **moderate** — deletes `users/{uid}` + `workspaces/{workspace-uid}` recursive trees, storage prefixes, provider secret refs/Secret Manager versions. (Coverage gap below.)
- **TTL on transient collections** — `firestore.indexes.json:1794-1830` — strength **moderate** — `stripe_webhook_events`, `pop_nonces`, `_rate_limits`, `hermes_gateway_device_sessions` expire. (Push queues excluded — gap below.)

---

## Claims verified against code

- "All log fields are scrubbed before emission … API keys and tokens are masked" (`logging.ts:1-10` header) — **Partial** — only string values are scrubbed; numbers/booleans pass through (`scrubValue` `logging.ts:72-90` returns non-strings unchanged). A secret placed in a numeric field, or PII that is not email/IPv4/known-prefix, is logged verbatim. Conservative read: the scrubber catches *common* shapes, not all secrets/PII.
- "Agent reply push notifications use a generic preview rather than message text" (threat-model:27,441) — **Defensible** — `agentNotifications.ts:310` sets `preview: GENERIC_PREVIEW`; `buildFcmMessage:234,257` use it for both `data.preview` and `notification.body`. Reply text never reaches the push.
- "VoIP/call push includes call and caller metadata" (threat-model:442,493,362) — **Defensible (this is a real leak the doc admits)** — `callables/voipPush.ts:39-45,68-76` ship `callId/connectionId/pairedDeviceId/displayName` to APNs payload and `connection_id/caller_name/caller_initial/feature/call_id/paired_device_id` to FCM `data`. Cleartext `displayName` → `caller_name` reaches Apple/Google and is stored cleartext in root `voip_outbound`/`fcm_outbound` docs.
- "Search operates over keyed hashes and plaintext facets … sealed bodies/previews/snippets" (threat-model:482,134) — **Defensible** — `encryptedSearchIndex.ts:44-67` stores `tokenHashes`/`semanticHashes` + cleartext `sourceKind/sourceID/provider/ordinal`; `conversationQuery.ts:100-113,140-152` filter/return cleartext `provider/model/deviceId/sourceType/costUSD/totalTokens`. Bodies/snippets are sealed; facets are not.
- "anonymized per-install user ID … without collecting any personally identifiable information" (AppDelegate.swift:72-78; AgentLensApp.swift:1188-1195) — **Partial** — iOS seeds from `identifierForVendor` (acceptable); **macOS seeds from `NSFullUserName()`** (`AgentLensApp.swift:1192`) — the OS account *full name* (often the user's real name) is the HMAC-less SHA input. Output is one-way hashed so Sentry cannot reverse it, but calling the *input* "no PII" is imprecise; and crash payloads themselves are unscrubbed (next claim).
- "Mirrors the macOS … consent posture exactly … crash-instrumented" (AppDelegate.swift:47-52) — **NotDefensible as a privacy control** — neither client sets `beforeSend`, `sendDefaultPii=false`, breadcrumb scrubbing, nor any consent gate (`AppDelegate.swift:60-70`, `AgentLensApp.swift:1176-1186`). Sentry default breadcrumbs (network/UI/console) and exception strings ship to Sentry SaaS unscrubbed. The server has a scrubber (`sentry.ts`); the clients do not — asymmetric.
- "Encrypted session backups … store sealed bodies" / project memory "opaque vault-key-derived document ID" — **Defensible** — `encryptedSearch.ts:87` stores `*.json.aesgcm`; `requireSealedText`/`requireCloudVaultBlobEnvelope` enforce sealed shape; project-memory docID is `pm_`+HMAC (`CloudVaultCrypto.swift:803-807`).
- "Notification metadata in Firestore; generic preview avoids reply text" (threat-model:137) — **Defensible** for content; **Partial** for metadata retention — events carry `runtime/providerLabel/title` (provider identity leak) and persist with no TTL.

---

## Threats

### T-PRV-01 — VoIP/call push leaks cleartext caller display name + call graph to Apple & Google
- **Category:** LINDDUN Disclosure + Identifying; STRIDE Information Disclosure. Maps Phase 11 / threat-model:362,493.
- **Severity:** High
- **Component:** `functions/src/callables/voipPush.ts:39-87`, `functions/src/voipPush.ts:42-58`, `functions/src/apnsSender.ts:141-221`, `functions/src/fcmAndroidSender.ts:57-106`.
- **Attack path:** Caller initiates a Mercury call → `triggerVoIPCall` writes `voip_outbound` (APNs payload `{callId, connectionId, pairedDeviceId, displayName, isVideo}`) and/or `fcm_outbound` (FCM `data.caller_name`/`call_id`/`connection_id`/`paired_device_id`). APNs (Apple) and FCM (Google) — third-party sub-processors — receive and can log the cleartext display name and stable connection/device identifiers. Apple/Google (or anyone with push-log access) builds a social graph + device-correlation over time.
- **Existing mitigation:** Entitlement gate (`voipPush.ts:28-30`); App Check; the doc openly admits this leak.
- **Gap:** Display name is unnecessary for wake-up; could be a sealed token resolved client-side or a generic "Incoming call". `connection_id`/`paired_device_id` are stable correlators.
- **Residual risk:** High — every call exposes caller identity + a persistent device link to two external processors.

### T-PRV-02 — Push-queue docs (voip_outbound/fcm_outbound) are root collections: never deleted on account erase, no TTL
- **Category:** LINDDUN Non-compliance (right-to-erasure) + Disclosure; GDPR Art.17. Agentic/data-lifecycle.
- **Severity:** High
- **Component:** `functions/src/callables/voipPush.ts:57,78` (root `collection("voip_outbound")`/`"fcm_outbound")`), `functions/src/accountDeletion.ts:112-113`, `firestore.indexes.json:1278-1332,1794-1830`.
- **Attack path:** `eraseUserCloudData` walks only `users/{uid}` + `workspaces/{workspace-uid}` trees + `provider_account_secret_refs` by uid. The push-queue collections are **top-level**, keyed by random doc id, carrying `uid` + cleartext `payload.displayName/caller_name`, `callId`, `connectionId`, `pairedDeviceId`, push tokens, and `lastFailureReason`. They are **not** enumerated by account deletion and have **no TTL** (only `stripe_webhook_events/pop_nonces/_rate_limits/hermes_gateway_device_sessions` carry `ttl:true`). After a user deletes their account, these cleartext call-metadata docs persist indefinitely.
- **Existing mitigation:** Default-deny client reads (no rules match block → Admin-SDK-only writes); `status:"sent"/"rejected"` doc never re-read by clients.
- **Gap:** No TTL field/index; no deletion in `eraseUserCloudData`/`dataDeletion.ts`; no scheduled purge of terminal-state docs.
- **Residual risk:** High — erasure contract ("delete cloud data", `accountDeletion.ts:2-6`) is violated for call metadata; unbounded retention of identifying push payloads.

### T-PRV-03 — Client crash reports (iOS + macOS) ship to Sentry with no scrubber, no consent gate
- **Category:** LINDDUN Disclosure + Unawareness; STRIDE Information Disclosure.
- **Severity:** High
- **Component:** `OpenBurnBarMobile/App/AppDelegate.swift:53-85`, `AgentLens/App/AgentLensApp.swift:1168-1202`.
- **Attack path:** Sentry started with only `dsn/environment/release/tracesSampleRate=0/enableAutoSessionTracking`. No `beforeSend`, no `beforeBreadcrumb`, no `sendDefaultPii=false`, default swizzling/breadcrumbs on. On a crash inside chat/agent/media code, Sentry's default breadcrumbs (network requests w/ URLs+params, view-controller lifecycle, console logs) and any exception messages/local-variable context that surface plaintext prompts, file paths, peer IDs, or tokens are uploaded to Sentry SaaS. No in-app consent toggle — enablement is silent (gated only on Info.plist `sentry.dsn` injected for internal builds).
- **Existing mitigation:** `tracesSampleRate=0` (no perf spans); DSN absent in OSS builds → disabled; server-side Sentry *is* scrubbed (`sentry.ts`).
- **Gap:** Client/server scrubbing asymmetry; no client `beforeSend`; no consent UX; macOS user-id seed uses real name (`NSFullUserName()`).
- **Residual risk:** High for internal/CI-DSN builds — uncontrolled PII/prompt egress to a third-party processor.

### T-PRV-04 — Server log scrubber is pattern-based; numeric fields and non-pattern PII bypass it
- **Category:** LINDDUN Disclosure; STRIDE Information Disclosure. Maps threat-model:365.
- **Severity:** Medium
- **Component:** `functions/src/logging.ts:16-29,48-90`.
- **Attack path:** `scrubValue` only transforms `string`; numbers/booleans returned as-is (`logging.ts:72-89`). A secret/PII written as a number, or a string that is none of {email, IPv4, `sk-|AIza|ya29.|eyJ`-prefixed, 16-digit-CC}, is logged verbatim. New providers' key formats (e.g. `xai-`, Anthropic `sk-ant-` partially matches `sk-`, MiniMax/Kimi tokens) aren't all covered; bearer values only redacted if the *key name* matches `isSensitiveLogKey`. Free-form `String(error)` (e.g. `lastFailureReason` from APNs body, provider error bodies) may carry tokens/paths not matching a pattern.
- **Existing mitigation:** Known-prefix + key-name redaction + 1024-char truncation; most callable logs only emit `event/callable/trace_id/user_id_hash`.
- **Gap:** No allowlist model; numeric values unscrubbed; depends on developers naming fields "sensitively".
- **Residual risk:** Medium — log/Sentry secret disclosure on edge fields.

### T-PRV-05 — Encrypted-search metadata: facets + posting graph + access patterns enable inference
- **Category:** LINDDUN Linking + Detecting + Disclosure; SSE leakage. Maps threat-model:363.
- **Severity:** Medium
- **Component:** `functions/src/callables/encryptedSearchIndex.ts:44-67`, `functions/src/callables/encryptedSearch.ts:618-757`, `functions/src/callables/conversationQuery.ts:100-152`.
- **Attack path:** Even with keyed token/semantic hashes, the server/operator observes: which hashes co-occur per chunk (`tokenHashes` arrays), posting fan-out per `postingKey`, query-time which hashes a user searches (`searchEncryptedSessionLogs` request), result set sizes/scores, and cleartext facets (`provider/model/deviceId/sourceType/costUSD/totalTokens/startTime`). Frequency analysis on hashes + facet correlation yields: which AI providers/models a user uses, spend, activity timeline, device usage, and probable repeated query topics (same hash recurring). Truncation to 128 bits is collision-safe but does not hide structure.
- **Existing mitigation:** Per-user HKDF keying (cross-user hashes differ); sealed snippets/titles; bounded hash counts.
- **Gap:** No padding/dummy-posting noise; facets are cleartext; query hashes sent in the clear to the endpoint.
- **Residual risk:** Medium — content-adjacent inference and behavioral profiling by a curious/compromised operator.

### T-PRV-06 — Agent-notification events retain provider identity + thread graph with no TTL
- **Category:** LINDDUN Linking + Disclosure + Non-compliance; data minimization/retention.
- **Severity:** Low
- **Component:** `functions/src/agentNotifications.ts:300-321,494-505`; `firestore.indexes.json:1334+` (no `ttl:true`).
- **Attack path:** Each reply writes `users/{uid}/agent_notification_events/{id}` with `runtime`, `providerLabel`, `title` (= "`<Provider>` replied"), `threadId`, `messageId`, `sourcePath`. These reveal *which* AI agent answered and a per-thread reply cadence. They live under `users/{uid}` (so account-erase *does* remove them — unlike T-PRV-02) but never expire; FCM `data` also carries `runtime`+`deep_link` to FCM/Google.
- **Existing mitigation:** Generic preview; covered by account-erase tree.
- **Gap:** No TTL; provider label in title/FCM is a usage-fingerprint leak to the push provider.
- **Residual risk:** Low/Medium — provider-usage fingerprint + reply timing.

### T-PRV-07 — Non-repudiation gap / push-token correlation across providers
- **Category:** LINDDUN Non-repudiation + Linking.
- **Severity:** Low
- **Component:** `functions/src/voipPush.ts:79-104` (`resolveFanOut`), `functions/src/agentNotifications.ts:551-562`.
- **Attack path:** Stable `pairedDeviceId`/`connection_id`/push tokens flow to APNs+FCM and are stored in queue docs; a processor with cross-service visibility (or BurnBar) can link a device across sessions and tie call events to a user with high confidence (and timestamps in queue docs prove a call was attempted).
- **Existing mitigation:** Tokens rotate on reinstall; per-user scoping.
- **Gap:** Identifiers are long-lived; no rotation of `connectionId` correlator.
- **Residual risk:** Low.

---

## Gaps / missing controls

1. **No TTL/erasure for `voip_outbound` & `fcm_outbound`** (root collections, cleartext caller names) — T-PRV-02. Add `ttl:true` on a `deleteAt`/`expireAt` field and include in `eraseUserCloudData`.
2. **No client-side Sentry `beforeSend`/breadcrumb scrubber and no consent gate** on iOS/macOS — T-PRV-03. Server has one; clients don't.
3. **Display name shipped cleartext to APNs/FCM** — T-PRV-01. Could be sealed/resolved client-side or generic.
4. **Log scrubber misses numeric fields and non-pattern secrets** — T-PRV-04. No allowlist model.
5. **macOS Sentry anonymized-id seed = `NSFullUserName()`** (real name as hash input) — T-PRV-03; inconsistent with iOS's `identifierForVendor`.
6. **No retention/TTL on `agent_notification_events`** — T-PRV-06.
7. **Search facets (provider/model/device/cost/source/time) cleartext + query hashes sent in clear** — T-PRV-05. No padding/obfuscation of access patterns.
8. **No documented sub-processor list / DPA mapping in-code** for Sentry, APNs (Apple), FCM (Google), Stripe, Firebase — Unawareness/Non-compliance (transparency).

---

## Overclaims (doc/name implies more than code)

- **`logging.ts:1-10` header — "All log fields are scrubbed before emission … API keys and tokens are masked."** Reality: only *string* values, only *known patterns/key-names*; numeric and unknown-format secrets pass through (T-PRV-04).
- **AppDelegate/AgentLensApp — "without collecting any personally identifiable information" / "consent posture."** Reality: no client crash-payload scrubbing, no consent gate; macOS seeds the "anonymized" id from the user's real name (T-PRV-03). The *id* is hashed but the *crash body/breadcrumbs* are not redacted.
- **"Encrypted search" / "zero-knowledge bodies stay sealed" (encryptedSearch.ts:773 comment).** Accurate for bodies, but the *name* "zero-knowledge" overstates: cleartext facets + observable hash co-occurrence/access patterns are non-trivial metadata leakage (T-PRV-05). The threat-model itself (threat-model:486) correctly rejects "BurnBar cannot see anything," so the code comment is the looser claim.
- **account-delete "promises cloud data deletion" (accountDeletion.ts:2-6).** Reality: root push-queue collections with cleartext caller metadata are not deleted (T-PRV-02).

Note: the canonical `docs/security/BurnBar-threat-model.md` is **honest** about T-PRV-01 and T-PRV-05 (lines 362-363, 493) and does NOT overclaim them. The overclaims above are in *code comments / client docstrings*, and the **uncovered** gaps the threat model misses are T-PRV-02 (root-collection erasure/TTL), T-PRV-03 (client Sentry scrubbing/consent asymmetry), and T-PRV-06 (event TTL).

---

## Crypto / protocol notes

- Search token hashes: `HKDF<SHA256>(vaultKey, salt "OpenBurnBar-CloudSearch-Salt-v1", info "OpenBurnBar-CloudSearch-TokenHash-v1") → HMAC<SHA256>(term)` truncated to 16 bytes / 32 hex (`CloudVaultCrypto.swift:850-859,1100-1110`). Per-user keyed → no cross-user equality, no offline plaintext recovery without the vault key. 128-bit truncation is collision-safe for a search index. **Confidentiality of plaintext: strong. Metadata/pattern hiding: none.**
- Semantic hashes: keyed LSH-style buckets over phrase tokens (`semanticHashes` `CloudVaultCrypto.swift:910+`), keyed by `semanticSearchKey`. Same property: trapdoor, not pattern-hiding.
- Server Sentry UID: `sha256(uid)[:16]` — one-way, non-reversible, grouping-only (`sentry.ts:180-183`). Good.
- APNs JWT: ES256 with `.p8`, 50-min cache (`apnsSender.ts:59-97`) — standard, not a privacy issue. `apns-id` randomized per request (`apnsSender.ts:172`).

---

## Open questions / UNKNOWN (deployed evidence would resolve)

1. **Is `SENTRY_DSN` actually set for client (iOS/macOS) production/App-Store builds, or only internal/CI?** Resolve with the deployed Info.plist `sentry.dsn` value per distribution channel. If set for public builds, T-PRV-03 is Critical for real users.
2. **Sentry project data-scrubbing/PII-stripping server-side config** (Sentry's own "Data Scrubber"/"Sensitive Fields") — could compensate for missing client `beforeSend`. Resolve with the Sentry org settings export.
3. **Is there an out-of-band scheduled purge or Firestore TTL policy applied at the GCP console level** for `voip_outbound`/`fcm_outbound`/`agent_notification_events` that isn't in `firestore.indexes.json`? Resolve with `gcloud firestore` TTL config / console export. (Code shows none.)
4. **Does account deletion (`deleteAccount` callable) invoke any additional cleanup** for root collections not visible in `accountDeletion.ts`? Resolve by reading the callable wiring in `functions/src/index.ts` + `callables/dataDeletion.ts` registration. (Reviewed paths show no push-queue cleanup.)
5. **Apple/Google push-log retention** for VoIP/FCM payloads (caller_name) — external processor retention policy; resolve via Apple/Google DPA.
6. **Production push-payload inventory** (Mercury media pushes, Android data pushes beyond the two reviewed) — resolve by enumerating every `getMessaging().send`/`add({collection:*_outbound})` call site in deployed functions.
