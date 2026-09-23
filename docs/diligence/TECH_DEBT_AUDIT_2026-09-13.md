# Tech Debt Review

**Date:** 2026-09-13
**Scope:** OpenBurnBar monorepo (macOS app, iOS, Android, daemon, Functions, Windows, Linux desktop, console, extension)
**Method:** Six-lens swarm (code quality, architecture, testing/CI, reliability/ops, security/deps, performance/data) plus orchestrator verification against the live tree, GitHub Actions, and GCP
**Tree:** `feat/living-glass-sweep` HEAD `83615058eb` (2026-08-20) + large uncommitted working tree; `origin/main` `a0f2d81e62` (2026-09-11)
**Prior register:** `TECH_DEBT_AUDIT_2026-09-01.md` (untracked). This review verifies that register against live evidence and replaces it as the current plan.

Do not treat April `docs/TECH_DEBT_STRATEGY.md` or the July 30 `docs/TECH_DEBT_METRICS.md` snapshot as current. Both are stale relative to this tree.

---

## Executive summary

The biggest truth: OpenBurnBar already built a fail-closed control plane (ratchets, attestations, promotion gates, 80+ workflows) and then stopped consuming its expensive signals. The cheap PR door is green enough to merge. The expensive proof (production Functions deploy, nightly Mac app, DAST, ops-plane) has been red, skipped, or waiting for months. Paying Mac clients are on `1.0.40+repair.36` (appcast 2026-08-30). Live Cloud Functions `healthReady` still serves `v1.0.4` / commit `d6f3098013`, `updateTime=2026-06-18T16:42:37Z`. Two “successful” August deploys skipped `deploy-functions`. Issue #2195 is still open.

That freeze is a symptom. The compounding debt is ownership at process boundaries the ratchets cannot see: two processes write one 8.4 GB `openburnbar.sqlite`; daemon RPC is frozen at protocol v1 with a 185-case Swift enum; Kernel is a 53,692-LOC hub behind a 900-file umbrella; six clients were stood up by copy. Ratchets measure file shape. They do not measure who owns a table.

What leadership should do first: unblock one real `deploy-functions` this week (not a skipped dry-run), then make every red scheduled lane green, quarantined-with-owner, or deleted. Spend the recovered attention on three seams — SQLite writer, RPC versioning, Computer Use / iroh tests — not on a Kernel rewrite, a unified UI kit, or resurrecting the Full Harness as a merge ticket.

Align with the 2026-08-15 cheap-door rule: keep the 45-minute PR set cheap. Do not put the 50-minute AgentLens XCTest corpus back on the merge door. The nightly Mac build still has to prove the app; today it fails on missing `cmake`/`protobuf` on the `burnbar-swift` pool.

---

## Closed since earlier registers (do not re-open)

| Item | Evidence |
|---|---|
| Empty `catch {}` in app/daemon/core/mobile | 0 sites |
| `fatalError` on DataStore init | `OpenBurnBarStartupRecovery.swift` archive/reset path; no `fatalError` in `AgentLensApp` / DataStore |
| SQLite unencrypted at rest | SQLCipher passphrase mode, `kdf_iter=256000`, refuse plaintext if `cipher_version` empty (`DatabaseEncryptionService.swift`, `decisions/sqlcipher-params.md`) |
| CloudSyncService 2,102-LOC god object | Split; live ~255 LOC; ADR-002 marks MainActor cleared |
| `fetchAllUsageCallSites` baseline stale at 3 | Now 1 (`budgets/usage-refresh-tick-baseline.json`) |
| Search hydration / indexer N+1 | Batched JOIN + preload; dashboard `assertMaxQueries(12)` |
| Settings UserDefaults write storm | Coalesced 100 ms dirty-key flush (`SettingsPersistenceCoordinator`) |
| ParserDiskCache pretty JSON | Binary plist |
| Mission create/claim/cancel as client `setDoc` | Admin-SDK callables; rules have **no** `allow create` on `cli_agent_mission_requests`; events unmatched = deny |
| `MissionRemoteAuthorizationShadow` default `.shadow` | Default is `.enforce` |
| Daemon heartbeat / crash-loop | 10s heartbeat file, LaunchAgent KeepAlive, supervisor backoff |
| Extension untrusted workspaces | `supported: false` |
| Attachment reaper unbounded | Batched 100×10 + 50s timeout |
| Headless app build | Last 20 runs all success |
| Phase 1 security **code** register | 0 open code items (`PHASE1_SECURITY_REGISTER.md`); remaining work is operator/deploy proof |

Accepted product risks stay in `docs/governance/RISK_REGISTER.md` (AR-001 unsandboxed direct-download, AR-003 unsigned extension package, AR-005 Path C MAS compile-out, AR-006 Cursor quick tunnel, AR-007 unsigned SOTA signoff). They are not debt.

---

## Top debt themes

| # | Theme | What it says |
|---|---|---|
| T1 | **Controls without a consumer** | Promotion attestations, Full Harness, DAST, ops-plane, and the App PR Gate produce red pages nobody unblocks. Fail-closed without an override became “nothing ships.” |
| T2 | **Ownership seams ratchets cannot see** | App + daemon write the same SQLite file. RPC v1 never negotiates. ADR-005 still says the app owns SQLite. Gates are scoped to one directory of one binary. |
| T3 | **Parity-by-port** | Mac, iOS, Android, Windows, Linux, console. Copies land; extraction never happens because the copy already works. gl-engine even has a test that **forbids** deleting the copy. |
| T4 | **Safety tests that lock in the weakening** | Computer Use coordinator is 2,975 LOC with six coordinator tests, two of them vacuous. Iroh replay tests assert that in-window replay **succeeds**. Phone-control replay is disk-persisted and fail-closed; iroh pairing is not. |
| T5 | **O(history) data plane** | 8.4 GB sqlite, no usage/conversation retention, VACUUM deferred, JSONL journals uncapped (controller-events 168 MB), conversation-bodies re-read whole files. |
| T6 | **Keeping-current** | GRDB 6.29.3 (upstream 7.11), libsignal fork 7+ minors behind, Stripe 19 vs 22, 29 open Dependabot PRs, 5 cargo dirs uncovered. |
| T7 | **Hub-and-umbrella graph** | Kernel 53,692 LOC / SharedModels 31,662 flat. 900 umbrella imports frozen. Rust domain core is a fourth copy, dormant since 2026-07-15, default `.legacy`. |
| T8 | **This branch copies chrome** | Living-glass is a visual unification theme implemented as lockstep twins (`LiquidGlass.swift` Mac 442 / iOS 335) plus a third Recap copy. Do not turn that into a cross-platform UI rewrite. |

---

## Ranked debt register / Top debt hotspots

Ranking: live production risk → safety-critical correctness → rewrite prevention → compounding cost → weekly velocity. Disposition: **now** / **soon** / **opp** / **accept**.

| # | Title | Sev | Scope | Effort | Disp | Owner |
|---|---|---|---|---|---|---|
| 1 | Production Functions frozen at 2026-06-18 `v1.0.4`; Mac feed is `1.0.40+repair.36` | Critical | Systemic | M unblock / L gate redesign | now | infra |
| 2 | Dual-writer `openburnbar.sqlite` (app GRDB + daemon GRDB + three self-heal DDLs) | Critical | Systemic | L | now (contract) / soon (move) | platform/daemon |
| 3 | Iroh live-session freshness 3→30 min, phone-asserted, in-memory replay swallowed | High | Cross | S–M | now (before merge) | security |
| 4 | `refs/preserved-stash/99^3` holds real Firebase plists + console `.env.production` | High | Local | S | now | repo admin |
| 5 | Computer Use coordinator 2,975 LOC; HUD/keep-awake/phone `setTrustMode` unproven | High | Cross | M | now | Computer Use |
| 6 | Scheduled proof lanes red/disabled and mostly unpaged (Harness, DAST, e2e, ops-plane) | High | Systemic | M | now | CI |
| 7 | App PR Gate (nightly Mac proof) red on self-hosted `cmake`/`protobuf` | High | Cross | S | now | CI |
| 8 | Daemon RPC frozen at v1, 185-case Swift-only enum, no TypeSpec | High | Systemic | M | now | daemon |
| 9 | Mission evaluation still ×5; `mission_groups` still client-writable | High | Systemic | M | soon | cloud + daemon |
| 10 | Unbounded sqlite (8.4 GB) + deferred VACUUM + uncapped JSONL | High | Systemic | M | soon | Mac data |
| 11 | Conversation-bodies JSONL full re-read on append | High | Cross | M | soon | LogParsers |
| 12 | PCM code-search brute-force cosine; HNSW unused on that path | High | Cross | M | soon | search |
| 13 | Kernel hub 53,692 LOC + 900 umbrella imports | High | Systemic | L | soon | core |
| 14 | Rust domain core: fourth copy, default `.legacy`, dormant 07-15 | High | Cross | M/domain or S freeze | decide now | core |
| 15 | `Package.swift` graph depends on local `Vendor/*.xcframework` `ls` | High | Cross | M | soon | build |
| 16 | Parity-by-port: gl-engine 13k byte copy (test-locked), 8 parser twins, Linux gateway 1,814 LOC | High | Systemic | S / M / L | now (gl) / soon | web / parsers / daemon |
| 17 | PR door runs no AgentLens/mobile XCTest; CU tests never execute on PRs | High | Systemic | M | now | CI |
| 18 | Money-path `onRequest` handlers outside Sentry wrap | High | Local | S | now | functions |
| 19 | Client/server catalog skew (200 `functions/src` commits since freeze) | Critical | Systemic | follows #1 | now | infra |
| 20 | Firestore `users/*/usage` has no TTL | Med | Systemic | S–M | soon | functions |
| 21 | GRDB 6.29.3 / libsignal 0.94.4+6 / Stripe 19; 29 Dependabot PRs | Med | Cross | M | soon | security |
| 22 | Firestore rules 4,984 lines near 1,000-expression limit | Med | Cross | M | soon | security |
| 23 | File-size ratchet fitted to 2000 (0 files over); 129 Swift files 1001–1930 | Med | Systemic | S gate / L decomp | now (gate) / opp | platform |
| 24 | `[String: Any]` Core+Daemon 1,169 unmeasured | Med | Cross | S | now | platform |
| 25 | SettingsManagerProtocol still 117 requirements | Med | Cross | M | soon | Mac app |
| 26 | Living-glass LiquidGlass + Recap triples | Med | Cross | M | now (this branch) | UI |
| 27 | `XCTSkip` ~159 + `Task.sleep` ~260 as a second quarantine | Med | Systemic | M | soon | tests |
| 28 | Schema doc 49 tables, verifier starts at v50; omits `conversations` | Med | Local | S | soon | data |
| 29 | Feature-flag / UserDefaults sprawl (~238 keys, no registry) | Med | Systemic | M | soon | platform |
| 30 | Repo ops: 108 open PRs, ~1,900 branches, no delete-on-merge; metrics stamped 2026-07-30 | Med | Local | S | now | ops |
| 31 | VideoEncoder still `@MainActor` (in-flight hop reduction on this branch) | Med | Local | M | opp (after current media diff) | media |
| 32 | Structured logging `privacy: .public` (~396 sites) | Med | Cross | M | opp | platform |
| 33 | Recovery-bundle PBKDF2 100k | Low | Local | S | opp | platform |
| 34 | Force-unwrap baseline 213 (audit wanted 203) | Low | Cross | S | opp | platform |
| 35 | ADR index decay (two 011s, two 015s, ADR-005 stale) | Low | Cross | S | now | architecture |
| 36 | Root cruft / unreferenced scripts | Low | Local | S | opp | ops |

### Detailed entries — top 12

### 1. Production Functions frozen at 2026-06-18
- **Category:** deploy safety
- **Severity:** Critical
- **Scope:** Systemic
- **Evidence:** `gcloud functions describe healthReady` → `updateTime=2026-06-18T16:42:37Z`, `version=v1.0.4`, commit `d6f3098013`. `curl healthReady` matches. `https://downloads.burnbar.ai/latest-macos.json` → `1.0.40+repair.36` (2026-08-30). Last `deploy-functions=success`: run `27775189384` on 2026-06-18. Aug 3/4 “success” runs skipped `deploy-functions`. Latest tag attempt `v1.0.40+repair.39` (2026-09-02) failed `prepare-functions-deploy` at “Verify protected promotion and exact rollback before build”; `deploy-functions` skipped. Issue #2195 still OPEN (`failures:55`, `escalated:72h`). Zero `deploy-production` runs after 2026-09-02. `origin/main` has ~200 commits in `functions/src` since the freeze.
- **Why it matters:** every callable, quota, mission, attachment, and vault change since June 18 is invisible in production. Shipped clients call a catalog that is 12+ weeks behind.
- **Business impact:** Hosted features 404 or run old policy. Incidents are silent because deploy-freshness itself is blind (#2557 identity-not-provisioned).
- **Engineering impact:** bots cut repair tags; humans debug the gate; product work stacks on an undeployable server.
- **Risk if ignored 3–12 months:** the backlog becomes one undeployable atomic change with no incremental rollback target.
- **Remediation:** (1) incident: break-glass (`docs/runbooks/functions-break-glass.md`) or fix the promotion/attestation step so missing attestation fails into **manual-approval**, not closed forever; (2) one tagged deploy that actually runs `deploy-functions`; (3) prove `healthReady.version` moves; (4) add a >14 d staleness tripwire to release; (5) stop repair-tag loops on a red lane.
- **Effort:** M unblock / L redesign
- **Owner:** release/infra
- **Prereqs:** GCP + `domain-core-promotion` environment
- **Disposition:** fix immediately

### 2. Dual-writer `openburnbar.sqlite`
- **Category:** state ownership
- **Severity:** Critical
- **Scope:** Systemic
- **Evidence:** ADR-005: “App owns SQLite.” Daemon opens the same file (`OpenBurnBarSwitcherShell.swift:89`, `BurnBarAIInboxStore.swift:40-49`) and can `SQLITE_OPEN_CREATE` it (`OpenBurnBarDaemonServer.swift:643-652`). Two 65-ID GRDB migrators (AgentLens + Core). Daemon also `CREATE TABLE IF NOT EXISTS` for chat, PCM, AI Inbox. Both sides `INSERT` `chat_messages`. Timestamp format already split (GRDB space vs daemon ISO `T`) — documented silent empty-result bug (`docs/AI_INBOX.md`). Live founder DB **8.4 GB**. The 88 migrator-parity rows are **Windows missing tables**, not app↔daemon schema diffs.
- **Why it matters:** chat, search, memory, inbox — the product — have no single writer. Migrations and VACUUM cannot be owned.
- **Business impact:** silent lost writes / empty inbox / WAL corruption on the highest-value local data.
- **Engineering impact:** every schema change is a two-binary change on different cadences.
- **Risk 3–12 months:** one side migrates; the other self-heals a divergent DDL; backups of an 8 GB file become the recovery plan.
- **Remediation:** interface-first table→owner matrix (extend ADR-005). Then strangler: daemon owns `chat_*` / `search_*` / PCM / inbox; app reads via RPC. One migrator. Delete AgentLens twin and daemon `CREATE TABLE IF NOT EXISTS` once the app migrator is guaranteed first.
- **Effort:** L
- **Owner:** platform/daemon
- **Prereqs:** #8 RPC versioning
- **Disposition:** fix immediately (contract); schedule soon (move)

### 3. Iroh pairing window widened; replay guard is a no-op for dials
- **Category:** remote-control trust
- **Severity:** High
- **Scope:** Cross-cutting
- **Evidence:** Uncommitted on this branch. `IrohPairingFreshness.liveSessionMaximumAgeSeconds = 30 * 60`. iOS sets `remoteSessionLive` from local `computerUseSessionLive` / media phase (`HermesIrohRelayTransport.shouldExtendPairingFreshness`) — not a Mac-minted nonce. Guard is `[String: Date]` process memory. `fetchAndVerify` **catches `.replayed` and continues** (`IrohPairingDirectory.swift:109-126`). Tests encode that weakening (`testFetchAndVerifyToleratesInWindowReplay`). Zero Swift tests of `IrohPairingReplayGuard` consume/prune/relaunch. Android still 3 minutes. Server still 3 minutes. Phone-control replay, by contrast, is disk-persisted and fail-closed.
- **Why it matters:** a captured signed pairing record is dialable for 30 minutes if the phone claims the session is live; the only replay defense evaporates on app restart and is swallowed on re-dial.
- **Business impact:** Computer Use / Mercury trust boundary.
- **Engineering impact:** merging this branch ships the window.
- **Risk 3–12 months:** one replayed pairing during a live session is an incident, not a ticket.
- **Remediation:** persist consumed keys or bind live-session records to a Mac-minted session nonce; Mac asserts liveness; clock-injected consume/prune/relaunch tests; do not swallow `.replayed` for attacker-shaped snapshots. Idle 3-minute bound stays.
- **Effort:** S–M
- **Owner:** platform/security
- **Disposition:** fix immediately (before merge)

### 4. Preserved-stash secrets
- **Category:** secrets hygiene
- **Severity:** High (asymmetric: one `git push --mirror` publishes them)
- **Scope:** Local refs, global blast radius
- **Evidence:** `refs/preserved-stash/99^3` = `b16b753c3b` contains real `GoogleService-Info.plist` (both apps), `apps/console/.env.production`, `functions/.env.burnbar` (Sentry DSN, KMS key name). 112 preserved-stash refs exist. HEAD tracks templates only.
- **Remediation:** `git update-ref -d` the secret-bearing refs, expire reflog, gc, rotate the plist/console keys, add gitleaks to pre-commit (CI already has it).
- **Effort:** S
- **Owner:** repo admin
- **Disposition:** fix immediately

### 5. Computer Use coordinator under-tested
- **Category:** coverage shape
- **Severity:** High
- **Scope:** Cross-cutting
- **Evidence:** 2,975 LOC across four files. Coordinator suite grew 2→6 tests. HUD factory returns `nil`, so panic-clear is vacuously true. Uncommitted `+Approvals`/`+Input` add phone `setTrustMode` and keep-awake/HUD lifecycle with **no** matching tests through `handlePhoneIntent`. `ComputerUseSafetyInvariantHarness` is a separate Core FSM that never instantiates the production coordinator. Phone-control **validator** is actually strong (attestation, disk replay, fail-closed). Capability gate has ~40 tests. The hole is the live session actor.
- **Remediation:** test-first: clock-injected table for trust-mode × action-class × approval-outcome; phone elevation refused through the coordinator; HUD/keep-awake teardown with a non-nil fake. Then split the actor by responsibility.
- **Effort:** M
- **Owner:** Computer Use
- **Disposition:** fix immediately (before next ring advance / this branch merge of CU slices)

### 6. Scheduled proof lanes unconsumed
- **Category:** CI/CD
- **Severity:** High
- **Scope:** Systemic
- **Evidence (live `gh`, 2026-09-13):** Full Harness last success **2026-06-19** (the “0/500 ever” claim is false; last 100 since late July: 0 success). DAST last green 2026-06-24. linux-nightly last schedule success 2026-07-08. nightly-e2e **never green**, now `disabled_manually`. ops-confidence last green 2026-07-13. ops-plane-verify last schedule success 2026-06-01; 2026-09-07 still **waiting** on `environment: production`. App PR Gate scheduled 2026-09-13 **failed** (`Missing native build tools (cmake, protobuf)` on `burnbar-swift`). `ops-failure-issue` still missing on harness, CodeQL, app-pr-gate, ops-plane-verify. Headless app build is green — not every expensive lane is dead.
- **Remediation:** triage each lane to fix / quarantine-with-owner-and-date / delete. Wire `ops-failure-issue` + escalation. A weekly “scheduled-lane health” job that fails a **main** scoreboard (not the PR door) when any required nightly is red >7 d. Do not put Full Harness back on the merge door.
- **Effort:** M
- **Owner:** CI
- **Disposition:** fix immediately

### 7. Nightly Mac proof is environmental-red
- **Category:** CI gating
- **Severity:** High
- **Scope:** Cross-cutting
- **Evidence:** Today’s App PR Gate: `AgentLens Rust + Swift build/test prerequisites` failed `Missing native build tools (cmake, protobuf) and Homebrew is unavailable`. Mobile job **succeeded**. Push “successes” on Sept 5–7 were 33-second classifier skips, not app builds. Cheap-door policy is correct (`docs/CI_COST_CONTROLS.md`); the nightly still has to prove the app.
- **Remediation:** install cmake+protobuf on the pool **or** evict the broken runner. Do not add a 50-minute App XCTest job to `burnbar-ci-gate.fast.json`. Optionally add a <10 min PR-time compile of a curated ComputerUse slice when those paths change (`pr-native-fast` already covers Core+Daemon).
- **Effort:** S
- **Owner:** CI
- **Disposition:** fix immediately

### 8. Daemon RPC frozen at v1
- **Category:** contract/versioning
- **Severity:** High
- **Scope:** Systemic
- **Evidence:** `BurnBarProtocolVersion.current = 1`, `supported = [1]`. `BurnBarRPCMethod` 185 cases. `tools/schema-sync` emits nothing for RPC. Extension hand-types a 37-method subset. App, daemon, extension, Linux, Windows ship on different cadences against it.
- **Remediation:** TypeSpec the envelope + method table; emit Swift/TS/Kotlin/C#; v2 with a real N-1 negotiation test. Prerequisite for SQLite strangler.
- **Effort:** M
- **Owner:** daemon
- **Disposition:** fix immediately (interface); schedule soon (emit)

### 9. Mission authority remainder
- **Category:** three-way state
- **Severity:** High (create-path Critical claim is stale)
- **Scope:** Systemic
- **Evidence:** Create/claim/cancel callables exist; rules deny client create. Remaining: daemon MissionControl 7,415 LOC; Mac GUI cluster frozen at 4,323 (`mission-splitbrain-baseline.json`); iOS/Android dispatchers; `mission_groups` still `allow create/update` for owners; Android still calls retired `writeSignalAtRestDocument`. TypeSpec `missions.tsp` is an 8-field stub vs a ~400-line rules match. Production may not have the callables (#1).
- **Remediation:** after #1, TypeSpec real mission + group docs; move `mission_groups` to callables; delete leftover client writes; keep daemon as sole attenuator (ADR-016).
- **Effort:** M
- **Owner:** cloud + daemon
- **Disposition:** schedule soon (depends on #1)

### 10. Unbounded primary data + VACUUM deferred
- **Category:** data lifecycle
- **Severity:** High
- **Scope:** Systemic
- **Evidence:** Live founder machine 2026-09-13: sqlite 8.4 GB, support dir 11 GB, `controller-events.jsonl` 168 MB, `provider-routing-decisions.jsonl` 50 MB. Retention only reaps terminal `projection_jobs`. v48 TODO still defers VACUUM. Backup prune is count=5, not bytes.
- **Remediation:** 180 d default retention setting; guarded `incremental_vacuum` on idle with free-disk check; size-capped JSONL rotation. Do **not** rewrite `token_usage` to integer PK (full-table copy on multi-GB files).
- **Effort:** M
- **Owner:** Mac app/data
- **Disposition:** schedule soon

### 11. Conversation-bodies full JSONL re-read
- **Category:** ingestion CPU
- **Severity:** High
- **Scope:** Cross-cutting
- **Evidence:** Claude incremental resume gated on `!includeConversation` (`ClaudeCodeParser.swift:355-361`). Codex bodies scan from byte 0. Usage-only pass already checkpoints. Live session files are hundreds of MB.
- **Remediation:** persist conversation accumulator alongside token accumulator; resume `byteOffset` for bodies, or move bodies to a lower-cadence pass.
- **Effort:** M
- **Owner:** LogParsers
- **Disposition:** schedule soon

### 12. PCM brute-force embedding recall
- **Category:** search scale
- **Severity:** High
- **Scope:** Cross-cutting
- **Evidence:** `BurnBarProjectCodeMemoryStore.semanticCodeChunkIDs` SELECTs every blob, cosines, sorts, `.prefix(limit)`. HNSW is used for indexed conversation search, not this path. Chat-memory recall is O(all memories) + N+1 body open — different bug; do not wire HNSW to the unused `memoryEmbeddingMatches` API.
- **Remediation:** back PCM search with the existing HNSW snapshot; keep brute force as test oracle.
- **Effort:** M
- **Owner:** search/memory
- **Disposition:** schedule soon

---

## What is hurting velocity most

1. **Red expensive lanes and repair-tag loops (#1, #6, #7).** Engineers and bots spend cycles on gates. 41 `*repair*` tags exist. The cheap door is the right shape; the nightlies are not an honest scoreboard.
2. **Two-binary schema changes (#2) and five-codebase mission/CU changes (#5, #9).** Features in these domains are implemented 2–5×.
3. **900-file umbrella + Kernel hub (#13).** Importing Core pulls 54k LOC. New types land in flat `SharedModels/` because that is the path of least resistance.
4. **Parser twins and Linux gateway twin (#16).** Quota bugs get fixed on the copy the author had open.
5. **SettingsManagerProtocol 117 requirements (#25) and 129 files in the 1–2k band (#23).** Reviewers reason about mixed concerns; the 2000-line ratchet never fires.
6. **`scripts/` ~1,250 files with no index (#36).** Agents cannot tell which script is the door.
7. **This branch’s lockstep twins (#26).** Every glass tweak is two (sometimes three) files.

---

## What is riskiest for production

1. **Functions freeze + catalog skew (#1, #19).** Clients on 1.0.40 talking to 1.0.4 server.
2. **Dual-writer SQLite on an 8.4 GB file (#2, #10).** Corruption is silent.
3. **Iroh pairing window + swallowed replay (#3).** Remote-control trust.
4. **Computer Use coordinator gaps (#5).** Approval is the v1 ground truth; the live actor is under-proven.
5. **Preserved-stash secrets (#4).** One mirror push.
6. **Money-path `onRequest` without Sentry (#18).** Stripe / App Store / Hermes HTTP.
7. **No Functions auto-rollback (#1 related).** Cloud Run auto-pins previous revision; Functions tell the operator to run a script after a deploy that never happens.

---

## Rewrite / refactor risk

These force expensive rework if left to compound. None of them need a greenfield rewrite today.

1. **DataStore / sqlite writer split.** Keep one `DatabaseQueue` family, one migrator, one owner per table. Splitting into multiple database files later is harder than assigning owners now.
2. **RPC as an unversioned Swift enum.** App nightly vs daemon vs extension vs Linux vs Windows. Without N-1, a method add becomes a coordinated flag day.
3. **Kernel hub.** The 55-target split exists in the manifest, not the import graph. Ceiling has been raised 37k → 54k. Next growth must be a new target, not another raise.
4. **Rust domain core half-on.** Fourth copy + 3–4k adapter glue + control-plane manifest churn. Payoff is entirely at the deletion gate. Decide: finish one domain in 30 days, or freeze.
5. **Parity-by-port.** gl-engine, parsers, Linux gateway, Settings-search twins. Copies that work become the product. Extraction cost grows with every ported feature.
6. **O(history) ingest and recall.** Bodies re-read and PCM brute-force will make the menu bar feel slow before anyone budgets a rewrite.

Do **not** rewrite: SwiftUI+actor UI, the cheap PR door, Liquid Glass into a cross-platform kit, `token_usage` integer PK, Full Harness as a merge ticket.

---

## Architecture concerns

- **ADR-005 is false.** It says the app owns SQLite. The daemon writes chat/search/PCM/inbox/switcher and can create the file.
- **ADR-016 is half-true.** Create/claim/cancel moved to callables in source. `mission_groups` did not. Production may not have the callables.
- **ADR-002 is partly done.** CloudSync MainActor cleared; UsageAggregator retained; `Task.detached` still 18 in `AgentLens/Services`; VideoEncoder still `@MainActor`.
- **ADR-014 is stalled.** Default `.legacy`. Last crate commit 2026-07-15.
- **ADR index decay.** Two 011s, two 015s, omitted numbers, ownership table missing daemon domains since May.
- **Module graph.** `OpenBurnBarCore` is 11 shims / 127 LOC. Kernel absorbed the god module. Umbrella baseline 900 files (AgentLens 528, Mobile 370) is an intentional keep — call it that, then ratchet per target to zero.
- **Build graph.** `Package.swift` probes `Vendor/*.xcframework` at evaluation. `git ls-files Vendor` has 0 xcframeworks. Domain-core linkage is machine-dependent.
- **Living-glass** is local mess (lockstep twins), not a new ownership seam. Keep platform adapters.

---

## Testing and CI gaps

- **PR door (`burnbar-ci-gate.fast.json`, 60 contexts):** Fast Feedback, PR Native (Core+Daemon `swift test`), Windows Fast, Android **ktlint**. Not AgentLens XCTest, not mobile XCTest, not Android unit, not Daemon PR Gate, not Domain Core PR Gate.
- **App PR Gate** is post-merge + nightly. Policy is correct. Execution is red on runner tooling. Bounded smoke (`OPENBURNBAR_RELEASE_APP_TEST_FILTERS`) is 11 suites, **zero ComputerUse**.
- **`computer-use-loopback-test.yml`** is on `pull_request` but path-filters omit `AgentLens/Services/ComputerUse/**` and it is not in the fast required set.
- **Coordinator tests live in `OpenBurnBarTests`**, which PRs never run.
- **Quarantine directory is empty.** The real quarantine is `XCTSkip` (~159) + `Task.sleep` (~260) inside Active.
- **Test theater:** HUD tests with nil factory; Iroh tests that replay must succeed; Aurora tests that mutate local vars, not the tray; CloudSync enum Equatable tests.
- **Schema tests** stamp v35 identifiers and walk forward; they do not restore a fleet-shaped DB. Verifier starts at v50, so `conversations` drift is invisible.
- **Living-glass tests** pin preference math (good) and skip visual proof (acceptable if named). They do not run on PRs.
- **Platform shape:** Android ~2,001 unit tests and Windows ~3,042 facts exist; they are off the 45-minute eligibility set (Windows Fast runs when `windows/` changes). Keyboard 0 tests. Widget “tests” are DEBUG previews.

Cheap-door constraint: do not “fix” this by making AgentLens XCTest a merge ticket. Fix the nightly runner; add a path-filtered ComputerUse slice to PR Native when those files change.

---

## Debt reduction strategy

**Philosophy:** Unfreeze production and make the scoreboard honest. Then assign owners at process boundaries. Then pay the copies that already have a deletion seam. Do not aesthetic-refactor.

1. Safety and deploy first — Functions, pairing, stash, CU tests.
2. Contracts before moves — table→owner, RPC TypeSpec, mission TypeSpec.
3. Strangle, do not rewrite — one migrator, one RPC version, one parser engine, one gl-engine.
4. Ratchets that measure the real thing — file-size 1500, String:Any includes Core/Daemon, twin **type names**, scheduled-lane health.
5. Keep the cheap merge door. Make nightlies tri-state: green / quarantined-with-owner / deleted.

**Will not do:** Kernel rewrite; unified SwiftUI/Compose/WinUI kit; TCA adoption; integer PK migration; Full Harness on PRs; parallel media cleanup on the in-flight BWE/GOP branch.

---

## Phased roadmap

### Phase 0 — this week (blockers)
**Goals:** production can receive Functions; this branch does not ship a weaker pairing story; secrets are gone; nightly Mac proof has a living runner.
**Workstreams:**
- P0-1: Unblock `deploy-functions` (break-glass or promotion-gate → manual approval). Prove `healthReady.version` ≠ `v1.0.4`.
- P0-2: Iroh pairing: Mac-asserted liveness or persistent replay; relaunch tests; do not merge the 30-minute window as-is.
- P0-3: Delete secret-bearing preserved-stash refs; rotate keys.
- P0-4: Fix `burnbar-swift` cmake/protobuf (or evict). Tonight’s App PR Gate must be able to compile.
- P0-5: `wrapRequestHandler` for Stripe / App Store / Hermes `onRequest`.
- P0-6: CU tests for phone `setTrustMode` through the coordinator + non-nil HUD teardown (on this branch).
- P0-7: Hoist `LiquidGlassTransparency` (or stop adding a third copy) before more glass call sites land.
- P0-8: Delete console gl-engine copy **or** invert the parity test so it fails if the copy exists.
**Why now:** these are incidents, merge blockers, or one-line governance lies.
**Risks:** break-glass without a second pair of eyes; pairing fix that re-breaks reconnect storms (the swallow was a 2026-07-03 live fix — replace it with a better one, don’t just revert).
**Success:** `healthReady` moves; stash refs gone; App PR Gate compiles; pairing tests fail on relaunch replay.

### Phase 1 — foundations (days 8–30)
**Goals:** written ownership; RPC v2 contract; data lifecycle; honest nightlies.
**Workstreams:**
- Extend ADR-005 with table→process→replica for all ~70 objects.
- TypeSpec RPC envelope + method table; negotiation test; keep v1 in `supported`.
- Retention window + guarded incremental vacuum + JSONL size-cap.
- Conversation-bodies byte-offset checkpoint.
- Nightly triage: each red lane → fix / quarantine+date / delete. Wire `ops-failure-issue` on harness, CodeQL, app-pr-gate, ops-plane-verify.
- Drop Swift file-size target to 1500 (baseline the 35). Extend String:Any to Core/Daemon. Close singleton 56→55 (`ComputerUseAuditExportSignerPublisher.shared`).
- Rust go/no-go: one domain promoted and legacy deleted, or freeze crate + stop adapters.
**Success:** ADR-005 matches code; RPC v2 exists even if not all clients emit yet; sqlite stops growing without bound; no required nightly is red >7 d without an owner.

### Phase 2 — cross-cutting cleanup (days 31–60)
**Goals:** start the sqlite strangler; kill the expensive copies.
**Workstreams:**
- Daemon owns `chat_*` (or app does — pick one) via RPC; stop dual `INSERT`.
- Delete AgentLens parser copies; Mac uses Core.
- Linux gateway: extract route pipeline; Linux keeps POSIX sockets.
- `mission_groups` callables; delete Android retired signal write.
- PCM HNSW for code search.
- Dependabot coverage for remaining cargo/npm; plan GRDB 7 / Stripe 22 as their own PRs.
- Feature-flag registry with owner + expiry.
**Success:** one writer per hot table; one AiderParser; gl-engine is a package; mission groups are server-owned.

### Phase 3 — architecture strengthening (days 61–90)
**Goals:** Kernel split by domain under the existing deny-gate; umbrella ratchet per target; VideoEncoder off MainActor after the media diff lands.
**Workstreams:**
- Split SharedModels (Hermes, CloudVault, Provider, MissionConsole, WarRoom) as new targets; freeze Kernel ceiling.
- Per-consumer umbrella-removal ratchet (AgentLens, then Mobile).
- Replace `nonisolated(unsafe)` upward hooks with injected protocols.
- Checksummed xcframework bundles; Package.swift shape from a declared flag.
- SettingsManagerProtocol split to match existing stores; ban new requirements.
**Success:** Kernel LOC falling; at least one app target at 0 umbrella imports; Package.swift identical on a clean CI machine and a laptop without Vendor artifacts.

### Phase 4 — polish (after 90)
Twin-type-name gate, `XCTSkip` burn-down, schema-doc completeness, `privacy: .public` audit, recovery-bundle KDF, script knip, root cruft. Opportunistic file splits on touch. Do not start this while Phase 0 is open.

---

## 30/60/90 day plan

### 30 days
- Functions production revision newer than 2026-06-18; `healthReady.version` recorded.
- Pairing merge blocker closed; stash refs deleted; keys rotated.
- App PR Gate compiles on the nightly runner three days running.
- ADR-005 owner matrix merged.
- RPC TypeSpec checked in (even if emitters are partial).
- Retention + JSONL rotation shipped or scheduled behind a setting.
- Rust decision recorded in ADR-014 (promote-one or freeze).
- Scheduled-lane board: every required nightly is green, quarantined, or deleted.
**Success criteria:** no P0 open in this register; cheap door unchanged.

### 60 days
- Dual-writer contract enforced in CI (table→owner; new dual writes fail).
- Parser twins gone.
- gl-engine single copy.
- mission_groups server-owned.
- PCM search on HNSW.
- Bodies ingest resumes by byte offset.
- String:Any + file-size ratchets include the real surface.
**Success criteria:** a schema change is a one-binary PR; quota parsers have one implementation.

### 90 days
- At least one Kernel domain split out; umbrella imports falling.
- Package.swift reproducible without `ls Vendor`.
- SettingsManagerProtocol shrinking.
- Dependabot coverage complete; one current major (Stripe or GRDB) in flight, not five.
- VideoEncoder isolation moved after media work landed.
**Success criteria:** Kernel ceiling has not been raised; a new intern can find the owner of `chat_messages` from ADR-005.

---

## Quick wins

| Item | Effort | Why first |
|---|---|---|
| Evict/fix `burnbar-swift` cmake+protobuf | S | Nightly Mac proof works |
| Delete gl-engine console copy / invert parity test | S | 13k LOC lie |
| Delete preserved-stash secret refs + rotate | S | Asymmetric |
| Singleton 56→55 (inject CU audit publisher) | S | Gate already red on this tree |
| Swift file-size target 1500 | S | Ratchet starts meaning something |
| String:Any gate → Core/Daemon | S | 1,169 unmeasured dicts |
| `wrapRequestHandler` on 10 `onRequest` | S | Money path Sentry |
| JSONL size-cap rotation | S | 168 MB journal |
| Invert CU HUD tests to use a fake session | S | Tests can fail |
| ADR-005 + ADR index cleanup | S | Stop lying in the architecture canon |
| Close force-unwrap slack 213→203 | S | Honest shrink |
| Path-filter CU into PR Native when those files change | S | Cheap door still cheap |

---

## Longer-horizon refactors

| Item | Strategy |
|---|---|
| SQLite single writer | Strangler + RPC |
| RPC v2 | Interface-first TypeSpec |
| Kernel / SharedModels split | Incremental per-domain target; no rewrite |
| Rust domain core | Finish one domain or freeze — no third state |
| Linux gateway | Extract route pipeline; keep transport adapters |
| SettingsManagerProtocol | Incremental protocol split matching existing stores |
| VideoEncoder actor | After current BWE/GOP lands |
| GRDB 7 | Dedicated upgrade PR after SQLCipher pin is explicit |
| Firestore rules split | Only if expression-count gate fails; not aesthetic |

---

## Metrics and governance

Regenerate `docs/TECH_DEBT_METRICS.md` on a weekly job that **fails if the timestamp is >14 d old**. Current snapshot is 2026-07-30 and the updater preserves the stamp unless `OPENBURNBAR_REFRESH_TECH_DEBT_TIMESTAMP` is set — that is why it lies.

Track these, not file-count vanity:

| Metric | Source | 30 d | 90 d |
|---|---|---|---|
| Functions `healthReady` age | live GCP | <14 d | <7 d |
| Required nightlies red >7 d | `gh` + ops-failure-issue | 0 unowned | 0 |
| App PR Gate compile (not 33s skip) | scheduled run | 3 consecutive greens | stay green |
| Dual-writer tables (both sides INSERT) | small CI probe | owner matrix exists | shrinking |
| RPC `current` / `supported` | `BurnBarRPCContracts` | v2 in supported | N-1 proven |
| Kernel LOC / umbrella files | existing baselines | ceiling not raised | falling |
| sqlite file size on founder machine | `du` | not growing unbounded | retention on |
| `IrohPairingReplayGuard` relaunch test | XCTest | exists and fails closed | stays |
| CU coordinator tests through production types | XCTest | phone trust + HUD | table-driven matrix |
| Open Dependabot PRs >30 d | GitHub | shrinking | <10 |
| `TECH_DEBT_METRICS.md` age | git | <14 d | <14 d |

Governance:
- Baseline bumps (`budgets/*.json`) only in `chore(baseline)` PRs, not feature PRs.
- Accepted risks live in `RISK_REGISTER.md`. Temporary red lanes are not accepted risks; they get an owner and a date.
- Cheap door stays cheap. Nightlies stay honest.
- One theme per PR (cheap-door rule). Do not open ten slice PRs for this plan. Phase 0 is one incident thread. Phase 1 is a small number of fat PRs.

---

## Highest-leverage first steps

1. **Unblock production Functions.** Until `healthReady` moves, every other server-side debt item is theoretical.
2. **Do not merge pairing-as-is.** Mac-asserted liveness or persistent replay, plus relaunch tests.
3. **Delete stash secrets and rotate.**
4. **Fix the nightly Mac runner tools.** Keep XCTest off the merge door.
5. **Write the table→owner contract.** One page in ADR-005. Blocks months of dual-write bugs.
6. **Decide Rust:** one domain to deletion, or freeze.
7. **Delete the gl-engine copy.** Smallest 13k-LOC win in the repo.

What can wait: Kernel split, SettingsManager protocol, GRDB 7, `privacy: .public` audit, script knip, VideoEncoder actor, schema-doc completeness.

What to accept intentionally: unsandboxed Developer ID (AR-001); MAS Path C compile-out (AR-005); Cursor quick tunnel (AR-006); platform UI twins (Liquid Glass adapters, not a shared UI framework); Windows subset schema (88 missing tables — document as accepted port subset, test Mac→Windows restore); cheap PR door without full AgentLens XCTest.

---

## Guardrails

- Tests first on CU and iroh. Do not split the coordinator until the matrix exists.
- Feature flags already exist for Computer Use kill switch and pairing; use them for the 30-minute window if product insists on shipping reconnect-through-sleep before Mac-asserted liveness.
- SQLite moves: parallel read via RPC, then cut writes, then delete the twin migrator. Keep pre-migration backup. `scripts/rollback-migration.sh` is restore-from-backup, not down-migrations — keep it that way.
- Functions: health gate after deploy; add auto-rollback like Cloud Run once deploys actually run.
- Docs: update ADR-005/014/016 residuals in the same PR as the contract change. Do not leave the canon lying.
- Ownership: CODEOWNERS already covers security trees. Assign a **named human** for scheduled-lane health. Gates without a consumer created this register.

---

## Final recommendation

This week is an incident, not a refactor sprint: **deploy Functions, don’t merge the pairing window, delete the stash, fix the nightly runner.**

The next month is contracts: **who owns each SQLite table, what the RPC version is, whether Rust is real.** Those three decisions prevent the rewrites.

Everything else — Kernel split, parser twins, file-size theater, glass lockstep — is real debt that should ride along fat theme PRs, not become its own program while production is twelve weeks behind the client.
