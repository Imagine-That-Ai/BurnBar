# 03 — Feature → Cost & Quota Map

> **Document 3 of 5.** One section per cloud-bearing feature. For each: what it does, what it consumes, the **exact hard caps** that bound worst-case cost (all are real code constants), whether it spends operator money on an LLM, and **which tier it belongs in**. This is the document that justifies the two-tier split: notice how every feature is either **Group A (cheap, flat-ish)** or **Group B (variable, LLM/bandwidth-heavy)**.
>
> **Tier legend:** **T1** = belongs in the cheaper "Cloud / Sync" tier. **T2** = belongs in the premium "Cloud Pro / Studio" tier (or T1+T2 means baseline in T1, higher allowance in T2). Doc 5 finalizes the packaging.

---

## Cost-behavior summary (read this first)

| Feature | Group | Operator LLM spend? | Bandwidth? | Worst-case/user bounded by | Tier |
|---|---|---|---|---|---|
| Hosted Quota Sync | A | No | No | 30/day, 300/mo → **$0.033/user/mo** max | **T1** |
| Encrypted Backup + Cloud Search | A | No | No | 10 MB/blob; batch 50 docs/800 chunks | **T1** |
| Hosted Intelligence Brief (LLM) | A | **Yes (tiny)** | No | 1400 out-tokens, 24 KB in, fallback-only | **T1** |
| Hermes / Pi Agent relay | A | No (relays user's model) | Negligible (P2P) | TTL rate-limits | **T1** |
| Hosted Remote MCP | A | No | No | per-tool rate buckets; 90-day tokens | **T1** |
| Cross-device usage sync + push | A | No | No (push = free) | rollup counters; FCM free | **T1** |
| **Mercury Media (Floo)** | **B** | No | **Yes (relay fallback)** | 5 GB/day, global $600/$1000 kill-switch | **T2** |
| **Computer Use (Agent Control)** | **B** | **Yes (vision, dominant)** | Via media relay | **$5/user/day**, global $1500/$2500 kill-switch | **T2** |

**The whole pricing thesis in one line:** Group A blended COGS is **~$0.20–$0.93/user/mo** and is structurally hard-capped near $0.03–$0.10 for the metered parts; Group B is the only place real, variable money flows (relay GB + vision tokens), and it is wrapped in per-user daily ceilings *and* global kill-switches. **Price T1 cheap and confidently; price T2 to cover variable cost + headroom.**

---

## 1. Hosted Quota Sync — **T1**

**What:** Refresh AI-provider quota (tokens used, limits, reset windows) to iPhone/iPad/Mac without the Mac staying online. Codex uses a hosted Cloud Run runner; Claude Code / OpenCode use self-hosted runners (provider auth stays in the user's environment) that upload a sanitized snapshot.

**Backed by:** `connectHostedQuotaAccount`, `connectSelfHostedQuotaAccount`, `refreshProviderAccountQuota`, `refreshProviderQuota`, `uploadProviderQuotaSnapshot`, `refreshAllProviderQuotas` (cron, stale-first batch of 20), Cloud Run quota runner.

**Consumes per refresh:** 1 Secret Manager access (~$0.000003) + ~4.5 s Cloud Run @ 1 vCPU/2 GB (~$0.000105) + 1 Firestore write (~$0.0000018) = **$0.00010998/refresh**.

**Hard caps (real constants):** **30 refreshes/day** and **300/month** per account (`HOSTED_QUOTA_DAILY_REFRESH_LIMIT=30`, `HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT=300`, enforced transactionally). → **Worst-case $0.033/user/month.** A user literally cannot cost more than ~3.3¢/mo here.

**LLM spend:** none (the runner calls the Codex CLI; no model inference).

**Tier rationale:** This is the cheapest, most predictable hosted feature and the original $4.99 hook. It is the anchor of **Tier 1**.

---

## 2. Encrypted Session-Log Backup + Zero-Knowledge Cloud Search — **T1**

**What:** Backs up every indexed session transcript to Cloud Storage as AES-GCM ciphertext, and maintains an encrypted Firestore index of HMAC token hashes + keyed semantic hashes for cross-device search that is **zero-knowledge** to the server. Bodies never sit in Firestore; only sealed metadata + hash posting edges.

**Backed by:** `beginEncryptedSessionBlobUpload`, `getEncryptedSessionBlobDownloadUrl`, `commitEncryptedSearchIndexBatch`, `searchEncryptedConversationIndex`, `queryConversations`, project-memory snapshot callables, `cloudSearchCore`.

**Consumes:**
- *Index one ~40-turn / 160 KB session:* split into 10×16 KB chunks → 1 GCS blob (~160 KB, $0.0000032/mo storage) + ~10 GCS writes + ~10 Firestore index writes + 1 validation invocation ≈ **$0.0001172/session**.
- *One search:* invocation + ~100 candidate reads ≈ **$0.000083/search**.

**Hard caps (constants):** blob **≤10 MB**; commit batch **≤50 docs / ≤800 chunks**; search input ≤10 token + ≤12 semantic hashes, ≤50 hits; conversation page 1–100 rows.

**LLM spend:** none (semantic hashes are computed on-device; no embedding API).

**Tier rationale:** Pennies even for heavy users; pure privacy/utility value. **Tier 1.**

---

## 3. Hosted Intelligence Brief (the one cheap server-funded LLM) — **T1**

**What:** When the user opens the analytics "Intelligence Brief" and has **no** personal model configured (or all their own routes fail), the server answers their usage question with a small hosted LLM over a privacy-bounded digest of their own data.

**Backed by:** `insightsHostedAnswer` (`maxInstances: 50`, 60 s timeout, 45 s abort).

**LLM:** **OpenRouter → `minimax/minimax-m2`** ("MiniMax 2.7"). `temperature 0.2`, `max_tokens 1400`, JSON mode. Cost-stamped at **$0.255/M in, $1.00/M out**. Input digest capped at **24 KB**. → **~$0.0004–$0.0015 per answer.**

**Route preference (important):** user-owned routes are always tried first; the hosted MiniMax fallback only fires when none are reachable. So the operator-funded path is the *exception*, not the norm.

**Hard caps:** entitlement-gated; 1400-token output ceiling + 45 s abort are the cost controls. No per-user token quota beyond that.

**Tier rationale:** Costs are trivial and bounded; it's a convenience that makes the analytics feel alive. **Tier 1.** (If desired, the per-answer token cost is so low it can stay in T1 with a generous monthly answer allowance.)

---

## 4. Hermes / Pi Agent Relay — **T1**

**What:** Pair a local AI chat gateway (Hermes) or local agent runtime (Pi, `127.0.0.1:8765`) on the Mac with the phone via an 8-char code + encrypted relay. The phone sends encrypted chat requests; the Mac decrypts, runs **the user's own model**, streams back encrypted chunks. Plaintext never transits the server.

**Backed by:** `create/complete/list/revoke/updateHermesPairing|Connection`, identical `PiAgent*` set. Transport: iroh P2P first; encrypted Firestore relay as last-resort fallback (the Redis/WebSocket relay was retired 2026-05-28).

**Consumes:** pairing/connection metadata docs + encrypted relay envelopes/chunks in Firestore (tiny). **No server inference** — the relay forwards to whatever model the user's gateway uses.

**Hard caps:** TTL rate-limits (create_pairing 5 s, complete 1 s, revoke/update 2 s windows; ≤5 failed pairings before auto-revoke; 10-min pairing TTL; 90-day audit TTL).

**Tier rationale:** Near-zero marginal cost; high "remote control" value. **Tier 1.**

---

## 5. Hosted Remote MCP — **T1**

**What:** Lets any MCP client (Claude Code, Cursor, the SDK) connect to `https://mcp.burnbar.ai/mcp` and search the user's encrypted hosted corpus, list resumable conversations, check index status, fetch usage — **without the user's device online**. Server returns **sealed** (ciphertext) results; decryption happens on-device or via the local `openburnbar-mcp-remote` shim.

**Backed by:** `issueRemoteMcpGrant`, `revokeRemoteMcpClient` (Functions) + the `services/hosted-mcp` Cloud Run service.

**Consumes:** Firestore reads of the already-stored encrypted index; Cloud Run request time. **No new storage writes, no LLM.**

**Hard caps:** short-lived HMAC-signed bearer tokens (90-day grant), per-tool rate-limit buckets (Cloud Run env), per-client revoke.

**Tier rationale:** Reads existing data, no model spend. **Tier 1** (a flagship T1 differentiator — "connect your agents to your encrypted memory").

---

## 6. Computer Use / "Agent Control" — **T2** (the dominant variable LLM cost)

**What:** Autonomous/assisted agent control of the Mac and a sandboxed browser, under strict human supervision, with a tamper-evident, Bitcoin-notarized audit trail. Four paths: **A** Agent Watch (screen mirror to phone), **B** Browser (sandboxed Playwright), **C** macOS System (CGEvent + Accessibility), **D** Phone-as-Controller (Ed25519-signed intents).

**Backed by:** `evaluateComputerUseBudget` (cron, kill-switch), `recomputeComputerUseQuotaUsage` (cron), `rollupComputerUseDaily` (cron, full scan), `validateOpenTimestampsProof`. The **vision LLM is called by the Mac client directly**, metered into Firestore as `visionTokensCostUSD`.

**LLM (operator-funded, the cost center):** default **Claude Sonnet 4.5**. Per turn ≈ 1 full screenshot + 3 thumbnails + last-5 action summaries ≈ 3,500 in + 400 out tokens ≈ **$0.013/turn**. A 100-action run ≈ **$1.30**. This dwarfs every other per-action cost in the system.

**Hard caps (per-user envelope, constants):**
| Mode (global projection) | Actions/run | Actions/day | Sessions/day | $/user/day | Max session |
|---|---|---|---|---|---|
| Normal (< $1,500/mo) | 50 | 200 | 4 | **$5.00** | 30 min |
| Soft cap ($1,500–$2,499) | 25 | 100 | 2 | $2.50 | 30 min |
| Hard cap (≥ $2,500) | 0 | 0 | 0 | $0 | terminate ≤60 s |

**Global kill-switch:** `evaluateComputerUseBudget` runs hourly; at ≥$2,500 projected month-end it publishes Remote Config `computer_use_kill_switch=true` and active sessions panic-halt within 60 s. **Four independent instant-stop paths** also exist (⌃⌥⌘. hotkey ≤100 ms; phone three-finger long-press ≤200 ms; Mac lock/sleep/loginwindow ≤100 ms; Remote Config ≤60 s).

**Storage:** screenshots stay **local on the Mac**; only chain headers (hashes) hit Firestore. OpenTimestamps proofs ≤256 KB; chain files ≤10 MB. → minimal cloud storage.

**Tier rationale:** This is the single most expensive feature per active user (real vision tokens, up to **$5/user/day = $150/user/mo** at the per-user ceiling). It **must** be in the premium **Tier 2**, and T2's price must comfortably exceed the realistic monthly vision spend of an engaged user (or pair with an overage/allowance). This is the feature that most needs GPT Pro's pricing judgment.

---

## 7. Mercury Media / "Floo" — **T2** (the bandwidth variable cost)

**What:** Mac↔iPhone/iPad file transfer, screen-share, video, and audio over the iroh QUIC mesh. VoIP push (`triggerVoIPCall` → APNs/FCM) rings the phone via CallKit.

**Backed by:** `evaluateMediaBudget` (cron, kill-switch), `recomputeMediaQuotaUsage` (cron), `rollupMediaSessionDaily` (cron), `validateMediaPurchase`, `grantMediaGrandfather`, `triggerVoIPCall`, `sendVoIPOutbound`, `sendFcmOutbound`.

**Bandwidth reality (who pays):** **≥75% of sessions are peer-to-peer** (zero operator bytes). Only NAT-blocked sessions fall back to the **n0 relay** — a **flat ~$200/mo** tier, *not* per-GB billed. The **$0.04/GB** figure is an internal accounting model that drives the budget caps, not an n0 invoice line. One 1080p/15fps screen-share ≈ 1.35 GB/hr ≈ $0.054/hr *in the accounting model*.

**Hard caps (per-user daily envelope, constants):**
| Mode (global projection) | File in/out/day | Screen-share/day | Video/day |
|---|---|---|---|
| Normal (< $600/mo) | 5 GB / 5 GB | 120 min (60/session) | 240 min (30/call) |
| Soft cap ($600–$999) | 2 GB / 2 GB | 30 min | 120 min |
| Hard cap (≥ $1,000) | 0 | 0 | 0 |

Plus: ≤1 GB/file, ≤4 concurrent transfers, ≤50 transfers/day. Global `media_kill_switch` flips at $1,000 projected; n0 dashboard alerts at 75/100/150% of $600.

**Storage:** **zero** — media bytes never touch Firebase Storage; local cache auto-purges after 7 days.

**Tier rationale:** Variable bandwidth + the flat $200 relay are the cost story. The flat fee is diluted across the subscriber base (break-even just 55 subs). Belongs in **Tier 2** alongside Computer Use; the per-user caps already bound exposure, and the global kill-switch bounds the operator's total media bill at ~$1,000/mo regardless of scale.

---

## 8. The margin-protection architecture (why the operator is safe at any scale)

This is a *selling point of the cost model* — GPT Pro can price aggressively because runaway cost is structurally impossible:

1. **Per-user hard caps** on every metered feature (refreshes 30/day-300/mo; media 5 GB/day; Computer Use $5/day + 50 actions/run).
2. **Global hourly budget evaluators** project month-end spend and **auto-tighten** envelopes at soft caps, then **kill-switch** at hard caps — Media $600/$1000, Computer Use $1500/$2500 — all tunable live via Remote Config without a redeploy.
3. **Abuse throttle:** drop `user_quota_daily_refresh_limit` to 5 via Remote Config to stop a rogue user within 60 s.
4. **Billing alert policies** on the four cost metrics + a launch gate that blocks go-live if alerts are missing.
5. **No `minInstances`** anywhere → zero idle compute; **FCM/APNs free** → push is never a cost; **zero-knowledge storage** → no compliance cost.

**Implication for pricing:** the worst case for the operator is bounded *globally* at roughly **$200 (relay) + $1,000 (media) + $2,500 (computer use) + Firestore/compute (small)** ≈ **<$4k/month total infrastructure even at thousands of users**, because the kill-switches cap aggregate variable spend. The real question Doc 5 asks is not "will we lose money" but "what price maximizes revenue while the caps keep us safe."

---

## 9. Hand-off to Doc 4

You now know each feature's **unit cost and its cap**. Doc 4 assembles these into the full **COGS model**: per-operation costs, blended per-user monthly cost by usage percentile, break-even, App-Store-fee-adjusted ARPU, and a per-tier serving-cost estimate you can price against.
