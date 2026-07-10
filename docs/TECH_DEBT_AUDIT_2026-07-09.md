# Tech Debt Audit & Reduction Plan — 2026-07-09

> **Method:** Six-lane coordinated swarm audit (code quality, architecture, testing, ops/reliability,
> security/dependencies, performance/data) against a clean checkout of `origin/main @ 8943aae79a`
> (2026-07-09/10), plus live GitHub state via `gh` (run history, issues, failed-job logs).
> **Rigor:** 49 findings filed; every Critical/High claim (20) was re-checked by an independent
> adversarial verifier that tried to refute it — **19 confirmed, 1 downgraded, 0 refuted.** Every
> number below was measured in this run, not quoted from prior docs.
> **Reconciled against:** `docs/TECH_DEBT_STRATEGY.md`, `docs/TECH_DEBT_METRICS.md`,
> `docs/STRUCTURAL_DEBT_REMEDIATION_PLAN.md`, `docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md`,
> `docs/ERROR_DEBT.md`, `docs/TYPE_DEBT.md`, `AGENTS.md`.
> **Status:** living (this document is the current debt register; supersedes the 2026-06-30 audit findings)

---

## 1. Executive Summary

**The biggest truth: the code got clean, and the proof plane died.**

The June remediation genuinely held — this run re-verified it: zero unsafe casts, zero empty
`catch {}`, zero untagged `try?` (483 reason-tagged), production Swift file-size baseline empty at
target 2000, near-zero lint suppressions behind a self-tested fail-closed meta-gate, singleton refs
92→1, >2000-line production files 4→0. Hand-written-code hygiene here is unusually strong.
**Prior debt docs are now stale in the "already fixed" direction as often as the "still broken" one**
(e.g. the "SCHEMA_SQLITE.sql is stale" memory is refuted — it's CI-gated and hash-pinned now).

What has rotted instead is everything that was supposed to *prove* the system still works:

- The post-merge "full-confidence" harness has **zero green runs in 250+ attempts** (since ≥June 30),
  and main is broken right now (iOS won't compile: `No such module 'AmplitudeCore'`).
- **Production backend deploys (Cloud Functions + Cloud Run) have not succeeded since June 18–19**,
  while client v1.0.28/v1.0.29 shipped — either prod runs 3-week-old backend code against newer
  clients, or deploys are happening manually around the hardened WIF pipeline.
- The Firestore rules deploy gate has been **red for 48 consecutive runs** (a post-deploy
  release-patch script 400s) — the exact lane that would catch a V-10-class rules regression is
  pure noise.
- The **auto-repair system built to prevent all of this is dead**: its daily scheduled trigger has
  been cancelled every day by its own concurrency group (~1,900 no-op runs/day flood it); zero
  repairs produced in 20 days.
- Nine **"P0 - Critical" issues sit open for up to 28 days** with bots commenting daily (one has 47
  comments). P0 has been trained to mean "ignorable."

The repo's core CI bargain — *light PR gates for velocity, heavy post-merge proof* — has silently
collapsed on the proof half. The 60 required PR checks keep merges flowing; nothing re-proves main.

The second-order truth: **the five-platform strategy is outrunning its own contracts.** Business
logic is hand-mirrored (Swift↔Kotlin↔C#, migrator twins, 4 schema authorities) with byte-identity
checks on copies nobody executes, while the sanctioned sharing seams (Kernel extraction, C-ABI)
are stalled at exactly their frozen ratchet baselines.

The debt is **payable without slowing product work** — most Phase 0/1 items are S/M-effort script
and config fixes. What it needs is ownership of "red main" as a stop-the-line event.

---

## 2. Top Debt Themes

**T1 — The dead proof plane (Critical).** Every scheduled/post-merge confidence lane and every
backend deploy lane is chronically red: harness 0/250, nightly E2E 0/100, DAST failing, ops-confidence
red 6 weeks, functions/Cloud Run deploys dead 3 weeks, Firestore gate red 48 runs. Green-at-PR,
red-at-main: confidence is front-loaded and never re-proven.

**T2 — Gates that measure nothing (gate-honesty 3.0).** The failure mode has migrated from
"ratchets measure the wrong thing" (mostly fixed) to "the gate silently asserts nothing": jscpd has
analyzed **zero** Swift/Kotlin/TS files since its introduction (one malformed config key); Swift/app
diff-coverage steps are conditioned on `pull_request` inside a workflow with no `pull_request`
trigger (can never run); Android diff-coverage runs post-merge with a vacuous main-vs-HEAD diff
(always 100%); the harness Windows job is four `echo "SKELETON"` steps feeding the "Platform
Confidence Gate" while 323 real C# test files exist; retry env vars are consumed by nothing.
Gates need self-tests that prove they measured something (`check-no-suppressions.test.sh` and
`diff-coverage-ts` self-test are the in-repo gold standard — copy them).

**T3 — Hand-synced twins without executable contracts.** The GRDB migrator is forked verbatim
(AgentLens ↔ OpenBurnBarData) with drift already present and no equality gate; the PCM/search schema
has four independent authorities guarded only at table-name granularity; the cross-platform budget
"contract" gate pins byte-identity of fixture copies that Android/Windows never execute; the Windows
port re-implements 152k LOC of C# while the C-ABI sharing seam exports exactly one function.

**T4 — Stalled structural paydown.** The Phase-0 ratchets from the split-brain program are real and
honest, but both architecture-critical baselines sit frozen at exactly their initial values:
core-ui-purity 115/115 files, mission-splitbrain 3,694/3,694 lines. The daemon still links the full
UI-carrying Core (181 import sites); the GUI has zero `authorizeRemote` callers. Enforcement landed;
paydown stopped.

**T5 — The FTS/data-growth incident engine.** The 128%-CPU pattern (unindexed FTS deletes) was fixed
only where the incident fired (daemon); three app-side copies remain live, plus ungated FTS triggers
that re-tokenize entire transcripts on watermark-only updates. Transcripts are stored three times
with no retention/GC, so every scan cost has a growing denominator. The rollback script froze at v47
while the migrator reached v54.

**T6 — Platform coverage asymmetry.** Android (948 Kotlin files): no PR-time compile/test gate.
iOS: PR gate compile-only *and* post-merge execution broken — mobile tests currently execute
**nowhere**. Linux: ships binaries whose Swift tests have never run on Linux. Windows/.NET and
apps/console: outside all dependency automation (no dependabot, no audit gate). TS-functions is the
only surface with honest pre-merge coverage gating.

**T7 — Factory exhaust.** 10.13 GiB local git pack (fleet snapshot refs captured SPM caches),
307 MB of `.glb` blobs in plain git, 3,099 remote branches, 126 top-level docs with no lifecycle
markers, 31 MB of binary evidence tracked under docs/. The evidence-driven agent culture generates
artifact debt as a byproduct and nothing collects it.

**T8 — Security residue (asymmetric-downside, mostly small).** June's security remediation held
(verified: base-ref gitleaks, fail-closed npm audit, SHA-pinned actions, App Check enforced). What
remains: V-47 preserve/* tags with secrets still present locally and rotation unverified; vendored
libsignal 95 commits behind upstream on a personal-account fork with no bump automation; one
path-unscoped gitleaks allowlist; a 4,869-line firestore.rules monolith (well-tested, but at the
edge of reviewability).

---

## 3. Ranked Debt Register

Severity shown is post-verification. ✓ = independently confirmed by an adversarial verifier.

| # | Sev | Item | Scope | Effort | Fix window |
|---|-----|------|-------|--------|-----------|
| 1 | Critical ✓ | Production backend deploys (Functions + Cloud Run) dead since June 18–19; clients shipped anyway | Systemic | M | **Now** |
| 2 | Critical ✓ | Post-merge full-confidence harness 0 green in 250+ runs; main currently broken (AmplitudeCore) | Systemic | L | **Now** |
| 3 | High ✓ | Firestore deploy gate red 48 consecutive runs (release-patch script 400s after successful deploy) | Cross-cutting | S | **Now** |
| 4 | High ✓ | Auto-repair system dead: schedule trigger self-cancelled daily by its own concurrency group; ~1,900 no-op runs/day | Systemic | S | **Now** |
| 5 | High ✓ | Swift/app diff-coverage steps are dead code (impossible `pull_request` condition); Android leg vacuously 100% | Systemic | M | Soon |
| 6 | High ✓ | iOS XCTest executes nowhere (PR compile-only by design + post-merge broken + release bypass knob) | Cross-cutting | M | **Now** |
| 7 | High ✓ | Android has no PR-time compile/detekt/unit-test gate (budget package only) — breaks land on main by design | Cross-cutting | S | **Now** |
| 8 | High ✓ | Split-brain mission authority fully live: daemon `authorizeRemote` RPC merged (#1425) but GUI has zero callers; 3,694-line listener unchanged | Systemic | L | Soon (M3→M4) |
| 9 | High ✓ | Daemon links full UI-carrying Core (181 imports, 115 SwiftUI/AppKit files); kernel extraction frozen at baseline since K2 | Systemic | XL | Soon (K4 slices) |
| 10 | High ✓ | Budget-enforcement "contract" gate green without executing on 2 of 3 platforms (Android vectors have zero Kotlin consumers; Windows unpinned) | Systemic | M | Soon |
| 11 | High ✓ | GRDB migrator forked verbatim into OpenBurnBarData: drift already present (v43/v46), zero production consumers, no equality gate | Systemic | M | Soon |
| 12 | High ✓ | App-side FTS5 deletes still on UNINDEXED columns — the 128%-CPU pattern fixed only in the daemon; 3 app copies live | Cross-cutting | M | Soon (v55) |
| 13 | High ✓ | jscpd duplication gate is a silent no-op (malformed config → 0 Swift/Kotlin/TS files analyzed since 2026-05-30) | Cross-cutting | S | **Now** |
| 14 | High ✓ | Linux ships binaries whose Swift test suite has never executed on Linux (compile + structural validators only) | Cross-cutting | M | Soon |
| 15 | High ✓ | Release pipeline untestable off-tag: v1.0.29 took ~15 tag re-pushes of gate-loosening band-aids | Cross-cutting | L | Soon |
| 16 | High ✓ | Standing-P0 process institutionalizes alert fatigue: 9 open P0s, oldest 28 days, no escalation path | Systemic | M | Soon |
| 17 | High ✓ | Nightly E2E 0 green in 100 runs; DAST privileged-socket red-team lane failing — daemon boundary security signal dead | Cross-cutting | M | Soon |
| 18 | Med | PCM/search schema has 4 independent authorities; verifier is table-name-level only; column drift (ftsRowid) already real | Cross-cutting | M | Soon |
| 19 | Med ↓ | `conversations_au` FTS trigger ungated: watermark-only updates re-tokenize entire transcripts (one whole-table statement) | Cross-cutting | S | Soon (with #12) |
| 20 | Med | `search_documents_fts_au/_ad` triggers: unindexed full-scan deletes per touched row | Local | M | Soon (with #12) |
| 21 | Med | rollback-migration.sh knows nothing after v47 (8 migrations unclassified, incl. entire PCM schema) | Local | S | Soon |
| 22 | Med | Harness Windows job = echo-skeleton feeding Platform Confidence Gate while 323 real test files exist | Cross-cutting | S | Soon |
| 23 | Med | Windows/.NET: no dependabot, no lockfiles, no vulnerability scanning — only unscanned platform | Cross-cutting | S | Soon |
| 24 | Med | apps/console + website outside fail-closed npm-audit gate; console outside dependabot (authenticated prod web app) | Cross-cutting | S | **Now** (1-line) |
| 25 | Med | Vendored libsignal 95 commits / 3 minors behind upstream, personal-account fork, no bump automation | Systemic | M | Soon |
| 26 | Med | V-47 residue: 35 local preserve/* tags with June-15 secret stashes; rotation unverified 3.5 weeks later | Local | S | **Now** |
| 27 | Med | Repo bloat: 10.13 GiB pack (snapshot refs captured SPM caches), 307 MB .glb plain blobs, 3,099 remote branches, 31 MB binary evidence on main | Systemic | M | Opportunistic |
| 28 | Med | RPC wire-name canon gate only in path-filtered Linux lane; generated TS + generator itself unwatched | Cross-cutting | S | **Now** (2-line) |
| 29 | Med | Windows C-ABI sharing seam stalled at one exported function while C# tree passes 152k LOC | Systemic | L | Scheduled |
| 30 | Med | ZAP ops-confidence gate fails on WARN-level findings — red 6 straight weeks with zero FAILs | Local | S | **Now** |
| 31 | Med | Repair-bot watchlist misses the deploy plane (firestore/cloud-run/DAST/linux lanes unwatched); two hand-duplicated 600-line workflows | Local | S | Soon |
| 32 | Med | Local DB has no retention/compaction: transcripts stored 3×, per-version embeddings never GC'd, chat_messages unbounded (Windows just shipped *bounded* history — flagship is the unbounded one) | Cross-cutting | L | Scheduled |
| 33 | Med | firestore.rules: 4,869-line single-file authz monolith (142 match blocks, 359 allows) — well-tested but at reviewability edge | Systemic | L | Opportunistic |
| 34 | Med | Post-merge-only quality tier drifted: detekt/Swift/Android coverage never gate PRs; merge_group exists and could host them | Cross-cutting | M | Soon |
| 35 | Med | Console/services have no coverage floor (61 test files vs 383 sources; escrow/WebCrypto interop logic) | Local | S | Soon |
| 36 | Med | XCUITest suites (13 files) + macmini remote-UI infra wired into project.yml, invoked by zero workflows | Cross-cutting | M | Opportunistic |
| 37 | Med | Top-3 Swift files are ungated test god-files (6.1k/6.1k/5.9k lines, 40–70 commits/10 weeks — merge-conflict magnets) | Cross-cutting | M | Scheduled |
| 38 | Med | docs/ has no lifecycle: 126 top-level plans/handoffs, a third untouched 5+ weeks, archive contains one file | Systemic | M | Scheduled |
| 39 | Med | ops-plane-verify red 5 weeks (gcloud interactive prompt); fix landed 07-08 but unproven on schedule | Local | S | Verify Sunday |
| 40–49 | Low/Med | Comment rot in security-pr.yml; gitleaks path-unscoped allowlist; knip gap (console/website); naming drift (BurnBar/OpenBurnBar 143/205 + typo'd `SwitcherCLILAunchService.swift`); vestigial retry env vars; TECH_DEBT_METRICS.md stale 25 days & missing 4 newest budgets; dependabot batch noise; .gitleaksignore line-pinned fingerprints; CHANGELOG single Unreleased section conflicts | — | S each | Opportunistic |

---

## 4. What Is Hurting Velocity Most

1. **Red main answers nothing.** Every "did my merge break mobile?" question requires local test
   runs because the post-merge lane has proven nothing for a month. Every push also burns a doomed
   90-minute macos-26 harness run.
2. **~1,900 no-op repair-bot runs/day** make the Actions UI unusable and burn runner quota.
3. **75+ minute PR waits** on app-pr-gate (cold SPM cache + libsignal FFI rebuilt across 4 macOS
   lanes with 3 different cache-key families).
4. **Every cross-platform behavior change is 3–5 hand-synced implementations** with no conformance
   failure to tell you which one you forgot; every schema change is a 6-artifact manual mirror with
   one table-name-level gate.
5. **10.13 GiB pack + 3,099 remote branches**: every fetch/worktree/gc on the factory machine pays
   it, multiplied by the agent fleet.
6. **Merge-conflict magnets**: the single shared CHANGELOG `Unreleased` section and 5–6k-line hot
   test files (70 commits/10 weeks) collide parallel agent lanes constantly.
7. **"What gates my PR?" is tribal knowledge** across 61 workflows and 1,100+-line YAML files, with
   sparse-checkout path pins that break on file moves (7 pin blocks in fast-feedback.yml alone).

## 5. What Is Riskiest for Production

1. **Deploy-plane blindness (#1, #3):** either prod backend is 3 weeks stale against shipped
   clients (the historical usage-sync-dead-a-month incident class), or deploys route around the
   hardened pipeline. And the lane that would catch a rules regression cries wolf 48 runs straight.
2. **Releases cut from an unprovable main (#2, #6):** iOS behavior changes currently merge with
   literally zero test execution anywhere; the release lane has a bypass knob for exactly this.
3. **Dead security signal (#17, #26):** the privileged-socket red-team gate — the only adversarial
   check on the daemon's input boundary, and the lane that would exercise the untested path-boundary
   fix — has no green signal; secret-bearing tags await a rotation nobody verified.
4. **Split-brain authorization (#8):** remote missions are authorized by the weaker of two divergent
   policy engines on the product's most dangerous surface.
5. **Same-version-different-schema databases (#11, #18):** two migrators registering identical IDs
   over the same format, already divergent — undetectable by version checks, discovered only after
   user data is written.
6. **FTS CPU recurrence (#12, #19, #20):** the incident will return for the highest-data (most
   retained) users, with the confusing twist that "we already fixed that."

## 6. What Could Force a Rewrite Later

- **The Windows C# tree (#29):** already the largest per-language tree (152k LOC); every deferred
  month of C-ABI/Kernel sharing converts future "route through shared core" into "re-migrate
  hundreds of behaviors."
- **Core monolith inertia (#9):** the 115-file UI set is frozen, not shrinking; Core keeps accreting
  around the K3 entanglement until a security review forces a rushed split.
- **The migrator/PCM authority fan-out (#11, #18):** reconciling N drifted schema authorities
  against real user databases later is a mission-scale archaeology project; a gate now is a day.
- **Git history bloat (#27):** binary assets and snapshot-captured caches compound until history
  rewrite — maximally disruptive — becomes the only fix.
- **libsignal fork drift (#25):** each deferred rebase compounds custom patches × FFI artifacts ×
  cross-language KATs; an upstream security release would force a rushed crypto upgrade.

---

## 7. Debt Reduction Strategy

**Core philosophy: restore the proof plane first, then make every twin executable, then resume the
structural paydown that's already planned.**

Five principles:

1. **Green main is a product.** The two-tier CI design is sound *only* if post-merge red is a
   stop-the-line event with a recovery SLO. That SLO is the single highest-leverage artifact this
   plan creates.
2. **Every gate proves it measured something.** No gate ships without a self-test/positive-control
   (the `diff-coverage-ts` self-test and `check-no-suppressions.test.sh` pattern). Retro-fit the
   existing silent no-ops rather than adding new gates.
3. **Twins get executable contracts, not byte-checksums.** Shared fixtures must be *executed* by
   every platform that claims conformance (the crypto KAT suites prove the pattern works in-repo).
4. **Don't re-plan what's already planned.** The split-brain/kernel program
   (`SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md`) is verified accurate and current — this
   plan *resumes* it (M3→M4, K4 slices, K3-as-cluster) rather than replacing it.
5. **Fix causes, not symptoms, of the factory's exhaust.** The snapshotter that captured SPM caches,
   the missing docs-status contract, the missing escalation tier — one causal fix each, then a
   one-time sweep.

What we explicitly **accept intentionally** (verified deliberate tradeoffs — do not re-litigate):
compile-only mobile PR gate *as a tier decision* (but its post-merge counterpart must work);
post-merge placement of heavy suites; manual rollback scripts at current scale; iOS/Android as
local-first non-daemon clients; Rust crates as ADR-008 seams; `enforceAppCheck:false` on the two
documented mint bootstraps; Swift CodeQL on push/nightly; frozen v43 enum in the Linux migrator twin
(the debt is the missing gate, not the freeze); WPD-0005 Windows storage boundary; the repair bots'
provenance ceremony; migration-pending-only integrity checks.

---

## 8. Phased Roadmap

### Phase 0 — Stop the bleeding (days 1–7)
*Goal: production deploy path verified, one green harness run, alarms mean something again.*

| Workstream | Actions | Effort |
|---|---|---|
| **Deploy plane** | Diagnose deploy-production 4-second zero-step failures (likely environment-protection rejection on tag re-push); re-deploy v1.0.29 backend through the pipeline or document/verify the manual path used; add alerting: any `v*` tag without a successful deploy-production run within 24h pages. | M |
| **Firestore gate** | Debug `deploy-firebase-rules-releases.mjs` `patchExistingRelease` 400 (likely Rules API contract change in updateMask/release-name); locally reproducible with a token; close #625. | S |
| **Repair bots** | Split concurrency group by trigger so `schedule` can't be stomped by the `workflow_run` flood; narrow the 16-workflow fanout; expect ~1,900/day → handful. | S |
| **Harness to green once** | Fix AmplitudeCore SPM link break (project.yml product list — also explains the PR-gate/harness resolution split-brain), the detekt LongMethod on main, App XCTest, Platform Misc. One green baseline = bisection restored. | M |
| **P0 triage** | One-time sweep of the 9 standing P0s (most are covered by fixes above); add age-based escalation to ops-failure-issue (>72h → notify Alberto + weekly ops dashboard); introduce a `known-red-named-blocker` label so P0 stays meaningful. | S |
| **V-47 closure** | Verify IROH_SERVICES_API_SECRET + Android keystore rotation actually happened; extract anything wanted from the 35 preserve/* tags, then delete them; refuse `preserve/*` in pre-push. | S |
| **One-line honesty fixes** | jscpd config (delete malformed `formatsExts`, `skip`→`ignore`, threshold at measured 4.8–6%, add analyzed-files floor self-test); ZAP `fail_action` on FAIL-only + fix the 9 header WARNs; RPC-canon check into the always-on debt-budgets job; `apps/console`+`website` into AUDIT_DIRS + dependabot. | S |

*Why now:* every item is either an active production risk or a <1-day fix that restores trust in a
signal other phases depend on. *Success:* deploy lanes green; harness has a green run on main; 0
standing P0s >72h without a named blocker; repair bots produce their first repair PR in 3 weeks.

### Phase 1 — Gate honesty 3.0 + platform floor (weeks 1–3)
*Goal: no gate that asserts nothing; every platform has a minimal pre-merge floor.*

- **Recovery SLO (the keystone):** a required `main-is-green` check — last harness conclusion —
  consulted by the factory merge loop; harness red >48h freezes non-fix merges. This is what makes
  the two-tier bargain sound again.
- **Diff-coverage resurrection:** move Swift package + app coverage steps to PR-path lanes (scripts
  exist and have self-tests) *or* delete them and state Swift/Kotlin coverage is ungated — no third
  option. Fix Android diff-coverage to a merge-base ref in a PR lane.
- **Android PR gate:** `android-pr-gate.yml` mirroring app-pr-gate — path-filtered
  `compileDebugKotlin` + detekt + `testDebugUnitTest` on ubuntu (~15–25 min). The budget-contract
  workflow is the proven template.
- **iOS execution somewhere:** root-cause done in Phase 0; add a lightweight PR-path mobile smoke
  (1–2 fast test bundles, not the simulator matrix).
- **Windows skeleton → real:** replace the four `echo` steps with the pr-windows-full job body;
  add byte-compat fixture paths to pr-windows-full's filters.
- **Budget contract made executable:** Kotlin test consuming the already-present vectors resource
  (pattern: `AndroidSignalInteropKatTest`); Windows copy pinned + xUnit vector runner; fail the
  contract workflow if any platform copy lacks a registered consumer test.
- **Windows/.NET security floor:** dependabot `nuget` entry; `RestorePackagesWithLockFile`;
  `dotnet list package --vulnerable --include-transitive` fail-closed in pr-windows-fast.
- **Small honesty sweeps:** delete vestigial retry vars; delete stale security-pr non-blocking step;
  scope the Swift-label gitleaks allowlist to Swift paths + extend the boundary verifier to reject
  path-unscoped regex allowlists; weekly TECH_DEBT_METRICS refresh including the 4 newest budgets.

*Risks:* Android gate adds PR latency (bound: path-filtered, ubuntu); coverage-gate placement may
need merge_group instead of PR for cost. *Success:* zero known no-op gates; every platform has a
pre-merge compile+test floor; metrics doc auto-refreshes.

### Phase 2 — Data layer: one migration, one authority chain (weeks 3–8)
*Goal: kill the FTS incident engine and make schema drift impossible, in the right order.*

1. **v55 mega-fix migration (app side):** ftsRowid column + (documentID, ftsRowid) index (mirroring
   the daemon's existing v55 anticipation at `BurnBarProjectCodeMemoryStore+Database.swift`), convert
   the 3 unindexed delete sites; recreate `conversations_au` with a `WHEN old.fullText IS NOT
   new.fullText` gate; fix `search_documents_fts_au/_ad` with the same rowid pattern.
   **Mirror into the OpenBurnBarData fork in the same PR** — and retire the now-symptomatic
   WriteTuning sleeps afterward.
2. **Twin equality gate:** CI normalized-diff of each migration-file pair (rename+import strip gets
   false positives to ~6 lines), hard-fail on body drift, baseline the two documented divergences.
   Then the real fix: AgentLens consumes OpenBurnBarData and the copies are deleted (coordinate with
   K-series so it doesn't collide).
3. **PCM verifier to column level:** extend `verify-sqlite-schema-doc.mjs` from table names to full
   column sets per authority; longer term, generate daemon/python DDL from one canonical description.
4. **Rollback backfill:** v48–v54 into rollback-migration.sh arrays + a CI assert that every
   `registerMigration(` identifier appears there (schema-doc-verifier pattern).
5. **Retention quick wins:** GC non-current-version chunk_embeddings after reindex; scheduled
   incremental VACUUM; design (don't yet build) transcript-body archival policy.

*Why this order:* the v55 fix is the known column delta blocking the column-level verifier; the
equality gate must exist before more migrations accrete single-sided.
*Success:* FTS deletes are O(log n); metadata syncs don't re-tokenize; a forgotten twin edit is a
red PR, not a field incident; rollback tool knows the live schema.

### Phase 3 — Resume the structural program + release rehearsal (months 2–3)
*Goal: the frozen ratchets move; releases stop being all-nighters.*

- **M3 → M4 (split-brain):** wire `CLIAgentMissionRequestListener` to `daemon.mission.authorizeRemote`
  in shadow mode, log divergence, run until quiet, flip fail-closed and delete the GUI decision code
  in the same PR (ratchet drops from 3,694). Prereq: divergence telemetry + daemon-unreachable UX.
- **K4 slices:** Views/ (~30.7k LOC) into an Apple-only OpenBurnBarUI product; repoint the daemon to
  Kernel + narrow additions; re-attempt K3 only as the combined LogParser+SQLite+utils cluster (the
  solo attempt was reverted for exactly that entanglement). Named blocker to resolve first: headless
  app build for K4 validation.
- **C-ABI expansion decision:** pick the next 3–5 highest-drift behaviors (budget decisioning, CLI
  stream parsing, quota math) and export through the existing seam before more C# is written; make
  the DLL a required Windows CI artifact so the `swift run` fallback stops masking breakage; ratchet
  "C# reimplementations of Kernel logic" like core-ui-purity. This is a **strategy decision for
  Alberto**: expand the seam vs. accept permanent double-implementation.
- **Linux tests on Linux:** fix the "unrelated daemon tests" blocking the graph, then `swift test`
  in the existing toolchain container in linux-pr-gate + nightly. Path-boundary security tests first.
- **Release rehearsal:** weekly scheduled dry-run of release.yml (build+gates, no publish) so gate
  bugs surface before release day; extract fragile smoke steps (DMG launch, SQLCipher gate) into
  locally-testable scripts.
- **E2E/DAST revival:** triage nightly-e2e + privileged-socket red-team to a green baseline; wire
  XCUITest via `scripts/test-openburnbar-ui.sh` as a non-blocking nightly lane first.

*Success:* both frozen ratchets strictly below baseline; one release ships with ≤2 tag pushes;
`swift test` green on Linux; red-team lane green and meaningful.

### Phase 4 — Polish and long-tail (ongoing/opportunistic)
docs lifecycle (status front-matter contract + one-time sweep of 126 docs + linter); repo hygiene
(snapshotter excludes dependency caches — the causal fix; prune wip-snapshot refs + gc; .glb → LFS;
evidence binaries → release assets; merged-branch auto-delete); test god-file split along MARK
sections + test-tree size ratchet; naming convention + typo rename (update sparse-checkout pins in
the same PR); knip for console/website; firestore.rules composition build + rules-coverage report;
libsignal org transfer + monthly pin-drift issue + v0.97 rebase with KAT acceptance; per-lane
CHANGELOG fragments composed at release; repair-bot watchlist single-sourced + deploy lanes added.

---

## 9. Quick Wins (high ROI, ≤1 day each, no prerequisites)

1. jscpd config fix + analyzed-files floor (**restores an entire debt dimension**).
2. Firestore release-patch script debug (**un-reds 48-run alarm masking rules regressions**).
3. Repair-bot concurrency split (**revives the self-healing loop, kills ~1,900 junk runs/day**).
4. `apps/console` + `website` into AUDIT_DIRS + dependabot (1-line each).
5. RPC-canon check into the always-on debt-budgets job (2-line).
6. ZAP fail-on-FAIL-only + fix 9 header WARNs.
7. dependabot `nuget` entry.
8. Android PR gate (template exists).
9. rollback-migration.sh backfill + CI assert.
10. Delete the dead coverage steps / vestigial retry vars / stale security-pr step (honesty by deletion).
11. P0 age-escalation in ops-failure-issue.
12. V-47 rotation verification + preserve-tag deletion.

## 10. Longer-Horizon Refactors (important, not urgent — strangler-style)

- **K4 UI extraction + K3 cluster + daemon→Kernel repoint** (XL; the plan exists; interface-first,
  ratchet-verified per slice).
- **M3/M4 split-brain collapse** (L; shadow-first with divergence telemetry, then fail-closed flip).
- **Migrator single-sourcing** (M; equality gate first, then consume-and-delete).
- **C-ABI/Kernel sharing expansion for Windows** (L; strategy decision, then per-behavior migration).
- **firestore.rules composition** (L; build step + coverage report; test-first — suites already exist).
- **Retention/archival policy for local data** (L; design-first; policy, not hardcode).
- **Test god-file decomposition** (M; mechanical, `swift test` equivalence as the gate).

## 11. Metrics and Governance

Add to the (now auto-refreshing) `TECH_DEBT_METRICS.md`:

| Metric | Baseline (2026-07-09) | 30-day target | 90-day target |
|---|---|---|---|
| Consecutive days with ≥1 green harness run on main | 0 (0 green in 250 runs) | ≥80% of days | ≥95% |
| Standing P0 issues older than 72h without named blocker | 9 | 0 | 0 |
| Deploy-lane success (functions/Cloud Run/Firestore, rolling 7d) | 0% | 100% | 100% |
| Gates with self-test/positive-control vs total honesty-critical gates | ~3 | +5 | all |
| Platforms with pre-merge compile+test floor | 2/5 (macOS, Windows) +TS | 4/5 | 5/5 |
| Executable cross-platform contract suites (vectors actually run) | 1 (crypto KAT) | 2 (budget) | 3+ (verdict engine) |
| core-ui-purity baseline (files) | 115 (frozen) | 115 | <100 and falling |
| mission-splitbrain baseline (lines) | 3,694 (frozen) | 3,694 | 0 (M4 flipped) |
| Migrator-twin drift gate | none | normalized-diff gate | single source |
| Tag re-pushes per release | ~15 (v1.0.29) | ≤5 | ≤2 |
| Repair-bot runs/day (noise) | ~1,900 | <50 | <50 |
| Local pack size | 10.13 GiB | <5 GiB | <3 GiB |
| Rollback script coverage | v47/v54 | v54/v54 + CI assert | current |

**Governance to keep debt from returning:** (1) every new gate ships with a self-test — enforce via
review checklist + the meta-gate pattern; (2) every new budgets/*.json still requires its
LINT_RATIONALE allowlist entry (existing tripwire — keep); (3) new platform surface = dependabot +
audit + PR floor in the *same* PR that creates it; (4) docs status header required by linter;
(5) the weekly ops dashboard reviews: green-main streak, P0 age, deploy success, frozen-ratchet
movement — 15 minutes, and the only recurring human ceremony this plan adds.

## 12. Final Recommendation

**Do first (this week):** Phase 0 verbatim. The deploy-plane investigation (#1) is the single most
urgent item in this audit — it is either a silent version-skew incident in progress or evidence that
production deploys bypass every hardening gate the team built. Everything else in Phase 0 is
S/M-effort and restores the signals the rest of the plan steers by.

**Do next:** the recovery SLO (Phase 1's keystone) — it is the one cultural/mechanical change that
prevents this entire audit from recurring as "gate-honesty 4.0" in six months — then the platform
floors and executable contracts.

**Schedule deliberately:** Phase 2's v55 data-layer migration (before more user data compounds the
cost) and Phase 3's resumption of the already-approved structural program (M3/M4, K4).

**Decide once (Alberto):** the Windows sharing-seam question (#29) — expand C-ABI/Kernel exports
now, or accept permanent double-implementation with ledger governance. Both are defensible; the
current state (a seam that exports one function while 152k LOC accretes) is the only indefensible
option.

**Accept intentionally:** everything in the tradeoffs list (§7) — and write that acceptance down so
future audits (and agents) stop re-litigating it.

The June audits proved this team can pay debt down and keep it down — the code-level registers went
to zero and stayed there. The same discipline now needs to move one level up: from the code to the
machinery that proves the code. That's this plan.

---

*Full per-finding detail (evidence, per-item business/engineering impact, verifier reasoning) is
preserved in the audit run transcript; each register row above cites its load-bearing paths inline.
Lanes: quality (8 items), architecture (7), testing (10), ops (10), security (7), perf (7).*
