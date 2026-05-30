# 02 — Cloud Backend & Infrastructure Inventory

> **Document 2 of 5.** This is the exhaustive map of everything in the OpenBurnBar cloud that can incur cost. Every function, collection, bucket, secret, relay, and external API. Doc 3 maps these to features; Doc 4 turns them into dollars.
>
> **Stack:** Firebase / Google Cloud Platform, single region **`us-central1`**. Functions are **Firebase Functions v2 (Node.js 22)**. Source: `functions/` in the repo. All config values below are read from the live code as of 2026-05-30.

---

## 1. Top-line shape of the backend

| Dimension | Value | Cost implication |
|---|---|---|
| **Total deployed Cloud Functions** | **76** | Scale-to-zero (see below) |
| Functions with `minInstances > 0` | **0** | **No always-on / idle compute cost.** Every function cold-starts from zero. |
| `setGlobalOptions()` defaults | **none** | Functions inherit v2 platform defaults: 256 MiB, 60 s timeout, max 1000 instances, concurrency 80 |
| Region | `us-central1` only | No multi-region replication cost; no geo-egress between regions |
| Scheduled (cron) functions | **12** | The only *guaranteed* recurring invocation cost |
| Functions calling a **server-funded** paid LLM/AI API | **2** | The only server-side model-token COGS in the whole system |
| Firestore composite indexes | ~per `firestore.indexes.json` (large-field exemptions applied) | Index storage bytes (a watched billing metric) |
| Cloud Storage usage | Encrypted session-log blobs only, **≤10 MB/blob** | Low ($0.02/GB-mo) |

**The headline:** this backend is architected to be **cheap at rest**. With zero `minInstances`, an operator with zero active users pays essentially only for the 12 cron jobs firing against a near-empty database plus the flat n0 relay fee. Variable cost scales with *paid* user activity, and the two genuine variable-cost vectors (relay bandwidth, vision-LLM tokens) are both wrapped in hard kill-switches (Doc 3 §8).

---

## 2. The 76 functions, grouped by cost behavior

Full per-function config (region, memory, timeout, maxInstances, secrets, trigger) is preserved at the end of this doc in §9. Here they are grouped by **what drives their cost**.

### 2.1 Always-running cron (the recurring baseline) — 12 functions

| Function | Cadence | What it scans | Scan cost risk |
|---|---|---|---|
| `rebuildRollups` | **every 5 min** | `collectionGroup(rollup_jobs).where(dirty==true).limit(50)` — dirty-flag gated | Low (bounded) |
| `refreshAllProviderQuotas` | **every 15 min** | `collectionGroup(provider_accounts)` stale-first `limit(20)` | Low (bounded, stale-first cursor) |
| `recomputeMediaQuotaUsage` | every 60 min | per-user media quota recompute (active users) | Medium (collection-group) |
| `recomputeComputerUseQuotaUsage` | every 60 min | `collectionGroup(computer_use_actions)` for active users today | Medium (collection-group) |
| `evaluateMediaBudget` | every 60 min | reads `ops/media_session_daily_rollups` (month) + writes Remote Config | Low |
| `evaluateComputerUseBudget` | every 60 min | reads `ops/computer_use_session_daily_rollups` (month) + Remote Config kill-switch | Low |
| `rollupComputerUseDaily` | **daily 00:30 UTC** | **full `collectionGroup(computer_use_sessions)` + `(computer_use_actions)`** — all users | **Highest scan in system; O(users×sessions/day)** |
| `rollupMediaSessionDaily` | daily | **full `collectionGroup(media_session_events)`** — all users | High (O(users×sessions/day)) |
| `rollupIrohTransportDaily` | daily 08:15 UTC | `collectionGroup(iroh_audit_events)` bounded by date | Medium |
| `refreshModelLandscapeBenchmarks` | daily | external benchmark APIs (no Firestore scan) | Low Firestore; external API call |
| `reconcileHostedEntitlementsDaily` | daily | active entitlements (≤250/run) via Apple ASC API | Low |
| `backfillProviderAccountDeviceLinksScheduled` | daily | first 500 users device-link backfill (migration) | Low/transient |

**Key scaling note from the paid-scale runbook:** rollups were deliberately re-architected to use **incremental counter documents** instead of rescanning every `users/{uid}/usage` doc every 5 minutes. `onUsageWritten` (a Firestore trigger) writes signed deltas into compact counter docs; `rebuildRollups` reads only those counters. This is the single most important cost-control in the write path. The two remaining *full* collection-group scans (`rollupComputerUseDaily`, `rollupMediaSessionDaily`) only touch the relatively small Computer-Use / Media event collections, which are themselves gated behind the expensive Tier-2 features.

### 2.2 Per-user-action functions (cost scales with paid activity)

These fire on user requests. They are the variable Functions-invocation cost. Grouped by feature family:

- **Usage / rollups:** `onUsageWritten` (Firestore trigger, high volume — see §3.1 write amplification), `rebuildUsageRollups` (manual rebuild).
- **Quota sync:** `connectProviderAccount`, `connectHostedQuotaAccount`, `connectSelfHostedQuotaAccount`, `uploadProviderQuotaSnapshot`, `refreshProviderAccountQuota`, `refreshProviderQuota`, `updateProviderAccount`, `deleteProviderAccount`, `deleteHostedQuotaCredentials`, `connectProviderCredential`, `deleteProviderCredential`.
- **Encrypted search / backup:** `beginEncryptedSessionBlobUpload`, `getEncryptedSessionBlobDownloadUrl`, `commitEncryptedSearchIndexBatch`, `searchEncryptedConversationIndex`, `queryConversations`, `commitEncryptedProjectMemorySnapshot`, `getEncryptedProjectMemorySnapshot`, `listEncryptedProjectMemorySnapshots`, `searchStreams`.
- **Remote MCP / CLI link:** `issueRemoteMcpGrant`, `revokeRemoteMcpClient`, `startCliLink`, `pollCliLink`, `completeCliLink`.
- **Hermes relay:** `createHermesPairing`, `completeHermesPairing`, `listHermesConnections`, `revokeHermesConnection`, `updateHermesConnectionStatus`.
- **Pi Agent relay:** `createPiAgentPairing`, `completePiAgentPairing`, `listPiAgentConnections`, `revokePiAgentConnection`, `updatePiAgentConnectionStatus`.
- **Device links:** `adoptProviderAccountForDevice`, `revokeProviderAccountDeviceLink`, `backfillProviderAccountDeviceLinks`.
- **Media / Computer Use:** `validateMediaPurchase`, `grantMediaGrandfather`, `triggerVoIPCall`, `validateOpenTimestampsProof`, plus the event-driven push senders `sendVoIPOutbound`, `sendFcmOutbound`, `onCliSessionAgentReplyNotification`, `onMobileAssistantAgentReplyNotification`, `submitAgentNotificationReply`.
- **Insights:** `insightsHostedAnswer` ⭐ (one of the two paid-LLM functions).
- **Billing:** `beginEntitlementBinding`, `verifyHostedQuotaEntitlement`, `restoreHostedQuotaEntitlement`, `appStoreServerNotificationsV2` (Apple S2S), `createStripeBurnBarProCheckoutSession`, `createStripeBurnBarProPortalSession`, `stripeBurnBarProWebhook`, `verifyGooglePlayBurnBarProSubscription`.
- **Public / misc:** `latestRouterRundown` (public, CDN-cached), `healthCheck`/`healthLive`/`healthReady`, `seedAndroidDemoAccount`, `deleteUserCloudData` (1 GiB / 540 s — GDPR erase).

### 2.3 The only two server-funded LLM/AI calls ⭐

This is the crux of server-side model COGS. **The user's own coding agents never run on the operator's dime** — OpenBurnBar relays the user's own keys/models. Only two functions spend the *operator's* money on a model:

1. **`insightsHostedAnswer`** — proxies the "Intelligence Brief" question through **OpenRouter**, default model **`minimax/minimax-m2`** (public name "MiniMax 2.7"). Bounded: `max_tokens: 1400` output, 24 KB input digest, 45 s abort, `maxInstances: 50`. Cost-stamped at **$0.255/M input, $1.00/M output** → ~**$0.0004–$0.0015 per answer**. This is the cheap-tier fallback, only used when the user has *no* model configured.
2. **`refreshModelLandscapeBenchmarks`** — calls the Artificial Analysis API (+ free HuggingFace / Design Arena) once daily to build the public router ranking. Fixed daily cost, not per-user.

**Computer Use's vision model is *also* server-funded** but is *not* a Cloud Function call — the Mac client calls it directly (default **Claude Sonnet 4.5**), and the spend is metered into Firestore (`visionTokensCostUSD`) and bounded by the $5/user/day + $1500/$2500 global caps (Doc 3 §6). Treat it as the dominant Tier-2 token COGS.

---

## 3. Firestore — the data model and its write amplification

### 3.1 Write amplification (the dominant Firestore cost driver)
Every usage event the client syncs triggers `onUsageWritten`, which fans out **~6–10 Firestore writes** in a counter transaction:
- mark `users/{uid}/rollup_jobs/current` dirty (1)
- `users/{uid}/usage_counter_keys/{hash}` (1+)
- `users/{uid}/usage_counter_days/{day}` + `usage_counter_totals/all_time` (2)
- per-dimension subcounters under each: `providers/`, `accounts/`, `models/`, `devices/` (3–4)

So a single agent session that emits 10 usage events can generate **60–100 Firestore writes**. At $0.18/100k writes this is still tiny per user, but it is the line that grows fastest with engagement. (Doc 4 §3 quantifies it.)

### 3.2 Top-level / per-user collections (cost-relevant ones)

**Per-user-action writers** (`users/{uid}/...`):
`usage`, `usage_counter_*` (days/keys/totals + subcounters), `usage_rollups` (5 docs/user/cycle), `quota_snapshots`, `provider_accounts`, `provider_connections`, `provider_account_device_links`, `devices`, `cli_sessions`, `mobile_assistant_chats`, `chat_threads`, `session_logs` (+ `chunks`), `text_snippets`, `cloud_search_documents` / `cloud_search_chunks` / `cloud_search_postings` / `cloud_search_index_state`, `cloud_vault_key_wrappers`, `project_memory_snapshots`, `hermes_connections` / `hermes_pairings` / `hermes_relay_requests` (+ `chunks`) / `hermes_audit_events`, `pi_agent_*` (same shape), `runtime_connection_preferences`, `remote_mcp_clients` / `remote_mcp_grants`, `agent_notification_events` / `agent_notification_replies`, `escrow_devices` / `escrow_grants` / `escrow_envelopes` / `escrow_audit_events`, `iroh_pairing` / `iroh_pairing_keys` / `iroh_audit_events`, `media_session_events` / `media_quota_usage` / `media_attachment_manifests`, `computer_use_sessions` / `computer_use_actions` / `computer_use_quota_usage`, `cli_agent_mission_requests`, `entitlements` / `entitlement_events` / `entitlement_bindings`, `budgetRules` / `budgetEvents`, `_rate_limits/*`.

**Global / ops collections:**
`ops/media_budget_status`, `ops/computer_use_budget_status` (+ events), `ops/media_session_daily_rollups`, `ops/computer_use_session_daily_rollups`, `ops/iroh_transport_daily_rollups`, `model_benchmark_snapshots`, `model_benchmark_source_status`, `router_rundowns` (+ `latest`), `router_rundown_catalog`, `voip_outbound`, `fcm_outbound`, `stripe_customers`, `workspaces/workspace-{uid}/.../artifacts`.

### 3.3 Index storage
`firestore.indexes.json` ships **single-field index exemptions** for large fields (`body`, `payloadCiphertext`, `ciphertext`, `text`, `data`, `chunkHashes`, big rollup arrays) so encrypted blobs and big arrays don't bloat index storage. The `chunks.terms` array index is intentionally kept (powers `array-contains` search). Index storage bytes are one of the four watched billing metrics.

### 3.4 Retention / deletion (affects storage cost)
- **No global TTL** on session logs, search indexes, or media/computer-use events — they persist until account deletion. (Cloud window in the UI emphasizes ~90 days, but data isn't auto-purged.)
- **TTL fields set** on: `_rate_limits` daily docs (8 days) / monthly docs (45 days), `iroh_audit_events`, Hermes/Pi relay requests, audit events (90 days) — but these require a Firestore console TTL policy to actually delete.
- **`deleteUserCloudData`** recursively erases `users/{uid}` + `workspaces/workspace-{uid}` in 400-doc batches and destroys all Secret Manager secrets before deleting the Auth user (GDPR-clean).

---

## 4. Cloud Storage (GCS)

- **What's stored:** Only **AES-256-GCM client-encrypted session-log bodies**. Path: `users/{uid}/session_logs/{documentId}/bodies/{bodyHash}.json.aesgcm`, content-type `application/octet-stream`. Real bucket: `burnbar-hosted-mcp-bodies-246956661961`.
- **Hard cap:** **10 MB per blob** (`ENCRYPTED_SESSION_BLOB_MAX_BYTES`, enforced in both `storage.rules` and the commit callable, which verifies size+hash+content-type before indexing).
- **Zero-knowledge:** the server never holds the encryption key; decryption is device-side only. → **no compliance/audit cost** for raw developer data.
- **Media and Computer-Use payloads are NOT in GCS.** Media bytes are E2E peer-to-peer (iroh). Computer-Use screenshots stay local on the Mac; only chain *headers* (hashes, no images) replicate to Firestore. This is a major COGS win — the two heaviest data features write almost nothing to paid storage.
- **Rough footprint:** ~160 KB encrypted body per indexed session (Doc 4). At $0.02/GB-mo, even a 500-session/mo power user adds <$0.002/mo of storage.

---

## 5. Secrets, KMS, and external paid APIs

### 5.1 Secret Manager / KMS
Stores: hosted Codex `auth.json`, provider access keys, Apple ASC API key/cert, Stripe keys, the Remote-MCP HMAC secret, the cloud vault wrap key. Pricing: $0.06/active secret version-month + $0.03/10k access calls. Each hosted quota refresh = 1 secret access (~$0.000003) — linear with refresh frequency, which is itself capped (30/day, 300/mo).

### 5.2 Registered secrets (module-scope)
`ARTIFICIAL_ANALYSIS_API_KEY`, `OPENROUTER_API_KEY`, `APNS_KEY_ID/TEAM_ID/KEY_P8`, `HOSTED_QUOTA_RUNNER_TOKEN`, `APP_STORE_ASC_KEY_ID/ISSUER_ID/KEY_P8`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `REMOTE_MCP_TOKEN_HMAC_SECRET`.

### 5.3 External paid / third-party APIs the backend calls
| API | Caller | Billing |
|---|---|---|
| **OpenRouter** (MiniMax 2.7) | `insightsHostedAnswer` | per-token, operator-funded, bounded |
| **Artificial Analysis** | `refreshModelLandscapeBenchmarks` | daily, fixed |
| **Apple App Store Server API** | entitlement verify / reconcile / S2S | free |
| **Google Play Android Publisher** | `verifyGooglePlayBurnBarProSubscription` | free |
| **Stripe API** | checkout / portal / webhook | 2.9% + $0.30 per charge (processing) |
| **Apple APNs HTTP/2** | `sendVoIPOutbound` | free |
| **Firebase Cloud Messaging** | reply/VoIP senders | **free** |
| **Hosted quota runner (Cloud Run)** | quota refresh | Cloud Run compute (see §6) |
| **Firebase Remote Config** | budget evaluators | free |

---

## 6. The two Cloud Run services (separate from Functions)

1. **Hosted Quota Runner** (`openburnbar-quota-runner`, us-central1) — Dockerized Codex CLI; called by quota-refresh functions over HTTP with `HOSTED_QUOTA_RUNNER_TOKEN`. Cost driver: ~4.5 s @ 1 vCPU / 2 GB per refresh (~$0.0001/refresh). Scale-to-zero.
2. **Hosted Remote MCP** (`services/hosted-mcp`, serves `mcp.burnbar.ai`, us-central1) — answers MCP tool calls against the encrypted corpus, returns *sealed* (ciphertext) results. Cloud Run **request rate** is one of the four watched billing metrics (used as the hosted-relay spend proxy).

**Retired (do not re-provision — flagged by the commercial-launch gate):** the Hermes Cloud Run WebSocket relay + Memorystore Redis were **decommissioned 2026-05-28**, removing ~$245/mo. The active remote path is now iroh P2P with encrypted Firestore as last-resort fallback.

---

## 7. The n0 iroh relay (the one flat infra fee that matters)

- Mercury media + Computer-Use control streams ride the **iroh QUIC mesh**, primarily **NAT-holepunched peer-to-peer** (no operator bandwidth cost). When holepunch fails, traffic falls back to a **hosted n0 relay**.
- **Cost model:** the owned relay is n0's **`team-200` tier at a flat ~$200/month**, *not* metered per-GB by n0. The internal **$0.04/GB** figure is an *accounting* model used to project whether relayed bytes will exhaust the tier — it is the basis of the $600 soft / $1000 hard media budget caps, not an actual per-GB invoice line.
- **Direct-vs-relay split target:** ≥75% of sessions go peer-to-peer (zero relay bytes). Only CGNAT/strict-firewall sessions touch the relay.
- **Net infra delta after the Redis retirement:** −$245 (retired) + $200 (n0 relay) = **−$45/mo**.

---

## 8. The pre-existing SKU / entitlement plumbing (what billing already supports)

Entitlement docs live at `users/{uid}/entitlements/{id}`, written *only* by server reconcilers. Existing entitlement ids and the SKUs that grant them:

| Entitlement doc | Apple product id | Price seen in code/plans | Grants (features) |
|---|---|---|---|
| `hosted_quota_sync` | `com.openburnbar.hostedQuotaSync.cloud.monthly` | **$4.99** (shipped, public) | quota sync + (today) accepted for all Pro gates |
| `hosted_media_sync` | `com.openburnbar.hostedMediaSync.monthly` | $9.99 (plan) | file transfer (+ screen/video only if Pro umbrella) |
| `burnbar_pro` (umbrella) | `com.openburnbar.pro.monthly` | $14.99 (plan) | hostedQuota + hostedLLM + encryptedSessionLogBackup + cloudConversationSearch + media |
| `hosted_computer_use_sync` | `com.openburnbar.hostedComputerUseSync.monthly` | $14.99 (test fixture) | Computer Use |
| `burnbar_pro_max` | `com.openburnbar.proMax.monthly` | $24.99 (test fixture) | everything incl. Computer Use |

**Gating logic in code today (important quirk):**
- `assertActiveBurnBarProEntitlement` accepts **either** `burnbar_pro` **or** `hosted_quota_sync` → so the **$4.99 SKU currently unlocks the full Group-A bundle** (Remote MCP, hosted LLM, encrypted search, CLI link).
- `assertActiveHostedQuotaEntitlement` accepts either → gates Hermes/Pi relay + hosted quota refresh.
- Media is gated by `hosted_media_sync` or the `burnbar_pro` umbrella; Computer Use by `hosted_computer_use_sync` / `burnbar_pro_max`.

→ The data already supports a clean **two-tier collapse**: **Tier 1 = "everything Group A" (today's $4.99–$14.99 cluster)**, **Tier 2 = Tier 1 + media + Computer Use (today's $24.99 pro-max)**. Doc 5 makes this concrete.

- **Rails status:** Apple StoreKit live (Sandbox default; pinned Apple root CAs; S2S webhook + daily reconcile). Stripe fully coded but `STRIPE_BURNBAR_PRO_PRICE_ID` not yet set. Google Play coded; needs published app.
- **Margin guardrails already wired:** billing alert policies (`npm run alerts:billing`) watch (1) Firestore reads, (2) Firestore storage bytes, (3) Cloud Run request rate, (4) absence of the retired Redis. A `commercial-launch-gate.mjs` blocks launch if any policy is missing.

---

## 9. Appendix — per-function config reference (non-default values)

All 76 functions are in `us-central1`, `minInstances: 0`. Only non-default memory / timeout / maxInstances are listed.

**Non-default memory:** `deleteUserCloudData` 1 GiB; `validateOpenTimestampsProof` 512 MiB; `reconcileHostedEntitlementsDaily` 512 MiB; `backfillProviderAccountDeviceLinksScheduled` 512 MiB.

**Non-default timeout (s):** `deleteUserCloudData` 540; `evaluateComputerUseBudget` 540; `recomputeComputerUseQuotaUsage` 540; `rollupComputerUseDaily` 540; `reconcileHostedEntitlementsDaily` 540; `refreshModelLandscapeBenchmarks` 300; `backfillProviderAccountDeviceLinks(Scheduled)` 300; `appStoreServerNotificationsV2` 30.

**Explicit `maxInstances` (throttle ceilings):** insights 50; provider/quota callables 100; Hermes 100; Pi Agent 100; encrypted-search callables 100; Google Play verify 100; ASC verify 100; Stripe checkout/portal 50; Remote-MCP grant/revoke 50; CLI completeLink 50; ASC begin/restore + notifications 50; `deleteUserCloudData` 20; `seedAndroidDemoAccount` 20; `stripeBurnBarProWebhook` 20; `rebuildUsageRollups` 10.

**Trigger types:** 3 health HTTPS-GET; `latestRouterRundown` HTTPS-GET (public, cached); `startCliLink`/`pollCliLink` HTTPS-POST; `appStoreServerNotificationsV2` + `stripeBurnBarProWebhook` HTTPS-POST (provider-initiated); 4 Firestore triggers (`onUsageWritten`, 2 agent-reply `onDocumentWritten`, `sendVoIPOutbound`/`sendFcmOutbound` `onDocumentCreated`); 12 scheduled; the remainder HTTPS callables.

---

## 10. Hand-off to Doc 3

You now have the **infrastructure ledger**. Doc 3 walks every cloud-bearing **feature** and ties it to: the functions/collections it uses, its per-action resource footprint, the **hard quota/budget caps** that bound worst-case cost, and **which of the two tiers it belongs in**.
