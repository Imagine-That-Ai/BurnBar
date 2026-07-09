# Quota + Proxy/Failover + Cloud-Sync SOTA Plan

**Author:** Fable (lead architect) · **Date:** 2026-07-04
**Status:** Execution-ready. Every task below is atomic, one-PR-shippable, and specified to
the level where a Sonnet/Haiku-class executor can implement it without judgment calls.
**Scope:** Four outcomes — (1) live, efficient quota status for every provider; (2) universal
failover including multi-endpoint Ollama and cross-provider model equivalence; (3) reliably
fresh Claude quotas; (4) secure, zero-setup cloud carryover of quota/account/routing state.

**How to use this document (executor contract):**
- Tasks are named `T<phase>.<n>`. Execute phases in order; tasks inside a phase are
  parallel-safe unless a `Depends on:` line says otherwise.
- Each task = one PR through the software-factory loop (`AGENTS.md` § Software factory PR
  loop). Include the task ID in the PR title, the task's Validation section in the PR body,
  and its Risks/Rollback verbatim.
- Never widen scope beyond the task's *Files* list without adding a `Cross-agent receipt`
  explaining why.
- All file paths are repo-root-relative. Line numbers are anchors as of commit `f9c0086957`;
  always re-locate by **symbol name** before editing.

---

## 1. Executive summary and definition-of-done

### 1.1 What exists today (verified against live code, 2026-07-04)

**Server quota refresh** — `refreshAllProviderQuotas` (`functions/src/scheduled.ts`, every
15 min, 120 s timeout) drives `runQuotaRefreshSweep` (`functions/src/quotaRefreshSweep.ts`):
stale-first ordered selection over `provider_accounts` with statuses
`connected|stale|error` and storage scopes `cloud_refreshable|server_private`, refreshed
5-wide, plus a legacy `provider_connections` fallback pass and a cursor-resumable
`lastRefreshAt` backfill. Per-account refresh is `refreshUserProviderAccountQuota`
(`functions/src/quota.ts`), dispatching to HTTP adapters in `functions/src/providers/`
(openai, minimax, zai, kimi, factory, cursor, xai, mimo) or — for
`storageScope === "server_private"` and provider in `HOSTED_RUNNER_PROVIDERS` — to the
hosted quota runner with entitlement + daily/monthly budget gates
(`consumeHostedRefreshBudget`, `functions/src/quota.ts` ~line 388).

**Client quota refresh** — `ProviderQuotaService` (`AgentLens/Services/ProviderQuota/`)
runs a flat 15-minute loop (`interval: Duration = .seconds(15 * 60)`, ~line 627) with a
5-minute `refreshIfNeeded` max-age (~line 616), fanning out to per-provider
`ProviderQuotaAdapter` implementations. Snapshots are pushed to Firestore by
`QuotaSnapshotSyncService` (`AgentLens/Services/CloudSync/QuotaSnapshotSyncService.swift`).

**Proxy/failover (daemon)** — `BurnBarProviderRouter`
(`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift`) scores
routes on five dimensions (capability/cost/latency/trust/policy-fit), enforces
format-family isolation ("two highways") and the exact-canonical-model invariant in
`sameModelFailover` mode. `BurnBarRunService+Execution.swift` runs the candidate-route
loop with `shouldFailOverProviderError` (429/401/402/403, transient-capacity, quota
strings) and `markRouteFailure` cooldowns. `OpenBurnBarHTTPGatewayServer+CrossVendorDegrade.swift`
provides an opt-in, allow-listed last-resort degrade for the OpenAI chat endpoint.

**Cloud sync/crypto** — `CloudVaultCrypto` (OpenBurnBarCore) is the E2E envelope layer
(AAD-bound, trust-chain-verified via `CloudVaultTrustedDeviceChainVerifier`, byte-compatible
with the C# port under `windows/cloudsync/` with parity vectors from
`windows/cloudsync/tools/CloudVaultVectorGen`). Credentials never sync in plaintext; the
Mac→phone escrow transfer uses ephemeral-static P-256 ECIES
(`MacEscrowSeal` in `AgentLens/Services/CloudSync/MacEscrowCredentialProducer.swift`,
sharedInfo `"OpenBurnBar-Escrow-v1"`). The Signal at-rest layer
(`OpenBurnBarSignalCore`) is additive and flag-gated.

### 1.2 Ground-truth corrections (differences from the mission's map)

These were found by verification and change the plan's shape; the plan below is built on
the corrected reality:

| # | Mission claim | Verified reality |
|---|---|---|
| C1 | "Claude quota comes ONLY from the hosted runner" | `HOSTED_RUNNER_PROVIDERS = new Set<Provider>(["codex"])` (`functions/src/quota.ts` line 54). The runner **does** implement `claude-code` hosted-credential mode (`quota-runner/src/server.mjs` lines 81–86, `quota-runner/src/providers/claude.mjs`), but Cloud Functions **never dispatch Claude to it**. `HOSTED_QUOTA_PROVIDERS = ["codex"]` too (`functions/src/callables/shared/accounts.ts` line 32). Claude is in `LOCAL_ONLY_PROVIDERS` (`functions/src/types/legacy/providers.ts` line 48). Self-hosted Claude connect writes `storageScope: "local_only"` (`applySelfHostedQuotaConnect`, `functions/src/callables/providerAccountWrites.ts` line 123) — a scope the sweep **never selects** (`REFRESHABLE_SCOPES = ["cloud_refreshable", "server_private"]`, `quotaRefreshSweep.ts` line 126). **Server-side Claude refresh is structurally absent.** |
| C2 | (implicit) Claude client path is just runner parsing | The Mac client has a four-tier cascade in `ClaudeQuotaAdapter.swift`: statusline bridge (15-min max age, `StatuslinePolicy.maxSnapshotAge` line 33) → OAuth `/api/oauth/usage` (`ClaudeOAuthUsageFetcher.swift`) → 1-token header probe of `anthropic-ratelimit-unified-*` (`headerProbeSnapshot`, ~line 293) → JSONL token counting with plan caps. |
| C3 | "QuotaSnapshotSyncService lacks the permission-denied suppression UsageSyncService has" | **Already fixed** — both `ProviderAccountSyncService.uploadAccounts` and `QuotaSnapshotSyncService.uploadSnapshots` call `context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)` on `permissionDenied`/`unauthenticated` (lines 44–50 and 151–157). No task needed. |
| C4 | (not claimed) | The daemon executors (`OpenBurnBarProviderExecutor.swift`, `OpenBurnBarAnthropicProviderExecutor.swift`) read **only** `Content-Type` from provider responses. Rate-limit headers (`anthropic-ratelimit-*`, `x-ratelimit-*`, `retry-after`) that arrive free on every proxied request are discarded. This is the single largest efficiency win for Objective 1. |
| C5 | "quota-runner: claude, kimi, opencode" | Runner providers are claude, codex, kimi, opencode, **antigravity** (`quota-runner/src/providers/`). |

### 1.3 Definition of done (measurable, per objective)

**Objective 1 — Live, efficient quota status.** DONE when:
- Every provider account with a `connected` status shows a quota snapshot whose
  `fetchedAt` age is ≤ 15 minutes while the user is actively sending traffic through the
  daemon, and ≤ 60 minutes while idle with the app open — measured by the freshness
  telemetry added in T0.2.
- Zero **marginal** provider-quota spend during active traffic: header harvesting (T1.1)
  supplies live data; the spend-probe tier fires only when no passive signal exists and a
  per-provider probe budget allows it (see § 3.1 ladder, tier 5).
- The quota UI labels every snapshot with its signal source (live-traffic header / local
  artifact / cached / probed) and staleness.

**Objective 2 — Universal failover.** DONE when the conformance matrix (§ 5) is green:
- Multi-account, same provider: for every provider in the daemon catalog with ≥ 2
  configured credential slots, a 429/401/402/403/exhausted response on slot A results in
  the request being served by slot B without client-visible failure, and a
  `ProviderRoutingDecisionEvent` records the switch.
- Ollama: ≥ 2 configured endpoints; killing endpoint A mid-session routes to endpoint B
  automatically; the quota panel shows both endpoints as separate accounts.
- Cross-provider (toggle ON): exhausting all accounts of the requested model's provider
  fails over to an equivalence-class member on another provider, gated by the
  `ModelEquivalenceRegistry` and format-family invariant; decision events show the
  equivalence reasoning. Toggle OFF: behavior is byte-identical to today.

**Objective 3 — Fresh Claude quotas.** DONE when:
- Cloud users with hosted Claude opted in: `quota_snapshots` age for Claude p95 ≤ 20
  minutes with the Mac asleep (driven by the 15-min server sweep).
- All users: while the user actively uses Claude through the daemon or Claude Code CLI,
  Claude snapshot age ≤ 2 minutes (header harvest + statusline).
- `claude /usage` parse failures produce a telemetry alarm and a `confidence: "stale"`
  snapshot instead of a silent error (no more invisible staleness).

**Objective 4 — Secure cloud carryover.** DONE when:
- A user signs into a brand-new Mac, and without any manual re-setup sees: all provider
  accounts (with correct status), quota snapshots, router mode + cross-provider toggle,
  account ordering, Ollama endpoint list, and equivalence overrides.
- Credentials restore via the escrow-grant flow (old device or phone approves; new device
  receives ECIES-sealed secrets) — zero plaintext credentials in Firestore or logs.
- The roaming-profile envelope passes CloudVault parity vectors on Swift **and** the C#
  port, is AAD-bound to `uid` + payload type, and fails closed on any trust-chain error.

---

## 2. Root-cause analysis: Claude quota staleness (Objective 3)

Ranked by impact, with evidence. All five causes are fixed by Phase 2.

**RC1 — No server-side Claude refresh path exists (structural; the dominant cause for
cloud users).**
Evidence chain:
1. `functions/src/quota.ts` line 54: `HOSTED_RUNNER_PROVIDERS = new Set<Provider>(["codex"])`.
   `refreshUserProviderAccountQuota` only routes `server_private` accounts to the hosted
   runner for providers in this set (line 243). For any other `server_private` provider it
   throws `"not cloud-refreshable"`.
2. `functions/src/callables/shared/accounts.ts` line 32: `HOSTED_QUOTA_PROVIDERS = ["codex"]`
   — the hosted connect callable rejects Claude, so a Claude account can never *become*
   `server_private`.
3. `applySelfHostedQuotaConnect` (`functions/src/callables/providerAccountWrites.ts` line
   123) writes `storageScope: "local_only"` for self-hosted Claude — and
   `REFRESHABLE_SCOPES` (`quotaRefreshSweep.ts` line 126) excludes `local_only`, so the
   sweep never touches those accounts.
4. Therefore the **only** writer of cloud Claude quota is the Mac app's
   `QuotaSnapshotSyncService.uploadSnapshots`. When the Mac is asleep/off, cloud Claude
   quota freezes. iOS/Android users see stale data with no recovery path.
5. The irony: `quota-runner/src/server.mjs` (lines 81–86) already implements
   `claude-code` hosted-credential refresh — the capability exists and is dead code from
   the functions side.

**RC2 — The statusline bridge is event-driven by *user* activity and hard-capped at 15
minutes.** `ClaudeQuotaAdapter.StatuslinePolicy.maxSnapshotAge = 15 * 60` (line 33). The
bridge payload only updates when the user runs a Claude Code turn. Idle users decay to
lower-confidence tiers; users who work through *other* tools get nothing.

**RC3 — The OAuth usage endpoint fails for common token scopes.** The comment at
`ClaudeQuotaAdapter.swift` lines 283–292 documents that `/api/oauth/usage` fails for
credentials lacking the `user:profile` scope (common on Pro/Max OAuth tokens). The
fallback header probe spends one real token per refresh — correct as a last resort, but
it is currently reached more often than necessary because tier-0 (traffic header
harvesting) doesn't exist (C4).

**RC4 — `claude /usage` parsing is a fixed-label regex with silent failure.**
`parseClaudeUsage` (`quota-runner/src/providers/claude.mjs` lines 92–119) matches four
exact English label strings (`"Current session"`, `"Current week (all models)"`, …) and
`(\d{1,3})%\s*used`. Any Anthropic CLI copy change zeroes the buckets and the runner
throws a generic error; the account is marked `status: "error"` with
`lastErrorCode: "hosted_runner_failed"` and nobody is alerted.

**RC5 — Token-refresh rotation loss (partially fixed, needs the server twin).** The client
persists rotated OAuth tokens back to the per-profile Keychain
(`persistRefreshedProfileCredential`, `ClaudeQuotaAdapter.swift` lines 195–206) — but a
server-side adapter (RC1 fix) must do the same against Secret Manager, or the hosted
credential dies after the first server-side refresh-token rotation
(`https://platform.claude.com/v1/oauth/token` rotates refresh tokens; see
`ClaudeOAuthUsageFetcher.refreshAccessToken`, line 341).

---

## 3. Target architecture

### 3.1 Quota: the passive-first signal ladder (before → after)

**Before:** flat 15-min polling loops on both client and server; every refresh is an
active fetch; rate-limit headers on proxied traffic discarded; the shared
`externalApiPolicy` breaker (`functions/src/resilience.ts` line 125) lets one dead
provider open the breaker for the whole sweep run.

**After:** every quota consumer draws from a **signal ladder**, always preferring the
cheapest fresh tier. The ladder is codified once (T0.3) and consumed by the daemon, the
Mac app, and Cloud Functions:

| Tier | Signal | Cost | Producer |
|---|---|---|---|
| 0 | Rate-limit headers harvested from real user traffic through the daemon proxy | **zero** | `BurnBarQuotaSignalHarvester` (T1.1) |
| 1 | Local artifacts: Claude statusline bridge, `~/.claude` / `~/.codex` JSONL scans, session logs | zero | existing adapters |
| 2 | Cached snapshot within adaptive TTL | zero | snapshot stores |
| 3 | Non-spending authenticated status endpoints (e.g. `/api/oauth/usage`, provider dashboards, `ollama.com/settings`) | zero quota, one HTTP call | adapters |
| 4 | Server sweep refresh (cloud_refreshable / hosted runner) | zero quota, budgeted HTTP/runner | functions |
| 5 | Real-spend probe (1-token `/v1/messages` probe) | **spends quota** | budgeted, last resort only |

Refresh scheduling becomes **event-driven**: reset-boundary crossings (`resetsAt`),
failover events (a 429 both triggers failover *and* refreshes the snapshot from the 429's
own headers — tier 0), system wake/network-change, and adaptive TTLs (near-exhaustion →
shorter TTL; long-window healthy buckets → longer TTL). The flat loops remain only as a
safety-net floor.

### 3.2 Failover: universal, quota-aware, equivalence-driven (before → after)

**Before:** slot rotation works for API-key providers; Ollama is a single hardcoded
endpoint; `intelligentModelRouter` is decode-aliased to `sameModelFailover`
(`ProviderAccountTypes.swift` lines 243–275); failover is purely *reactive* (must see the
error first).

**After:**
- **Ollama multi-endpoint:** daemon config gains an `endpoints` array for Ollama; each
  endpoint is enumerated as a distinct route (slotID = endpoint ID) so the *existing*
  `markRouteFailure` / cooldown / scoring machinery handles rotation with no special
  cases. A lightweight health prober feeds trust scores. Opt-in Bonjour discovery
  suggests LAN endpoints; nothing is auto-added without user confirmation.
- **Model equivalence (the real `intelligentModelRouter`):** a versioned, committed
  `ModelEquivalenceRegistry` defines equivalence *classes* (deterministic membership) and
  *tiers*; the daemon expands failover candidates class-wide **only when the user toggle
  is on**, ranks within class by the existing five-dimension score plus benchmark bonus
  (already implemented at `OpenBurnBarProviderRouter.swift` ~line 1884), and never crosses
  the format-family invariant. Registry data flows: committed seed JSON → schema-sync
  emitters (Swift/TS/Kotlin/C#) → server `routerRundown` annotates with live benchmark
  bands → daemon merges committed + server data, committed wins on conflict.
- **Predictive demotion:** routes whose harvested quota snapshot shows an exhausted
  primary bucket with a future `resetsAt` are demoted *before* they 429, when an
  alternative exists. Reactive failover remains as the backstop.

### 3.3 Claude freshness (before → after)

**Before:** client-only cascade; cloud staleness structural (RC1).

**After (both lanes, hosted preferred):**
- **Hosted lane:** `claude-code` joins `HOSTED_QUOTA_PROVIDERS` + `HOSTED_RUNNER_PROVIDERS`.
  A new first-class functions adapter (`functions/src/providers/claude.ts`) calls
  `https://api.anthropic.com/api/oauth/usage` directly with the Secret-Manager-stored
  OAuth bundle, rotating tokens via `https://platform.claude.com/v1/oauth/token`
  (client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, the same constant the daemon uses in
  `BurnBarClaudeOAuthRouteCredential`) and persisting rotated bundles back to Secret
  Manager. The CLI runner (`quota-runner/src/providers/claude.mjs`) becomes the fallback
  when the OAuth endpoint fails (scope errors), with hardened parsing + alarms.
  Same entitlement, budget, and high-risk-owner-action gates as hosted Codex.
- **Client lane:** tier-0 header harvesting keeps Claude live during any daemon-proxied
  Claude traffic; statusline stays tier-1; the 1-token probe becomes strictly budgeted
  tier-5.

### 3.4 Secure carryover: the Roaming Profile (new)

A new CloudVault envelope type, `RoamingProfilePayload` v1, E2E-encrypted with the
existing vault key machinery, AAD-bound to `(uid, "OpenBurnBar-RoamingProfile-v1")`,
carrying **no secrets**:

```
RoamingProfilePayload v1 {
  schemaVersion: 1
  routerMode: String                     // ProviderRouterMode.rawValue
  crossProviderFailoverEnabled: Bool
  accountOrder: [String]                 // provider account IDs, sortKey order
  ollamaEndpoints: [{id, baseURL, label, priority}]   // credential-adjacent → encrypted
  equivalenceOverrides: [{canonicalModelID, action(pin|exclude), classID?}]
  quotaDisplayPreferences: {…}
  updatedAt, sourceDeviceID
}
```

Credentials ride the **existing escrow model**, generalized from Mac→phone to
Mac→any-trusted-device: the new Mac enrolls an escrow keypair through the trusted device
chain; the old Mac (or phone) approves per-credential grants; secrets transfer as
ECIES-sealed envelopes exactly like `MacEscrowSeal` today. `server_private` (hosted)
accounts need nothing — the server already holds their secrets and the sweep resumes on
the new machine automatically.

Byte-compat: the payload envelope gets parity vectors generated by
`windows/cloudsync/tools/CloudVaultVectorGen` and a matching C# test, like every other
CloudVault payload.

---

## 4. Phased work breakdown

Legend: **AC** = acceptance criteria, **V** = validation/tests, **R** = risks,
**RB** = rollback. Every task is one PR.

---

### Phase 0 — Foundations

#### T0.1 Per-provider circuit breakers for the quota sweep
- **Files:** `functions/src/resilience.ts`, `functions/src/resilienceHelpers.ts`,
  `functions/src/providers/httpClient.ts`, `functions/src/__tests__/` (new
  `providerResilience.test.ts`).
- **Change:** add `providerApiPolicy(providerKey: string): IPolicy` in `resilience.ts`
  backed by a `Map<string, IPolicy>` memo, each entry composed exactly like
  `externalApiPolicy` (same `externalTimeout`, retry, breaker constants — import and
  reuse them, do not copy numbers). Add
  `providerApiWithResilience(provider: string, label: string, fn)` to
  `resilienceHelpers.ts`. In `functions/src/providers/httpClient.ts`, thread the provider
  key into `providerFetch` so each provider adapter's outbound calls execute under its own
  policy. Keep `externalApiPolicy` for non-provider callers (benchmarks, insights).
- **AC:** a simulated dead provider (all calls throw) opens only its own breaker; a
  concurrent healthy provider's calls succeed in the same process. Update the stale
  comment block at `quotaRefreshSweep.ts` lines 34–40.
- **V:** new unit test with two fake providers through `mapWithConcurrency`; existing
  `npm test --prefix functions` suite green; `bash scripts/ci/verify-resilience-wiring.sh`.
- **R:** breaker state fragmentation slightly delays detection of a *global* outage.
  Mitigation: none needed — the sweep is per-provider by nature.
- **RB:** revert commit; policies are process-local, no data migration.

#### T0.2 Quota freshness telemetry + SLO
- **Files:** `functions/src/quota.ts` (both refresh functions), `functions/src/logging.ts`
  (reuse `logError`-style structured logs — add `logInfo` event
  `quota.snapshot_written` with `provider`, `age_ms_bucket`, `source`),
  `AgentLens/Services/ProviderQuota/ProviderQuotaService.swift` (extend the existing
  `TelemetryService.shared.record(feature: .providerQuotaRefresh, …)` call sites ~lines
  750–760 with a `snapshot_age_bucket` attribute), `docs/runbooks/slos.md` (new "Quota
  freshness" SLO section: p95 snapshot age ≤ 20 min per connected provider account,
  measurement query, alert threshold, escalation).
- **AC:** every snapshot write (server and client) emits one structured freshness event;
  the runbook documents the SLO and the exact log-based metric to chart.
- **V:** unit test asserting the event fields; `npm test --prefix functions`;
  `./scripts/test-openburnbar-app.sh` for the Swift side.
- **R:** log volume. Mitigation: bucket ages (reuse `AnalyticsBuckets.durationMs` style).
- **RB:** revert; telemetry only, no behavior change.

#### T0.3 Shared `QuotaRefreshPolicy` (the signal ladder as code)
- **Files:** new `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/QuotaRefreshPolicy.swift`;
  new `functions/src/quotaRefreshPolicy.ts`; new tests in
  `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/QuotaRefreshPolicyTests.swift` and
  `functions/src/__tests__/quotaRefreshPolicy.test.ts`.
- **Change:** one pure module (mirrored Swift/TS with a shared JSON fixture asserting
  identical outputs — follow the `PacingMath` precedent referenced in
  `AgentLens/Services/ProviderQuota/ProviderQuotaPacing.swift`):
  - `enum QuotaSignalTier { trafficHeaders=0, localArtifact=1, cachedSnapshot=2, statusEndpoint=3, serverSweep=4, spendProbe=5 }`
  - `adaptiveTTL(remainingFraction, windowKind, resetsAt, now) -> TimeInterval`:
    piecewise — remaining ≥ 50% → 30 min; 20–50% → 10 min; < 20% → 3 min; unknown → 15
    min; clamp to `[60s, min(4h, timeUntilReset)]`.
  - `shouldSpendProbe(lastProbeAt, probesToday, dailyProbeBudget=4) -> Bool`.
  - `nextRefreshAfter(snapshot) -> Date` = `fetchedAt + adaptiveTTL(…)`.
- **AC:** both implementations pass the same JSON fixture table (≥ 12 cases covering each
  piecewise branch and both clamps).
- **V:** `swift test --package-path OpenBurnBarCore`; `npm test --prefix functions`.
- **R:** none (pure functions, not yet wired).
- **RB:** revert.

---

### Phase 1 — Passive-first live quota (Objective 1)

#### T1.1 Daemon rate-limit header harvesting
- **Files:** new `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarQuotaSignalStore.swift`;
  edits in `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderExecutor.swift`
  (the three `httpResponse.value(forHTTPHeaderField: "Content-Type")` sites ~lines 158,
  387, 477) and `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarAnthropicProviderExecutor.swift`
  (~line 158); new test file
  `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarQuotaSignalStoreTests.swift`.
- **Change:**
  1. New `public struct BurnBarQuotaSignal: Codable, Sendable` — fields: `providerID`,
     `credentialSlotID?`, `capturedAt`, `buckets: [BurnBarQuotaSignalBucket]` where a
     bucket is `{name, remaining?, limit?, usedPercent?, resetsAt?, window?}` plus
     `retryAfterSeconds?` and `httpStatus`.
  2. New `public actor BurnBarQuotaSignalStore` — `record(_ signal:)` appends to an
     in-memory ring (cap 256) and persists latest-per-(provider, slot) to
     `BurnBarDaemonPaths`-derived `quota-signals.json` (0600, atomic write — mirror the
     permission handling in `BurnBarProviderRoutingDecisionEventStore.append`).
     `latestSignals() -> [BurnBarQuotaSignal]` reads the map.
  3. Header parsers (pure, unit-testable statics on the store):
     - Anthropic: `anthropic-ratelimit-unified-status`, `anthropic-ratelimit-unified-remaining`,
       `anthropic-ratelimit-unified-limit`, `anthropic-ratelimit-unified-reset`, plus the
       Console triplets `anthropic-ratelimit-{requests,input-tokens,output-tokens}-{remaining,limit,reset}`.
     - OpenAI-compat: `x-ratelimit-remaining-requests`, `x-ratelimit-limit-requests`,
       `x-ratelimit-remaining-tokens`, `x-ratelimit-limit-tokens`,
       `x-ratelimit-reset-requests`, `x-ratelimit-reset-tokens` (parse both `1s`/`6m0s`
       duration forms and epoch seconds).
     - Generic: `retry-after` (seconds or HTTP-date).
     Headers absent → no signal recorded (never fabricate).
  4. At each executor response site, after status handling, call
     `await quotaSignalStore.record(...)` with the parsed signal (inject the store through
     the executor's initializer; default a process-shared instance). Capture on **both**
     success and error responses — a 429's headers are the freshest data available.
- **AC:** fixture-driven parser tests for all three header families (≥ 10 cases including
  malformed values → nil, not crash); an integration test with a stubbed HTTP response
  proves a signal lands in the store; permissions on the persisted file are 0600.
- **V:** `swift test --package-path OpenBurnBarDaemon`.
- **R:** hot-path overhead. Mitigation: parsing is header-dictionary reads only; recording
  is a non-blocking actor hop.
- **RB:** revert; harvesting is additive, nothing consumes it yet.

#### T1.2 Daemon→app quota signal bridge
- **Depends on:** T1.1.
- **Files:** the daemon status/RPC surface (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`
  — add a `GET /v1/quota/signals` local endpoint returning
  `BurnBarQuotaSignalStore.latestSignals()`, wired like the existing status endpoints;
  auth identical to existing local control endpoints);
  `AgentLens/Services/ProviderQuota/ProviderQuotaService.swift` (new
  `harvestedSignalSnapshots()` source consulted **first** in the refresh pass);
  `AgentLens/Services/ProviderQuota/ProviderQuotaModels.swift` (add
  `ProviderQuotaSource.liveTraffic` case with display string "Live from traffic").
- **Change:** ProviderQuotaService maps `BurnBarQuotaSignal` → `ProviderQuotaSnapshot`
  (confidence `.exact`, source `.liveTraffic`); a harvested signal newer than the
  adapter's snapshot for the same (provider, account) wins per-bucket (newest-wins merge);
  snapshots produced this way flow into the normal `uploadQuotaSnapshotsForIOS` push so
  the cloud gets tier-0 freshness too.
- **AC:** with a fake daemon returning one Anthropic signal, the Claude card shows the
  header-derived bucket with the "Live from traffic" source; a fresher adapter fetch
  still overrides an older signal.
- **V:** `./scripts/test-openburnbar-app.sh` (new
  `AgentLensTests/Active/ProviderQuotaHarvestedSignalTests.swift`).
- **R:** double-counting sources confusing users. Mitigation: single newest-wins merge
  point with unit tests; source badge makes provenance visible.
- **RB:** feature-flag `quota_header_harvest` (see T6.4); flag off restores adapter-only.

#### T1.3 Event-driven refresh scheduling (client)
- **Depends on:** T0.3.
- **Files:** `AgentLens/Services/ProviderQuota/ProviderQuotaService.swift` (the loop at
  ~line 627 and `refreshIfNeeded` at ~line 616),
  `AgentLens/Services/ProviderQuota/QuotaRefreshActor.swift`.
- **Change:** keep the 15-min loop as the floor, but before each per-provider fetch check
  `QuotaRefreshPolicy.nextRefreshAfter(latestSnapshot)`; skip providers not yet due.
  Add three wake triggers, each calling the existing refresh entry point:
  `NSWorkspace.didWakeNotification`, `NWPathMonitor` satisfied-transition, and a
  per-bucket `resetsAt` timer (schedule one `Task.sleep` until the earliest future
  `resetsAt` + 30 s jitter; reschedule after each refresh).
- **AC:** unit tests over a fake clock: (a) provider with 80% remaining is *not*
  refetched at the 5-min mark; (b) provider crossing `resetsAt` is refreshed within
  90 s of the boundary; (c) wake triggers a due-check, not a blanket refresh.
- **V:** `./scripts/test-openburnbar-app.sh`.
- **R:** under-refreshing if adapters return no `resetsAt`. Mitigation: unknown → 15-min
  TTL per T0.3, identical to today.
- **RB:** revert; loop constant unchanged.

#### T1.4 Adaptive server sweep priority
- **Depends on:** T0.3.
- **Files:** `functions/src/quota.ts` (`refreshUserProviderAccountQuota` success
  transaction ~lines 288–296 — also write `nextRefreshAfter` computed by
  `quotaRefreshPolicy.ts` from the snapshot's dominant bucket),
  `functions/src/quotaRefreshSweep.ts` (selection pass: after the ordered query, skip
  docs whose `nextRefreshAfter` is in the future — a doc-level filter, not a new index),
  `functions/src/__tests__/quotaRefreshSweep.test.ts`.
- **AC:** in-memory-Firestore test: an account with `nextRefreshAfter` in the future is
  skipped and does not consume batch budget; missing field behaves exactly as today
  (always eligible).
- **V:** `npm test --prefix functions`.
- **R:** a wrong long TTL could starve an account. Mitigation: clamp already in T0.3
  (max 4 h) and the stale-first ordering still guarantees eventual selection.
- **RB:** stop writing the field; the filter treats missing as eligible — self-healing.

#### T1.5 Quota source/staleness badges in UI
- **Depends on:** T1.2.
- **Files:** `AgentLens/Views/Components/ProviderQuota/ProviderQuotaPopoverViews.swift`,
  `AgentLens/Views/Components/ProviderAccount/ProviderRoutingCockpit.swift`,
  `AgentLens/Views/Components/ProviderDashboardQuotaPanel.swift`.
- **Change:** render the snapshot source (`liveTraffic` / `localCLI` / `officialAPI` /
  cached / probed) and a relative-age label ("2m ago", amber ≥ TTL, red ≥ 2×TTL) on each
  quota card. Follow existing SwiftUI component patterns in those files; no new
  dependencies.
- **AC:** snapshot previews for each source render distinct badges; VoiceOver labels
  include age.
- **V:** `./scripts/test-openburnbar-app.sh`; screenshot in PR body.
- **R/RB:** cosmetic; revert.

---

### Phase 2 — Fresh Claude quotas (Objective 3)

#### T2.1 First-class Claude OAuth adapter in functions
- **Files:** new `functions/src/providers/claude.ts`; `functions/src/quota.ts`
  (`adapterFor` — add `case "claude-code": return claudeAdapter;`);
  `functions/src/secrets.ts` (confirm an `addSecretVersion`-style helper exists; if the
  only exports are `retrieveCredential`/`destroyCredential`, add
  `storeCredentialVersion(secretName, payload)` following the existing Secret Manager
  client usage in that file); new `functions/src/__tests__/providers/claude.test.ts`.
- **Change:** implement `ProviderAdapter.fetchQuota(credential, accountID, options)`:
  1. Decode the credential exactly like `decodeCredential` in
     `quota-runner/src/providers/claude.mjs` (raw JSON or base64 JSON, `claudeAiOauth`
     root or flat).
  2. If access token expired (mirror `BurnBarClaudeOAuthRouteCredential.isExpired` — 60 s
     skew), POST `https://platform.claude.com/v1/oauth/token` with
     `grant_type=refresh_token`, `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e` via
     `providerFetch` (never raw fetch — CI enforces this). On rotation, persist the
     re-encoded bundle to Secret Manager and update the
     `provider_account_secret_refs` doc's `secretVersionName` (reuse
     `providerAccountSecretRefPath`).
  3. GET `https://api.anthropic.com/api/oauth/usage` with
     `Authorization: Bearer <access>` and the `anthropic-beta` header value copied from
     `ClaudeOAuthUsageFetcher.swift` (~line 239's request construction — replicate its
     exact headers).
  4. Map the response's unified rate-limit windows to `QuotaBucket[]` with the same
     names/windows the client produces (`claudeQuotaBuckets(from:)` naming:
     `"Current session"` / 5h, weekly all-models, weekly-opus) so mobile renders
     identically regardless of writer.
  5. On 401/403 scope failure return
     `{ ok: false, errorCode: "oauth_scope_unsupported" }` — the caller falls back to the
     runner (T2.2).
- **AC:** fixture tests for: happy path mapping; expired→refresh→rotate→persist; scope
  failure code; malformed credential rejection. No plaintext token ever logged (assert
  log lines in tests).
- **V:** `npm test --prefix functions`; `bash scripts/ci/verify-resilience-wiring.sh`.
- **R:** Anthropic endpoint drift. Mitigation: fixtures pinned to current response shape
  + freshness SLO alarm (T0.2) catches silent breakage in production.
- **RB:** remove the `adapterFor` case; accounts fall back to runner-only behavior.

#### T2.2 Hosted Claude dispatch (server)
- **Depends on:** T2.1.
- **Files:** `functions/src/quota.ts` (line 54: add `"claude-code"` to
  `HOSTED_RUNNER_PROVIDERS`; in `refreshHostedQuotaAccount`, try `claudeAdapter` first
  for `claude-code` and fall back to `fetchHostedRunnerSnapshot` when the adapter
  returns `oauth_scope_unsupported`);
  `functions/src/callables/shared/accounts.ts` (line 32: add `"claude-code"` to
  `HOSTED_QUOTA_PROVIDERS`); `functions/src/types/legacy/providers.ts` (move
  `"claude-code"` from `LOCAL_ONLY_PROVIDERS` into a new exported
  `HYBRID_REFRESH_PROVIDERS` list and grep all `LOCAL_ONLY_PROVIDERS` consumers to keep
  their semantics — client-side scanning must remain enabled for claude);
  regenerate `functions/src/security/endpointAuthorizationCatalog.generated.ts` via its
  documented generator; `functions/src/__tests__/bola/authOnly.bola.test.ts` additions.
- **AC:** an integration-style test drives `refreshUserProviderAccountQuota` for a
  `server_private` claude account through (a) the OAuth adapter happy path and (b) the
  runner fallback; entitlement and budget gates (`requireHostedQuotaEntitlement`,
  `consumeHostedRefreshBudget`) are exercised unchanged (existing tests still green).
- **V:** `npm test --prefix functions`; `make ci` (Firestore rules unchanged — hosted
  accounts reuse existing paths).
- **R:** hosted budget consumption doubles if both adapter and runner run. Mitigation:
  fallback only fires on the specific scope error, and both count as the single budgeted
  refresh (budget consumed once, before dispatch — current code already does this).
- **RB:** remove `"claude-code"` from both sets; existing codex behavior untouched.

#### T2.3 Hosted Claude connect flow (client)
- **Depends on:** T2.2.
- **Files:** locate the existing hosted **Codex** connect UI/service by grepping AgentLens
  for the callable name used against `connectHostedQuotaAccount`
  (`functions/src/callables/providerAccounts.ts`) and mirror it:
  `AgentLens/Views/Settings/ConnectionsSettingsView*.swift` for the entry point, the
  Claude OAuth bundle sourced from `ClaudeCredentialsReader` /
  `ClaudeCodeOAuthCredentialImporter` (user-selected profile, explicit consent sheet).
  The upload payload is the JSON bundle exactly as `encodedStorageSecret()` shapes it.
- **Change:** add "Enable cloud-fresh Claude quota (uploads your Claude login to
  BurnBar's encrypted server vault)" opt-in row for Claude accounts; call the same
  high-risk-owner-action-gated callable path Codex uses; on success the account doc
  becomes `server_private` and the sweep takes over.
- **AC:** UI flow behind entitlement check; explicit consent copy names exactly what is
  stored and how to delete it (`deleteHostedQuotaCredentials` flow already exists);
  cancelling leaves the account untouched.
- **V:** `./scripts/test-openburnbar-app.sh`; manual flow screenshot in PR.
- **R:** user surprise at credential upload. Mitigation: opt-in only, consent sheet,
  existing delete callable surfaced next to the toggle.
- **RB:** hide the row (flag `hosted_claude_quota`, T6.4); already-connected accounts
  can be deleted via the existing delete flow.

#### T2.4 Runner Claude parser hardening + alarms
- **Files:** `quota-runner/src/providers/claude.mjs`, `quota-runner/test/claude-parser.test.mjs`.
- **Change:**
  1. **Decision procedure (fully specified, no improvisation):** run
     `claude /usage --help` and `claude usage --help` in the runner image. If either
     documents a JSON/`--output json` mode, implement
     `runClaudeUsageJSON(env)` as the primary path with the regex transcript path as
     fallback. If neither exists (both exit non-zero or show no JSON flag), skip the JSON
     path entirely and proceed with step 2 only. Record which branch was taken in the PR
     body.
  2. Golden-transcript contract tests: commit ≥ 3 captured real transcripts (current CLI,
     ANSI-heavy, narrow-terminal wrap) as fixtures; `parseClaudeUsage` must extract all
     four buckets from each.
  3. On zero-bucket parse, return a structured error object
     `{ code: "claude_usage_parse_failed", transcriptHash }` (never the raw transcript —
     it may contain account info) instead of a generic throw; `server.mjs` maps it to
     HTTP 502 with that code; `functions/src/quota.ts` `refreshHostedQuotaAccount` stores
     `lastErrorCode: "claude_usage_parse_failed"` and logs a `logError` event
     (`quota.claude_parse_failed`) that the SLO runbook (T0.2) lists as page-worthy.
- **AC:** fixtures pass; the parse-failure path produces the named error code end-to-end
  in a functions test.
- **V:** `node --test quota-runner/test/`; `npm test --prefix functions`.
- **R:** none beyond current behavior; strictly additive diagnostics.
- **RB:** revert.

#### T2.5 Client Claude tier ordering + probe budget
- **Depends on:** T0.3, T1.2.
- **Files:** `AgentLens/Services/ProviderQuota/ClaudeQuotaAdapter.swift`,
  `AgentLensTests/Active/` (extend the existing Claude adapter tests).
- **Change:** (1) consult harvested tier-0 signals before the statusline tier (they are
  fresher whenever present); (2) gate `headerProbeSnapshot` behind
  `QuotaRefreshPolicy.shouldSpendProbe` persisted per-account (UserDefaults suite the
  adapter context already carries); (3) keep all existing account-scoping guards
  byte-identical — they encode the "never reuse another account's data" invariant.
- **AC:** unit tests: probe is skipped when budget exhausted (falls to JSONL); harvested
  signal newer than statusline wins; account-scoping tests still green.
- **V:** `./scripts/test-openburnbar-app.sh`.
- **R:** probe budget too tight for heavy users. Mitigation: budget=4/day *per account*
  and only when tiers 0–3 all failed — strictly better than today's unbudgeted probe.
- **RB:** revert; cascade returns to current order.

---

### Phase 3 — Ollama multi-endpoint + universal failover conformance (Objective 2a)

#### T3.1 Daemon config schema: Ollama endpoint list
- **Files:** `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonConfiguration.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarConfigStore.swift` (~line 1268
  where ollama config resolves today), daemon config docs
  (`docs/PROVIDERS.md` Ollama section).
- **Change:** add `ollamaEndpoints: [OllamaEndpointConfig]` where
  `OllamaEndpointConfig { id: String, baseURL: String, apiKeyRef: String?, label: String, priority: Int, enabled: Bool }`.
  Migration: when the array is absent, synthesize one entry
  `{id: "default", baseURL: resolved(OLLAMA_HOST) ?? "http://localhost:11434", priority: 0}`
  — current behavior preserved exactly. Reject duplicate IDs and non-http(s) URLs at
  decode with a descriptive error.
- **AC:** decode tests for legacy config (no array), populated array, duplicate-ID
  rejection; `OLLAMA_HOST` still wins for the synthesized default.
- **V:** `swift test --package-path OpenBurnBarDaemon`.
- **R:** config-format drift for existing installs. Mitigation: additive field with
  synthesis; no existing key changes meaning.
- **RB:** revert; the array is ignored by old code.

#### T3.2 Router enumeration of Ollama endpoints as slots
- **Depends on:** T3.1.
- **Files:** `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift`
  (the ollama route-construction sites ~lines 883–898 and 1154–1165),
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderExecutor+OllamaNative.swift`
  (resolve base URL from the route, not global config),
  `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarProviderRouterTests.swift`.
- **Change:** for each enabled endpoint, emit a `BurnBarProviderRoute` with
  `providerID: "ollama"`, `credentialSlotID: endpoint.id`,
  `credentialSlotLabel: endpoint.label`, `baseURL: endpoint.baseURL`, ordered by
  `priority`. **No changes to failover logic** — `routeKey(providerID:slotID:)`,
  `markRouteFailure`, cooldowns, and the candidate loop in
  `BurnBarRunService+Execution.swift` handle rotation automatically once endpoints are
  slots.
- **AC:** router test: two endpoints → two ranked routes; excluding endpoint A's routeKey
  yields endpoint B; `executeProviderOnlyRun` test where endpoint A's executor throws a
  connection-refused error serves from B (extend `shouldFailOverProviderError` **only if**
  the test shows `URLError.cannotConnectToHost`/`timedOut` are not already covered by
  `isTransientCapacityFailure` — add
  `case .connectionFailed` handling mirroring the existing transient-capacity branch,
  keeping 401-on-local-endpoint non-failover semantics unchanged).
- **V:** `swift test --package-path OpenBurnBarDaemon`.
- **R:** double-routing to the same server via two aliases (localhost + LAN IP).
  Mitigation: document in Settings copy; harmless (cooldown converges).
- **RB:** revert to single-endpoint enumeration; config stays.

#### T3.3 Ollama endpoint health prober
- **Depends on:** T3.2.
- **Files:** new `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OllamaEndpointHealthProber.swift`
  + tests.
- **Change:** actor probing each enabled endpoint's `GET /api/tags` (5 s timeout) every
  60 s while any Ollama route exists; consecutive-failure count ≥ 2 marks the endpoint
  unhealthy → the router's trust dimension for that slot scores 0 (feed through the same
  mechanism `markRouteFailure` uses — call it with a synthetic health error) and recovery
  (1 success) clears it via `markRouteSuccess`. Never probes non-Ollama providers; probes
  are local/LAN HTTP only.
- **AC:** fake-clock tests: down→demoted within 2 cycles; up→restored on first success;
  prober idles (no timers) when no Ollama endpoints are configured.
- **V:** `swift test --package-path OpenBurnBarDaemon`.
- **R:** LAN chatter. Mitigation: 60 s cadence, only while configured, `/api/tags` is
  trivial.
- **RB:** revert; reactive failover (T3.2) still covers outages.

#### T3.4 Opt-in Bonjour discovery (suggest-only)
- **Depends on:** T3.1.
- **Files:** new `AgentLens/Services/ProviderQuota/OllamaEndpointDiscovery.swift`;
  Settings UI in the existing Ollama connect area (grep `"Connect Ollama"` in
  `AgentLens/Views/Settings/`); tests.
- **Change:** using `NWBrowser` for `_ollama._tcp` **and** a fallback probe of
  `http://<bonjour-host>:11434/api/tags` for `_http._tcp` results advertising port 11434
  (Ollama versions differ in what they advertise; both paths are implemented, results
  deduped by host:port). Discovery runs **only** while the "Discover local Ollama
  servers" sheet is open; results are *suggestions* the user must confirm to add to
  `ollamaEndpoints`. Nothing scans subnets; nothing persists without a click.
- **AC:** unit tests with a stubbed browser; UI adds an endpoint only after explicit
  confirm; closing the sheet cancels browsing.
- **V:** `./scripts/test-openburnbar-app.sh`; manual LAN demo in PR body.
- **R:** privacy optics of network browsing. Mitigation: explicitly user-initiated,
  sheet-scoped, suggest-only; copy states exactly what is browsed.
- **RB:** hide the sheet entry point; no data model impact.

#### T3.5 Multi-endpoint Ollama quota snapshots
- **Depends on:** T3.1.
- **Files:** `AgentLens/Services/ProviderQuota/OllamaQuotaAdapter.swift`
  (`resolveEndpoint`, line 239 → enumerate), `AgentLens/Services/ProviderQuota/ProviderQuotaService.swift`
  (Ollama fan-out), tests.
- **Change:** the adapter reads the endpoint list (delivered through
  `ProviderQuotaAdapterContext` — add `ollamaEndpoints` to the context, populated from
  the shared config the daemon writes; the Mac app already reads daemon config via
  `BurnBarConfigStore`), producing **one snapshot per endpoint** with
  `accountID = endpoint.id`, `accountLabel = endpoint.label`. Cloud scraping
  (ollama.com cookie) remains a single account (`accountID = "ollama-cloud"`), unchanged.
- **AC:** two configured endpoints → two quota cards (one reachable "running", one
  "unreachable"); single-endpoint installs render exactly as today (snapshot diff test).
- **V:** `./scripts/test-openburnbar-app.sh`.
- **R:** UI clutter for many endpoints. Mitigation: existing account-grouping UI already
  groups per provider.
- **RB:** revert; adapter returns to first-endpoint-only.

#### T3.6 Quota-aware predictive route demotion
- **Depends on:** T1.1.
- **Files:** `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift`
  (`scoreAndRankRoutes` already carries `quotaResetsAt`/`quotaRemainingPercent` on
  `BurnBarRankedRoute` — wire real values from `BurnBarQuotaSignalStore.latestSignals()`),
  router tests.
- **Change:** when a route's latest harvested signal shows `remaining == 0` (or unified
  status `rejected`) with `resetsAt` in the future: if ≥ 1 non-exhausted candidate exists,
  move the exhausted route after all non-exhausted ones (never drop it — it stays as the
  final fallback); record `exhausted_demotion` in the decision event's skip reasons. If
  all candidates are exhausted, rank as today (let the provider be the judge).
- **AC:** router tests: exhausted primary demoted below healthy secondary; sole-route
  case unchanged; decision event carries the reason string.
- **V:** `swift test --package-path OpenBurnBarDaemon`.
- **R:** stale exhaustion signal pinning a healthy route down. Mitigation: signals older
  than `resetsAt` or 15 min (whichever first) are ignored for demotion.
- **RB:** revert; reactive failover unaffected.

#### T3.7 Failover conformance test matrix (CI-gated)
- **Depends on:** T3.2.
- **Files:** new `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/ProviderFailoverConformanceTests.swift`.
- **Change:** a parameterized suite iterating **every** provider in
  `OpenBurnBarProviderCatalogSupport` × error classes
  {429, 401, 402, 403, 500-transient, timeout, connection-refused} × {2 slots same
  provider}: assert (a) `shouldFailOverProviderError` classification matches a committed
  expectation table (a literal Swift dictionary in the test — reviewable, no logic),
  (b) the candidate loop serves from slot B for failover-classified errors,
  (c) a `recoveryDecided`/decision event is emitted. The expectation table is the
  executable spec of "universal failover, no exceptions".
- **AC:** suite passes for all catalog providers including ollama; adding a provider to
  the catalog without a table row fails the test (completeness guard).
- **V:** `swift test --package-path OpenBurnBarDaemon`; wire into the existing daemon CI
  job.
- **R:** none — tests only.
- **RB:** n/a.

---

### Phase 4 — Cross-provider intelligent router (Objective 2b)

#### T4.1 `ModelEquivalenceRegistry` core type + seed data
- **Files:** new `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ModelEquivalenceRegistry.swift`;
  new seed `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/model-equivalence-v1.json`
  (registered as a SwiftPM resource); tests; `tools/schema-sync/` TypeSpec model +
  emitters so TS (functions), Kotlin (android), and C# (windows) get the same shape;
  run `./tools/schema-sync/check-drift.sh`.
- **Change:**
  - Types: `ModelEquivalenceClass { classID, displayName, tier (frontier|strong|fast|local), requiredCapabilities: [String], contextFloorTokens: Int, members: [ModelEquivalenceMember] }`,
    `ModelEquivalenceMember { canonicalModelID, providerIDs: [String], benchmarkKeys: [String], rankHint: Int }`,
    `ModelEquivalenceRegistry { schemaVersion: 1, generatedAt, classes }` with lookups
    `classFor(canonicalModelID)` and `equivalents(of:excluding:)`.
  - Seed JSON: build classes from the canonical model IDs already present in
    `OpenBurnBarLiveModelCatalog.swift` — group by capability class + tier
    (e.g. `frontier-coding`: claude opus/sonnet-latest, gpt-5-class, grok-4-class;
    `fast-general`: haiku-class, gpt-mini-class, flash-class; `local-oss`: the ollama
    catalog models). Every canonical ID in the live catalog must appear in exactly one
    class (test-enforced) — completeness is the point.
  - Merge rule (documented in the type's doc comment): committed seed is authoritative
    for **membership**; server benchmark data (T4.2) may only affect **ranking**.
- **AC:** decode + lookup tests; completeness test against the live catalog; schema-sync
  drift check green.
- **V:** `swift test --package-path OpenBurnBarCore`; `./tools/schema-sync/check-drift.sh`.
- **R:** membership judgment calls. Mitigation: PR review of the seed JSON is exactly the
  audit surface we want; user overrides (T4.4) handle disagreement.
- **RB:** revert; nothing consumes it yet.

#### T4.2 Server: benchmark bands on the router rundown
- **Depends on:** T4.1.
- **Files:** `functions/src/routerRundown.ts` (`buildAndPersistRouterRundown`),
  `functions/src/modelLandscape.ts` (read-only), tests.
- **Change:** annotate each rundown model entry with `equivalenceClassID` (from the
  schema-sync-emitted registry) and `benchmarkBand` (quartile of its class by the
  landscape's primary coding score; `unknown` when no data). Additive fields only.
- **AC:** rundown doc contains the fields; models absent from the registry get
  `equivalenceClassID: null` and are logged once per run (`router_rundown.unmapped_model`).
- **V:** `npm test --prefix functions`.
- **R/RB:** additive; revert.

#### T4.3 Daemon: real `intelligentModelRouter`
- **Depends on:** T4.1; T3.6 recommended first (shares ranking touchpoints).
- **Files:** `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderAccountTypes.swift`
  (lines 243–288), `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderRouter.swift`
  (`candidateRoutes` exact-model gate ~lines 467–475; benchmark bonus ~line 1884),
  router tests.
- **Change:**
  1. Un-alias the mode **decode-compatibly**: `init(from:)` decodes
     `intelligent_model_router` as itself; `effectiveMode` returns `.intelligentModelRouter`
     only when the runtime feature flag `intelligent_model_router` (T6.4) is on, else
     `.sameModelFailover` (today's behavior, bit-for-bit). Restore it to `allCases` only
     behind the same flag so UI pickers stay unchanged until rollout.
  2. Candidate expansion in `candidateRoutes`: in `intelligentModelRouter` mode, first
     collect exact-canonical routes (unchanged logic). If **zero** exact routes survive
     exclusions, look up `equivalents(of: requiredCanonicalModelID)` and admit routes
     whose `canonicalModelID` is a class member **and** whose `formatFamily` matches the
     request (the two-highways invariant is never crossed — reuse the existing
     `formatScopedRoutes` filter which already runs first).
  3. Ranking: existing five-dimension composite + the existing benchmark bonus, plus a
     deterministic `rankHint` tiebreak from the registry.
  4. Decision events: populate the existing `blockedExactModelRoutes` field and add the
     equivalence class ID to the narrative built at ~line 1310 so the cockpit can explain
     "served by X because it is in class frontier-coding with Y exhausted".
- **AC:** router tests: (flag off) byte-identical ranking to `sameModelFailover` on the
  full existing test suite; (flag on) exhausted exact routes + available class member →
  member wins; cross-format member never selected; decision narrative includes class ID.
- **V:** `swift test --package-path OpenBurnBarDaemon` (entire suite, not just new tests).
- **R:** silently serving a different model than requested. Mitigation: only in the
  explicit mode + flag + per-request decision event + UI disclosure (T4.4); exact routes
  always win when any exist.
- **RB:** flag off = alias behavior restored exactly.

#### T4.4 Cross-provider toggle + override UI
- **Depends on:** T4.3.
- **Files:** `AgentLens/Views/Components/ProviderAccount/ProviderRoutingCockpit.swift`,
  `AgentLens/Services/ProviderQuota/ProviderQuotaService.swift` (router-mode plumbing
  ~lines 810–825), config storage for overrides
  (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarConfigStore.swift` — new
  `equivalenceOverrides` array mirroring the RoamingProfile shape in § 3.4).
- **Change:** cockpit gains (a) the "Cross-provider failover" toggle (sets router mode to
  `intelligentModelRouter` / back), (b) a per-model override sheet: *pin* (never
  substitute this model) and *exclude* (never substitute *to* this model). Overrides are
  enforced in `candidateRoutes` expansion (pin → skip expansion entirely; exclude →
  filter member). Routing decisions render the equivalence narrative from T4.3.
- **AC:** toggle round-trips through daemon config; pinned model never expands (test);
  excluded member never selected (test); narrative visible in cockpit.
- **V:** `./scripts/test-openburnbar-app.sh` + daemon tests for override enforcement.
- **R/RB:** flag-gated with T4.3.

---

### Phase 5 — Secure cloud carryover (Objective 4)

#### T5.1 `RoamingProfilePayload` + CloudVault envelope + parity vectors
- **Files:** new `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/RoamingProfilePayload.swift`;
  `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` (add the
  AAD domain constant `roamingProfileAADDomain = "OpenBurnBar-RoamingProfile-v1"` next to
  the existing domain constants — follow the exact pattern of the signal at-rest domain
  constants); `windows/cloudsync/tools/CloudVaultVectorGen` (emit vectors for the new
  payload); the C# CloudVault test project under `windows/cloudsync/` (consume vectors);
  Swift tests in `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultCryptoTests.swift`.
- **Change:** the payload type per § 3.4 (Codable, `sortedKeys` + ISO8601 encoding to
  make ciphertext-input deterministic for vectors); seal/open helpers
  `sealRoamingProfile(payload, vaultKey, uid)` / `openRoamingProfile(data, vaultKey, uid)`
  that bind AAD = domain ‖ uid (byte layout identical to the existing per-payload AAD
  construction in `CloudVaultCrypto` — copy the exact framing helper the conversation
  payload uses). **No new cryptographic primitives** — reuse the existing envelope
  functions only.
- **AC:** Swift round-trip tests incl. wrong-uid AAD failure (must throw, fail-closed);
  parity vectors generated and green on both Swift and C# suites.
- **V:** `swift test --package-path OpenBurnBarCore`; the windows cloudsync test command
  documented in `windows/cloudsync/README` (run on CI's Windows lane).
- **R:** payload-evolution churn. Mitigation: `schemaVersion` + unknown-field-tolerant
  decoding from day one.
- **RB:** revert; envelope type unused.

#### T5.2 Roaming profile sync service (Mac) + Firestore surface
- **Depends on:** T5.1.
- **Files:** new `AgentLens/Services/CloudSync/RoamingProfileSyncService.swift` (model on
  `TextExpansionSyncService.swift`, which already does CloudVault-envelope upload/download
  with vault-key access); Firestore rules for
  `users/{uid}/roaming_profile/{current}` (owner-only read/write, envelope-shape
  validated — mirror the existing CloudVault blob rules; update
  `firestore.rules` and its tests); `functions/src/callables/shared/validators.ts`
  (envelope validator reuse — `CloudVaultBlobEnvelopeDoc` at line ~301 is the pattern);
  `docs/SCHEMA_SQLITE.sql` note if any local cache table is added (avoid one — read
  directly, cache in UserDefaults).
- **Change:** upload on any change to router mode/toggle/account order/ollama
  endpoints/overrides, debounced 5 s, through the existing sync gate
  (`context.syncGate()` — signed in + cloud sync enabled + not suppressed) with
  permission-denied suppression like `QuotaSnapshotSyncService`. Download on sign-in and
  on app launch; **fail closed**: any trust-chain or AAD failure logs and leaves local
  state untouched (never applies a profile it cannot authenticate). Conflict rule:
  last-writer-wins on `updatedAt` with per-field merge for `equivalenceOverrides`
  (union, exclusions win over pins on the same model).
- **AC:** emulator round-trip test (extend
  `AgentLensTests/Active/CloudSyncEmulatorIntegrationTests.swift`); tampered envelope →
  rejected + local state unchanged; rules tests deny cross-uid reads.
- **V:** `./scripts/test-openburnbar-app.sh`; `make ci` (rules suite).
- **R:** clobbering a newer local config with an older cloud one. Mitigation:
  `updatedAt` guard + `sourceDeviceID` shown in a "profile restored from <device>" toast.
- **RB:** flag `roaming_profile` (T6.4) off stops both directions; doc remains inert.

#### T5.3 Escrow generalization: Mac→Mac credential restore
- **Depends on:** T5.2.
- **Files:** `AgentLens/Services/CloudSync/MacEscrowCredentialProducer.swift` (the
  producer is already recipient-key-generic — `MacEscrowRecipientKey` resolves from
  `escrow_devices` + `escrow_public_keys`); the **new-device consumer** side: a Mac
  implementation mirroring the iOS import path (grep `iOSDeviceKeypair` /
  `LiveEscrowGateway.runImport` and port the import flow into a new
  `AgentLens/Services/CloudSync/MacEscrowCredentialConsumer.swift` with a P-256 keypair
  in the Mac Keychain); enrollment UI in Settings ("Restore credentials from another
  device"); `functions/` — verify `consumeCredentialTransfer` callable
  (`endpointAuthorizationCatalog` line ~689) is device-kind-agnostic; if it validates
  device kind, extend its validator to accept mac recipients with the same auth gates.
- **Change:** new Mac: generate escrow keypair → publish public key + fingerprint via the
  existing `escrow_public_keys` path → request grants for each `local_only` /
  `device_keychain` account listed in the roaming profile → old device (Mac or phone)
  shows the existing approval UX → sealed envelopes flow through the existing grant
  documents → consumer decrypts and writes Keychain items + flips account status to
  `connected`.
- **AC:** end-to-end emulator test: producer seals with recipient key, consumer opens,
  fingerprint mismatch fails closed; UI lists restorable credentials from the roaming
  profile with per-item approve state.
- **V:** `./scripts/test-openburnbar-app.sh`; emulator integration suite; manual
  two-machine (or two-user-account) demo documented in the PR.
- **R:** enrollment spoofing. Mitigation: unchanged trust model — fingerprint is bound to
  published key bytes and verified through `CloudVaultTrustedDeviceChainVerifier`
  exactly as the phone path does; approval is explicit on the old device.
- **RB:** hide enrollment UI; escrow docs are inert without a consumer.

#### T5.4 Zero-setup assembly: first-run restore orchestration
- **Depends on:** T5.2, T5.3; T2.3 for hosted accounts.
- **Files:** new `AgentLens/Services/CloudSync/NewDeviceRestoreCoordinator.swift` + a
  first-run Settings banner; tests.
- **Change:** on first sign-in on a device with no local provider accounts:
  (1) apply roaming profile (router mode, order, ollama endpoints, overrides);
  (2) `server_private` accounts: nothing to do — mark restored (server sweep already
  refreshes them); (3) `cloud_refreshable`: nothing to do; (4) `local_only`/
  `device_keychain`: surface the escrow-restore list (T5.3) in one banner with a single
  "Restore all" action; (5) after credentials land, trigger one quota refresh pass.
  Every step idempotent and resumable (a step-state record in UserDefaults).
- **AC:** integration test simulating fresh install + populated cloud: profile applied,
  hosted accounts live, escrow list shown; re-running the coordinator is a no-op.
- **V:** `./scripts/test-openburnbar-app.sh`.
- **R:** partial restores confusing users. Mitigation: banner shows per-account state
  (restored / needs approval / unavailable) until dismissed.
- **RB:** coordinator behind the `roaming_profile` flag.

#### T5.5 iOS + Windows consumption
- **Depends on:** T5.1.
- **Files:** `OpenBurnBarMobile/Services/` (read-only roaming-profile display: router
  mode + account order in the mobile provider list — model on
  `MobileCloudVaultKeyAccess` usage in `MobileTextExpansionStore.swift`); the phone-side
  escrow approval path already exists (verify, don't rebuild);
  `windows/cloudsync/` C# `RoamingProfilePayload` port with the T5.1 vectors.
- **AC:** iOS renders profile data read-only; C# vector test green; no write paths added
  on mobile.
- **V:** `./scripts/test-openburnbar-mobile.sh`; windows test lane.
- **R/RB:** additive read-only; revert.

---

### Phase 6 — Validation, rollout, documentation

#### T6.1 Conformance matrix execution + fixture freeze
- Run the § 5 matrix end-to-end; freeze golden fixtures (header samples, claude
  transcripts, registry seed) with a `README` in each fixture directory explaining
  refresh procedure. Any red cell blocks release.

#### T6.2 Documentation
- **Files:** new `docs/ARCHITECTURE/quota-signal-ladder.md` and
  `docs/ARCHITECTURE/model-equivalence.md` ADRs (follow the existing ADR format in
  `docs/ARCHITECTURE/README.md` and link from it); `docs/PROVIDERS.md` (Ollama
  multi-endpoint, hosted Claude); `CHANGELOG.md`; `docs/runbooks/slos.md` (from T0.2);
  update this plan's status header to `Shipped` per phase as phases land.

#### T6.3 Security review execution
- Run the § 6 checklist as a dedicated review PR comment on each security-relevant task
  (T2.1–T2.3, T5.1–T5.4); regenerate `endpointAuthorizationCatalog.generated.ts`;
  extend `functions/src/__tests__/bola/authOnly.bola.test.ts` for any new callable
  surface; `bash scripts/ci/verify-ops-readiness.sh` before the release tag.

#### T6.4 Feature flags + ring rollout
- **Files:** the rollout registry consumed by `scripts/rollout.mjs`.
- Flags: `quota_header_harvest`, `hosted_claude_quota`, `ollama_multi_endpoint`,
  `intelligent_model_router`, `roaming_profile`. Advance ring-by-ring
  (`node scripts/rollout.mjs --flag <flag> --stage ring-N`) with the rollback runbook
  (`docs/runbooks/rollback-automation.md`) linked in each flag's entry. Flag-off behavior
  for every flag is verified byte-identical to pre-change behavior by the tests named in
  the corresponding tasks.

---

## 5. Test and validation matrix

Rows = providers; columns = objective checks. Every cell names its concrete test home.
`DC` = daemon conformance suite (T3.7), `HH` = header-harvest tests (T1.1/T1.2),
`FQ` = functions quota tests, `EM` = emulator integration, `RS` = real-surface manual
check documented in the release PR.

| Provider | Live quota (Obj 1) | Multi-account failover (Obj 2) | Cross-provider (Obj 2) | Freshness SLO (Obj 3 style) | Carryover (Obj 4) |
|---|---|---|---|---|---|
| claude-code | HH (anthropic-unified headers) + statusline tests + FQ (T2.1) | DC | DC + T4.3 tests | T2.6 alarm test + RS | escrow restore EM (T5.3) |
| codex | existing hosted FQ + HH | DC | DC + T4.3 | T0.2 events | hosted = automatic (T5.4 test) |
| openai | FQ adapter + HH (x-ratelimit) | DC | DC + T4.3 | T0.2 | cloud_refreshable = automatic |
| minimax / zai / kimi / factory / cursor / xai / mimo | FQ adapter tests (existing) + T1.4 skip test | DC | DC + T4.3 | T0.2 | automatic |
| opencode / antigravity | runner tests (`node --test quota-runner/test/`) | DC | DC | T0.2 | escrow restore EM |
| **ollama (local, N endpoints)** | T3.5 multi-snapshot tests | **T3.2 + T3.3 (kill-endpoint test)** | T4.3 (`local-oss` class) | client T0.2 events | endpoints in roaming profile (T5.2 EM) |
| ollama cloud | scraper tests (existing) + cookie RS | via endpoint slots | T4.3 | T0.2 | cookie via escrow (T5.3) |

Cross-cutting suites: `make ci` (full parity), `./scripts/test-openburnbar-app.sh`,
`swift test --package-path OpenBurnBarDaemon`, `swift test --package-path OpenBurnBarCore`,
`npm test --prefix functions`, `node --test quota-runner/test/`,
`./tools/schema-sync/check-drift.sh`, windows cloudsync test lane,
`bash scripts/ci/verify-resilience-wiring.sh`, `bash scripts/ci/check-no-suppressions.sh`.

Real-surface validation (release gate, documented with screenshots/logs in the release
PR): (1) two Ollama endpoints, kill one mid-chat → seamless switch; (2) Claude quota
card updates within seconds of a proxied Claude request with the "Live from traffic"
badge; (3) hosted Claude account stays ≤ 20 min fresh with the Mac lid closed (check
from iOS); (4) fresh macOS user account sign-in → full restore per T5.4.

---

## 6. Security review checklist (per security-relevant PR)

Tied to the non-negotiable invariants; every item is a hard gate:

1. **Plaintext prohibition.** No credential, OAuth bundle, cookie, or session token in:
   Firestore docs, logs (`logError`/`logInfo` fields), decision events, quota snapshots
   (`sanitizeMeta` + `isSecretLikeKey` in `functions/src/quota.ts` stays on every new
   meta path), telemetry, or PR bodies. Grep the diff for token-bearing variable names
   before review.
2. **AAD + envelope invariants.** Every new CloudVault payload uses the existing framing
   helpers; AAD binds uid + a unique versioned domain string; wrong-AAD tests exist and
   assert throw (T5.1). No new crypto primitives; no parameter changes to existing ones.
3. **C# byte-compatibility.** Any new envelope/payload ships parity vectors from
   `CloudVaultVectorGen` and a green C# vector test in the same PR train (T5.1/T5.5).
4. **Trust chain fail-closed.** Roaming profile and escrow consumers reject on any
   `CloudVaultTrustedDeviceChainVerifier` failure and leave local state untouched
   (tested in T5.2/T5.3). No "best-effort apply".
5. **App Check + auth.** Every new/modified callable keeps
   `enforceAuthAndAppCheck` + `enforceHighRiskOwnerAction` where the catalog requires it;
   `endpointAuthorizationCatalog.generated.ts` regenerated; BOLA tests extended (T2.2,
   T5.3, T6.3).
6. **Escrow model integrity.** Recipient keys resolved only via
   `escrow_devices` + `escrow_public_keys` with fingerprint-to-bytes binding; ECIES
   construction unchanged (`OpenBurnBar-Escrow-v1` sharedInfo); grants are
   per-credential and explicitly approved.
7. **Secret Manager hygiene.** Rotated Claude bundles create new secret versions and
   destroy superseded ones where the existing codex flow does; `provider_account_secret_refs`
   docs never readable by clients (rules unchanged).
8. **Budget/entitlement gates.** Hosted Claude refresh passes through
   `requireHostedQuotaEntitlement` + `consumeHostedRefreshBudget` unmodified; no budget
   bypass on the adapter-first path (consumed once pre-dispatch).
9. **No new suppressions.** `scripts/ci/check-no-suppressions.sh` green; any unavoidable
   suppression carries an inline `reason:` and a `docs/LINT_RATIONALE.md` entry.
10. **Local file hygiene.** New daemon persistence (`quota-signals.json`) is 0600 in a
    0700 directory, matching `BurnBarProviderRoutingDecisionEventStore`.
11. **Header-harvest privacy.** Harvested signals contain rate-limit numerics only —
    never request/response bodies, API keys, or org identifiers beyond what the snapshot
    schema already carries.

---

## 7. Sequencing, critical path, and parallelization

```
P0: T0.1 ── T0.2 ── T0.3          (all parallel, no interdependencies)
                     │
P1: T1.1 → T1.2 → T1.5            T1.3 (needs T0.3)   T1.4 (needs T0.3)
      │        │
P2: T2.1 → T2.2 → T2.3            T2.4 (independent)  T2.5 (needs T0.3+T1.2)
      │
P3: T3.1 → T3.2 → {T3.3, T3.5, T3.7}    T3.4 (needs T3.1)   T3.6 (needs T1.1)
                     │
P4: T4.1 → {T4.2, T4.3} → T4.4
P5: T5.1 → T5.2 → {T5.3, T5.5} → T5.4   (T5.4 also wants T2.3)
P6: T6.1–T6.4 last (T6.2 docs may trail each phase)
```

- **Critical path (longest chain):** T0.3 → T1.1 → T1.2 → T2.5 → conformance — but the
  *user-visible* critical path is T2.1 → T2.2 → T2.3 (hosted Claude), which is
  independent of Phase 1 and should start immediately in parallel.
- **Three independent lanes** can run simultaneously after Phase 0:
  Lane A (quota efficiency): P1 → T2.5;
  Lane B (Claude cloud): T2.1–T2.4;
  Lane C (failover): P3 → P4.
  Lane D (carryover, P5) is independent of A–C except T5.4's soft dependency on T2.3.
- **Do not parallelize within a lane** where tasks touch the same files
  (`OpenBurnBarProviderRouter.swift` is shared by T3.2/T3.6/T4.3 — serialize those).
- Every phase ends with its flag at ring-0; T6.4 governs ring advancement.

---

## Appendix A — Adversarial loophole audit (closed before finalizing)

Questions asked of this plan ("how does a literal executor still ship non-SOTA or
insecure?") and the closures baked in above:

1. *"Executor harvests headers but fabricates buckets when headers are absent."* —
   T1.1 AC forbids fabrication ("headers absent → no signal recorded").
2. *"Executor makes tier-5 probes 'efficient' by just probing less but the ladder still
   bottoms out at probes for Claude idle users."* — T2.2 gives idle-cloud freshness via
   the server sweep, removing probe pressure; T2.5 budgets probes independently.
3. *"Hosted Claude ships but silently double-spends the refresh budget via
   adapter+runner."* — T2.2 R section: budget consumed once, pre-dispatch.
4. *"Ollama failover works only for the quota card, not live routing."* — T3.2 routes are
   the routing substrate itself (slots), with a kill-endpoint execution test.
5. *"Equivalence expansion silently crosses format families."* — T4.3 keeps
   `formatScopedRoutes` first-in-pipeline and tests the negative case.
6. *"intelligentModelRouter un-aliasing breaks old configs."* — decode-compat + flag-off
   equivalence verified byte-identical (T4.3 AC).
7. *"Roaming profile applies unauthenticated data on decrypt failure."* — fail-closed AC
   with tamper test (T5.2).
8. *"Escrow Mac consumer invents a new crypto path."* — T5.3 mandates porting the exact
   iOS import construction; checklist § 6.6 gates it.
9. *"Executor marks a task done with tests that never run in CI."* — every V section
   names an existing CI-wired command; T3.7 and T6.1 add completeness guards.
10. *"Parser hardening 'figures out' the CLI."* — T2.4 step 1 is a fully specified
    two-branch decision procedure with recorded outcome.
11. *"Freshness SLO exists but nobody is alerted."* — T0.2 requires the runbook entry
    with alert threshold; T2.4/T2.6 name page-worthy events.
12. *"Legacy `provider_connections` installs miss all of this."* — the sweep's legacy
    pass is untouched; hosted Claude creates first-class account docs; no regression
    surface.
