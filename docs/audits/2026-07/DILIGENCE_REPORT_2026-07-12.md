# Technical Diligence Report — OpenBurnBar / BurnBar

**Date:** 2026-07-12
**Scope:** Full-stack diligence review of the entire monorepo
**Method:** Coordinated 6-lane specialist swarm (architecture, code quality, reliability/ops, security, performance, QA/delivery) + adversarial re-verification of every claimed launch blocker against **live GitHub Actions state and live production infrastructure** (gcloud, Firebase Rules API).
**Tree reviewed:** branch `codex/windows-macos-parity-audit-implementation` working tree (since merged to `main` as PR #1550); leads from prior internal audits independently re-verified against the current tree, not taken on faith.
**Confidence:** High. Every material claim is backed by file paths + line numbers, executed commands, live `gh`/`gcloud`/Rules-API output, or reproduced test runs.

---

## 1. Executive Summary

**This is a credible production system with genuinely impressive client-side engineering, sitting on top of a broken deployment plane.** The split is stark and it is the whole story of this report.

The code you can read is top-decile for a company this size. Six languages (Swift, Kotlin, C#, TypeScript, Rust, Python) read as **one coherent codebase** despite ~99% AI-agent authorship, because quality is enforced by **mechanical ratchets that actually work** — a measured 4.48% code-duplication gate that rejects its own vacuous reports, a god-file burn-down driven to zero and frozen there, near-zero swallowed errors and lint suppressions across all six languages, and honest debt accounting written directly into the lint configs (it records its 715 force-unwrap sites rather than hiding them). The architecture is a deliberate, daemon-first, capability-attenuated design with codegen'd cross-platform contracts and drift gates. A diligence engineer reading this repo cold would be impressed within the hour.

Then they would look at CI and production, and get nervous within the next hour. **The entire backend deploy plane has been dead for ~24 days.** Cloud Functions last deployed 2026-06-18 (verified live: every function's `updateTime` is that date); Cloud Run last deployed 2026-06-18; and the Firestore **security-rules** release has failed on every single main push since 2026-06-19 with a `400 INVALID_ARGUMENT`. We diffed the *live production ruleset* against `main` and found **427 semantic diff lines** — production is enforcing early-June-era rules while merged, CI-green security hardening (append-only escrow audit, erasure gating, spend caps, monotonic-counter protection) is **not live**. Client v1.0.29 shipped to the App Store on 2026-07-06 against 6/18 backend code. The "proof plane" that would certify a release end-to-end has been **red since June 19** (nightly E2E is 0-for-43 all-time; the full post-merge harness is 0-for-250 since its last green run on 2026-06-19). And a wall of trivially-green "CI Repair" bot runs masks all of this on the `main` run history.

The good news: the dead deploy plane is almost certainly an **hours-to-days fix, not a rewrite** — a GitHub environment-protection tag policy plus a grown-past-limit rules file, not a rotten architecture. The bad news for a fundraise: it has sat broken for over three weeks with auto-filed P0 issues ignored, which reads as a **single-operator bus-factor** problem more than a technical one.

**True maturity:** a genuinely impressive engineering *foundation* being operated by a team (effectively one person + agents) that has outrun its own operational capacity.

---

## 2. Final Verdict

- **Professionalism:** High. This is not a prototype and not a messy startup hairball — it is a deliberately architected, ratchet-enforced, multi-platform system with real tests, real runbooks, and real security engineering. The taste and discipline are visible in the code.
- **Launch readiness:** **Launchable with major caveats.** Clients are already live and healthy; production is up and synthetically monitored. But you cannot currently ship or roll back a backend/security fix through CI, and production is running stale security rules. That is a launch blocker in the operational sense even though nothing is on fire *today*.
- **Series A technical-diligence readiness:** **Strong startup-grade foundation, not yet diligence-clean.** The codebase would create real confidence; the dead deploy plane, dead proof plane, and single-operator bus factor would each generate a diligence finding. Fix the deploy plane and get one green end-to-end run, and this becomes a credible Series A technical story.

**If shown to excellent engineers and Series A investors tomorrow: both impressed and nervous.** Impressed by the code and the enforcement culture; nervous that the team cannot currently prove `main` is healthy or update production.

---

## 3. Scorecard

| Category | Score /10 | Maturity | Rationale (one line) |
|---|---|---|---|
| **Architecture** | 7 | Credible production | Deliberate daemon-first design + codegen'd contracts; dominated by a 5×-hand-ported-platform bet and a still-live GUI/daemon authority split-brain. |
| **Code Quality** | 9 | Genuinely impressive | Six languages read as one codebase; quality is mechanically enforced, debt is honestly accounted. |
| **Reliability / Ops** | 4.5 | Ambitious but messy | Excellent ops *design*; the *operation* is broken — backend deploy plane dead 24 days, proof plane red since June 19. |
| **Security** | 6.5 | Credible production | Top-decile security *as written* (fail-closed rules, CI-gated adversarial suites); ~1-month-stale *as deployed* with no working fix path. |
| **Performance / Scalability** | 6.5 | Credible production | Strong idle-cost discipline; the app-side FTS5 CPU-burn class is unfixed and O(total-history)-per-tick is a growth time bomb with zero perf CI. |
| **Testing / CI / Delivery** | 6 | Ambitious but messy | Top-decile PR-gate wall; dead post-merge/deploy proof plane; repair bots green-wash `main`. |
| **Documentation / Maintainability** | 7 | Credible production | 151 runbook/release docs, ADRs, honest audit trail; offset by god-file test files and split-brain duplication. |
| **Overall Professionalism** | 7.5 | — | Visible taste and rigor; enforcement culture is the standout. |
| **Launch Readiness** | 5 | — | Clients live; backend un-shippable and security-rule-drifted. |
| **Series A Diligence Readiness** | 6 | — | Foundation impresses; ops/proof/bus-factor gaps would each surface. |

**Overall weighted score: 72 / 100** (weighting launch-blocking ops/security gaps heavily, as a diligence team would).

**Severity summary:** 1 systemic launch blocker (verified 4 ways) · ~10 serious weaknesses · ~18 medium concerns · numerous polish items.

---

## 4. What Inspires Confidence

These are verified strengths, not surface impressions.

1. **Quality is enforced, not aspirational.** The god-file burn-down is real and *frozen at zero* by `budgets/swift-file-size-baseline.json` (target 2000, total 0; largest production Swift file is 1,986 lines). Duplication is genuinely measured — a green CI run reports 4.48% across 3,710 files, and `scripts/ci/verify-jscpd-report.mjs` *fails the build* if any language stops being analyzed (killing the prior "jscpd no-op" finding). Empty catches are ratcheted to literally zero; Rust `.unwrap`/`.expect` callsites are ratcheted to zero by `scripts/debt/check-rust-panic-budget.sh` (note: this budget covers unwrap/expect only, not `panic!()` macros — a few `panic!()` callsites remain in shipping Rust, e.g. `crates/openburnbar-iroh/src/lib.rs`).

2. **Six languages, ~99% agent-authored, reading as one codebase.** Shared design tokens across macOS/iOS/web, uniform typed-error idioms, and one naming system. The consistency-risk you'd expect from heavy multi-agent authorship simply did not materialize — because the ports drift-check against each other via canons and fixtures instead of forking.

3. **Honest debt accounting.** `.swiftlint.yml` records its exact measured debt (715 force-unwraps, 326 discouraged-optional-collections) rather than hiding it; baselines are shrink-only with written rationales; release-workflow *step ordering* is asserted as a Python test. This is the strongest single signal of long-term thinking in the repo.

4. **Daemon-first trust architecture, verified in code.** The privileged daemon has **zero** `import Firebase*` and one AppKit import; RPC is capability-attenuated per-method with an asserted coverage table and peer code-signature auth. Security-sensitive execution lives in a defensible trust root.

5. **Contracts are codegen'd from single canons with merge-blocking drift gates.** A 116-method RPC canon emits Swift + TS + Linux JSON with a `--check` gate; a 14-domain TypeSpec schema canon hand-mirror-verifies Swift/Kotlin/TS; the Hermes protocol has its own canon. Wire-name split-brain is caught at PR time.

6. **Security-as-written is top-decile.** A 4,899-line fail-closed Firestore ruleset with **21 adversarial emulator suites** blocking every PR; backend that *refuses to boot* in production with App Check disabled; gitleaks with self-verifying allowlist boundaries; cross-tenant isolation proven adversarially in CI with skip-treated-as-failure semantics.

7. **Real idle-cost discipline in the always-on app.** Cadence coordination pauses on display sleep and stretches 5× in background; the WKWebView backdrop is occlusion-paused with low-power GPU hints; every audited timer is gated or slow-cadence. For a menu-bar product, treating idle CPU as a first-class invariant is exactly right.

8. **Ops *design* is genuinely strong.** WIF/OIDC-only deploys with build-before-auth artifact isolation, sub-minute revision-pin rollback tooling, real runbooks (severity matrix, SLIs, DR drills), and circuit-breaker resilience in functions. The blueprint is excellent — it just isn't running.

---

## 5. What Would Alarm a Serious Reviewer

1. **The backend deploy plane is dead and has been for 24 days.** No path to ship or roll back functions/Cloud Run/rules through CI. This is the defining finding (see §6).
2. **Production is enforcing stale security rules.** Live-ruleset-vs-`main` diff = 427 lines; merged, CI-green hardening is not live. The rules the tests validate are **not** the rules in production.
3. **The proof plane has been red since June 19.** Nightly E2E is 0-for-43 all-time; the full post-merge harness is 0-for-250 since its last green run on 2026-06-19. There is no recent end-to-end evidence any release candidate works; iOS Mobile XCTests effectively never execute in the PR gate (compile-only) or post-merge harness (job always cancelled), though `release.yml` does run `./scripts/test-openburnbar-mobile.sh` during release-mobile-gate unless owner-approved bypass inputs are set.
4. **Green-washing via repair bots.** Dozens of trivially-green "Codex/Cursor Nightly CI Repair" runs per hour make `main` look healthy while the harness/e2e/deploy lanes underneath are red; the bot concludes `success` even when its operator job is `skipped`.
5. **Single-operator bus factor, visible as operational debt.** Every problem above was *detected* within hours by auto-filed issues (#625, #1091, #565…) — and then ignored for 3+ weeks. The alerting works; the acting-on-it doesn't. This is the #1 risk a diligence team would name.
6. **The 5×-hand-ported-platform bet.** The same product is implemented five times (Swift ~520k LOC, Kotlin 183k, C# 171k, TS 91k, plus Tauri Linux and Next.js console). Parity is fixture-based, not shared-code; every log-format/quota/crypto change must be re-implemented N times. This is the dominant 12–24-month velocity drag and the largest hidden rewrite risk.

---

## 6. Launch Blockers

**One systemic blocker, independently confirmed four separate times** by different lanes hitting live infrastructure from different angles. It has two faces:

### LB-1: Backend deploy plane dead — cannot ship or roll back functions/Cloud Run
- **Evidence:** `deploy-production.yml` last success 2026-06-18T16:48Z (96 failures since); `deploy-cloud-run.yml` last success 2026-06-18T18:29Z. **Live proof:** `gcloud functions list --project=burnbar` shows every function's `updateTime` = 2026-06-18; a live `curl` of prod `healthReady` returns the 2026-06-18 commit hash. 137 commits touched `functions/src` since. Root cause: GitHub environment-protection tag-policy rejections ("Tag v1.0.29 is not allowed to deploy to production"), failing in 2–4s with zero steps. A permissive policy now appears configured but **has never been exercised** — the pipeline and the tag→deploy rollback path remain unproven.
- **Why it blocks:** launching means operating a backend you cannot update or roll back through the safe path; client v1.0.29 already shipped against 24-day-old backend code (live client/backend skew).

### LB-2: Firestore security-rules release fails on every main push — production runs drifted rules
- **Evidence:** `deploy-firestore.yml` fails 40+ consecutive times since 2026-06-19; the firebase CLI ships only `indexes,storage`, and **rules ship exclusively via** `scripts/ci/deploy-firebase-rules-releases.mjs`, which `400 INVALID_ARGUMENT`s on the release PATCH after its full retry ladder. Ruleset *creation* succeeds; the *release* PATCH rejects it. **Live proof:** downloaded the production ruleset via the Firebase Rules API and diffed vs transformed `main` → **427 semantic diff lines**. Production still allows `update`/`delete` on escrow audit events where `main` blocks them with `if false` for `update` and `delete` (while intentionally allowing owner `create`, per R-S3, commit 75d3b92ffb); production is missing the erasure-tombstone auth gate, monotonic-counter enforcement (prod allows counter rollback), vision-token spend caps, and Ultra-entitlement recognition. Five merged fix PRs (#1169/#1171/#1173/#1174/#1176) did not revive it.
- **Why it blocks:** the committed, tested security posture is **not the enforced one**; there is no version-control rollback reference for prod rules; clients built against `main`'s rules can hit `PERMISSION_DENIED`; and the emergency rules-fix path during a security incident is broken.

**Verification note (calibration):** the adversarial pass *softened* two sub-claims honestly — a one-off manual rules deploy on 2026-07-03 narrowed the gap (so "stale since 6/19" is imprecise), and PR #1539 ships with the client, not this pipeline (strike it as an example). Neither changes the verdict: production verifiably lacks merged security controls and there is no demonstrated working CI path to ship a fix. **Likely remediation is hours, not weeks** — one successful `workflow_dispatch`/tag deploy through the now-permissive environment plus resolving the rules-release 400 (the deployed working ruleset is 166KB transformed vs a 236KB raw source that may be tripping a release-time limit).

---

## 7. Diligence Risks (fundraising-stage findings)

1. **"Can you deploy a fix right now?"** — today, no. This is the first question a technical DD partner asks and the honest answer is a 24-day-red pipeline.
2. **Security-posture drift** — "your tests prove rules you don't run" is a finding on its own, independent of LB-1/LB-2 being fixed.
3. **No end-to-end proof** — 0 green E2E/harness runs means no artifact demonstrates the multi-device E2EE product works end to end.
4. **Bus factor** — the automation plane (~116 workflows, 16 ratchets, parity validators) is itself a large bespoke product with effectively one maintainer; when it breaks, the bots still report green.
5. **5× port duplication** — a reviewer will price in the ongoing N-way re-implementation tax and the parity-only-as-strong-as-fixtures risk (Windows and Android don't even consume the RPC canon).
6. **Deep-language SAST cadence** — CodeQL PR gate covers only JS+Python (CodeQL explicitly does not cover Swift/Kotlin/C#/Rust). Rust does have a dedicated `rust-sast.yml` workflow (cargo-audit + clippy security lints) triggering on PR/merge_group/push/schedule/dispatch over both Rust crates. Swift/Kotlin/C# deep scans still depend on the main-branch CodeQL run, which self-cancels 8/10 times.
7. **V-47 unrotated secrets** — Android keystore passwords + `IROH_SERVICES_API_SECRET` sit in 35 local `preserve/*` stash tags (confirmed **not** pushed), rotation still unverified ~4 weeks later, with no pre-push guard preventing an accidental `git push --tags`.
8. **`firestore.rules` at 236KB** — one file near Firebase's 256KB limit, the likely deploy-killer, with no PR-time compile+size tripwire.

---

## 8. Hidden Rewrite Risks

1. **The N-way port strategy (highest).** Business-logic parity is maintained by hand across 5 implementations with fixture goldens covering wire names + 14 schema domains — **not behavior**. This will either slow feature velocity to N× or force a consolidation onto shared cores (Rust/FFI, as already done for iroh/remote/media). Not a crisis, but the dominant multi-year drag.
2. **Core is still a 95.5k-LOC god module.** The kernel-extraction program is real and moving (28.7k LOC pulled into `OpenBurnBarKernel`, K1/K2/M1/M2 merged) but ~25% done; `Views/` (~117 files/30k LOC) still lives inside the module every platform links, K3-Quota was attempted and **reverted** (entangled cluster), K4 deferred pending a headless app build.
3. **GUI/daemon mission-authority split-brain is live.** The 3,698-LOC Firestore mission listener in AgentLens still executes missions with its *own* trust checks; the merged `daemon.mission.authorizeRemote` RPC has **zero callers** in AgentLens (shadow-mode wiring never started). A policy tightening applied to the daemon does not apply to the GUI path — the classic setup for a later authorization-bypass discovery.
4. **Split-brain database layers.** `OpenBurnBarCore/…/OpenBurnBarData` and `AgentLens/…/DataStore` carry near-identical FTS schema/triggers/migrations — the exact mechanism by which the FTS5 CPU fix landed in the daemon but **not** the app.
5. **New ports regrowing god-files unchecked.** The Swift file-size ratchet has no Kotlin/Rust/TS equivalent; `lib.rs` (3,267 lines), `SwarmBackground.kt` (2,987), `tauriBridge.ts` (2,304) already exceed anything left in Swift.

---

## 9. Top 10 Highest-Leverage Improvements

Ranked by impact on professionalism + launch/diligence readiness.

1. **Revive the backend deploy plane and prove it with one green run** (functions + Cloud Run via `workflow_dispatch`/tag through the now-permissive environment). Clears half of LB-1. *Hours.*
2. **Fix the Firestore rules-release 400 and deploy `main`'s rules to prod**; add a PR-time ruleset compile+size dry-run so growth can never silently kill deploys again. Clears LB-2 and the drift. *1–2 days.*
3. **Get one green end-to-end run** (nightly-e2e or the full harness) so a release candidate is provably healthy once. Resolves the "red since June 19" diligence finding.
4. **Make the CI-repair bots conclude `neutral`/`skipped`, not `success`, when the operator skips** — stop green-washing `main`'s run history. *One-line-class fix, high signal-integrity payoff.*
5. **Add `Mobile build (compile gate)` to required checks** (it exists and runs but isn't required) so mobile compile breaks can't merge under pressure.
6. **Wire the AgentLens shadow-mode call to `daemon.mission.authorizeRemote`** (plan Phase M3) so the merged RPC stops being dead code and the mission-authority split-brain starts closing.
7. **Port the closed PR #1221 app-side FTS5 ftsRowid fix** (+ its `SearchIndexFTSRowidTests`) so the app database stops full-scanning on every chunk delete — the unfixed half of the 128–195% CPU incident.
8. **Replace `fetchCloudTotal`'s 90-day document download with a Firestore `sum('cost')` aggregate query** — a one-line-class fix that eliminates a per-tick read/bandwidth fan-out that gets strictly worse with adoption.
9. **Rotate the V-47 secrets and add a pre-push guard refusing `preserve/*` tag pushes** — contained today, one accidental push from a live leak.
10. **Add a force-unwrap-budget ratchet** (the one documented debt with no driving-down mechanism) and start a Kotlin/Rust/TS file-size ratchet so the newer ports don't regrow the god-file problem.

---

## 10. Appendix — Method, Evidence, Files

**Swarm composition:** 6 specialist reviewers run in parallel over the full tree, each producing a structured verdict with evidence; then every claimed launch blocker was handed to an independent adversarial verifier instructed to *refute* it against live GitHub + production state. All 4 blocker claims survived (all resolved to the same systemic deploy-plane failure). ~850k tokens, 443 tool calls, 10 agents.

**Live-infrastructure verification performed (not just config reading):**
- `gcloud functions list --project=burnbar` → every function `updateTime` 2026-06-18.
- `curl` of prod `healthReady` → 2026-06-18 commit hash.
- Firebase Rules API ruleset download + normalized diff vs transformed `main` → 427 semantic diff lines; specific missing controls enumerated (escrow R-S3, erasure gate, monotonic counters, spend caps, Ultra entitlement).
- `gh run list`/`gh run view` across ~15 workflows; `gh api …/branches/main/protection` (enforce_admins=true, 60 required checks, 0 required approving reviews — worth confirming the review gate lives in an org ruleset).

**Scale (measured via `wc`/`git ls-files`):** ~985k Swift LOC total (AgentLens 272.9k + Core 95.5k + Kernel 28.8k + Mobile 154.3k + Daemon 63.3k); Kotlin 183.4k; C# 171.2k; TS functions 91.3k; plus Tauri Linux + Next.js console. ~13,000+ test functions across platforms.

**Prior-audit leads re-verified against the current tree:**
- God-file 4→0 — **TRUE**, now ratchet-frozen.
- jscpd no-op — **FIXED** (4.48% measured, anti-vacuous guard).
- Backend deploys dead since 6/18 — **TRUE**, confirmed against live gcloud.
- Nightly harness 0-green — **TRUE** (0-for-43 all-time; full harness 0-for-250 since last green 2026-06-19).
- Repair bots self-cancelling — **TRUE** (now skipped-but-green).
- App-side FTS5 fix — **STILL UNFIXED** (fix died in closed PR #1221; daemon half merged via #1384).
- V-47 secret rotation — **STILL UNVERIFIED**, tags confirmed not pushed.

**Representative files inspected (per lane, full lists in the swarm record):**
`docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md`, `OpenBurnBarCore/Package.swift`, `OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift`, `tools/ipc/generate-burnbarrpc-canon.mjs`, `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener*.swift`, `.swiftlint.yml`, `.jscpd.json`, `scripts/ci/verify-jscpd-report.mjs`, `budgets/*`, `scripts/debt/*` (executed), `windows/pal/input/CapabilityTokenVerifier.cs`, `crates/burnbar-remote/burnbar-remote-security/src/lib.rs`, `.github/workflows/deploy-{production,cloud-run,firestore,staging}.yml`, `scripts/ci/deploy-firebase-rules-releases.mjs`, `docs/runbooks/{oncall,slos,rollback-automation,production-deploy-boundaries}.md`, `functions/src/{resilience,auth,config,triggers}.ts`, `firestore.rules` (4,899 lines), `firestore-rules-tests/`, `.github/workflows/nightly-dast-sandbox.yml`, `AgentLens/Services/DataStore/SearchIndexStore.swift`, `AgentLens/Services/CloudSync/DownloadSyncService.swift`, `OpenBurnBarDaemon/…/BurnBarProjectCodeMemoryStore.swift`, `.github/workflows/{app-pr-gate,fast-feedback,openburnbar-pr-harness}.yml`.

---

*Generated by a coordinated diligence swarm with adversarial blocker verification against live production infrastructure. Every launch-blocker claim in §6 was independently re-verified and survived refutation. Companion follow-up: six scoped improvement PRs (#1562–#1566, #1569) were opened against several §9 items the same session.*
