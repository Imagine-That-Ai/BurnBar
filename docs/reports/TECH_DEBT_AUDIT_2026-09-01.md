# OpenBurnBar Tech Debt Audit & Reduction Plan — 2026-09-01

*Third formal audit (after 2026-06-11 and 2026-06-30). Produced by a six-lane swarm (code quality, architecture, testing, reliability/ops, security/dependencies, performance/data) plus an orchestrator pass over git, CI run history, and branch protection. Every claim was verified against the working tree at `feat/living-glass-sweep` (main + 42), `origin/main`, live `gh` run logs, and the local filesystem. mem0 was unreachable this session and was not consulted.*

---

## 1. Executive Summary

**The biggest truth:** the June remediation built an enormous fail-closed control plane — 84 workflows, 32,118 lines of YAML, 229 check/verify scripts, 28 ratchets, 18 baselines, attestation-bound promotion gates — and then nobody was assigned to consume its signals. Where the controls are cheap (the PR fast lane) they are green. Where they are expensive (nightly proofs, the macOS app build, DAST, ops-plane verification, production deploy) they have been red for four to eleven weeks, filed once, de-duplicated, and ignored. The result is that **production Cloud Functions have not successfully deployed in the last 120 attempts** (the deploy-freshness gate last read the live function `updateTime` as 2026-06-18) while the Mac client shipped on 2026-08-28 calling at least 20 callables that exist only on `main`. Rules deployed on 2026-09-01 are ~75 days ahead of the code they guard.

That is the headline, but it is a symptom. The pattern underneath it appears in every lane:

- **Ratchets measure shape, not health.** File size, import lists, declaration counts, tagged `try?` — all green. Meanwhile two processes write the same SQLite file with independent migrators, mission authority lives in five codebases, the daemon RPC contract is frozen at version 1 with no negotiation, and a byte-identical 13k-LOC engine copy landed in August. None of that is visible to any gate.
- **Parity-by-port is the delivery model.** Six full clients (Mac, iOS, Android, Windows, Linux desktop, web console) plus a daemon were stood up by copying the nearest working implementation. The Rust "shared domain core" meant to end this is a fourth copy with zero legacy deletions and no commits in six weeks.
- **Velocity collapsed while the fix ratio stayed high.** Commits per week fell from 700–880 (June/July) to 42–103 (August); fix commits outnumber feature commits 3.4:1 in August (7.4:1 in June). The team is paying interest, not principal.

The good news is real and should not be relitigated: import-level Firebase isolation, crash reporting on all clients, 110/110 callables wrapped for Sentry, Stripe/webhook verification, default-deny Firestore rules, 93% SHA-pinned actions, DB migration backup/restore, FTS orphan leak, rollup contention — all verified closed. The plan below does not touch them.

**What leadership should do first:** unfreeze production (Phase 0, this week), then make every red lane either green, quarantined-with-owner, or deleted, then spend the recovered attention on the three ownership seams (SQLite, missions, RPC) that will otherwise force a rewrite.

---

## 2. Top Debt Themes

| # | Theme | What it says about the system |
|---|---|---|
| T1 | **Controls without a consumer** — red nightlies, frozen deploy, self-suppressed paging, 166-commit manifest churn, baselines bumped inside feature PRs, metrics reporting tagged sites as zero | Governance was built at AI-fleet speed and scaled past the humans who read it. Fail-closed without an override degrades into "nothing ships". |
| T2 | **Ownership seams the ratchets can't see** — shared `openburnbar.sqlite` with two writers, mission authority ×5 + client-writable Firestore, RPC v1 with no compat policy, ADR-005 ownership table stale since May | The product's real seams are process and platform boundaries; every gate is scoped to one directory of one binary. |
| T3 | **Parity-by-port duplication** — gl-engine byte copy, 8 parser twins already diverged, Linux gateway twin, 120 type names in both Mac and iOS, DB migrator twin, Rust core as 4th copy | New surfaces are stood up by copy; extraction never happens because the copy already works. |
| T4 | **Safety boundary under-tested** — Computer Use coordinator (2,975 LOC) has 2 direct tests; iroh replay guard has 0; the in-flight branch widens pairing freshness 3→30 min with a process-memory replay guard; 260 `Task.sleep`, 158 `XCTSkip` | Test volume is huge (13k Swift tests) but concentrated on crypto and contracts, thin on stateful orchestration where remote control of a Mac is decided. |
| T5 | **O(history) and O(all-users) data paths** — no retention/VACUUM (18 GB on a dev machine), conversation-bodies pass re-reads whole JSONL files, brute-force embedding recall, hourly unbounded `collectionGroup` reaper, no TTL on `usage` | Every past perf incident has a tripwire; the guards cover the path that paged, not the class of path. |
| T6 | **Keeping-current debt** — GRDB vendored at 6.29.3 (2024-09, upstream 7.11), libsignal personal fork 7 minors behind, 21 open Dependabot PRs, Stripe SDK 3 majors behind, a preserved stash ref holding real Firebase/console secrets | Strong at design time, weak at staying current; anything outside Dependabot's directory list has no freshness signal. |
| T7 | **Hub-and-umbrella module graph** — 54k-LOC Kernel with 31k in one flat `SharedModels/`, ~900 files still import the umbrella, `Package.swift` shape depends on `ls Vendor`, `SettingsManager` behind a 117-requirement protocol, 686 `.shared` uses | The 55-target split exists in the manifest, not the import graph; nothing can be reshaped without a repo-wide touch. |

---

## 3. Ranked Debt Register

Ranking axis: **live production risk → safety-critical correctness → rewrite prevention → compounding cost → velocity drag → long tail.** Lane key: OP ops, AR architecture, TE testing, SE security, PF performance, CQ code quality. Disposition: **now** (this week), **soon** (next 4–8 weeks), **opp** (opportunistic, on touch), **accept** (record, don't fix).

| # | Title | Sev | Scope | Effort | Disp | Lane |
|---|---|---|---|---|---|---|
| 1 | Production Functions frozen at 2026-06-18; clients ship against `main`; 0/120 deploys succeed; P0 #2195 self-suppressed | **Critical** | Systemic | M unblock / L redesign | now | OP |
| 2 | Shared `openburnbar.sqlite` written by app *and* daemon (12 shared tables, 2 migrators, 88 "intentional divergences") | **Critical** | Systemic | L | now (contract) / soon (move) | AR |
| 3 | Mission authority in 5 codebases; clients write Firestore mission docs directly, contradicting ADR-016 | **Critical** | Systemic | L | now (rules flip plan) / soon | AR/SE |
| 4 | Scheduled proof lanes perpetually red and unconsumed (Full Harness 0/500 ever; DAST since 06-24; Linux nightly since 07-08; nightly-e2e 0/48; ops-plane-verify since 08-03) | **High** | Systemic | M | now | OP/TE |
| 5 | PR door runs no macOS-app / mobile / daemon / Android tests; App PR Gate is post-merge and 23/30 red on self-hosted runner tool drift | **High** | Systemic | M | now | TE/OP |
| 6 | In-flight: iroh live-session pairing freshness widened 3→30 min with in-memory replay guard; phone asserts liveness | **High** | Cross | S | now (before merge) | SE |
| 7 | Computer Use coordinator/approvals state machine has 2 direct tests; replay guard 0; HUD session 0 | **High** | Cross | M | now | TE/SE |
| 8 | Daemon RPC contract Swift-only, version frozen at 1, 185-case string enum, hand-typed in extension, no compat policy | **High** | Systemic | M | now | AR |
| 9 | Unbounded primary tables, no retention, VACUUM deferred; 8.5 GB sqlite + 8.6 GB backups on one machine | **High** | Systemic | M | soon | PF/OP |
| 10 | Conversation-bodies ingest discards byte-offset checkpoint; full JSONL re-read per append | **High** | Cross | M | soon | PF |
| 11 | Brute-force embedding recall (app + daemon) while HNSW backend sits unused for that path | **High** | Systemic | M | soon | PF |
| 12 | Rust domain core: 4th copy + 3–4k LOC adapter glue, zero deletions, dormant since 07-15 | **High** | Cross | M/domain | decide | AR |
| 13 | Kernel hub (54k LOC, 31k flat SharedModels) + ~900 umbrella imports frozen by a 64 KB baseline | **High** | Systemic | L | soon | AR |
| 14 | `Package.swift` graph shape depends on local `Vendor/` contents; xcframeworks untracked | **High** | Cross | M | soon | AR/OP |
| 15 | Cross-target reimplementation: gl-engine 58/58 identical files (~13k LOC, Aug-20); 8 diverged parser twins; Linux gateway twin (1,814 LOC, 0 shared names); 120 Mac/iOS type-name twins | **High** | Systemic | S / M / L | now (gl) / soon | CQ |
| 16 | Preserved stash ref holds real Firebase plists + console `.env.production` | Med | Local | S | now | SE |
| 17 | GRDB-SQLCipher vendored at 6.29.3 with no provenance/refresh; libsignal fork v0.94.4+6 vs upstream v0.101.2 | Med | Cross | M | soon | SE |
| 18 | 21 open Dependabot PRs; Stripe 19→22, TS 5.9→7, eslint 9→10; 5 cargo dirs and 4 npm packages uncovered | Med | Cross | M | soon | SE |
| 19 | Metrics doc reports tagged sites as 0 (`try?` 526/519 tagged; `@unchecked Sendable` 146 live vs "78"); `[String: Any]` unmeasured in Core/Daemon (1,150) | Med | Systemic | S | now | CQ |
| 20 | File-size ratchet fitted to worst offender (2000, never moved; 132 files >1000); `+Extension`/`*Sections.kt` splitting = 11% of Swift, 61 "+" files define top-level types | Med | Systemic | S gate / L decomp | now (gate) / opp | CQ |
| 21 | Branch-protection verifier cancelled by PR concurrency; drift unwatched since 08-03 | Med | Local | S | now | OP |
| 22 | Time-based tests: 260 `Task.sleep`, 131 timeouts ≥5s; `XCTSkip` ×158 as a second quarantine (~20 "fixture not bundled") | Med | Systemic | M | soon | TE |
| 23 | Cloud Functions: hourly unbounded `collectionGroup` reaper; no TTL on `users/*/usage`; 163 functions in one deploy bundle; no auto-rollback | Med | Systemic | S / M | now (reaper) / soon | PF/OP |
| 24 | Feature-flag/config sprawl: 227 UserDefaults keys, 92 env keys in functions, flags with zero consumers, no registry/owner/expiry | Med | Systemic | M | soon | OP |
| 25 | `SettingsManager` god object (117-requirement protocol, 175 files); 686 `.shared` uses (289 in Views) uncounted by singleton gate | Med | Cross | M | soon | AR |
| 26 | Firestore rules 4,984 lines near the 1,000-expression limit; hand-maintained ~110-collection allowlist; 42 rule tests for 98 match blocks | Med | Cross | M | soon | SE |
| 27 | Video encoder state on `@MainActor`, 5 hops per frame at 30–60 fps; quota loops outside cadence coordinator (mac + iOS) | Med | Local | M / S | soon | PF |
| 28 | Schema doc covers 50/68 live tables; verifier scans v50+ only; migration tests never walk a seeded fleet-shaped DB | Med | Local | S | soon | PF/TE |
| 29 | `scripts/` is a second product: 1,213 files, 492 commits in 2 months, 38 unreferenced scripts, 73 unreferenced test scripts, a 4,647-line Python verifier | Med | Cross | M | soon | CQ |
| 30 | Repo ops: 91 open PRs (67 aged 7–30 d), 1,798 remote branches, no delete-on-merge, no stale bot; factory promises MERGED/CLOSED/BLOCKER but only a nightly repair job exists | Med | Local | S | now | OP |
| 31 | `onRequest` money-path handlers (Stripe webhook, App Store notifications, Hermes gateway) outside the Sentry/logging wrapper | Med | Local | S | now | OP |
| 32 | Test targets on Swift 5.10 while shipping targets are 6 strict; 113 `nonisolated(unsafe)`; 11 upward mutable-global hooks in Core | Med | Cross | S | now | AR |
| 33 | Platform sprawl with unowned spikes: `apps/pensieve-experience`, Keyboard/Widget (0 tests), `packages/gl-engine` (no tests), `crates/openburnbar-media` (no CI), Safari extension (3 commits) | Med | Systemic | S decide / M archive | decide | AR |
| 34 | ADR decay: two 011s, two 015s, index omits 5, no Status on 2, ownership table missing every daemon domain since May | Low | Cross | S | now | AR |
| 35 | Committed automation runs Claude with permissions disabled (2 sites, one inside a security verifier); PBKDF2 100k; `LICENSES/` missing AGPL text; Sparkle residue in Info.plist | Low | Local | S | opp | SE/OP |
| 36 | Root/disk cruft: 4.8 MB `tmp-utm-desktop.png`, 8 dated reports at root, dormant `gateway/`, `hermes_cli/`, `tui_gateway/`, `spikes/`, 1.7 GB ignored `artifacts/` | Low | Local | S | opp | CQ |

### Detailed entries — the top 16

**#1 — Production Functions frozen since 2026-06-18**
Category: deploy safety · Severity **Critical** · Scope Systemic · Lane OP
Evidence: `deploy-production.yml` last 120 runs — no run with a successful `deploy-functions` job; last 40 are all `failure`/`cancelled` on `push`. Latest failure step: `prepare-functions-deploy :: Verify protected promotion and exact rollback before build` → `failed to fetch attestations: HTTP 404` (`.github/workflows/deploy-production.yml:379-506`, `verify-domain-core-release-gate.mjs`). 37 `v*repair*` tags cut by `factory-droid`/`BurnBar Perf Bot` between 08-18 and 09-01. Issue #2195 (P0, `failures:53`, `escalated:72h`), latest action output `not paged (already-paged)`. The `ops-confidence` deploy-freshness gate (itself red since 07-13) last reported `cloudFunctions 66.8 days old, updateTime=2026-06-18`. `beginBurnbarAttachment` added to `functions/src` on 2026-08-20 (`6b8f7c13b3`) and referenced by `OpenBurnBarMobile/Services/BurnbarAttachmentUploadClient.swift` and `AgentLens/Services/Media/MacAttachmentLandingService.swift`; Mac release published 2026-08-28. `deploy-firestore.yml` succeeded 2026-09-01.
Why it matters: every `functions/` change in 2.5 months (194 commits, 43 new callables) is invisible to users; shipped clients get NOT_FOUND; live rules and live code have diverged.
Business impact: attachments, CLI missions, phone-control enrollment, credential transfer are dead server-side for paying users; incident is silent.
Engineering impact: the team debugs the gate instead of the product; each attempt spawns a repair tag.
Risk 3–12 mo: the backlog becomes un-deployable as one atomic change; a forced big-bang deploy with no incremental rollback target.
Remediation: (1) declare an incident and use the documented break-glass (`docs/runbooks/functions-break-glass.md`) to deploy a known commit from source; (2) change the promotion gate so a missing attestation fails *into a manual-approval environment*, not closed forever; (3) add a prod-staleness tripwire (>14 d) to `burnbar-ci-gate` for PRs that add client callable references and to `release.yml`; (4) stop bot re-tagging on a red lane; (5) re-page when `failures:N` crosses thresholds or `escalated:72h` is present.
Effort: M unblock / L redesign · Owner: release/infra (CODEOWNERS) · Prereqs: GCP + `domain-core-promotion` environment access · **Fix now.**

**#2 — Shared SQLite file with two writer processes**
Category: state ownership · Severity **Critical** · Scope Systemic · Lane AR
Evidence: ADR-005 says the app owns SQLite. Daemon opens the same file (`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarSwitcherShell.swift:89`; `AIInbox/BurnBarAIInboxStore.swift:41` comment "openburnbar.sqlite the app and the rest of the daemon share"). Both issue writes on 12 identical tables: `chat_messages`, `chat_threads`, `search_chunks`, `search_chunks_fts`, `search_documents`, `agent_memories`, `memory_audit`, `chunk_embeddings`, `project_memory_snapshots`, `switcher_profiles`, `switcher_active_profile`, `vector_index_snapshots`. App writes 115 tables, daemon 48. Two 65-migration migrators (`AgentLens/Services/DataStore/OpenBurnBarDatabase+Migrations*.swift` and `OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase.swift`) held together by `scripts/check-migrator-parity.mjs` with 88 annotated divergences (baseline grew 142→150 in `b13b0fb6c0`). The `datastore-isolation` ratchet counts sync `dbQueue` calls in one process and cannot see a second GRDB pool.
Why it matters: chat, memory, and code index — the product's core value — have no single writer; every migration must be coordinated across two binaries on different release cadences.
Business impact: silent lost writes / corruption in the highest-value data. Engineering impact: every schema change is a two-binary change.
Risk 3–12 mo: one side runs a migration the other doesn't expect; the divergence baseline keeps growing.
Remediation: interface-first — write a table→owner row for all 68 tables (extend ADR-005), then strangler: daemon owns `chat_*`, `search_*`, PCM, memory; app reads via RPC or a read-only replica; retire the Core twin or make it the only migrator.
Effort: L · Owner: platform/daemon · Prereqs: #8 (RPC versioning) · **Fix now (contract), schedule soon (move).**

**#3 — Mission authority replicated ×5; clients write Firestore mission docs**
Category: three-way state ownership · Severity **Critical** · Scope Systemic · Lane AR/SE
Evidence: ADR-016 declares server-owned create/claim/cancel. Functions has zero `.set/.update/.create` on `cli_agent_mission_requests`. Writers are clients: `android/.../CLIAgentMissionDispatcher.kt:600-601`, `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher+MissionControl.swift:119-120`, `AgentLens/Services/CloudSync/MacWandMissionDispatcher.swift:94-95`; `firestore.rules:2412` grants the write. Evaluation logic: daemon `MissionControl/` 7,415 LOC, Mac GUI cluster 4,323 (`budgets/mission-splitbrain-baseline.json` admits evasion by rename, 3,506→4,320), mobile 1,392, Android 1,375; `MissionRemoteAuthorizationShadow.swift` defaults to `.shadow`.
Why it matters: a security-sensitive approval/trust path with four authorities; inconsistency is either an exploit or a runaway agent.
Remediation: strangler via the server — callables for create/claim/cancel, flip rules to deny client writes, shrink each dispatcher to "call function". TypeSpec the mission docs first.
Effort: L · Owner: cloud + daemon · Prereqs: #1 (must be able to deploy functions), TypeSpec models · **Fix now (plan + rules flip behind flag), schedule soon (migration).**

**#4 — Scheduled proof lanes perpetually red and unconsumed**
Category: CI/CD · Severity **High** · Scope Systemic · Lane OP/TE
Evidence (`gh run list`): `openburnbar-pr-harness.yml` ("OpenBurnBar Full Harness", the only lane running diff-coverage, debt budgets, retrieval evals, App XCTest) — **0 successes in its last 500 runs** (258 fail, 242 cancelled) despite 96 edits since creation on 2026-04-04; `nightly-dast-sandbox` last green 06-24 (emulator start fails); `linux-nightly` last green 07-08; `nightly-e2e` 0/48; `codeql.yml` last green 08-09 (Swift build); `ops-confidence` last green 07-13; `ops-plane-verify` last green 08-03 (47 cancelled). Only 9 of 84 workflows use `./.github/actions/ops-failure-issue`; the harness, CodeQL, app gate, and ops-plane-verify file nothing. 21 scheduled workflows ≈ 13 runs/day burning macOS minutes for no signal. `codex-nightly-ci-repair.yml` is green while everything it should repair is red.
Why it matters: the "fast PRs, nightly proof" trade (CLAUDE.md, 08-15) has become "fast PRs, no proof".
Remediation: triage every red lane into fix / quarantine-with-owner-and-date / delete; give every scheduled lane `ops-failure-issue` with escalation; add a weekly "scheduled-lane health" job that fails `burnbar-ci-gate` on `main` when any lane has been red >7 d; delete the Full Harness or rebuild it as three lanes that can individually pass.
Effort: M · Owner: CI owner · **Fix now.**

**#5 — PR door runs no native product tests; app gate is post-merge and red**
Category: CI gating · Severity **High** · Scope Systemic · Lane TE/OP
Evidence: `governance/burnbar-ci-gate.fast.json` (58 contexts) lacks Daemon/Android/Domain-Core/Windows-Full; `app-pr-gate.yml:23-31` triggers on push-to-main + `17 9 * * *` only; `docs/CI_COST_CONTROLS.md:11-17` documents the move. Only `pr-native-fast.yml` (SwiftPM `swift test` on Core + Daemon, path-filtered) compiles Swift on PRs. "App PR Gate (Swift)" is not in the 64-context umbrella; on `main` it is 23/30 red, latest failure on the self-hosted `burnbar-swift` pool: `Missing native build tools (cmake, protobuf) and Homebrew is unavailable` — environmental, not a code regression. Two "green the main gates the squash left red" commits already exist (`9b2867885f`, `4ad143cc2d`).
Why it matters: 1,047 app + 534 mobile source files merge on lint/type/TS gates alone; regressions surface the next morning, if the nightly is even read.
Remediation: keep the nightly rule, but add a sub-10-minute PR-time `app-smoke` job: compile `OpenBurnBarTests` with `-only-testing` on a curated ~40-suite list (ComputerUse/, MercuryRouter, migrations, BudgetGate, CloudSync) using the DerivedData cache; fix or evict the broken self-hosted runner from the pool; put "App PR Gate (Swift)" in the umbrella when it is green three days running.
Effort: M · Owner: CI/platform · Prereqs: DerivedData cache hit-rate proof · **Fix now.**

**#6 — In-flight pairing freshness widened 3→30 min with in-memory replay guard**
Category: remote-control trust · Severity **High** · Scope Cross · Lane SE
Evidence (uncommitted diff on this branch): `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift:69-86` adds `liveSessionMaximumAgeSeconds = 30*60`; `IrohPairingDirectory.swift:93-118` selects it when `remoteSessionLive` (caller/phone-supplied) is true; `IrohPairingReplayGuard.swift:15-42` is an actor with a `[String: Date]` that resets on relaunch; 0 direct tests for the guard.
Why it matters: a captured signed pairing record is dial-able for 30 min; the only replay defense evaporates on app restart; the phone decides which window applies.
Remediation: persist consumed keys (or bind live-session records to a Mac-minted session nonce), have the Mac assert liveness, add a test that a 4-minute-old record is rejected after relaunch. Make the guard injectable and test consume/prune/expiry with a fake clock.
Effort: S · Owner: platform/security · **Fix before merging `feat/living-glass-sweep`.**

**#7 — Computer Use safety boundary under-tested**
Category: coverage shape · Severity **High** · Scope Cross · Lane TE/SE
Evidence: `ComputerUseSessionCoordinator*.swift` 2,975 LOC, 88 stored-property lines in the base actor; coordinator-specific suite is `ComputerUseSetTrustModeDowngradeOnlyTests.swift` with 2 tests; `PhoneControlReceiverTests.swift` uses 11 `Task.sleep`; `AgentWatchHUDSession.swift` 0 tests; Coordinator, +Approvals, +Input are all modified in the working tree with no matching test edits beyond the downgrade suite. (Positive: trust-mode elevation is Mac-UI-only when no session is active; `AXIsProcessTrusted` re-checked every 5 s → panic halt; Remote Config kill switches exist.)
Remediation: test-first hardening — clock-injected, table-driven tests for every trust-mode × action-class × approval-outcome cell before any further coordinator refactor; this also unblocks splitting the coordinator by responsibility rather than by file.
Effort: M · Owner: Computer Use · **Fix now (before next ring advance).**

**#8 — Daemon RPC contract unversioned and Swift-only**
Category: contract/versioning · Severity **High** · Scope Systemic · Lane AR
Evidence: `OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift:3-10` — `current = 1`, `supported = [1]`, `negotiate()` has never negotiated; `BurnBarRPCMethod` is a 185-case string enum; five unix sockets; `extensions/openburnbar/src/daemon/client.ts` hand-types method strings; `tools/schema-sync` emits nothing for RPC; no compat doc. App (nightly), daemon, extension (50 workflows), Linux desktop ship on different cadences against it.
Remediation: interface-first — TypeSpec the envelope + method table, emit Swift/TS/Kotlin, bump to v2 with a real negotiation test and a documented N-1 policy.
Effort: M · Owner: daemon · **Fix now (cheap; prerequisite for #2).**

**#9 — Unbounded primary tables; no retention; VACUUM deferred**
Category: data lifecycle · Severity **High** · Scope Systemic · Lane PF/OP
Evidence: no retention on `token_usage`/`conversations` (only tombstone GC and backup pruning); VACUUM after v48 FTS repair still deferred (`+MigrationsV41toV51.swift:289-293`, `TODOS.md`); `RefreshOrchestrator.swift:95-100` "No user-facing retention window is configured ... config TODO". Dev machine: `~/Library/Application Support/OpenBurnBar` 18 GB; `openburnbar.sqlite` 8.5 GB; `installation-backups` 4.6 GB; `backups` 4.0 GB (5 full copies of a multi-GB DB); `controller-events.jsonl` 166 MB. `token_usage` has a 36-byte TEXT UUID PK copied into 10 indexes (~1.1–1.3 KB/event → 0.9–1.8 GB/yr for a heavy user). `budgets/usage-refresh-tick-baseline.json` still says `fetchAllUsageCallSites: 3` while live is 1 — stale ceiling permits 2 regressions.
Remediation: retention window setting (default ~180 d), guarded `incremental_vacuum` on idle with a free-disk check (the daemon already does this for code memory), size-capped rotation for `*.jsonl`, cap migration backups by bytes not count, ratchet the tick baseline to 1 now. Do **not** rewrite `token_usage` to an integer PK (full-table copy on multi-GB files).
Effort: M (S for the ratchet) · Owner: Mac app/data · Prereqs: retention UX decision · **Schedule soon.**

**#10 — Conversation-bodies pass re-reads whole JSONL files**
Category: ingestion · Severity **High** · Scope Cross · Lane PF
Evidence: `ClaudeCodeParser.swift:352-363` — incremental resume gated on `!includeConversation`; with bodies requested `resumeOffset = 0` and every line is JSON-decoded (usage-only pass skips lines lacking `"usage"`). Invoked on every signature change (`UsageAggregatorParsers+More.swift:124-137`). Codex scanner has the same shape (`CodexSessionLogScanner.swift:255-284`). Checkpoint machinery already exists for the usage pass (`ParserDiskCache.swift`, `parser_checkpoint_files`).
Why it matters: live session files reach hundreds of MB; each append triggers a full re-read at the moment the user is looking at the menu bar; idle-CPU regressions have "recurred twice" per the budget file.
Remediation: persist the conversation accumulator alongside the token accumulator and resume from `byteOffset` for bodies; or move bodies to a lower-cadence pass that only scans files whose size grew.
Effort: M · Owner: LogParsers · **Schedule soon (largest CPU win for active users).**

**#11 — Brute-force embedding recall while HNSW sits unused**
Category: search/scalability · Severity **High** · Scope Systemic · Lane PF
Evidence: `ControlPlaneStore+MemoryEmbeddings.swift:130-160` selects every BLOB for a version/dimension with no LIMIT, decodes, cosines, sorts, `.prefix(limit)`; daemon `BurnBarProjectCodeMemoryStore.swift:1536-1550` same shape per project. `BurnBarHNSWVectorIndex.swift` is used only by `OpenBurnBarIndexedSearchService.swift:97`; `vector_index_snapshots` table already exists.
Risk: ~150 MB decoded per recall at 50k × 768-dim; falls over between 20k–100k vectors per model version — grows with memories × chunks.
Remediation: back recall and code-memory search with the persistent HNSW snapshot; keep brute force as the test oracle.
Effort: M · Owner: search/memory · **Schedule soon.**

**#12 — Rust domain core: fourth copy, zero deletions, dormant**
Category: strategic duplication · Severity **High** · Scope Cross · Lane AR
Evidence: `docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md:3` "no domain has completed production promotion and legacy deletion"; default `.legacy` everywhere (`DomainCoreBuildProfile.swift:68,101,126`, Android `DomainCoreBuildProfile.kt:101-104`); legacy intact (`CloudVaultCrypto.swift` 1,354, `.kt` 1,242, `HermesRatchetCrypto` 578/410, 8 C# quota files); adapter glue ~3–4k LOC (`CloudVaultDomainCoreAdapter.swift` 881, `...RewrapDomainCoreAdapter.swift` 945, runtime 471); crate 9.3k LOC, last commit 07-15, 6 commits since June vs ~2,500 repo-wide. The "Shared Rust domain core promotion proof" workflow is 3/3 red on `main` because the control-plane hash manifest (`config/domain-core-control-plane-manifest.json`, 43 KB, 166 commits in 90 d) must match trusted main.
Why it matters: ADR-014 is sound but its payoff is entirely at the deletion gate nobody has reached; until then it is net-negative and its manifest is the second-most-churned file in the repo.
Remediation: decide. Either finish one domain end to end (pricing or statusline quota: promote to `rust`, delete legacy, prove the loop closes) within 30 days, or freeze the crate and delete the adapters and the promotion workflow. Do not leave it half-on.
Effort: M per domain · Owner: core · Prereqs: #14 · **Decide now.**

**#13 — Kernel hub and umbrella imports**
Category: module graph · Severity **High** · Scope Systemic · Lane AR
Evidence: `OpenBurnBarKernel` 53,692 LOC / 191 files; `SharedModels/` 31,662 LOC in 111 flat files (Hermes crypto, provider registry, CloudVault crypto, WarRoom, SmartHub, UI enums); 13 targets depend on it; umbrella `OpenBurnBarCore` is 11 `@_exported import`s consumed by 528 AgentLens + 379 Mobile files, frozen by the 64 KB `core-umbrella-imports-baseline.json`; 11 `nonisolated(unsafe) static var` upward hooks let lower layers call the app through mutable globals (`Kernel/Platform/CLILaunchAdapter.swift:53-61`, `CloudVaultCrypto.swift:141,289`, `ControllerKeyPinStore.swift:96`).
Remediation: incremental — per-consumer-root umbrella-removal ratchet that must reach zero; then split `SharedModels` by domain (Hermes, CloudVault, Provider, MissionConsole); replace the upward hooks with injected protocols.
Effort: L · Owner: core · **Schedule soon.**

**#14 — Package graph depends on local filesystem state**
Category: build/reproducibility · Severity **High** · Scope Cross · Lane AR/OP
Evidence: `OpenBurnBarCore/Package.swift:64-100,353,403,433,538-552` probe `../Vendor/*.xcframework` at manifest evaluation and add/prune `binaryTarget`s; `git ls-files Vendor | grep xcframework` = 0. Single-file 2–5k-LOC targets are checked-in UniFFI bindings whose binaries are not.
Remediation: interface-first — assert both graph shapes build in CI; publish xcframeworks as checksummed artifact bundles; make the manifest's shape a function of a declared flag, not `ls`.
Effort: M · Owner: build · **Schedule soon.**

**#15 — Cross-target reimplementation**
Category: duplication · Severity **High** · Scope Systemic · Lane CQ
Evidence: `packages/gl-engine/src/engine` vs `apps/console/lib/gl/engine` — 58/58 files byte-identical (~13k LOC), same commit 2026-08-20, console has no import of the package. Parser twins: `AiderParser`, `CursorParser`, `CodexParser`, `CopilotParser`, `OpenClawParser`, `OpenCodeParser`, `PiAgentParser`, `JunieParser` defined in both `AgentLens/Services/UsageAggregatorParsers*.swift` and `OpenBurnBarCore/Sources/OpenBurnBarLogParsers/LogParser/AdditionalLocalUsageParsers.swift` (1,762 LOC, 07-24) — already diverged (AiderParser 239 vs 109 lines sharing 18). `OpenBurnBarHTTPGatewayServerLinux.swift` 1,814 LOC beside the June-decomposed macOS gateway, 0/51 shared function names; daemon has 141 `#if os(...)` branches. 120 type names defined in both AgentLens and Mobile (entire Settings-search family). Two byte-identical 5,295-line UniFFI Python bindings in `tools/*/vendor/`.
Remediation: (a) delete the console copy and import `@openburnbar/gl-engine` — S; (b) delete AgentLens parser copies or subclass Core — M; (c) extract a platform-neutral gateway route pipeline with transport adapters — L; (d) a "twin basenames" gate already exists (`check-twin-basenames.sh`) — extend it to twin *type names* across roots.
Effort: S / M / L · Owner: web / macOS / daemon · **Fix now (a, d), schedule soon (b, c).**

**#16 — Preserved stash ref with real secrets**
Category: secrets hygiene · Severity Med · Scope Local · Lane SE
Evidence: `refs/preserved-stash/99` → `b16b753c3b` (2026-06-06) contains `AgentLens/Resources/GoogleService-Info.plist`, `OpenBurnBarMobile/Resources/GoogleService-Info.plist`, `apps/console/.env.production`, `functions/.env.burnbar`. Unreachable from branches; HEAD tracks only `.example`/`.template`. A `git push --mirror` or any `refs/*` push publishes it; `git log --all` surfaces it to every agent.
Remediation: `git update-ref -d refs/preserved-stash/99`, expire reflog, gc, rotate the console env values on principle; add gitleaks to pre-commit (CI has it; pre-commit has only `detect-private-key`).
Effort: S · Owner: repo admin · **Fix now.**

*(Items 17–36: full evidence and remediation live in the lane reports; the register row carries severity, effort, owner lane, and disposition sufficient to schedule them.)*

---

## 4. What Is Hurting Velocity Most

1. **Red-by-default lanes and repair-tag loops (#1, #4, #5).** Engineers and bots spend cycles on gates instead of product; 37 repair tags in 14 days; a 96-times-edited harness that has never passed.
2. **Control-plane hash manifest churn (#12).** `config/domain-core-control-plane-manifest.json` must be re-hashed on every workflow edit — 166 commits in 90 days, second only to `project.pbxproj` (318).
3. **Two-binary schema changes (#2) and five-codebase mission changes (#3).** Every feature in these domains is implemented 2–5×.
4. **Umbrella imports (#13).** Any Kernel split touches ~900 consumer files, so it never happens; clean builds pay for a 59-target graph whose layering consumers cannot see.
5. **`scripts/` as a second product (#29).** 492 commits in two months, 28% of files are tests of scripts, 4,647-line verifiers.
6. **91 open PRs with median age 14 days (#30)** waiting on a factory loop that has no closer.

## 5. What Is Riskiest for Production

1. **#1** — clients calling callables that don't exist; rules ahead of code. Already happening.
2. **#6** — pairing replay window ×10 with a guard that resets on relaunch; in the branch about to merge.
3. **#3** — mission approval/trust decided in four places with client-writable Firestore.
4. **#2** — two writers, two migrators, one file.
5. **#9** — a menu-bar utility consuming 10–20 GB with no way to shrink; first-frame time grows with DB age.
6. **#23** — hourly O(all-users) Firestore read; no usage TTL; no auto-rollback.
7. **#31** — Stripe/App Store webhooks outside the Sentry wrapper.

## 6. What Could Force a Rewrite Later

1. **Shared SQLite with independent migrators (#2)** — every month adds tables and "intentional divergences"; the exit cost grows linearly.
2. **Mission split-brain (#3)** — moving writes server-side gets harder with every client feature.
3. **Kernel hub + umbrella + filesystem-dependent manifest (#13, #14)** — the module graph cannot be reshaped without a repo-wide touch, so it won't be, so it calcifies.
4. **Parity-by-port (#15, #12)** — six clients diverging from copies; the shared-core strangler stalled at zero deletions.
5. **Unversioned RPC (#8)** — the day the daemon needs a breaking change, every client breaks at once.

---

## 7. Debt Reduction Strategy

**Philosophy: fewer controls with owners beat more controls without.** The June sprint proved the team can build fail-closed gates fast; this quarter must prove it can *consume* them. Three rules:

1. **Every gate has a consumer or it is deleted.** A lane that is red for 7 days with no owner action is quarantined with a name and a date; red for 30 days, it is deleted. The number of workflows should go down this quarter.
2. **Ratchets move from shape to ownership.** Add three boundary contracts — table→process, Firestore collection→writer, RPC→schema — enforced where the bug lives. Stop adding per-directory shape ratchets.
3. **No new copies; finish or freeze the shared core.** The `twin basenames` gate becomes a twin *type* gate across all roots; the Rust domain core either deletes one legacy implementation in 30 days or is frozen.

Non-goals (explicitly): no "rewrite the daemon", no GRDB 7 migration this quarter, no `token_usage` PK rewrite, no SettingsManager split for render perf, no sweeping `id: \.self`/formatter cleanups, no change to the nightly-Mac-build rule beyond a small PR-time slice.

---

## 8. Phased Roadmap

### Phase 0 — Unfreeze and stop the bleeding (Week 1)
**Goal:** production deploys again; the in-flight branch does not weaken the trust root; secrets are gone; paging works.
**Workstreams:** #1 break-glass deploy from a known commit, then gate redesign to fail-into-manual-approval; #6 replay-guard persistence + Mac-asserted liveness + tests (blocks merge of `feat/living-glass-sweep`); #16 delete stash ref + rotate; #21 move ops-plane-verify off `pull_request`, add `ops-failure-issue` to harness/CodeQL/app-gate/ops-plane; re-page rule in `ops-failure-issue`; #30 `delete_branch_on_merge` + stale bot; #31 `wrapRequestHandler` for the 10 `onRequest` handlers; #15(a) delete the gl-engine copy; #19 metrics doc prints tagged + untagged; #9 ratchet tick baseline to 1; #23 bound the attachment reaper.
**Why now:** all S/M, no refactors, every item is asymmetric-downside or unblocks Phase 1.
**Risks:** break-glass deploy of a 194-commit backlog could surface rules/code skew — deploy to staging first (`burnbar-staging` exists), diff `firestore.rules` against the June-18 revision, deploy functions with `--only` on the parity-critical target list, then the rest.
**Success:** a green `deploy-functions` job on `main`; #2195 closed; freshness gate <7 d; zero secret refs; harness/CodeQL/app-gate failures file issues.

### Phase 1 — Make the gates honest, then fewer (Weeks 2–5)
**Goal:** every lane is green, quarantined-with-owner, or deleted; a PR-time native slice exists; the ratchets report health.
**Workstreams:** #4 triage all 21 scheduled lanes (fix / quarantine / delete — target ≤12); rebuild or delete Full Harness; fix the self-hosted runner pool or evict it; #5 `app-smoke` PR job (~40 suites, <10 min); "App PR Gate (Swift)" into the umbrella once green 3 days; #12 decision (finish pricing domain or freeze + delete promotion workflow + manifest); #20 lower file-size target to 1500 (37 files baselined), add function-length ratchet at 300 with baseline, lint "no top-level types in `+` files"; #19 extend `[String: Any]` counter to Core/Daemon, shrink-only ratchet on `try?-ok` tag count; #22 count `XCTSkip` bodies in the quarantine-freshness gate; #18 merge the 21 Dependabot PRs through the factory, add missing cargo/npm dirs; #32 flip test targets to Swift 6; #34 ADR renumber + ownership rows for every daemon domain; require a `Cross-agent receipt` for every baseline raise.
**Why now:** structural work on unverified gates recreates this report; honest gates are the precondition.
**Risks:** deleting lanes removes coverage someone silently relied on — record what each deleted lane checked in the ADR.
**Success:** 0 lanes red >7 d; workflow count down ≥15%; app-smoke on every PR; metrics doc numbers match `rg`.

### Phase 2 — Ownership contracts and safety-boundary tests (Weeks 4–10)
**Goal:** the three seams have written, enforced owners; the Computer Use boundary is table-tested; data stops growing without bound.
**Workstreams:** #8 TypeSpec the RPC envelope + method table, emit Swift/TS/Kotlin, v2 with negotiation test; #2 table→owner rows for all 68 tables, drift test that fails when a process writes a table it doesn't own (start as shadow/report, then enforce); #3 TypeSpec mission docs, server callables for create/claim/cancel behind a flag, rules flip to deny client writes on ring-0; #7 clock-injected table-driven approval/trust tests; iroh replay guard direct tests; #9 retention window + guarded incremental vacuum + jsonl rotation + byte-capped backups; #10 bodies pass resumes from byte offset; #23 usage TTL decision mirroring local retention; #28 schema doc regenerated from a migrated DB + walk-all migration test from a seeded fixture; #26 rules allowlist generated from a schema manifest + server-only-collection deny tests + expression-count check.
**Why now:** these are the rewrite-preventers; they are safe to start once the gates that will verify them are honest.
**Risks:** RPC v2 and rules flip are client-visible — ship behind flags, ring 0 first, keep N-1 compat for one release.
**Success:** every table/collection/RPC method has an owner in a machine-checked file; CU coordinator has ≥1 test per state cell; a heavy user's DB stops growing past the retention window.

### Phase 3 — Architecture strengthening (Weeks 8–16)
**Goal:** the module graph consumers see matches the manifest; duplication has a single source; the daemon owns its data.
**Workstreams:** #13 umbrella-removal ratchet per consumer root → 0, then split `SharedModels` by domain, replace the 11 upward hooks; #14 checksummed xcframework bundles, manifest shape declared not probed; #15(b,c) parser twins collapsed to Core, gateway route pipeline extracted; #2 daemon takes ownership of `chat_*`/`search_*`/PCM/memory, app reads via RPC; #11 HNSW-backed recall; #25 split `SettingsManagerProtocol` into facets, Views-side `.shared` ratchet; #27 encoder bookkeeping to a dedicated actor; quota loops under the cadence coordinator; #24 `config/feature-flags.json` with owner/expiry + drift test; #33 tier the platform portfolio (supported / best-effort / archived) and archive `pensieve-experience`, decide Keyboard/Widget test floor.
**Why now:** each item depends on an honest gate (Phase 1) and an ownership contract (Phase 2).
**Risks:** umbrella removal is a large mechanical diff — do it per root, one PR each, with the ratchet preventing regression.
**Success:** umbrella imports 0; Kernel <35k LOC; parser types defined once; single SQLite writer per table; recall p95 <50 ms at 50k vectors.

### Phase 4 — Polish and long tail (ongoing / opportunistic)
#17 GRDB provenance file + refresh script, libsignal monthly rebase PR; #29 delete 38 unreferenced + 73 unreferenced test scripts, knip on `scripts/`, split the 4,647-line verifier's embedded data; #35 permissions-disabled automation, PBKDF2 → 600k or Argon2id, AGPL text in `LICENSES/`, Sparkle keys removed; #36 root cruft; `+More/+Support` renames on touch; formatter caching on touch; `.limit()` on the four unbounded mobile reads on touch.

---

## 9. Quick Wins (days, high ROI — do these first)

| Win | Items | Effort |
|---|---|---|
| Break-glass functions deploy to staging then prod; close #2195 | #1 | M (1–2 days) |
| Persist replay guard + Mac-asserted liveness + 3 tests | #6 | S |
| Delete stash ref 99, rotate console env | #16 | S |
| Move ops-plane-verify off PR triggers; `ops-failure-issue` on 4 lanes; re-page thresholds | #4, #21 | S |
| `delete_branch_on_merge`, stale bot for bot PRs >21 d | #30 | S |
| Delete `apps/console/lib/gl/engine`, import the package | #15a | S |
| Metrics doc prints tagged + untagged; `[String: Any]` counter → Core/Daemon; tick baseline → 1; force-unwrap baseline → 203 | #19, #9 | S |
| Bound `reapBurnbarAttachments` with `where` + `limit` | #23 | S |
| `wrapRequestHandler` + verifier extended to `onRequest` | #31 | S |
| Test targets → Swift 6 strict | #32 | S |
| File-size target 2000→1500; function-length ratchet; "no top-level types in `+` files" lint | #20 | S |
| Register mac/iOS quota loops with cadence / `scenePhase` | #27 | S |
| `git rm tmp-utm-desktop.png`; root reports → `docs/reports/`; 38 unreferenced scripts | #36, #29 | S |

## 10. Longer-Horizon Refactors (deep surgery — sequence behind honest gates)

| Refactor | Items | Strategy | Effort |
|---|---|---|---|
| Single SQLite writer per table; daemon owns chat/search/memory | #2 | interface-first (ownership rows) → strangler | L |
| Server-owned missions; deny client writes | #3 | strangler via callables + flag + ring rollout | L |
| RPC v2 from TypeSpec with negotiation | #8 | interface-first | M |
| Kernel de-hubbing; umbrella → 0; SharedModels by domain | #13 | incremental ratchet per root | L |
| Rust domain core: finish one domain or freeze | #12 | test-first (KATs exist) → promote → delete | M/domain |
| Parser + gateway twins collapsed | #15 | test-first (fixtures per CLI version) → delete copies | M–L |
| Retention + vacuum + HNSW recall + bodies checkpoint | #9, #10, #11 | incremental, each behind a setting | M each |
| Rules allowlist generation + expression budget | #26 | interface-first (schema manifest) | M |

**Full redesign only if absolutely necessary:** none identified. The daemon, the Functions layer, and the clients are structurally sound; the debt is in seams and governance, not in the cores.

---

## 11. Refactor Strategy by Area

| Area | Strategy | Rationale |
|---|---|---|
| CI/deploy control plane | **Delete-first, then incremental** | Controls without consumers are cost; fewer lanes with owners beats more lanes. |
| SQLite ownership, missions, RPC | **Interface-first → strangler** | Write the contract, enforce it in shadow, migrate writers one at a time, keep N-1. |
| Computer Use coordinator, Mercury router, iroh pairing | **Test-first hardening** | Safety boundaries; no structural change until the state machine is table-tested with fake clocks. |
| Kernel/umbrella, SettingsManager | **Incremental with ratchet** | Large mechanical diffs; one root per PR, ratchet prevents regression. |
| Parser/gateway/settings twins | **Test-first → collapse** | Fixtures per CLI version first, then delete the copy; parity gate prevents re-forking. |
| Rust domain core | **Finish-one-or-freeze** | A strangler that never strangles is pure cost. |
| Data lifecycle | **Incremental behind settings** | Retention/vacuum are user-visible; default conservative, ring-roll. |
| Dependencies/vendoring | **Scheduled refresh** | Monthly rebase PRs; provenance files; Dependabot coverage for every lockfile dir. |

## 12. Guardrails

- **Tests first** on any safety-boundary file (ComputerUse/, IrohRelay/, PhoneControl*, MissionControl/): a PR that touches them without a test change fails a path-scoped check.
- **Feature flags + rings** for every client-visible contract change (RPC v2, rules flip, retention default): `scripts/rollout.mjs` rings, ring 0 = maintainers, and `--advance` gated on Crashlytics + health thresholds rather than manual.
- **Parallel/shadow runs** for ownership enforcement: table→owner and collection→writer checks report for two weeks before they fail.
- **Migration safety** stays as-is (integrity check + encrypted backup + restore-on-failure); add the seeded walk-all test before any migrator consolidation; byte-cap backups.
- **Rollout/rollback:** functions get a post-health-gate auto-rollback (`rollback-revision.sh` on the parity-critical target list); Mac rollback runbook rewritten around `latest-macos.json`; rules deploys diffed against live code's expectations.
- **Documentation:** every deleted lane, every ownership row, every flag lands in an ADR or `config/feature-flags.json`; ADR index fixed; `docs/TECH_DEBT_METRICS.md` shows tagged and untagged.
- **Ownership clarity:** a per-lane CI owner map (today two names own all 84 workflows); every scheduled lane names an owner in its header; baseline raises require a `Cross-agent receipt`.
- **No new copies:** twin-type gate across all roots; a `+` file may not declare top-level types; new platform surfaces must name what they share before what they port.

## 13. Metrics and Governance

Track monthly in `docs/TECH_DEBT_METRICS.md` (extend `update-tech-debt-metrics.sh`):

| Metric | Now | 30 d | 90 d |
|---|---|---|---|
| Days since last successful prod functions deploy | ~75 | <7 | <7, alert at 7 |
| Scheduled lanes red >7 d | 6+ | 0 | 0 |
| Workflow count / YAML lines | 84 / 32,118 | ≤72 | ≤60 |
| Repair tags per 14 d | 37 | 0 | 0 |
| PRs with native test execution | ~0% | 100% (app-smoke) | 100% |
| Ratchet baselines raised inside feature PRs (per month) | ~16 | ≤3 with receipt | 0 |
| Tables with two writer processes | 12 | 12 (owners written) | ≤4 |
| Firestore collections client-writable that ADRs say server-owned | ≥1 (missions) | flagged | 0 |
| RPC protocol version / negotiation test | 1 / none | v2 spec | v2 shipped, N-1 test |
| Umbrella `import OpenBurnBarCore` consumers | ~907 | ratchet live | ≤600 |
| CU coordinator direct tests | 2 | ≥20 (table) | full cell coverage |
| `Task.sleep` in tests / `XCTSkip` (broken-fixture class) | 260 / ~20 | shrinking | ≤130 / 0 |
| Twin type names across roots | 120 (+8 parsers) | gate live | ≤60, parsers 0 |
| Heavy-user DB growth | unbounded | retention setting shipped | bounded at window |
| Open PRs median age / Dependabot open | 14 d / 21 | ≤7 d / ≤5 | ≤5 d / ≤5 |
| Fix:feat commit ratio | 3.4:1 | ≤2.5:1 | ≤2:1 |
| Mean time from red lane to owner action | weeks | ≤2 d | ≤1 d |

**Governance:** a 30-minute weekly "red lane review" with one owner per lane; quarterly "vendor refresh + security constants" checklist in the factory loop; debt review reads this register, not the metrics doc alone; any new ratchet must name the ownership boundary it protects or it is not merged.

## 14. 30 / 60 / 90 Day Plan

**30 days:** Phase 0 complete; Phase 1 largely complete — prod deploying, #2195 closed, every lane green/quarantined/deleted, app-smoke on PRs, self-hosted pool fixed or evicted, Rust core decided, metrics honest, Dependabot backlog cleared, replay guard fixed and merged, stash purged, twin-type gate live, gl-engine copy gone.
**60 days:** Phase 2 — RPC v2 spec emitted and negotiating; table→owner and collection→writer contracts in shadow-enforce; mission callables live behind a flag on ring 0; CU coordinator table tests; retention window + vacuum shipped to ring 1; bodies pass resumes from offset; schema doc regenerated with walk-all migration test; rules allowlist generated.
**90 days:** Phase 3 underway — umbrella ratchet driving toward ≤600; parser twins collapsed; daemon owns chat/search/memory with app on RPC; HNSW recall; feature-flag registry; platform tiers declared and `pensieve-experience` archived; GRDB provenance + libsignal monthly rebase in place. Fix:feat ratio ≤2:1; commits/week recovered toward 200+ on product, not gates.

## 15. Final Recommendation

**Do first (this week):** #1 unfreeze production via break-glass to staging then prod, and redesign the promotion gate to fail into manual approval; #6 fix the replay guard before `feat/living-glass-sweep` merges; #16 purge the stash ref; the paging/visibility fixes (#4, #21). These are all S/M and every one is asymmetric-downside.

**Do next (weeks 2–5):** make the gates honest and fewer (#4, #5, #19, #20, #32), clear Dependabot (#18), and decide the Rust core (#12). This is the durable fix for the pattern that produced all three audits.

**Can wait (weeks 4–16):** the ownership contracts and the structural work (#2, #3, #8, #13, #14, #15), sequenced behind honest gates and shipped behind flags.

**Accept intentionally (record, don't fix):** the nightly-Mac-build rule (add a small PR slice, keep the rule); XcodeGen pbxproj churn; checked-in UniFFI bindings; the BudgetLedger mac/iOS fork (sha-pinned); per-platform E2EE crypto implementations with KAT cross-checks; `@Observable` SettingsManager as a render concern; `Insecure.MD5` in the ARD client; single-file `firestore.rules` (until generated); the `token_usage` TEXT PK; English-only v1.

**The one-sentence mandate:** *the June sprint proved this team can build fail-closed gates faster than anyone can read them; the next ninety days must prove it can delete the ones nobody reads, own the ones that matter, and spend the recovered attention on the three seams — SQLite, missions, RPC — that will otherwise force a rewrite.*

---

## Appendix A — Verified prior claims (2026-06-30 → 2026-09-01)

| Claim | Status |
|---|---|
| CloudSyncService 228-line facade | Holds (255 LOC; `CloudSync/` 52 files) |
| `@unchecked Sendable` assert-zero gate, 78 allowlist | Mechanically holds; allowlist 84; 146 live conformances unreported |
| TypeSpec canon + bidirectional drift check | Holds (`fast-feedback.yml:691`) |
| ktlint honest | Holds |
| Quarantine = 0, LegacyReference = 2 | Holds |
| Empty `catch {}` = 0 in app + daemon | Holds (Core 2, Mobile 11 comment-only) |
| Sentry symbolicated on all clients (#3) | Closed |
| libsignal CI cache (#14) | Closed (`ensure-libsignal-toolchain` ×26) |
| Firestore DR gate, alert policies as code | Holds — but the runner (`ops-plane-verify`) has not passed since 08-03 |
| Cloud Functions deploy detects unhealthy but no auto-rollback (#27) | Standing — and now deploy never succeeds (#1) |
| Unbounded tables + VACUUM deferred (#8, #12) | Standing; whole-table reconcile largely closed (1 call site) |
| `Task.sleep` ~175 in tests (#10) | Worse: 260 |
| `[String: Any]` boundary (#11) | Shrinking in gated roots (1,190); 1,150 ungated in Core/Daemon |
| TypeSpec strangler stalled (#13) | Standing |
| File-size ratchet-hugging (#28) | Standing; target never moved |
| Split-brain mission execution (#5) | Worse: gate evaded by rename, cluster 3,506→4,320 |
| Privileged-input kill switch silent failure (#7) | Not re-verified this pass; root-owned watchdog exists |

## Appendix B — Per-lane verdicts

| Lane | Verdict | One line |
|---|---|---|
| Reliability/ops | **Controls without consumers** | Alerting, DR, migration safety, logging are real; the deploy and every expensive proof are red and unread. |
| Architecture | **Import hygiene fixed; ownership worse** | Zero Firebase in Core; two SQLite writers, five mission authorities, RPC v1 forever. |
| Testing | **Wide, deep on crypto, thin on orchestration** | 13k tests; PR door runs none of the native ones; safety boundary has 2 direct tests. |
| Security | **Strong design, weak currency** | Default-deny, SHA-pinned, App Check, sealed content; vendored crypto 2 years stale, in-flight window widening. |
| Performance/data | **Incident guards, not class guards** | Every past page has a tripwire; O(history) and O(all-users) paths that haven't paged yet are unguarded. |
| Code quality | **Gates fitted to the worst offender** | Suppressions/TODOs genuinely low; pressure moved into `+` splits, twins, and a 1,213-file `scripts/` tree. |
