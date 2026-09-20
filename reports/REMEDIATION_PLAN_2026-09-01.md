# OpenBurnBar Remediation Plan — 2026-09-01

**Repo:** `Imagine-That-Ai/BurnBar` (public). **Base for all work:** `origin/main` @ `9503b490b0` (2026-09-01 05:40Z, #2461).
**Source audit:** `FABLE-DILIGENCE_REPORT_2026-09-01.md` (score 61/100).
**Status of this document:** operating document for the next eight weeks. Every claim below is checkable by a named command, a `gh` query, or a file path. Where a claim could not be checked, it is marked `UNVERIFIED` and given an owner.

---

## Executive summary

| | |
|---|---|
| **Current score** | **61** (weighted raw 607.5/1000 — reproduces the report exactly) |
| **Target asked for** | 85 by 07:00 CDT 2026-09-02 |
| **Best case by 07:00 CDT 2026-09-02, all eleven wave-0 PRs merged** | **63.85 → 64** (sum of the wave-0 on-merge deltas, +30.95 weighted; see the [Score ledger](#score-ledger)) |
| **Central expectation by 07:00** | **62–63** — the first 4–6 PRs in landing order merge (+13.75 to +22.00 weighted → 62.1–63.0) |
| **Floor if the owner does nothing** | **61.0** — unchanged. Live branch protection requires one approving review from a human collaborator on every PR. Zero PRs merge without Alberto, emilio3435, or Lionsfan4. |
| **Absolute theoretical max tonight** | **65.0** — all eleven merged *plus* every contingent that is physically realizable before 07:00 (W0-2 P-PERF-3 dispatch, W0-5 human queue 7–9, W0-6 live drill, W0-8 first verified tag = +11.75 weighted). The deploy lane's own history says the tag and GCP legs cannot conclude in one window (see [On 85 tonight](#on-85-tonight)), so this is a bound, not a forecast. |
| **Plan's own ceiling, all four waves complete** | **74.6** on merged deltas alone; **76.6** if every contingent in the plan is also realized (week 8, 2026-10-27). Both are the arithmetic sum of the `scoreDelta` lines in this document — see the [Score ledger](#score-ledger). |
| **Earliest honest 85** | **2026-12-08 ± 2 weeks** — gated on 90 days of green trailing history, a second human with real access, and a written scope freeze, none of which is engineering work |

### What runs tonight (agents, no human needed to start)

Ten PRs and one stacked commit, all from fresh worktrees off `origin/main 9503b490b0`, sequenced by a pace controller that keeps **at most 3 PRs ready at once**:

| ID | Branch | Theme | Lane |
|---|---|---|---|
| W0-0 | *(no branch)* | Sequencer, pace controller, standing adversarial verifier | orchestration |
| W0-1 | `hotfix/main-compiles-20260901` | iOS notification category + AgentLens test import + Platform Misc lock | fast |
| W0-2 | `ci/ops-honesty-20260901` | Repair bot fails closed, nightly-health + deploy-lane-health scoreboards, P-PERF-3 exit codes, Linux/DAST reason codes | structured-large |
| W0-3 | `ci/gate-circuit-breaker-observe-20260901` | Main-red circuit breaker in **observe** mode; delete `xcode_false_negative_pass` | structured-large |
| W0-4 | *(stacked onto open PR #2349)* | Deploy-lane ancestor guard; the rest is human-gated | stacked |
| W0-5 | `ops/alert-plane-drift-wif-20260901` | New WIF-only `alert-plane-drift` job off the environment gate; concurrency unwedge | structured-large |
| W0-6 | `ops/runbook-topology-20260901` | Rollback runbooks point at the real project; topology lint; fixture drill receipt | fast |
| W0-7 | `ci/toolchain-pins-20260901` | One pin per language, drift check — **lands last** | structured-large |
| W0-8 | `security/supply-chain-vendor-integrity-20260901` | Stop labelling an SBOM attestation as SLSA; vendor checksum door; GRDB fork documented | structured-large |
| W0-10 | `ci/swift-sast-20260901` | CodeQL Swift Metal toolchain + Semgrep observing — **own PR** so 60–120 min iterations block nothing | fast |
| W0-11 | `docs/data-room-and-release-status-20260901` | `docs/data-room/INDEX.md` + `verify-data-room.mjs`, root-inventory ratchet, generated README release-status block | fast |
| W0-12 | `security/bola-strict-gap-ledger-20260901` | Measure the real denial code per endpoint; delete `ANY_CALLABLE_DENIAL_CODE`; shrink-only pending ledger | structured-large |

**Expected wave-0 outcome, stated honestly:** of the eleven PRs, **4–6 MERGED and 5–7 `OPEN_WITH_NAMED_BLOCKER`**. Historical merge throughput in the 19:00→07:00 window over the last 20 nights is mean 4.7 / median 4 / max 11 `[live 2026-09-01T~20Z]` — and every one of those nights ran *without* the human-approval gate that is live today. **The night grades `COMPLETE` only if the first three in landing order (W0-11, W0-6, W0-1) merge; fewer is `PARTIAL`; if #2466 never lands it is `BLOCKED-ON-QUEUE`** — see wave-0 exit gate item 6b, which exists because "every PR is MERGED **or** `OPEN_WITH_NAMED_BLOCKER`" is otherwise satisfiable by merging nothing.

### What the owner must do (full checklist in [Human queue](#human-queue))

1. **Approve and merge PR #2466 — right now, ~2 minutes.** The merge queue is wedged. The last two `merge_group` "BurnBar CI Gate" runs (2026-09-01 19:37Z and 20:15Z) both failed inside ~60 s on the required `OSV Scanner` context (GHSA-w9m9-85wc-3x92, postcss-selector-parser). Until #2466 lands, **every** merge-queue candidate fails closed and tonight's ceiling is exactly 61.0 regardless of how good the code is. #2466 is authored by `app/cursor`, so Alberto's own approval is valid on it.
2. **Resolve the approval deadlock.** GitHub forbids self-approval. 63 of the 92 open PRs are authored by `Ajnunezg`. Agent PRs tonight are therefore opened from a **bot/app identity**, so Alberto alone can approve them. Otherwise emilio3435 or Lionsfan4 must be awake.
3. **Dispatch `codex-nightly-ci-repair.yml` yourself, BEFORE you set `OPENAI_API_KEY` — ~2 minutes (queue item 28).** `codex-nightly-ci-repair.yml:169-186` grants `safe=true` on a dispatch only to a sender with `admin|maintain|write` collaborator permission, so no agent token can produce the fail-closed evidence wave-0 gate item 3b asks for. And the criterion asserts the string `OPENAI_API_KEY missing`, so the moment you set the secret (item 5) it can never be produced again. Order matters and it is the only place in this plan where it does.
4. Everything else — GCP service accounts, billing budget, environment approvals, the release tag, the rollback drill, App Check enforcement, the `feat/living-glass-sweep` media diffs (item 29, the only thing that closes F18), the domain-core attestation (item 30, the only thing that closes F10), a second human — is on the numbered 30-item queue and none of it is agent-reachable.

### The one-sentence version

Tonight buys **honest signals**, not a higher number: main compiles, the nightlies report red when they are red, the repair bot stops silently succeeding, the deploy lane gets a documented path back to life, the runbooks name the real project, and every artifact lands in a machine-checked data room. That is worth **+1.4 to +2.2 points** in the central case (4–6 PRs merged in landing order) and **+3.1** if all eleven merge — the exact figures in the [Score ledger](#score-ledger), not a feel. The rest of the distance to 85 is calendar time, one more human being, and a scope decision.

---

## How to read this plan

Every workstream in the winner plan (`plan-ops-first`, 245 pts) was independently attacked by two adversarial lenses — **feasibility** (can agents actually finish this by morning?) and **constraints** (does this violate CHEAP_FAST, the no-fake-green rule, or the human-only list?). **All 27 workstreams were refuted by both lenses.** 54 verdicts produced roughly 540 amendments.

This document applies them. Each workstream carries a **`⚠ Verdict-forced changes`** block naming what was cut, split, or corrected and which verdict forced it. Where the original plan claimed something the tree does not support, the claim is deleted, not softened.

Notation:
- **`✅ AGENT-FEASIBLE TONIGHT`** — no human credential, console, device, or approval is needed to *do the work and open the PR*. (Merging still needs a human approving review; that is universal and is stated once.)
- **`🔒 HUMAN-GATED`** — requires the owner's hands. Numbered in the human queue.
- **`doneCriteria`** — every line is a command whose exit code or output is the proof. If a criterion cannot be expressed as a command, it was rewritten or deleted.
- **`scoreDelta`** — per-workstream deltas were systematically inflated in all four candidate plans (verdicts flagged 2–3× over-summing). Deltas below are the verdict-corrected values. **Every wave projection in this document is the arithmetic sum of those deltas, computed line by line in the [Score ledger](#score-ledger).** If a checkpoint in the trajectory table disagrees with the ledger, the ledger is right and the table is a bug — an earlier draft of this document carried a headline ceiling of 80.95 that its own deltas did not support, and that is exactly the failure mode this plan exists to prevent.
- **Capture timestamps.** Every figure that depends on the GitHub API or the live GCP/Firebase console — open-PR counts, branch counts, run ids, pass rates, p50/p75/p90 durations, merge throughput, branch-protection JSON, secret presence — was captured **2026-09-01 between 19:30Z and 21:00Z** and is *not* reproducible from a local clone. Those figures are tagged `[live 2026-09-01T~20Z]` where they carry weight. Everything derived from the tree is reproducible against `origin/main 9503b490b0` with the command given.

---

## Scoreboard

### Current (2026-09-01), reproduced from the rubric

| Category | Weight | Score | Weighted |
|---|---:|---:|---:|
| Architecture | 15 | 6.0 | 90.0 |
| Code Quality | 10 | 6.5 | 65.0 |
| Reliability/Ops | 15 | 5.0 | 75.0 |
| Security | 15 | 7.5 | 112.5 |
| Performance/Scalability | 10 | 6.5 | 65.0 |
| Testing/CI/Delivery | 15 | 6.0 | 90.0 |
| Documentation/Maintainability | 5 | 6.0 | 30.0 |
| Overall Professionalism | 5 | 6.5 | 32.5 |
| Launch Readiness | 5 | 4.5 | 22.5 |
| Series A Diligence Readiness | 5 | 5.0 | 25.0 |
| **Total** | **100** | | **607.5 → 60.75 → 61** |

### Trajectory

**Every row below is `60.75 + (cumulative weighted Δ ÷ 10)`, taken from the [Score ledger](#score-ledger) directly beneath it. No row exceeds the sum of its own workstream deltas.**

| Checkpoint | Date | Cumulative weighted Δ | Score | What it assumes |
|---|---|---:|---:|---|
| Now | 2026-09-01 | 0.00 | 60.75 → **61** | — |
| **Morning, all eleven merged** | **2026-09-02 07:00 CDT** | 30.95 | 63.85 → **64** | #2466 merged early, **all eleven** wave-0 PRs approved and merged, no live deploy proof |
| Morning, central expectation | 2026-09-02 07:00 | 13.75–22.00 | **62.1–63.0** | Alberto approves in two sittings, does no console work; the first 4–6 PRs in landing order merge |
| Morning, absolute max | 2026-09-02 07:00 | 42.70 | **65.0** | All eleven merged **and** the owner clears the P-PERF-3 dispatch, GCP items 7–9, the live drill and a verified tag — improbable, see [On 85 tonight](#on-85-tonight) |
| Morning, floor | 2026-09-02 07:00 | 0.00 | **61.0** | Owner asleep — nothing merges |
| End of wave 1 | 2026-09-05 | 66.75 | **67.4** | Deploy lane proven with `deploy-functions` **executed**; breaker enforced; BOLA strict; alert plane green |
| End of wave 2 | 2026-09-19 | 106.25 | **71.4** | Debt ledger, perf contracts, deterministic tests, generated Firestore model |
| End of wave 3 | 2026-10-27 | 138.25 | **74.6** | Rust pricing promoted, composition root, RPC IDL, bus-factor kit — **merged deltas only** |
| End of wave 3, every contingent realized | 2026-10-27 | 158.25 | **76.6** | + all 20.00 weighted points of contingent award. **This is the plan's ceiling.** |
| Honest 85 | **2026-12-08 ±2wk** | — | 85 | + 90 days of green trailing history, a second human with real access, a written scope freeze, a real launch with an evidence bundle. **The remaining ~8.4 points come from none of the 27 workstreams** — they are calendar, headcount and scope. |

### Score ledger

Weights: Architecture 15 · Code Quality 10 · Reliability/Ops 15 · Security 15 · Performance 10 · Testing/CI 15 · Documentation 5 · Professionalism 5 · Launch 5 · Diligence 5. Weighted Δ = Σ (category delta × weight); score Δ = weighted Δ ÷ 10. Every number here is transcribed from a `scoreDelta:` line in this document — grep for them and re-add the column.

**Wave 0 — on merge, in landing order**

| WS | Deltas | Weighted |
|---|---|---:|
| W0-11 | Docs +0.35, Prof +0.15, Dil +0.15, Launch +0.05 | 3.50 |
| W0-6 | Docs +0.20, Rel +0.10, Launch +0.05 | 2.75 |
| W0-1 | Test +0.15, Rel +0.10 | 3.75 |
| W0-12 | Sec +0.10, Test +0.15 | 3.75 |
| W0-2 | Rel +0.15, Test +0.15 | 4.50 |
| W0-3 | Test +0.15, Rel +0.10 | 3.75 |
| W0-8 | Sec +0.10 | 1.50 |
| W0-5 | Rel +0.05 | 0.75 |
| W0-10 | Sec +0.10, Launch +0.10 | 2.00 |
| W0-7 | Test +0.08, Rel +0.05 | 1.95 |
| W0-4 | Rel +0.10, Sec +0.05, Launch +0.05, Dil +0.05 | 2.75 |
| **Wave 0 total** | | **30.95 → +3.095** |

Cumulative in landing order: 3.50 · 6.25 · 10.00 · **13.75 (4 PRs → 62.1)** · 18.25 · **22.00 (6 PRs → 62.95)** · 23.50 · 24.25 · 26.25 · 28.20 · **30.95 (11 PRs → 63.85)**. This is where "central expectation 62–63" comes from; it is not a vibe.

**Waves 1–3 — on merge**

| Wave | Workstreams (weighted) | Total |
|---|---|---:|
| 1 | W0-9 deferred 3.75 · W1-1a 10.00 · W1-2a 2.25 · W1-2b 1.00 · W1-3a 2.25 · W1-4 4.50 · W1-5 2.00 · W1-6 2.55 · W1-7 2.50 · W1-1b\* 5.00 | **35.80** |
| 2 | W2-1 6.25 · W2-2 4.25 · W2-3 4.25 · W2-4a 3.25 · W2-4b 3.00 · W2-5 7.50 · W2-6 2.75 · W2-7 8.25 | **39.50** |
| 3 | W3-1 11.25 · W3-2 8.00 · W3-3 9.00 · W3-4 3.75 | **32.00** |
| **On-merge total, all four waves** | 30.95 + 35.80 + 39.50 + 32.00 | **138.25 → +13.825 → 74.58** |

\* **W1-1b's own header says wave 2, not wave 1.** Its 5.00 is booked in the wave-1 row here only because it sits under the W1-1 heading. Booked at its true wave, wave 1 is 30.80 (→ 67.0) and wave 2 is 44.50 (→ 71.4); the wave-3 total is identical either way. The coverage table's `1→2` cell for F12 reflects the true wave.

**Contingent awards — not counted in any row above**

| Source | Award | Weighted | Unlocked by |
|---|---|---:|---|
| W0-2 | Rel +0.25 | 3.75 | `app-pr-gate` P-PERF-3 dispatch passing with real samples |
| W0-2 | Test +0.15 | 2.25 | `nightly-health.yml` producing two consecutive green scheduled runs on main (wave 1) |
| W0-5 | Rel +0.25 | 3.75 | human queue items 7–9 (WIF verifier SA + billing budget) |
| W0-6 | Launch +0.15 | 0.75 | the live staging rollback receipt (human queue item 15) |
| W0-8 | Sec +0.20, Dil +0.10 | 3.50 | first verified tag release (human queue item 14) |
| W1-2a | Sec +0.15 | 2.25 | `deploy-functions` succeeds **and** the console API-key restriction lands |
| W1-3a | Sec +0.25 | 3.75 | human queue item 20 (production Remote Config epoch gate after soak) |
| **Total contingent** | | **20.00 → +2.000** | |

Realizable **tonight**, at least in principle: W0-2 P-PERF-3 (3.75) + W0-5 items 7–9 (3.75) + W0-6 live drill (0.75) + W0-8 verified tag (3.50) = **11.75**, giving the 65.0 absolute-max row. The W0-2 nightly-health trailing award needs two nights and the W1-\* awards need wave-1 code, so neither can land before 07:00.

**Grand total, every delta and every contingent realized: 158.25 weighted → +15.825 → 76.58 → 76.6.**

### Reconciling the three ceiling analyses

Three independent estimators landed at **67.8**, **65.0**, and **64.0** for 07:00 tomorrow.

- All three agree the **floor is 61.0** with no human approval, for the same reason: `required_approving_review_count=1`, `enforce_admins=true`, three human collaborators, and Codex only ever *comments*.
- The 67.8 branch requires the owner to work the full 11-hour window on GCP console, both environment approvals, a release tag, and a live rollback drill. The deploy lane has failed on **every** tag through `v1.0.40+repair.37`, and the `production` environment carries a required reviewer **plus a wait timer** — so a green tag deploy concluding inside the window is improbable, not merely optimistic.
- The 64.0 branch is derived from measured throughput: PR-gate p50 68 min with a **46.8% terminal pass rate** (58 success / 66 failure / 72 cancelled over 200 runs), so ~2.1 attempts and 2.5–3 h of wall clock per PR before review.

**The number this plan commits to is 63.85 (→ 64 rounded), and only if all eleven wave-0 PRs merge**, with **62–63** as the expectation because 4–6 is the historical throughput. Anything above 64 requires an event outside the night's control; anything at 61 means the approval gate never opened. Note the two words are not interchangeable: 64 is the **all-merge case**, 65.0 is the **absolute bound** if the owner also clears the console queue, and the earlier draft's phrase "honest ceiling 64" conflated the two. Where this document says *ceiling* it now means the arithmetic bound of the ledger, never the expected value.

---

## On 85 tonight

**85 tonight is not reachable. Here is the arithmetic.**

- 61 = **607.5** weighted points. 85 = **850**. The gap is **+242.5**.
- Total remaining headroom across all ten categories, taking every score to a perfect 10, is **392.5** points.
- So 85 tonight means capturing **61.8% of all remaining headroom in eleven hours.**
- For scale: summing **every** `scoreDelta` in the full four-wave plan — 27 workstreams, all 35 findings, ~1,600 agent-hours over eight weeks — yields **138.25 weighted = +13.83 = 74.6**, or **158.25 weighted = +15.83 = 76.6** if every contingent award is also realized. **The complete remediation plan does not reach 85 — it falls 8.4 points short.** Asking for 85 by morning asks for more than two months of the best available plan, in one night, and then some. *(An earlier draft of this section claimed 80.95. That figure did not reproduce from the document's own deltas; it has been replaced by the [Score ledger](#score-ledger), which does. The conclusion is unchanged and the gap is larger, not smaller.)*

**Why the biggest pools cannot move at any spend:**

- **Architecture (weight 15, 60 of the 392.5 available points) moves +0.0 tonight.** Its five findings are F10 (Rust promotion, 320 h, human-gated attestation), F19 (composition root, 320 h), F29 (RPC IDL, 110 h), F30 (mission consolidation, 130 h), F31 (Firestore model, 60 h) — 940 agent-hours, and F10/F19/F29/F30 are all marked `agentFeasibleOvernight: false`.
- **Reliability/Ops and Testing/CI are scored on observed time series, not on the current commit.** `app-pr-gate.yml` on main is 12 failure / 5 success over its last 17 runs. The last successful production `deploy-functions` job was run `27775189384` on **2026-06-18 — 75 days ago**. One green deploy at 03:00 does not rewrite a trailing window. There is no honest way to buy history.
- **Performance is gated on a 304 MB asset removal whose only proof is a Mac app build**, which by standing policy is nightly and not a merge ticket. It cannot be proven before 07:00.
- **Launch Readiness (4.5) and Series A Diligence (5.0)** are capped at 5.5 and 6.1 respectively *even after the entire plan*, because they key on an actual commercial launch, a second human being, and a scope decision.

**And the way to "hit 85" tonight is available, which is exactly why it must be named and refused.** Every one of these scores **zero**:

- raising `OPENBURNBAR_APP_TEST_ATTEMPTS`, or keeping the 4-attempt retry loop so one pass in four reads as green
- `continue-on-error` or `timeout-minutes` raises on the four 0-for-20 nightlies
- dropping `Analyze (swift)` from `codeql.yml` instead of fixing the Metal toolchain
- raising `.swiftlint.yml` `file_length` (precedent exists: it was already raised 5,950 → 6,130 to accommodate growth)
- adding `budgets/*.json` entries, or `known-red-named-blocker` labels applied in bulk
- removing the seven "missing" contexts from `governance/burnbar-ci-gate.json` `required_contexts`
- relaxing or removing the OSV gate instead of bumping the dependency
- using the ruleset bypass actor to merge around the queue while the merge-result OSV check is red
- satisfying the review gate with a `cursor[bot]` approval (the constraints declare explicitly this is **not** approval evidence)
- an agent approving PRs with Alberto's `gh` token
- editing the rubric or its weights

Most of these are caught by `scripts/ci/check-no-suppressions.sh`, which fails closed. All of them are found by a diligence engineer diffing the workflows in the first hour — and the source report already names *"green dashboards over a red system"* as its second alarm. **A faked 85 tonight is a real 55 next week.**

### The most aggressive honest alternative — run this tonight

In priority order, highest real points per human minute first. **Gains are transcribed from the [Score ledger](#score-ledger) and sum to exactly the wave-0 total of 30.95 weighted (+3.095), not above it.**

| # | Action | Owner | Cost | Weighted | Score Δ |
|---:|---|---|---|---:|---:|
| 0 | **Approve + merge #2466.** Nothing on this list can land until it does. | Alberto | 2 min | — | unblocks everything |
| 1 | **Open every agent PR from a bot/app identity, not `Ajnunezg`.** Removes the self-approval deadlock at zero cost. | agents | 0 | — | unblocks everything |
| 2 | **W0-6 + W0-11** — runbook topology truth, data-room index, root inventory ratchet, generated release-status block. ~21 agent-hours, cheapest CI, highest odds of merging. | agents | 21 h | 6.25 | +0.625 |
| 3 | **W0-1** — main compiles again. Prerequisite for interpreting every nightly. | agents | 5 h | 3.75 | +0.375 |
| 4 | **W0-12** — BOLA strict-gap ledger. Test-only, no Mac dependency, attacks the largest remaining deduction in a weight-15 category. | agents | 16 h | 3.75 | +0.375 |
| 5 | **W0-2** — nightly + deploy-lane honesty. Biggest single testable lever; costs Alberto **three** actions (human queue items 5, 6 and 28 — *not* one, see W0-2). | agents | 34 h | 4.50 | +0.450 *(+0.600 contingent)* |
| 6 | **W0-3** — circuit breaker in observe mode; delete the false-negative acceptance path. Book **no** score for enforce until it flips in wave 1. | agents | 12 h | 3.75 | +0.375 |
| 7 | **W0-8 + W0-5** — supply-chain truth and the WIF alert-plane job. Both land honest reds where reds are true. | agents | 26 h | 2.25 | +0.225 *(+4.50 weighted contingent)* |
| 8 | **W0-10** — CodeQL Swift. Start early, let it iterate in the background, let it gate nothing. Closes the only one of six launch blockers an agent can fully close. | agents | 8 h | 2.00 | +0.200 |
| 9 | **W0-7** — toolchain pins. **Last**, because it touches every workflow and will need a rebase after the others land. | agents | 9 h | 1.95 | +0.195 |
| 9b | **W0-4** — the deploy-lane ancestor guard, stacked onto #2349. Omitted from the earlier draft of this table even though it carries a `scoreDelta`. | agents | 4 h | 2.75 | +0.275 |
| — | **All eleven agent PRs merged** | | | **30.95** | **+3.095 → 63.85** |
| 10 | **Human ops sitting**, in order: **dispatch `codex-nightly-ci-repair` (item 28) BEFORE setting `OPENAI_API_KEY` (item 5)** → cancel the stuck ops-plane run → create the WIF verifier SA + repo vars → create the Cloud Billing budget → decide the domain-core candidate policy → environment approvals + tag → one staging rollback drill. | Alberto | 2–4 h | ≤ 11.75 | ≤ +1.175 → 65.0 |

**Launch blocker #4 is closed by decision, not by fix.** The source report (`FABLE-DILIGENCE_REPORT_2026-09-01.md:106-118`) lists six launch blockers, and #4's stated fix shape is *"put `xcodebuild build` (not tests) of the app target into the merge door"*. This plan **refuses that fix** on CHEAP_FAST grounds (a 27-minute Mac compile on every merge candidate) and recommends closing PR #2405, which implements it (human queue item 3). The substitute is W0-3's main-red circuit breaker: it does not compile the app at PR time, it reads the *already-paid* push-to-main `app-pr-gate` verdict and refuses to merge on top of a red main. **A re-scoring reviewer applying the report's own checklist will still count blocker #4 open, and that is correct** — the plan buys the same protection by a different mechanism and does not claim the blocker closed. Of the six, exactly one (#Swift SAST, via W0-10) is closed by engineering tonight; four are human-gated (queue items 8–15); this one is a product decision recorded here so it is never silently re-scored as done.

### The shortest real path to 85, with a date

| Milestone | Date | Why it is the critical path |
|---|---|---|
| Merge queue unwedged; wave 0 landed | 2026-09-02 | One human click plus one night |
| Deploy lane proven with `deploy-functions` **executed**; alert plane green; rollback drilled | 2026-09-08 | Three of six launch blockers; needs GCP IAM + a tag + a drill, all owner-only |
| **Second human named with real GCP/Firebase/ASC/GitHub-admin/Sentry access** | 2026-09-08 | Single largest non-engineering lever. Series A Diligence cannot pass ~6.5 with bus factor 1, and Reliability/Ops cannot pass ~7.5 with no on-call rotation. Costs one afternoon; no agent can do any part of it. |
| **Written scope freeze** — name the core (Mac + daemon + extension + one cloud plane), mark other surfaces experimental in the README support-tier table | 2026-09-08 | The only lever that moves Architecture without spending F10/F19/F29/F30's 940 agent-hours. The report calls it the single change most likely to make the next 12 months accelerate. |
| Waves 1–2 complete | 2026-09-19 | **71.4** (73.4 with every contingent through wave 2 realized) |
| Wave 3 complete — Rust pricing promoted with legacy deleted, composition root, typed RPC IDL | 2026-10-27 | **74.6 on merged deltas; 76.6 with every contingent. This is the plan's ceiling.** |
| History rewrite (`git filter-repo`, 8.62 GiB pack → <1 GiB) in one announced window | 2026-11-03 | Needs `allow_force_pushes` lifted, tag rulesets relaxed, and all open PRs landed or closed first |
| Real launch + `launch-evidence/final-launch-evidence.json` | 2026-11-17 | Launch Readiness is capped at 5.5 by engineering alone |
| **90 days of green trailing history** for Ops and Testing | **2026-12-08** | **Binding constraint.** These categories score the observed window, so the number moves as the red runs age out. Calendar time and nothing else. |

**Earliest defensible 85: 2026-12-08, ±2 weeks.**

If the deadline is genuinely immovable, change the **deliverable**, not the number. What survives contact with a real reviewer at 07:00 is a signed status memo: *"61 → 63, here are the ten landed commits, here are the six blockers that are mine and the dates I will clear them."* A diligence team scores that founder **higher** than one who presents 85 and cannot reproduce it — the report already credits this repo's honest self-audits as one of its eight genuine strengths.

---

## The two hard gates tonight

### Gate 1 — the merge queue is wedged, right now

`OSV Scanner (open source vulnerabilities)` is a required context. It passes on main's push event but fails on **every** merge group because of a newly published advisory (GHSA-w9m9-85wc-3x92, `postcss-selector-parser`). Both merge_group "BurnBar CI Gate" runs today (19:37Z, 20:15Z) died in ~60 s on it.

PR **#2466** fixes it, is `MERGEABLE`, has 132 checks green and zero failing, and is authored by `app/cursor` — so Alberto's own approval is valid. `mergeStateStatus=BLOCKED`, `reviewDecision=REVIEW_REQUIRED`.

```bash
gh pr review 2466 --approve && gh pr merge 2466 --merge
```

**Until this lands, tonight's score at 07:00 is 61.0 exactly.**

### Gate 2 — one human's approval finger is the throughput ceiling

Live protection on `main` (verified via `gh api`, `[live 2026-09-01T~20Z]` — re-run `gh api repos/Imagine-That-Ai/BurnBar/branches/main/protection` before acting on it):

```
required_approving_review_count = 1     dismiss_stale_reviews  = true
require_code_owner_reviews      = false require_last_push_approval = false
strict                          = true  enforce_admins         = true
required_linear_history         = true  required_conversation_resolution = true
allow_force_pushes              = false allow_deletions        = false
10 required contexts
```

Collaborators: `Ajnunezg` (admin), `emilio3435` (push), `Lionsfan4` (push). All human. `chatgpt-codex-connector` **comments only** — `gh api .../requested_reviewers` returns 422 and Codex has never approved anything.

Two structural consequences the plan is built around:

1. **GitHub forbids self-approval.** An `Ajnunezg`-authored PR needs a *third* person at 02:00. **Therefore: every agent PR tonight is opened from a bot/app identity** (as #2466 already is), so Alberto alone can clear the night.
2. **`dismiss_stale_reviews=true` + `strict=true`** means every merge into main invalidates every other PR's approval and forces a rebase. With a 46.8% terminal pass rate, budget ~2 approval actions per PR. This is why W0-0 caps ready-at-once at 3.

### Measured throughput, for planning

**All six rows are `gh`-API captures, not tree facts. Capture window: `[live 2026-09-01T19:30Z–21:00Z]`. None is reproducible from a local clone; re-capture before relying on them, and treat drift as expected, not as a contradiction.**

| Metric | Value | Source | Captured |
|---|---|---|---|
| PR "BurnBar CI Gate" p50 / p75 / p90 | 68 / 81 / 170 min | last 200 pull_request runs | `[live 2026-09-01T~20Z]` |
| PR gate terminal pass rate | 46.8% (58 / 66 / 72 success/fail/cancel) | same | `[live 2026-09-01T~20Z]` |
| merge_group gate median | 18.9 min over 31 successes | same | `[live 2026-09-01T~20Z]` |
| Merge queue capacity | `max_entries_to_build=5`, `max_entries_to_merge=5`, `ALLGREEN`, `min_entries_to_merge_wait=0` | ruleset 19396995 | `[live 2026-09-01T~20Z]` |
| Merges per 19:00→07:00 window, last 20 nights | mean 4.7, median 4, max 11 | `gh` history | `[live 2026-09-01T~20Z]` |
| Hosted macOS concurrency | 5 slots, shared repo-wide | GitHub plan limit for this public repo | `[live 2026-09-01T~20Z]` |

**The other load-bearing live figures, all captured in the same window and all unreproducible offline:** 92 open PRs (63 authored by `Ajnunezg`) · 1,798 remote branches (652 `codex/`, 327 `preserve/`, 198 `fix/`, 85 `windows/`) · 69 `+repair` tags · `app-pr-gate` 12 failure / 5 success over its last 17 main runs · `deploy-functions` last success run `27775189384` on 2026-06-18 · run ids `33480049007`, `33481246108`, `33432321267`, `33517666151`, `33326737617`, `33522206852` · the branch-protection JSON in Gate 2 · #2466's state, mergeability and `app/cursor` authorship · the absence of `OPENAI_API_KEY` and `OPS_PAGING_SLACK_WEBHOOK` from repo secrets. Every one of these was checked once, by one query, at one moment. Anything derived from the **tree** — context counts, file sizes, symbol counts, line numbers — carries its reproducing command instead and holds against `9503b490b0` indefinitely.

**Free 5× on the queue leg, never once used:** all 40 sampled merge groups are single-PR `pr-<N>-<sha>` branches purely because arrivals were serialized. W0-0 batches low-risk PRs in groups of up to 5. `ALLGREEN` means one red PR sinks its whole group, so risky PRs still go alone.

### Gate 3 — macOS runner concurrency is the night's other hard ceiling

The public repo has **5 concurrent hosted macOS jobs**, shared with the merge queue's own Daemon PR Gate, the `ci-cache-warm` cron and the five nightlies. Three wave-0 workstreams draw on the same pool at the same time, and the earlier draft of this plan reserved nothing:

| Draw | Job shape | Slots × minutes | Window |
|---|---|---|---|
| W0-10 | CodeQL Swift, `macos-26`, 3–4 dispatch cycles at 60–120 min | 1 × 240–480 | continuous, background |
| W0-2 (e) | `app-pr-gate.yml` dispatch: `AgentLens Rust + Swift prerequisites` (90-min budget) + `Mobile build + unit test` (120-min budget), ×2 dispatches | 2 × 110–140 each | two windows |
| W0-1 | local cold `xcodebuild build-for-testing` on Alberto's own M5 Max | 0 hosted (local) | 30–60 min |
| Nightlies | `openburnbar-pr-harness` 08:37Z, `codeql` 09:17Z, `app-pr-gate` 09:17Z, `linux-nightly` 10:17Z, `ci-cache-warm` | up to 5 | 08:30–11:00Z = **03:30–06:00 CDT** |

**Reservation policy, owned by the W0-0 sequencer and enforced in `.agent/runs/wave0-landing-order.json` under a `macosBudget` key:**

1. **At most 2 of the 5 slots are ever held by wave-0 work.** Three stay free for the merge queue's Daemon PR Gate, or the queue wedges behind our own dispatches.
2. **W0-10 owns slot 1 for the whole night** and starts first (22:00 CDT). It gates nothing, so a queued run costs nothing but wall clock.
3. **W0-2 (e) owns slot 2** and dispatches **at most twice**, both before 03:00 CDT.
4. **Nothing wave-0 dispatches into 08:30–11:00Z.** The five nightlies own the pool in that window; a dispatch there evicts the very runs W0-2's scoreboard is supposed to report on.
5. **W0-1's compile proof is local, not hosted** — it consumes zero hosted macOS slots, which is the entire reason wave-0 gate item 2 reads the free push-to-main lane instead of dispatching one.

**Reconciling W0-2 (e) with CHEAP_FAST.** Wave-0 gate item 2 refuses to dispatch a 180-minute macOS lane *to manufacture a compile receipt*. W0-2 (e) dispatches `app-pr-gate.yml` for a different reason: it is the **only** executor of the `proc_pidinfo` idle-CPU measurement that P-PERF-3 needs, the step has failed five consecutive nightlies, and the dispatch is the root-cause repair loop, not evidence theatre. The two are distinguishable by a rule the sequencer applies: **a Mac dispatch is allowed when it is the only way to observe a failing measurement, and forbidden when a free scheduled lane would produce the same receipt later.** If W0-2 (e) cannot get a green P-PERF-3 inside its two dispatches, it parks `OPEN_WITH_NAMED_BLOCKER: P-PERF-3 root cause unresolved`, forfeits the +0.25 Reliability contingent, and does **not** buy a third dispatch. *(W2-4's alternative — one dispatched `burnbar-turbo.yml` run on the owner-authorized ephemeral group — is the wave-2 path and is explicitly not available tonight.)*


---

## Human queue

Post this verbatim as one GitHub issue titled **`Ops unblock queue 2026-09-02`**, with checkboxes. **30 items.** Items are ordered by *what unblocks the most per minute of your time*, with two hard ordering constraints: **item 28 must be done before item 5** (setting `OPENAI_API_KEY` makes item 28's evidence permanently unproducible), and **item 30 must not be started before W3-1-M0 lands**. Nothing in this list can be done by an agent — every one is on the `humanOnly` list (secrets, environment approvals, branch protection, GCP/Firebase console, signing, force-push, App Store).

### Batch A — tonight, before you sleep (~5 minutes total)

**1. Approve and merge PR #2466.** *Blocks: literally everything.*
```bash
gh pr review 2466 --approve && gh pr merge 2466 --merge
```
~2 min. Authored by `app/cursor`, so your approval is valid. Watch `gh-readonly-queue/main/pr-2466-*` for the queue's own run.

**2. Confirm the bot-identity decision.** Reply `ok` on the wave-0 tracking issue confirming agent PRs are opened from a bot/app identity so you can approve them yourself. If you would rather they come from `Ajnunezg`, say so and name who is awake to approve (emilio3435 / Lionsfan4). ~1 min.

**3. Decide open PR #2405 (`ci(macos): compile the app at PR time — macOS App Compile Gate`).** Recommend **CLOSE**: a 27-minute Mac compile on the merge door directly contradicts CHEAP_FAST, and W0-3's observe-first circuit breaker is its cheap replacement. Night shift must not close your PR.
```bash
gh pr close 2405 --comment 'Superseded by the main-red circuit breaker (W0-3) — CHEAP_FAST keeps the Mac build off the merge door.'
```
~2 min.

### Batch B — first sitting tomorrow (~30 minutes)

**4. One-sitting approval pass on wave-0 PRs.** After Codex review lands on each.
```bash
gh pr list --label factory-review --json number,title,reviewDecision,mergeStateStatus | jq
# then per PR:
gh pr review <n> --approve
```
Approve → merge → approve. Every merge dismisses the others' approvals (`dismiss_stale_reviews=true`), so serialize. ~20 min for 5–6 PRs.

**28. Dispatch `codex-nightly-ci-repair.yml` from your own account — DO THIS BEFORE ITEM 5.** *Satisfies wave-0 exit gate item 3b.* `codex-nightly-ci-repair.yml:169-186` sets `safe=true` on a `workflow_dispatch` **only** when `repos/{repo}/collaborators/{sender}/permission` returns `admin|maintain|write`. No agent token clears that check, so this is yours and nobody else's; the earlier draft assigned it to nobody.
```bash
gh workflow run codex-nightly-ci-repair.yml --ref ci/ops-honesty-20260901
gh run list --workflow codex-nightly-ci-repair.yml -L1 --json conclusion,url
# expected: conclusion=failure, job summary contains ::error::OPENAI_API_KEY missing
```
**Ordering is load-bearing and was previously unstated:** the criterion asserts the error *"OPENAI_API_KEY missing"*, so **the moment item 5 sets that secret this dispatch can never produce it again.** Item 28 first, item 5 second. If you set the secret first, gate item 3b is unsatisfiable for the rest of the night and the correct outcome is `OPEN_WITH_NAMED_BLOCKER: fail-closed dispatch not observed (secret set first)`, not a re-run. ~2 min.

**5. `gh secret set OPENAI_API_KEY`.** ***Run item 28 first.*** The `codex-nightly-ci-repair` bot has silently no-op'd since June. After W0-2 it reports **honestly red** until this exists — that red is the correct signal, not a regression. ~2 min.

**6. Confirm `OPS_PAGING_SLACK_WEBHOOK`.** It is absent from the repo Actions secrets, so `ops-failure-issue` opens issues but pages nobody and only warns. Either add it or confirm issue-only paging is acceptable. ~2 min.

**7. Cancel the stuck ops-plane runs.** Scheduled run `33432321267` (created 2026-08-31 19:45:39Z) is still `pending` with **0 jobs**, holding concurrency group `ops-plane-verify` with `cancel-in-progress: false`. That is why every `pull_request` run since 2026-08-25 was cancelled with zero jobs.
```bash
gh run cancel 33432321267
gh run list --workflow ops-plane-verify.yml --status pending    # cancel any others
gh run cancel 30815516424 31379382090 32020520695 33419353759   # waiting ops-confidence approvals
```
> *Correction carried from the judges:* the winner plan cited run `30831297265`; the live pending run is `33432321267`. Query rather than trusting either id. ~3 min.

### Batch C — the GCP sitting (~45 minutes, needs your gcloud + billing IAM)

**8. Create the read-only ops verifier service account and bind it to WIF.** *Blocks: W0-5, W2-4.*
```bash
gcloud iam service-accounts create ops-verifier --project burnbar
for R in roles/monitoring.viewer roles/billing.viewer roles/logging.viewer roles/iam.securityReviewer; do
  gcloud projects add-iam-policy-binding burnbar \
    --member serviceAccount:ops-verifier@burnbar.iam.gserviceaccount.com --role "$R"
done
gcloud iam service-accounts add-iam-policy-binding ops-verifier@burnbar.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member 'principalSet://iam.googleapis.com/<POOL>/attribute.repository/Imagine-That-Ai/BurnBar'
gh variable set OPS_VERIFY_WIF_PROVIDER   # copy from the existing GCP_WORKLOAD_IDENTITY_PROVIDER secret
gh variable set OPS_VERIFY_SERVICE_ACCOUNT --body ops-verifier@burnbar.iam.gserviceaccount.com
```
W0-5 commits `governance/ops-plane-verifier-sa.json` with the exact role set and pool binding, so this is copy-paste. Do **not** rotate/delete `GCP_SA_KEY` until the WIF verify has one green scheduled run.

**9. Create the Cloud Billing budget.** Needs `roles/billing.admin`. W0-5 ships `scripts/ops/create-billing-budget.sh` with a `--dry-run` that prints the exact gcloud commands first.
```bash
bash scripts/ops/create-billing-budget.sh --dry-run   # read it
bash scripts/ops/create-billing-budget.sh
gh secret set OPS_ALERT_CHANNELS   # currently exists nowhere, so `apply` can never run
```
No `google_billing_budget` / `billingbudget` reference exists anywhere in the repo today. ~15 min.

**10. Browser API key + App Check.** *Blocks: W1-2a.*
- Console → APIs & Services → Credentials → the `AIzaSy…` browser key → set HTTP-referrer restrictions (`burnbar.ai`, `app.burnbar.ai`, `localhost`) and API restrictions (Identity Toolkit, Firestore, Functions, App Check).
- Firebase → App Check → confirm **enforcement is ON** for Cloud Functions, Firestore, Storage.
- Firebase → Authentication → **enable the Anonymous sign-in provider** for project `burnbar`. `signInAnonymously` appears nowhere in `website/` or `apps/console/` today, so this is unproven-off, not merely unconfigured.
- Create a dedicated OpenRouter provisioned key with a hard USD limit; `firebase functions:secrets:set`.

> *Correction from the W1-2 verdict:* **do not** register a new reCAPTCHA Enterprise / Turnstile key. `website/src/lib/firebaseClient.ts:26-27,43` already ships site key `6Ld3bAkt…` and already calls `initializeAppCheck` with `ReCaptchaEnterpriseProvider`; `website/scripts/update-csp-hashes.mjs:122-129` already allowlists the recaptcha origins. The winner plan gated W1-2 on a prerequisite that already exists.

~20 min.

### Batch D — the deploy lane (~1 hour, and it may not conclude in one sitting)

**11. Recover the prod-ahead-of-main functions source.** *Blocks: the whole deploy proof.*
The winner plan's "PR A" cannot exist: `git diff origin/main origin/feat/cross-platform-bug-reporting -- functions/src` is **empty**, PR #2457 is already merged as `0b56358b5d`, and the #2195 postmortem records that the CLI deploys *"match the working-tree state"* — i.e. your **uncommitted local tree**. It exists on no branch and in no worktree.

On the Mac that ran the 2026-09-01 06:52Z `firebase deploy`:
```bash
git -C <checkout> status functions/src
git -C <checkout> add functions/src && git commit -m 'feat(functions): land CLI-shipped production deltas'
git -C <checkout> push both HEAD
```
Or hand over the deployed bundle:
```bash
gcloud functions describe rebuildUsageRollups --gen2 --region us-central1 \
  --format='value(buildConfig.source.storageSource)'
```
Until this lands, deploying main **regresses live production fixes**. The ancestor guard in W0-4 is the mechanical protection; it will trip on the first tag deploy because production was deployed from an unstamped working tree, so an `allow-regression` receipt must be committed once. ~20 min.

**12. Decide the domain-core candidate policy.** The activation candidate `c292cc99` (2026-08-11) no longer byte-matches main's 322-file control-plane manifest, so no tag can pass `verify-domain-core-control-plane.mjs`. Choose:
- **(a) Fresh activation ceremony** — freeze the release train, merge a fresh candidate, wait for a green `domain-core.yml` push run, dispatch the signer. *(Recommended: it is the documented path and survives `docs/runbooks/shared-rust-legacy-deletion.md:95`.)*
- **(b) Policy-versioned manifest digest** — a schemaVersion-3 manifest with an explicit `policyVersion` and a committed policy/incidental path partition. This needs an ADR and is a spike, not a merge candidate.

> *Correction from the W0-4 verdict:* the winner plan's PR B ("attest the manifest sha256 as a second subject, accept a candidate whose attested digest equals the committed digest") is **logically inert** — `verify-domain-core-control-plane.mjs:299` (committed manifest == trusted-main digest) together with `:302` (candidate file == trusted-main digest) already requires the committed manifest to equal the trusted-main digests, and the manifest is regenerated on every control-plane edit. It restates the existing byte-match. Do not implement it as written.

~15 min of decision.

**13. Approve the environments and cut the tag.** You are the sole required reviewer on both.
```bash
gh workflow run domain-core-promotion-proof.yml --ref main -f candidate_commit=<sha>
# approve the domain-core-promotion environment prompt in the Actions UI
git tag v1.0.40+repair.38 && git push both v1.0.40+repair.38   # or v1.0.40-hotfix.1 once W1-5 lands
# approve the production environment prompt for deploy-production
gh run watch
```
**Warning:** `deploy-firestore.yml:50` also declares `environment: production` with a required reviewer **and a wait timer**, so an index deploy blocks on you overnight. Deploy Firestore indexes **before** any tag that ships a query needing them, or the hourly reaper throws `FAILED_PRECONDITION` in production. ~20 min plus wait.

**14. Fix the Release Preflight first.** `release.yml` has failed at *Release Preflight* on the last six tag pushes (`v1.0.40+repair.35/.36/.37` plus two dispatches), which is why the last 8 `supply-chain-provenance` runs are `skipped`. W0-8's provenance fix can only be exercised by a *successful* release. ~unknown; triage needed.

### Batch E — the rollback drill (~20 minutes, needs authenticated gcloud)

**15. Run one live rollback drill on `burnbar-staging`.** `COMMERCIAL_ROLLBACK.md:219` mandates a quarterly drill; none has ever been recorded.
```bash
gcloud auth list
gcloud projects get-iam-policy burnbar-staging   # confirm run.revisions.list
bash scripts/ops/rollback-revision.sh <service> --project burnbar-staging --drill \
  --receipt launch-evidence/rollback-drill-$(date +%F).json
node scripts/security/check-public-evidence-redaction.mjs   # receipt must pass STRICT redaction
```
W0-6 ships the `--drill` mode, the receipt schema, and a **fixture-only** dry-run committed as `launch-evidence/rollback-drill-<date>.fixture-dry-run.json` with `"mode":"fixture","liveDrill":false`. The agents' receipt is explicitly **not** rollback evidence — `docs/TECHNICAL_READINESS.md` says PENDING until you run this. ~20 min.

### Batch F — product and posture decisions (reply on the PR, ~2 min each)

**16.** Truthful README status line, and whether to cut `windows-v1.0.40`. (W1-5) — W1-5a is **blocked** until you author `docs/status/release-status.input.json` with the non-derivable store fields (`macAppStoreReviewState`, `iosReviewState`, `manualReleaseEnabled`, `windowsChannelClaim`), because no repo file encodes Apple review state.
**17.** Trust-root recovery factor (recovery code / passkey / both) and cooling-off window length. (W1-3)
**18.** Ratify or reject an ADR reversing the deliberate no-zod decision recorded at `functions/src/validation/callableSchema.ts:19`. If rejected, F12 is satisfied by driving the existing dependency-free `parseCallableInput` from 9 to 113 sites. (W1-1b)
**19.** R2 bucket prefix + an Ed25519 manifest-signing key for the pet asset pack. (W2-6) `gh secret set PET_ASSET_SIGNING_KEY`; R2 prefix via the Cloudflare dashboard.
**20.** Enable the trust-root epoch gate in **staging** Remote Config, then production, after a soak. (W1-3)

### Batch G — weeks 3–8, admin-only and irreversible

**21.** Sign off `docs/audits/branch-prune-manifest.json` and enable `delete_branch_on_merge` (currently `false`, admin-only). 1,798 remote heads (652 `codex/`, 327 `preserve/`, 198 `fix/`, 85 `windows/`). Agents deliver per-prefix counts and a proposed policy; mass deletion is yours.
**22.** Decide the `git filter-repo` history purge. Pack is **485,241 objects / 8.62 GiB**; `.git` is 9.9 GB. Requires lifting `allow_force_pushes`, the v*/linux-v*/windows-v* tag rulesets, and re-basing every open PR. Agents deliver the decision packet from a throwaway `--mirror` clone; the rewrite is a scheduled, announced outage.
**23.** **Name a second human** with real GCP / Firebase / App Store Connect / GitHub-admin / Sentry access, put break-glass credentials in a shared vault, and enable `require review from Code Owners`.
> **Warning before you enable code-owner reviews:** `.github/CODEOWNERS` currently puts `@Ajnunezg @emilio3435` on `*`. Flipping `require_code_owner_reviews=true` today would demand emilio3435 (4 commits, 0 merged PRs in 30 days, though 17 PRs reviewed since 2026-08-01, latest #2318 on 08-18) on **all 92 open PRs** and wedge the entire door.
**24.** **Reconcile the live branch-protection drift.** `governance/branch-protection.main.json` says `require_code_owner_reviews=true`, `require_last_push_approval=true`, `check_response_timeout_minutes=300`, 7 contexts; live says `false`, `false`, `90`, 10 contexts. `node scripts/ops/check-branch-protection-drift.mjs` exits **1** today with `[CRITICAL] enforceAdmins desired=true live=false` and `[CRITICAL] bypass actors ADDED live (must be zero): ["User:125839313:always"]`, and `docs/SOLO_OPERATOR_POLICY.md` asserts the opposite of live state. Agents may only *document* the drift; changing either side is yours.
**25.** Install the Mend Renovate GitHub App if toolchain bump PRs are wanted. Dependabot cannot bump `.nvmrc`, `rust-toolchain.toml`, `global.json`, or `.xcode-version`, and Renovate has no Xcode manager. (W0-7)
**26.** Provision a GitHub App or fine-grained PAT (`FACTORY_BOT_TOKEN`) so auto-revert PRs opened by a workflow actually trigger CI. A `GITHUB_TOKEN`-opened PR triggers nothing. (W1-7)
**27.** Grant `roles/monitoring.metricWriter` if the `deploy/age_days` custom metric is wanted (deferred to wave 2; it contradicts a viewer-only verifier identity, so it needs its own identity).

*(Item 28 is in Batch A above — it must run before item 5.)*

### Batch H — the two owner dependencies that had no queue number

**29. Land or abandon the `feat/living-glass-sweep` media diffs. *This is the only thing that will ever close F18.*** That branch is 45 behind main with **210 dirty paths**, and the entire bitrate-clamping ladder F18 describes (`BitrateController` +54, `VideoEncoder` +52/−16, `MediaSessionCoordinator` +17, plus `MediaGOP.swift` and `MediaBweFeedbackPayload.swift`, which do not exist on main at all) lives **only** in that uncommitted working tree. W2-3b is `needsHuman: true` on exactly this and no agent may touch the tree. Choose one:
- **(a) Land it.** From the machine holding that worktree: review `git status --porcelain`, split the media hunks from the rest, and open a PR from a fresh branch. Agents can then rebase W2-3b onto it.
- **(b) Abandon it.** Say so, and W2-3b is re-planned as a from-scratch bounded-frame-budget implementation on `origin/main` with no reference to the dirty tree — roughly 3× the hours and a different design review.

Until you answer, **F18's only mapped workstream cannot start**, and the honest status of F18 in the coverage table is `BLOCKED-ON-OWNER`, not "covered". *(W2-3a's `ScreenCapturePipeline` bounded-AsyncStream change is clean against main and proceeds regardless — it is credited to F18 in the coverage table as the partial that ships without you.)* ~20 min to decide, ~1 h to split if (a).

**30. Approve the domain-core protected attestation and cut the three signed releases. *The only thing that closes F10.*** W3-1's entire delta is gated behind three actions no agent can perform, and the earlier draft left this 🔒 cell unnumbered:
- (a) approve the protected attestation via `domain-core-promotion-proof.yml` (the `domain-core-promotion` environment names you as sole reviewer);
- (b) cut signed releases for **apple, linux and functions** — the three consumers `verify-domain-core-legacy-deletion.py:195-215` actually governs for `pricing.token_cost` — so schema-v2 release predicates exist;
- (c) sign the `deletionReview` receipt.

**Prerequisite, and it is not yours:** W3-1-M0 must land first — the root cause of `"reason": "release_train_advanced_before_stable_receipt"` in `config/domain-core-legacy-deletion-receipts/pricing.token_cost/3/annulment.json`. Approving an attestation before M0 buys generation 4 of the same annulment. Wave 3, not tonight; listed here so F10's dependency has an owner and a number. ~1 h across two sittings.


---

# WAVE 0 — Green means green (tonight)

**When:** 2026-09-01 ~22:00 CDT → 2026-09-02 07:00 CDT. One ultracode Workflow run, 16 concurrent slots, ~59 agents.

**Goal:** restore truthful CI/ops signals and stage every human-gated unblock so the owner can clear it in one sitting. Nothing here puts the Mac app build on the merge door. Every fix that would otherwise turn a lane red lands as an **honest red plus a named blocker** — never a soft-skip, threshold raise, or suppression.

**Every branch is a fresh worktree off `origin/main 9503b490b0`.** `feat/living-glass-sweep` (45 behind / 42 ahead, **210 dirty paths**) is never touched, read-only at most. Several wave-0 and wave-1 workstreams have file collisions with that dirty tree; each says so inline.

```bash
# canonical setup, run once per workstream
git -C /Volumes/DevSSD/Developer/BurnBar fetch origin
git worktree add /Volumes/DevSSD/burnbar-worktrees/<ws-id> -b <branch> 9503b490b0
```

## Wave-0 exit gate

**ALL of:**

1. **PR #2466 is MERGED** and the next `merge_group` "BurnBar CI Gate" run on main concludes `success`.
   `gh run list --workflow burnbar-ci-gate.yml --event merge_group -L1 --json conclusion`
   *Until human queue item 1 clears, every wave-0 PR is legitimately `OPEN_WITH_NAMED_BLOCKER: awaiting collaborator approval` and the night is **not** counted as failed.* (Forced by W0-1/W0-3 constraints verdicts and all three judge panels.)
2. **main compiles the iOS target.** Evidence is the free, already-scheduled lane, not a paid dispatch: the first push-to-main `app-pr-gate.yml` run after merge shows `Mobile build + unit test` past `build-for-testing` with no `deviceApprovalCategory` / `cannot find … in scope`, and the next `openburnbar-pr-harness.yml` cron (37 8 * * *) shows `iOS Mobile` and `Retrieval Evals` past their build steps.
   *Forced by W0-1 constraints A5: dispatching a 180-minute macOS lane purely to produce a compile receipt is the "wake a rented Mac for a receipt" pattern CHEAP_FAST forbids.*
3. **The repair bot is honest.** Split into an agent half and an owner half, because the earlier draft assigned the whole condition to nobody:
   - **3a (agent, ALL-of):** `node --test scripts/ci/verify-repair-bot-fail-closed.test.mjs` exits 0. That test parses `.github/workflows/codex-nightly-ci-repair.yml` and asserts, statically: every terminal job path exits non-zero when `OPENAI_API_KEY` is absent; every terminal path exits non-zero when `validate-provenance` yields `safe=false` or the repair job is `skipped`; the `if: always()` summariser job exists and its `run:` block contains both `::error::` strings; and the `validate-provenance` block (`:159-218`) is byte-identical to `9503b490b0`. **This is the criterion that must hold; it needs no token and no dispatch.**
   - **3b (owner, human queue item 28, best-effort):** a `workflow_dispatch` **by Alberto's own account** concludes `failure` with `::error::OPENAI_API_KEY missing` in the job summary. `codex-nightly-ci-repair.yml:169-186` sets `safe=true` only for a sender with `admin|maintain|write` collaborator permission, so **no agent token can produce this evidence** — a dispatch by an untrusted token yields `safe=false` and proves nothing (W0-2 constraints A4). **This half is item 28 and must be dispatched BEFORE human queue item 5 sets the secret**, after which the asserted error string becomes permanently unproducible. If item 28 does not happen, wave-0 gate item 3 is satisfied by 3a alone and 3b is recorded as `OPEN_WITH_NAMED_BLOCKER: trusted-token dispatch not performed` — it does **not** fail the night.
4. **The nightly scoreboard exists and is provably correct — proven locally, because it cannot be dispatched.** `gh workflow run nightly-health.yml --ref <branch>` **cannot work**: `workflow_dispatch` resolves the workflow definition from the **default branch**, and `nightly-health.yml` is created by this PR and does not exist on main (`git cat-file -e origin/main:.github/workflows/nightly-health.yml` → missing). The observable criteria are:
   ```bash
   GH_TOKEN=$GH_TOKEN node scripts/ci/nightly-health.mjs --out ci/nightly-health.json   # exit 0
   node --test scripts/ci/nightly-health.test.mjs   # fixture Checks-API payloads; infra-failed classified red
   python3 -c "import json;d=json.load(open('ci/nightly-health.json'));ls={x['lane'] for x in d['lanes']};assert len(d['lanes'])==6, len(d['lanes']);assert 'codex-nightly-ci-repair' in ls;assert all({'lane','run_id','conclusion','consecutive_red'} <= set(x) for x in d['lanes'])"
   actionlint .github/workflows/nightly-health.yml
   ```
   The **dispatch** is a post-merge verification task assigned to the wave-1 gate: the first scheduled `nightly-health.yml` run after merge uploads the artifact. Same constraint applies to any other workflow a wave-0 PR creates.
5. **Local self-tests exit 0 on their own PR head** (each command runs only on the branch that creates the file — corrected from the winner plan, which gated every PR on files only one PR contains):

   | Command | Runs on |
   |---|---|
   | `bash scripts/ci/check-no-suppressions.sh` | every branch |
   | `bash scripts/ci/verify-resilience-wiring.sh` | every branch |
   | `node scripts/ci/classify-ci-impact.mjs` | every branch touching CI |
   | `node --test scripts/ci/classify-ci-impact.test.mjs` | W0-1 |
   | `node --test scripts/ci/await-burnbar-ci-gate.test.mjs` | W0-3 |
   | `node --test scripts/ops/check-ops-alert-plane-drift.test.mjs` + `node scripts/ci/verify-ops-plane-workflow-boundary.mjs` | W0-5 |
   | `bash scripts/ops/rollback-revision.test.sh` + `node scripts/ci/check-runbook-topology.mjs` | W0-6 |
   | `node scripts/ci/check-toolchain-pins.mjs` | W0-7 |
   | `bash scripts/supply-chain/verify-vendor-checksums.sh` | W0-8 |
   | `node scripts/ci/verify-data-room.mjs --check` + `bash scripts/ci/check-root-inventory.sh` + `bash scripts/ci/check-root-inventory.sh --self-test` + `node scripts/release/render-release-status.mjs --check` | W0-11 |
   | `npm --prefix functions run test:security` (which, after this PR, includes `src/__tests__/bolaCoverage.test.ts`) | W0-12 |
   | `node --test scripts/ci/verify-repair-bot-fail-closed.test.mjs` + `node --test scripts/ci/nightly-health.test.mjs` | W0-2 |

6. **Every wave-0 PR is exactly one of MERGED / `OPEN_WITH_NAMED_BLOCKER`**, blocker named in a review-gate note, with `factory-review` applied and `@codex review` commented. No draft marked ready without review. If Codex answers with a usage-limit message, no review happened and the PR is `OPEN_WITH_NAMED_BLOCKER: no independent review available`.
   **6b — the minimum-merge condition, and it is not optional.** Item 6 as written is satisfiable with **zero** merges and a score of exactly 61.0, which makes it unfalsifiable. It therefore carries a floor: **at least the first three PRs in landing order (W0-11, W0-6, W0-1) are MERGED, or the night is graded `PARTIAL`.** Those three are the cheapest CI, carry no Mac dependency and no required-context risk, and are the ones the sequencer marks ready first; if none of them merged, the cause is the approval gate, not the work, and the honest label is *"blocked on human approval — 0 of 11 landed"*, never *"wave 0 complete"*. The one exemption: if human queue item 1 (#2466) never lands, **no** wave-0 PR can merge by construction, and the night grades `BLOCKED-ON-QUEUE` with all eleven `OPEN_WITH_NAMED_BLOCKER: awaiting collaborator approval`. `BLOCKED-ON-QUEUE`, `PARTIAL` and `COMPLETE` are three distinct outcomes and the morning memo names which one occurred.
7. **The human queue above is posted as one GitHub issue** (`Ops unblock queue 2026-09-02`) with checkboxes and the exact commands.

**Explicitly removed from the wave-0 gate** (verdicts W0-3 A9, W0-4 A8, W0-5 A9, W0-8 A1): any criterion requiring a green `deploy-production` run, a green `ops-plane-verify` run, a green tag release, a `supply-chain-provenance` dispatch, or a live rollback drill. All five are human-gated and none can conclude tonight.

---

## W0-0 — Sequencer, pace controller, and standing adversarial verifier

> **Grafted in** from plan-0 W0-01/W0-14 and plan-3's staggered readiness, on the explicit instruction of judge panels 1 and 3. Not in the winner plan; every ceiling analysis identified PR throughput, not code, as the binding constraint.

**✅ AGENT-FEASIBLE TONIGHT.** No PR of its own.

**Fanout (2 agents):** 1 sequencer + 1 standing cross-PR verifier.

**Sequencer duties**
- Maintains `.agent/runs/wave0-landing-order.json`: PR id, branch, dependency edges, ready-state, blocker.
- **Never more than 3 PRs marked ready at once.** Rationale: `dismiss_stale_reviews=true` + `strict=true` means each merge invalidates the others' approvals; a pile of ready PRs multiplies Alberto's approval count instead of the merge count.
- **Landing order:** `#2466` (human) → W0-11 → W0-6 → W0-1 → W0-12 → W0-2 → W0-3 → W0-8 → W0-5 → W0-10 → **W0-7 last** (it touches ~84 workflow files and will need a rebase after every other workflow PR lands; #2449, #2440, #2435, #2424, #2405, #2371 also edit `.github/workflows`).
- **Batches the queue.** `max_entries_to_build=5` / `max_entries_to_merge=5` / `ALLGREEN` and all 40 sampled merge groups have been single-PR. Enqueue low-risk PRs in groups of up to 5; enqueue risky ones alone (`ALLGREEN` sinks the whole group on one red).
- Opens every PR **from a bot/app identity, never `Ajnunezg`** (self-approval is forbidden by GitHub).
- Posts a `Cross-agent receipt` (saw / reaction / status / next owner, with review, comment and thread ids and commit SHAs) on every Codex or Cursor reaction.

**Standing verifier duties** — runs on every branch before it is marked ready:
```bash
bash scripts/ci/check-no-suppressions.sh
bash scripts/ci/verify-resilience-wiring.sh
node scripts/ci/classify-ci-impact.mjs          # record the verdict in the PR body
actionlint $(git diff --name-only 9503b490b0 -- '.github/workflows/*.yml')
git diff 9503b490b0 --unified=0 | grep -nE 'continue-on-error|timeout-minutes:|swiftlint:disable|@ts-(ignore|expect-error|nocheck)|# noqa|#\[allow|eslint-disable' || echo 'clean'
```
Any hit that is not accompanied by a `reason:` token or an exact-path `docs/LINT_RATIONALE.md` allowlist entry **blocks readiness**.

> **`make debt-check` is NOT in the standing verifier, and this is deliberate.** `Makefile:325` runs `./scripts/ci/update-tech-debt-metrics.sh`, whose last act is `cat > docs/TECH_DEBT_METRICS.md` — a **tracked** file. Using it as a pass/fail proof means a "clean" verifier run silently dirties the worktree it is validating, and the next `git status` check then reads as an uncommitted change nobody made. The verifier runs the **non-mutating ratchet subset** instead, exactly as the `Debt budgets (shrink-only ratchets)` job does (`fast-feedback.yml:1481-1526`), which also never calls the updater:
> ```bash
> ./scripts/ci/check-no-committed-build-artifacts.sh
> ./scripts/ci/check-no-stale-launch-evidence.sh
> ./scripts/debt/check-try-optional-budget.sh   ./scripts/debt/check-empty-catch-budget.sh
> ./scripts/debt/check-unsafe-cast-budget.sh    ./scripts/debt/check-grdb-row-cast-budget.sh
> ./scripts/debt/check-unchecked-sendable-budget.sh ./scripts/debt/check-force-unwrap-budget.sh
> ./scripts/debt/check-swift-file-size-budget.sh
> git status --porcelain docs/TECH_DEBT_METRICS.md   # must be empty
> ```
> Any workstream whose doneCriteria names `make debt-check` (W0-11, W1-4, W2-1) must either commit the regenerated `docs/TECH_DEBT_METRICS.md` in the same commit **or** substitute the subset above. Stating "`make debt-check` green" while leaving the file dirty is not a proof.

**doneCriteria:** the landing-order file exists and is updated after every merge; no moment in the night has >3 PRs simultaneously `isDraft=false, reviewDecision=REVIEW_REQUIRED`; `.agent/runs/wave0-landing-order.json` carries a `macosBudget` object showing at most 2 hosted macOS slots held by wave-0 work at any timestamp and zero dispatches inside 08:30–11:00Z (see [Gate 3](#gate-3--macos-runner-concurrency-is-the-nights-other-hard-ceiling)); the verifier's transcript is attached to each PR body.
**scoreDelta:** none directly. It is the multiplier on everything else.

---

## W0-1 — Main compiles again

**Findings:** F07 (partial), F04 (partial). **Branch:** `hotfix/main-compiles-20260901`. **Lane:** fast. **✅ AGENT-FEASIBLE TONIGHT.**

Both compile errors are confirmed on `origin/main 9503b490b0` and both came from `0b56358b5d` (#2457):
- `OpenBurnBarMobile/Services/AgentReplyNotificationService.swift:181` references `Self.deviceApprovalCategory`; only `agentReplyCategory` (:662) and `aiInboxCategory` (:647) exist.
- `AgentLensTests/Active/DeviceApprovalRoutingTests.swift:2` does `@testable import OpenBurnBarCore` while `AppCommandRouter` lives at `AgentLens/App/AppCommandRouter.swift:53`. Its sibling `AppCommandRouterLinkCliTests` correctly uses `@testable import OpenBurnBar`.

> ### ⚠ Verdict-forced changes
> - **Cut the OpenBurnBarCore notification-category registry.** *(feasibility A2)* No such registry exists; `OpenBurnBarCore` is built and tested **on ubuntu** by PR Native Fast Gate, so any `UNNotificationCategory`-shaped type there needs `canImport` guards, and "the category set cannot drift" is only provable by a mobile XCTest that the wave keeps off the door — the adversarial verifier had no oracle. The pure-data-registry variant *(constraints A2)* is recorded as an **optional wave-1 hardening**, not a red-main hotfix.
> - **Cut the `classify-ci-impact.mjs` implementer — it is a no-op sold as a fix.** *(feasibility A3, constraints A1)* `classify-ci-impact.mjs:114-117` already maps `^OpenBurnBarMobile/` to the mobile lane and `app-pr-gate.yml:213` already keys on it. The only real gap is a missing direct assertion in the test file. 10 minutes, folded into the same implementer, no Codex lane.
> - **Do not stack onto #2463.** *(feasibility A4, constraints A4)* #2463 is `app/cursor`-owned (`cursor/imagine-that-duty-officer-d3d5`, `maintainerCanModify=false`), carries no `factory-review` label and no `@codex review`, and its gate is red only because it consumed a superseded `Signal Activation Parity` run. Pushing product code onto a Cursor-bot branch makes the bot the nominal author of a fix Codex must review, and the Cloud Agent may overwrite it. **Open one fresh PR and close #2463 with a Cross-agent receipt.**
> - **Correct the scheme name.** *(feasibility A1)* CI uses `-scheme OpenBurnBarMobileUnitTests`, not `OpenBurnBarMobile` (which also drags UITests into `build-for-testing`).
> - **Forbid `scripts/test-openburnbar-mobile.sh` as evidence.** *(feasibility A1)* Its dry run resolves to a physical device with automatic provisioning — signing/device management is human-only.
> - **Rename the theme.** *(feasibility A5)* "OpenBurnBar Full Harness green on main" is overclaimed: after this fix the harness stays red on `mercury-media-e2e` (exit 65), `hermes-gateway-e2ee-proof`, and a ~1,596-test iOS suite never observed green anywhere in the sample.
> - **Fanout 7 → 3; scoreDelta halved.** *(feasibility A7/A8, constraints A6)*

**Fanout (3 agents):** 1 implementer (all four edits ≈ 40 lines) → 1 local Mac builder/verifier (two `xcodebuild` proofs, sequential) → 1 PR author.

**The change:**
1. `private static let deviceApprovalCategory: UNNotificationCategory` beside the two existing ones, with approve/deny `UNNotificationAction`s.
2. One `OpenBurnBarMobileTests` XCTest asserting all three category identifiers are registered.
3. `DeviceApprovalRoutingTests.swift` → `@testable import OpenBurnBar`, wrapped in `#if canImport(AppKit)` like its sibling.
4. Assertion in `scripts/ci/classify-ci-impact.test.mjs` that `classifyPaths(['OpenBurnBarMobile/Foo.swift'])` yields `mobile=true, macos=false`.
5. Cherry-pick the 133→138 fresh-host count lock from `c434cbb52e` (Cursor agent credited).

**doneCriteria**
```bash
# 1. iOS target compiles, exactly as CI does it (cold build: budget 30-60 min)
FIREBASE_SOURCE_FIRESTORE=1 xcodebuild build-for-testing \
  -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobileUnitTests \
  -destination 'generic/platform=iOS Simulator' \
  -clonedSourcePackagesDirPath .spm-cache-new -derivedDataPath .derived-data/mobile-pr-gate \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO SWIFT_COMPILATION_MODE=wholemodule \
  SWIFT_ENABLE_BATCH_MODE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO   # exit 0

# 2. the AgentLens test compiles and runs — ONE attempt, no retry loop.
#    scripts/test-openburnbar-app.sh:83 defaults to OPENBURNBAR_APP_TEST_ATTEMPTS=4, and "keeping the
#    4-attempt loop so one pass in four reads as green" is on this plan's own fake-green blacklist.
#    Producing W0-1's compile evidence through that harness at its default would be the blacklisted
#    pattern verifying the fix. Pin it to 1; a genuine infra hang then surfaces as a named blocker
#    instead of being silently retried away.
OPENBURNBAR_APP_TEST_ATTEMPTS=1 \
  ./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/DeviceApprovalRoutingTests   # exit 0
# executed-count floor: a renamed filter selects zero tests and still exits 0
grep -qE 'Executed [1-9][0-9]* test' .derived-data/test-openburnbar-app.log

# 3. classifier assertion
node --test scripts/ci/classify-ci-impact.test.mjs   # exit 0
```
**evidence:** both `xcodebuild` logs with `xcodebuild -version` and the simulator runtime named; the `xcresult` path; the attempts log showing **exactly one** attempt (`jq -s 'length' .derived-data/test-openburnbar-app-attempts.jsonl` = 1); the closing Cross-agent receipt on #2463 (`saw c434cbb52e / reaction: superseded by #<new> / status CLOSED / next owner: night shift`).
**Hosted-runner cost: zero.** Criterion 1 is a *local* cold build on Alberto's own M5 Max (30–60 min), not a hosted dispatch — that is why wave-0 gate item 2 reads the free push-to-main lane. W0-1 draws no slot from the 5-wide macOS pool (see [Gate 3](#gate-3--macos-runner-concurrency-is-the-nights-other-hard-ceiling)).

**PR lane:** fast, one PR: `fix(mobile): main compiles again — iOS notification category + AgentLens test import + Platform Misc lock`. PR body records as **known remaining harness red, not in scope:** `mercury-media-e2e` exit 65, `hermes-gateway-e2ee-proof` plaintext-hardening scan, and the never-green iOS suite.
**CLI lane:** build Grok 4.6; tests Agy × Gemini 3.7 Flash medium; review `@codex review`.
**scoreDelta:** Testing/CI +0.15, Reliability/Ops +0.10.
**Risks / blockers:** cannot merge until #2466 lands. The router's approve-device branch spawns a `@MainActor` Task into `SettingsDeepLinkRouting`; if it crashes in the test host that is a **named blocker to report**, not something to quarantine. Once compile is restored, the first full iOS suite result must be triaged with a named blocker per failing test class — added to the human queue as follow-up, never silently quarantined.

---

## W0-2 — Honest nightlies and honest ops scoreboards

**Findings:** F07, F06 (partial → W0-10), F04, F27, F01 (lane-health slice). **Branch:** `ci/ops-honesty-20260901`. **Lane:** structured-large. **✅ AGENT-FEASIBLE TONIGHT.**

> ### ⚠ Verdict-forced changes
> - **"Measurement-infrastructure failure → neutral conclusion" is deleted.** *(feasibility A1, constraints A1)* A step cannot set a neutral conclusion — `app-pr-gate.yml` has `permissions: contents: read` with no `checks: write` — and implementing it as exit 0 + evidence is precisely the "success on a skipped path" the workstream's own verifier forbids. Replaced by **a distinct non-zero exit code (3) that still fails the job**, with `result.json` carrying `status:"infra-failed"` and a `reasonCode` (`helper-timeout` / `no-backdrop-ack` / `launch-failed`) so the scoreboard can separate harness-red from budget-red.
> - **`"no path exits 13"` is not a testable assertion** *(A2)*; replaced with "every `execFile` receives a bounded timeout or `AbortSignal`, and a hung helper yields exit 3 + evidence JSON within `stateTransitionTimeoutSeconds`".
> - **CodeQL Swift is split out into W0-10.** *(judge grafts ×3, feasibility A3)* Each iteration is a 60–120 min hosted `macos-26` run; the 2026-09-01 run `33517666151` hits the Metal error **75 minutes in**, after the whole non-Metal build. It must not hold this PR hostage.
> - **The lane-health slice of W0-4 is absorbed here.** *(W0-4 feasibility A3)* Both PRs otherwise edit `escalation.cjs` and would conflict.
> - **Paging is human-gated.** *(A5)* `OPS_PAGING_SLACK_WEBHOOK` is absent from the repo secrets; `ops-failure-issue` opens issues and only *warns*. Criterion reworded to "opens/refreshes the per-lane issue".
> - **Item (f) DAST is re-scoped.** *(A6, constraints A3)* The readiness probe already exists at `nightly-dast-sandbox.yml:100-123`. The real change is naming the exit-124 path `emulator-not-ready`, uploading emulator stdout/stderr + `firebase --version` / Java presence as an artifact, and giving `privileged-socket-redteam`'s "FAIL: binaries missing" its own reason code. **The redteam binaries gap moves to the human queue** — hosted `macos-26` lacks the privileged bridge binaries (`nightly-dast-sandbox.yml:44` already says so).
> - **Item (e) Linux is reason-codes only.** *(A7)* Root causes for `run-shell-desktop-session` / `run-shell-evidence` / `run-perf-budget` / `verify-shell-evidence` are a later wave. `verify-shell-evidence.mjs` (539 lines) is also consumed by `linux-product-parity.yml`, so any evidence-schema change must keep that consumer green — added to the validation matrix.
> - **Repair bot must also fail closed on the provenance-skip path.** *(constraints A4)* When `validate-provenance` yields `safe=false` on a scheduled run, or the repair job is skipped for any reason, a final `if: always()` job exits 1 with `::error` naming the reason. `validate-provenance` (`:159-218`) stays **byte-identical**; verifier B diffs that block.
> - **One pinned "Nightly health" issue for all lanes**, per-lane sections updated in place, one P0 page on first red-day crossing — not five issues. *(constraints A5)*
> - **Do not touch the Platform Misc count assertion** — #2463 owns it. *(constraints A7)*
> - **Do not add a `push-to-main` trigger to any nightly.** *(A3)* The 2026-07-31 cost hardening removed it; the public repo shares 5 concurrent macOS jobs with Daemon PR Gate in the merge queue.
> - **scoreDelta Reliability/Ops 0.4 → 0.15**, with the remaining 0.25 awarded only if the `app-pr-gate` P-PERF-3 dispatch passes with real samples. *(A10)*

**Fanout (14 agents):** 1 scout (`--log-failed` for the last 8 runs of each nightly, classify infra vs product) → 8 implementers → 2 adversarial verifiers → 1 root-cause implementer for the backdrop handshake → 1 root-cause implementer for the emulator → 1 PR author.

| # | Implementer | Deliverable |
|---|---|---|
| a | repair bot | `codex-nightly-ci-repair.yml` exits 1 with `::error` when `OPENAI_API_KEY` is absent **and** when `safe=false` / the repair job is skipped; job summary names the reason; pinned "Nightly health" issue via `ops-failure-issue`. `validate-provenance` byte-identical. |
| b | scoreboard | New `nightly-health.yml` querying the Checks API for **six** lanes → `ci/nightly-health.json` + Markdown summary + 7-day re-page tier in `escalation.cjs` (which today only has `escalated:72h` and an already-paged short-circuit at `:65`). `status:"infra-failed"` counts as red. |
| c | **deploy lane-health** *(absorbed from W0-4)* | Scheduled workflow querying the last N `deploy-production` runs → `ci/deploy-lane-health.json`, feeding `ops-failure-issue` with the same 7-day tier; runbook text in `docs/runbooks/shared-rust-release-evidence.md` + `functions-break-glass.md` describing the current blocker and the two exit paths. |
| d | P-PERF-3 | `macos-idle-occlusion-gate.mjs`: `AbortController`-bounded child promises; **exit 3** on infra failure with `status:"infra-failed"` + reasonCode; budget-exceeded → normal failure. `budgets/macos-idle-cpu.perf.json` keeps `absoluteOccludedIdleCpuPercentCeiling 5.0` and the behavioral-assertions list **unchanged**; update `macos-idle-occlusion-gate.test.mjs:67` rather than deleting it. **No new `budgets/*.json`.** |
| e | backdrop root cause | Fix the readiness handshake (helper waits on a bounded `__backdropReady` ack). Validate with one `workflow_dispatch` of `app-pr-gate.yml` on the branch showing P-PERF-3 green with real samples. |
| f | Linux | `run-shell-*.mjs` emit structured evidence JSON with per-step reason codes; `linux-product-parity.yml` consumer stays green. |
| g | DAST | Name the exit-124 path `emulator-not-ready`; upload emulator logs + toolchain presence as an artifact; reason code for the redteam binaries gap. No timeout raise, no `continue-on-error`. |
| h | escalation tests | Unit tests for the 7-day tier and for infra-vs-budget classification. |

**doneCriteria**
**Every criterion below runs to completion with an agent token on the PR branch. The two things that need Alberto's identity are named as such and are queue items, not silent assumptions.**

```bash
# (1) repair bot fails closed — STATIC proof, no dispatch, no token.
#     A workflow_dispatch cannot produce this evidence from an agent: codex-nightly-ci-repair.yml:169-186
#     sets safe=true only when repos/{repo}/collaborators/{sender}/permission is admin|maintain|write.
node --test scripts/ci/verify-repair-bot-fail-closed.test.mjs
#   asserts, by parsing the YAML: every terminal path exits non-zero when OPENAI_API_KEY is absent;
#   every terminal path exits non-zero when safe=false or the repair job is skipped;
#   the `if: always()` summariser exists and emits both ::error:: strings;
#   validate-provenance (:159-218) is byte-identical to 9503b490b0.
git diff 9503b490b0 -- .github/workflows/codex-nightly-ci-repair.yml | \
  awk '/^@@/{h=$0} /^[-+]/ && h ~ /15[0-9],|2[01][0-9],/' | grep . && exit 1 || echo 'validate-provenance untouched'
#   -> human queue item 28 supplies the live fail-closed dispatch. Its absence is a named blocker,
#      not a gate failure (wave-0 exit gate 3a/3b).

# (2) nightly scoreboard — LOCAL run, not a dispatch.
#     `gh workflow run nightly-health.yml --ref <branch>` CANNOT work: workflow_dispatch resolves the
#     workflow from the DEFAULT branch and this file is created by this PR.
GH_TOKEN=$GH_TOKEN node scripts/ci/nightly-health.mjs --out ci/nightly-health.json   # exit 0
node --test scripts/ci/nightly-health.test.mjs        # fixture Checks-API payloads; infra-failed == red
python3 -c "import json;d=json.load(open('ci/nightly-health.json'));ls={x['lane'] for x in d['lanes']};assert len(d['lanes'])==6;assert 'codex-nightly-ci-repair' in ls;assert all({'lane','run_id','conclusion','consecutive_red'} <= set(x) for x in d['lanes'])"
GH_TOKEN=$GH_TOKEN node scripts/ci/deploy-lane-health.mjs --out ci/deploy-lane-health.json && \
  jq -e '.runs|length>0' ci/deploy-lane-health.json
actionlint .github/workflows/nightly-health.yml

# (3) P-PERF-3 exit codes — pure unit test, no Mac.
node --test scripts/ci/macos-idle-occlusion-gate.test.mjs
#   helper timeout -> exit 3 AND job red;  CPU over ceiling -> non-zero;  no path exits 0 without a matched-pair measurement
node --test scripts/ci/verify-pr-harness-aggregate-gates.test.mjs   # the door verifier still passes with the edit

# (4) P-PERF-3 real samples — the ONE hosted-Mac dispatch this workstream is allowed, twice at most.
#     Budgeted against slot 2 of the 5-wide macOS pool, both before 03:00 CDT, never inside 08:30-11:00Z.
gh workflow run app-pr-gate.yml --ref ci/ops-honesty-20260901   # P-PERF-3 step green with real samples
#   -> if two dispatches do not yield a green P-PERF-3 with real samples, park
#      OPEN_WITH_NAMED_BLOCKER: P-PERF-3 root cause unresolved, forfeit the +0.25 Rel contingent,
#      and do NOT buy a third dispatch.

# (5) no threshold, timeout or continue-on-error moved
git diff 9503b490b0 -- budgets/macos-idle-cpu.perf.json | grep -E 'Ceiling|threshold' && exit 1 || echo 'no threshold change'
git diff 9503b490b0 --unified=0 | grep -E 'continue-on-error|timeout-minutes:' && exit 1 || echo 'clean'
bash scripts/ci/check-no-suppressions.sh
actionlint $(git diff --name-only 9503b490b0 -- '.github/workflows/*.yml')
```
**evidence:** the local `ci/nightly-health.json` and `ci/deploy-lane-health.json` files plus their fixture-test output; `gh run view` URLs for the ≤2 `app-pr-gate` dispatches; harness `result.json` samples for infra-failed vs budget-failed; the diff proving `validate-provenance` (`:159-218`) is byte-identical to main. **Post-merge verification task, assigned to the wave-1 gate:** the first *scheduled* `nightly-health.yml` run on main uploads the artifact, and human queue item 28's dispatch URL (if it happened) is pasted into the PR thread.

**PR lane:** structured-large, one PR `ci(ops): red means red`. Review map ordered **(1) repair-bot fail-closed → (2) nightly-health + deploy-lane-health → (3) P-PERF-3 exit codes → (4) Linux/DAST reason codes**. Invariants: privileged repair-loop provenance (`workflow_run` `safe=true`, exact-SHA re-check) untouched; no lane may succeed on a skipped path; no threshold, timeout or `continue-on-error` changed. Rollback = revert.
**CLI lane:** workflows/scripts Grok 4.6; P-PERF-3 harness + `escalation.cjs` Codex GPT-5.6 Sol xhigh; evidence schemas Agy × Gemini 3.7 Flash medium; review map Fable; review `@codex review`.
**scoreDelta:** Reliability/Ops **+0.15** (+0.25 contingent on the P-PERF-3 dispatch passing with real samples), Testing/CI **+0.15** (+0.15 contingent, see below). Weighted on merge: **4.50**.
> **Why Testing/CI was cut 0.30 → 0.15 on merge.** `ci/nightly-health.json` is an *artifact*. It changes no gate, blocks no merge, and is not a required context — booking it at twice the circuit breaker's Testing/CI delta invited the fair reading that this plan bought a dashboard. What the scoreboard genuinely earns is the **trailing history it starts accumulating**: the wave-1 exit gate's condition 2 ("all six lanes green for 2 consecutive nights") and W1-7b's enforce precondition both read this file and cannot exist without it. So half the award moves to a contingent — **Testing/CI +0.15 once `nightly-health.yml` has produced two consecutive green scheduled runs on main** — and is booked in the [Score ledger](#score-ledger)'s contingent table, in wave 1, where the evidence actually appears. The repair-bot fail-closed change, by contrast, *does* alter behaviour on merge and keeps its share of the on-merge award.

**Human cost, stated correctly: three owner actions, not one.** The earlier draft's *"costs Alberto exactly one action (`gh secret set OPENAI_API_KEY`)"* was wrong and is retracted. This workstream needs: **item 28** (trusted-token dispatch of `codex-nightly-ci-repair`, which no agent identity can perform, and which must run **before** item 5), **item 5** (`gh secret set OPENAI_API_KEY`), and **item 6** (confirm or add `OPS_PAGING_SLACK_WEBHOOK`, absent from repo secrets, so `ops-failure-issue` pages nobody). None of the three is a merge blocker; all three are gate-evidence blockers.

**Risks:** making the repair bot fail closed turns it **red immediately** until `OPENAI_API_KEY` exists — that is the desired signal, announced in the PR body. Critical path: **at most two** `app-pr-gate` dispatches at 55–70 min each, holding slot 2 of the 5-wide macOS pool; start them first and never inside 08:30–11:00Z. Estimated ~34 agent-hours.

---

## W0-3 — Merge-gate semantics: main-red circuit breaker, observing-first

**Findings:** F04, F26 (partial). **Branch:** `ci/gate-circuit-breaker-observe-20260901`. **Lane:** structured-large. **✅ AGENT-FEASIBLE TONIGHT.**

> ### ⚠ Verdict-forced changes
> - **The lookup was wrong against the code.** *(feasibility A2, constraints A2)* `merge_group.base_sha` is the **previous queue entry's temporary commit**; `app-pr-gate.yml` **carries a `merge_group:` trigger at `:31` but every job is guarded `if: github.event_name != 'merge_group'` (`:47`, `:64`, `:213`, `:332`)**, so a merge_group run produces no build verdict at all — the earlier phrasing "never runs on merge_group" was imprecise in a way that matters, because the workflow *is* triggered and *does* report. Its aggregate also reports `success` when the classifier skips the app/mobile lanes. "Latest verdict for the base SHA" is therefore *missing* for stacked entries and *falsely green* after a docs-only push. **Rewritten:** resolve the merge-base with `origin/main`, then walk main commits backwards via `GET /repos/{r}/actions/workflows/app-pr-gate.yml/runs?branch=main&event=push|schedule` and take the newest completed run whose `App build + test (AgentLens)` **and** `Mobile build + unit test` jobs *actually ran*. Treat a classifier-skipped aggregate success as **no verdict**. Requires adding `actions: read` to `burnbar-ci-gate.yml`.
> - **Missing verdict is not fail-closed.** *(constraints A2)* Both observe and enforce **pass** with a job-summary line noting no completed verdict; only an explicit completed failure fails. Otherwise enforce deadlocks the queue for the 30–45 min after every merge while `app-pr-gate` (32–44 min measured on the last four main runs) is still running.
> - **The override path needed permissions the trusted workflow does not grant.** *(A3)* Bound concretely: label `ci-freeze-override`, PR number parsed from `merge_group.head_ref` (`gh-readonly-queue/main/pr-<n>-*`), counted **only** when the `labeled` timeline event's actor login is `Ajnunezg` (id 125839313); needs `pull-requests: read` + `issues: read`. "Required reviewer" is undefined in live protection (`require_code_owner_reviews=false`) and was replaced by `circuitBreaker.overrideActors` in governance.
> - **Governance goes in BOTH files.** *(A1)* The `pull_request_target` path reads `governance/burnbar-ci-gate.fast.json`; the `merge_group` path reads `governance/burnbar-ci-gate.json`. Adding the key to only one is how the queue wedges fail-closed.
> - **Auto-revert bot and flake ledger → wave 1.** *(feasibility A1/A5, constraints A1)* `workflow_run` workflows only fire from main, so no dry-run PR can be produced on a branch; and a `GITHUB_TOKEN`-opened revert PR triggers **no CI** (needs `FACTORY_BOT_TOKEN` — human queue item 26). The flake ledger has no data source: `attempts.jsonl` is only uploaded by `app-pr-gate` with 7-day retention and the harness currently fails *before* tests run.
> - **`governance/flake-quarantine.json` is not created in wave 0**, and the "allowlist entry + reason" criterion is deleted — `check-no-suppressions.sh` matches only `budgets/*.json` and `*baseline*.{xml,yml,yaml}`, so the entry would be a no-op. *(feasibility A7, constraints A7)*
> - **`xcode_false_negative_pass` removal must be coherent across all five sites.** *(feasibility A6, constraints A6)*
> - **Evidence 2 and 3 were unattainable pre-merge.** *(A4)* Governance and the evaluator are read from the **base tree**, so no `merge_group` run on the PR can show the observe annotation. Replaced by local self-test output plus a post-merge verification task.

**Fanout (4 agents):** 1 scout (map the trusted-base-SHA flow; read #2405 and draft the close memo) → 1 Codex implementer (evaluator) → 1 test author → 1 PR author.

**The change**
1. `scripts/ci/await-burnbar-ci-gate.mjs`: main-walk verdict resolution as above; **observe** mode emits a job-summary line + annotation; **enforce** mode fails closed with named blocker `main-red-circuit-breaker` unless a valid `Ajnunezg`-applied `ci-freeze-override` exists, logging actor, event id and timestamp.
2. `circuitBreaker: {mode: "observe", overrideActors: ["Ajnunezg"]}` in **both** governance files.
3. `burnbar-ci-gate.yml` permissions widened to `actions: read`, `pull-requests: read`, `issues: read` — **called out in the review map as a security-relevant change to a `pull_request_target` workflow**; extend `scripts/ci/verify-pr-secret-boundaries.test.mjs` / `verify-merge-queue-workflows.test.mjs` if they pin those permissions.
4. Remove `xcode_false_negative_pass` from **all** of: `scripts/lib/openburnbar-app-test-classifier.sh:205` (helper + `classify_attempt` at `:54`), `scripts/test-openburnbar-app.sh` (`:312` tally, `:626`, `:710`), `scripts/test-openburnbar-mobile.sh:1228`, `scripts/test-openburnbar-retrieval-evals.sh:252`; delete/invert the **11** `is_xcode_false_negative_pass` assertions in `scripts/test-openburnbar-app-classifier.sh:295-321` (at `:295`, `:296`, `:298`, `:299`, `:300`, `:301`, `:303`, `:305`, `:309`, `:320`, `:321` — the earlier draft said 12; the other lines in that range assert `openburnbar_app_test_has_terminal_concrete_xctest_failure` or `is_known_hang` and are **kept**); the emitted outcome enum in `emit_attempt_event` no longer contains `xcode_false_negative_passed`. Verify with `git show origin/main:scripts/test-openburnbar-app-classifier.sh | sed -n '295,321p' | grep -c is_xcode_false_negative_pass` → `11`.
5. Docs: `docs/SOFTWARE_FACTORY_PR_LOOP.md`, `AGENTS.md`, `CLAUDE.md` describe the breaker, the override, and that the Mac app build stays off the door.
6. `ci-freeze-override` label created.

**doneCriteria**
```bash
node --test scripts/ci/await-burnbar-ci-gate.test.mjs   # exit 0, with NEW cases:
#   stacked queue entry (base is a temp merge commit)      -> no verdict -> observe AND enforce pass, summary notes it
#   docs-only push masking an older red                    -> walks back to the last run that actually executed
#   lane classifier-skipped                                -> treated as "no verdict", never as green
#   completed failure + observe                            -> pass with annotation
#   completed failure + enforce + no override              -> fail, blocker text "main-red-circuit-breaker"
#   completed failure + enforce + Ajnunezg-labelled override -> pass with audit line (actor, event id, timestamp)
#   override label applied by anyone else                  -> ignored

python3 -c "import json;a=json.load(open('governance/burnbar-ci-gate.json'));b=json.load(open('governance/burnbar-ci-gate.fast.json'));assert a['circuitBreaker']['mode']=='observe' and b['circuitBreaker']['mode']=='observe'"
bash -n scripts/test-openburnbar-app.sh scripts/test-openburnbar-mobile.sh \
        scripts/test-openburnbar-retrieval-evals.sh scripts/lib/openburnbar-app-test-classifier.sh
bash scripts/test-openburnbar-app-classifier.sh        # exit 0 — run ONLY in the fresh worktree
rg -n 'xcode_false_negative_pass' scripts/ | wc -l      # 0
BURNBAR_CI_SHA=9503b490b0 node scripts/ci/await-burnbar-ci-gate.mjs governance/burnbar-ci-gate.json   # output pasted in the PR body
bash scripts/ci/check-no-suppressions.sh

# VERDICT-AVAILABILITY RATE — the criterion that decides whether this breaker is enforcement or theatre.
# Missing verdict passes in BOTH modes by design (see the verdict-forced changes above), and
# app-pr-gate takes 32-44 min on main, so for 30-45 minutes after every merge the base SHA has
# no completed verdict. If that is the NORMAL state, the breaker never binds and the score it
# books is unearned. So it must be measured, not assumed:
node scripts/ci/await-burnbar-ci-gate.mjs --replay-window 30d --report verdict-availability.json
jq -e '.samples >= 20 and (.verdictPresentRate|type=="number")' verdict-availability.json
```
**The rate is a reported number, not a pass/fail bar, in wave 0** — the honest posture for an observe-mode breaker. It becomes a **hard precondition on the wave-1 enforce flip (W1-7b)**: `verdictPresentRate ≥ 0.60` measured over the first 20 `merge_group` runs after this PR merges, or the flip does not happen and W1-7b ends `OPEN_WITH_NAMED_BLOCKER: breaker would not bind`. Without this, "the breaker passes on no-verdict" and "the breaker is enforcement" are both true statements about a thing that never fires. The PR body states the measured wave-0 rate in one line.

Plus: **`node --test scripts/ci/await-burnbar-ci-gate.test.mjs` is added to the test list in `.github/workflows/workflow-lint.yml`** (currently absent — the self-tests do not run on the door today). *(constraints A5)*

**evidence:** self-test output; the local evaluator run against main's SHA; a **post-merge** verification task assigned to the wave-1 gate: the first `merge_group` run on main *after* this PR merges shows the observe summary line.
**PR lane:** structured-large, `ci(gate): main-red circuit breaker, observing-first`. Includes the recommendation memo for closing #2405.
**CLI lane:** Codex GPT-5.6 Sol xhigh (trusted gate evaluator); tests Agy × Gemini; #2405 memo Fable; review `@codex review`.
**scoreDelta:** Testing/CI +0.15, Reliability/Ops +0.10. *(The remaining +0.15 / +0.10 is booked against the wave-1 enforce flip and the auto-revert bot — a breaker in observe mode is not enforcement.)*
**Risks:** no `merge_group` run can be green until #2466 merges; a red merge_group caused by OSV is **not** breaker evidence. Governance is read from the base tree, so this PR cannot test its own enforce flip — self-tests are the evidence. Estimated 10–12 agent-hours.

---

## W0-4 — Deploy lane: what is actually landable tonight

**Findings:** F01. **No new PR.** **🔒 MOSTLY HUMAN-GATED.**

> ### ⚠ Verdict-forced changes — this workstream was gutted by both lenses
> - **PR A is deleted.** *(feasibility A1, constraints A1)* `feat/cross-platform-bug-reporting` **is** PR #2457 and is already **merged** as `0b56358b5d`; `git diff origin/main origin/feat/cross-platform-bug-reporting -- functions/src` is **empty**. The "prod-ahead" deltas named by the #2195 postmortem (`guards.ts normalizeProvider()` fallback, `providers.ts`, `types/legacy/bug-report.ts`) exist on no branch, in none of the 20 worktrees, and only in Alberto's **uncommitted working tree**. Main already has the v3 rollup contract, `callables/knowledgeSearch.ts`, `callables/bugReporting.ts` and the escrow callables. A scout plus three implementers had **nothing to land**. → **human queue item 11**.
> - **PR B's fix shape is logically inert.** *(feasibility A2, constraints A2)* `verify-domain-core-control-plane.mjs:299` (committed manifest == trusted-main digest) together with `:302` (candidate file == trusted-main digest) **already** requires the committed manifest to equal the trusted-main digests, and the manifest is regenerated on every control-plane edit — so "attested manifest digest == committed digest" is the existing byte-match restated. → **human queue item 12** (fresh ceremony vs a schemaVersion-3 `policyVersion`, the latter as a spike with an ADR, never a merge candidate tonight).
> - **Do not open a fourth competing control-plane PR.** *(constraints A2)* #2349 (open, non-draft) already edits `deploy-production.yml` + `config/domain-core-control-plane-manifest.json`; #2334 and #2430 also re-hash that manifest. CHEAP_FAST: stack into the open theme. **The ancestor guard lands as a stacked commit onto #2349.**
> - **Cut tonight** *(feasibility A4, constraints A3/A5)*: the Cloud Monitoring `deploy/age_days` custom metric (needs `roles/monitoring.metricWriter` — GCP IAM, and it contradicts a viewer-only identity); the `actions/create-github-app-token` identity (App creation, human-only); and the `workflow_run` auto-dispatch of the signer (a new privileged secret-bearing loop that would have to revisit the `workflow_dispatch` guard at `domain-core-promotion-proof.yml:41`, which `scripts/ci/verify-domain-core-workflows.test.mjs` pins).
> - **"Domain Core Trusted Deletion Guard green on the PR" is not proof** *(constraints A4)* — it evaluates with trusted main code and cannot exercise the PR's verifier.
> - **F07 removed from this workstream's findings.** *(feasibility A6)* Nothing here addresses nightlies.
> - **The lane-health scoreboard slice moved to W0-2** to avoid an `escalation.cjs` conflict.
> - **scoreDelta 0.5/0.3/0.1/0.2 → 0.10/0.05/0.05/0.05.** *(feasibility A9, constraints A7)*

**What lands tonight — one stacked commit on #2349 (2 agents)**

**Ancestor guard.** `prepare-functions-deploy` fails unless the live deployed git sha is an ancestor of the release commit, or a committed `config/deploy-regression-receipts/<date>.json` exists. **Extend the existing `functions/src/sourceMetadata.ts` `GIT_SHA`** (already surfaced in `health.ts`) rather than inventing a label mechanism. *(constraints A6)*

State plainly in the commit message: **the first tag deploy after this lands will trip the guard**, because production was deployed from an uncommitted working tree with no sha stamp. Human queue item 11 must land first, or an `allow-regression` bootstrap receipt must be committed — documented in `functions-break-glass.md`.

**doneCriteria**
```bash
npm --prefix functions run test:unit                       # guard unit tests
node --test scripts/ci/verify-domain-core-workflows.test.mjs
bash scripts/ci/verify-resilience-wiring.sh
# and in the PR body: the exact human sequence for proving the lane (queue items 11-14)
```
**PR lane:** stacked commit onto #2349 with a Cross-agent receipt; if #2349's owner objects, park as `OPEN_WITH_NAMED_BLOCKER`.
**CLI lane:** Codex GPT-5.6 Sol xhigh (provenance/authority code); review `@codex review`.
**scoreDelta:** Reliability/Ops +0.10, Security +0.05, Launch Readiness +0.05, Series A Diligence +0.05.
**Wave-0 status, stated honestly:** every deploy-lane outcome tonight is `OPEN_WITH_NAMED_BLOCKER` — *"#2466 not merged"*, *"environment approval"*, *"Alberto decision on candidate policy"*, *"uncommitted functions tree"*. It counts toward wave-0 gate items 5–7 only.

---

## W0-5 — Alert plane runs without a human

**Findings:** F02. **Branch:** `ops/alert-plane-drift-wif-20260901`. **Lane:** structured-large (**not** fast — it edits a CODEOWNERS security-tree gate). **✅ AGENT-FEASIBLE TONIGHT** (lands honestly red).

> ### ⚠ Verdict-forced changes
> - **The original plan would have failed the required Fast Feedback Gate by construction.** *(feasibility A1, constraints A1)* `scripts/ci/verify-ops-plane-workflow-boundary.mjs` — run in the `no-suppressions` job, a `needs:` member of the required **Fast Feedback Gate**, and again in `workflow-lint.yml` — **hard-requires** the `verify` job to carry `environment: production` and `credentials_json: ${{ secrets.GCP_SA_KEY }}`, with `GCP_SA_KEY` appearing **exactly twice**, plus a `skipped-no-gcp-key` job with fixed markers. The winner plan's doneCriterion ("no `environment:`, no `GCP_SA_KEY`") is the exact inverse.
> - **Do not re-auth the existing `verify` job.** *(feasibility A1)* It also runs Firestore DR, App Check, GitHub governance, and `collect-firebase-security-evidence --strict` (firebaserules, IAM, KMS) — a monitoring/billing/logging viewer SA would fail on IAM, not on the intended `wif-not-provisioned` signal. **Add a NEW `alert-plane-drift` job instead**, leaving `detect-secrets` / `verify` / `skipped-no-gcp-key` byte-compatible with the boundary gate.
> - **Extend the boundary gate as an explicit invariant SWAP, not a deletion.** *(constraints A1)* Add `verify-ops-plane-workflow-boundary.mjs` + `.test.mjs` to fixTouches; the new assertions cover the new job. The PR body must name the old invariant, the new invariant, and why — `scripts/ci/` is a CODEOWNERS security tree.
> - **Fix the concurrency wedge in the same PR.** *(feasibility A3)* Workflow-level `concurrency: {group: ops-plane-verify, cancel-in-progress: false}` becomes `group: ops-plane-verify-${{ github.event_name }}-${{ github.ref }}` with `cancel-in-progress: true` for pull_request/schedule, plus a job-level `ops-plane-apply` group with `cancel-in-progress: false` on the apply path. This unblocks PR runs — **every `pull_request` run since 2026-08-25 was cancelled with zero jobs by the stuck group** — and lets the next schedule clear the stuck run without Alberto.
> - **`ops-confidence` deploy-freshness is not "split"** — it is already WIF-only and has no apply job. *(feasibility A4)* Change only its auth to the viewer repo vars and drop `environment: production`, with the same fail-closed pre-step.
> - **Cut from wave 0** *(A5, constraints A4)*: the `deploy/age_days` metric emitter (needs `roles/monitoring.metricWriter`, a **write** role that contradicts viewer-only) and the budget-notification Cloud Function (new `functions/src` code shipping via `deploy-production.yml`, human).
> - **`scripts/ops/create-billing-budget.sh` is human-run, with a `--dry-run` that prints the gcloud commands.** *(A5)*
> - **scoreDelta 0.3 → 0.05–0.10.** Nothing turns green tonight; the lanes flip from silent `waiting` to honest red.

**Fanout (6 agents):** 1 scout → 3 implementers → 1 adversarial verifier (a schedule run with creds absent must **FAIL**, never skip) → 1 PR author.

**The change**
1. New job `alert-plane-drift` in `ops-plane-verify.yml`: **`if: github.event_name != 'pull_request'`** (mandatory — without it the job's designed-red `wif-not-provisioned` exit would fail the PR's own run, and this workstream's own doneCriteria require that run green); `google-github-actions/auth@v3` (already SHA-pinned at `7c6bc770…`) with `workload_identity_provider: ${{ vars.OPS_VERIFY_WIF_PROVIDER }}` and `service_account: ${{ vars.OPS_VERIFY_SERVICE_ACCOUNT }}`; a pre-step that **exits 1 with `::error::wif-not-provisioned`** when either var is empty; **no `environment:`**; job-level `id-token: write`; own concurrency group with `cancel-in-progress: true`; runs only `scripts/ops/check-ops-alert-plane-drift.mjs` and `check-branch-protection-drift.mjs`.
2. Concurrency fix as above.
3. `ops-confidence.yml` deploy-freshness → viewer vars, no `environment:`, same fail-closed pre-step, `ops-failure-issue` wiring unchanged.
4. Extend `verify-ops-plane-workflow-boundary.mjs` + `.test.mjs` with the new-job assertions (no `environment:`, no `credentials_json`, `vars.*` not `secrets.*`, contains the `wif-not-provisioned` marker, never references `GCP_DEPLOY_SERVICE_ACCOUNT` / `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT`).
5. `scripts/ops/create-billing-budget.sh` — idempotent by `--display-name` lookup, `--threshold-rule=percent=0.5/0.9/1.0`, `--notifications-rule-pubsub-topic`, `--dry-run` mode, `bash -n` + shellcheck clean.
6. `governance/ops-plane-verifier-sa.json` — the exact SA email, role set (`roles/monitoring.viewer`, `roles/billing.viewer`, `roles/logging.viewer`, `roles/iam.securityReviewer`; **no writer roles**), the WIF binding `principalSet://…/attribute.repository/Imagine-That-Ai/BurnBar`, and the two `gh variable set` commands. Referenced from `docs/runbooks/oncall.md`.

**doneCriteria**
```bash
node --test scripts/ops/check-ops-alert-plane-drift.test.mjs
node --test scripts/ops/check-branch-protection-drift.test.mjs
node scripts/ci/verify-ops-plane-workflow-boundary.test.mjs
node scripts/ci/verify-ops-plane-workflow-boundary.mjs          # exit 0 with the NEW invariant
actionlint .github/workflows/ops-plane-verify.yml .github/workflows/ops-confidence.yml

# The PR's own ops-plane-verify pull_request run reaches conclusion=success with NON-ZERO jobs.
#   (every PR run since 2026-08-25 was cancelled with zero jobs by the stuck concurrency group — the
#    run URL goes in the PR body). This is NOT in tension with the new job failing closed, because
#    `alert-plane-drift` is schedule/dispatch-only: on `pull_request` the workflow runs exactly one
#    job, `drift-check-selftest` (ops-plane-verify.yml:41, the only job without an event guard), and
#    `detect-secrets` / `verify` / `skipped-no-gcp-key` all carry `github.event_name != 'pull_request'`.
#    The new job MUST carry the same guard, and the boundary gate asserts it:
grep -q "if: github.event_name != 'pull_request'" <(yq '.jobs.alert-plane-drift' .github/workflows/ops-plane-verify.yml)
gh pr checks <n> --json name,state | jq -e '.[]|select(.name|test("Ops plane verify"))|.state=="SUCCESS"'

# Fail-closed proof, on a dispatch. wif-not-provisioned is the marker WE emit, so it is observable.
gh workflow run ops-plane-verify.yml --ref ops/alert-plane-drift-wif-20260901
gh run view <id> --log-failed | grep -q 'wif-not-provisioned'   # honest red

# The GCP_SA_KEY fail-closed marker is preserved by DIFF, not by grep on a run log.
#   `production DR/governance verification could not run` lives in the `skipped-no-gcp-key` job at
#   ops-plane-verify.yml:192 and is emitted ONLY when github.event_name == 'schedule' AND
#   detect-secrets reports has-gcp-sa-key == 'false'. GCP_SA_KEY exists, and this is a dispatch, so
#   that string is unreachable twice over — the earlier draft's `gh run view <id> --log | grep`
#   criterion could never pass. Assert the invariant statically instead:
git diff 9503b490b0 -- .github/workflows/ops-plane-verify.yml \
  | grep -E "^-.*(production DR/governance verification could not run|event_name.*== 'schedule')" \
  && exit 1 || echo 'schedule fail-closed path byte-preserved'
node scripts/ci/verify-ops-plane-workflow-boundary.mjs   # the boundary gate re-asserts it on every PR
```
**evidence:** the fail-closed dispatch URL; drift self-test output; the non-cancelled PR run URL showing `drift-check-selftest` executed (non-zero jobs); the preserved-invariant diff; `governance/ops-plane-verifier-sa.json`.
**PR lane:** structured-large `ops(alert-plane): drift verification without an approval gate, WIF-only`. Review map: **gate diff → workflows → scripts/docs/governance**. Invariants: schedule stays fail-closed; `apply` stays `environment:`-gated; no JSON key introduced. Rollback = revert restores the `GCP_SA_KEY` path (the secret still exists until human queue item 8 completes).
**CLI lane:** Grok 4.6; boundary-gate rewrite Codex; tests Agy × Gemini; review `@codex review`.
**scoreDelta:** Reliability/Ops +0.05 tonight; **+0.25 contingent** on human queue items 7–9.
**Wave-0 exit state, explicit:** MERGED with a **red-by-design weekly cron documented in `docs/runbooks/oncall.md`**, or `OPEN_WITH_NAMED_BLOCKER: wif-not-provisioned` if Codex objects to merging a known-red schedule. It is never marked green by soft-skipping on missing vars — the adversarial verifier must dispatch and confirm `conclusion=failure` with the named error. Estimated 12–14 agent-hours.


---

## W0-6 — Rollback truth: topology source of truth, runbook lint, honest drill receipt

**Findings:** F03. **Branch:** `ops/runbook-topology-20260901`. **Lane:** fast. **✅ AGENT-FEASIBLE TONIGHT.**

> ### ⚠ Verdict-forced changes
> - **The "dry-run drill receipt" hid a live-credential dependency — and would have been fake-green.** *(feasibility A1, constraints A1)* `scripts/ops/rollback-revision.sh` runs `gcloud run revisions list` and `gcloud run services describe` (lines ~115-127) **before** the `--dry-run` exit at `:199`. No receipt can be produced without an authenticated principal holding `run.revisions.list` on `burnbar`/`burnbar-staging`; this Mac's gcloud is `alberto8793@gmail.com` with default project `imaginethat-llc`. Producing the receipt anyway, then citing it from `docs/TECHNICAL_READINESS.md` as rollback evidence, is exactly the pattern the constraints forbid. **Resolution:** add an offline fixture input, commit the receipt as `launch-evidence/rollback-drill-<date>.fixture-dry-run.json` with `"mode":"fixture","liveDrill":false`, and mark `TECHNICAL_READINESS.md` **PENDING**. The live drill is human queue item 15.
> - **The receipt must pass the confidentiality guard.** *(constraints A2)* `scripts/security/check-public-evidence-redaction.mjs` (`confidentiality-guard.yml:59`) rejects `projects/<id>/locations|services/...`, `*-*.a.run.app` hosts and service-account strings in `launch-evidence/*.json` — the exact fields a real Cloud Run receipt carries. The schema must redact by design.
> - **Drop the generated `ops/topology.json`.** *(feasibility A3, constraints A3)* `scripts/ops/resolve-functions-base-url.sh` is already the region/base-URL source of truth; extend it with a `--print-json` mode. `functions/.env.burnbar.production` carries no project/region. A parallel generator plus a new drift surface violates "extend what exists".
> - **Widen the search scope.** *(feasibility A2)* The `rg` criterion scanned only `docs scripts` and missed the tracked `functions/openapi.yaml`, which carries the same stale `us-central1-openburnbar.cloudfunctions.net` base URL.
> - **Wire the lint as a STEP in an existing fast-feedback job**, not a new job, so the aggregator `needs` list is untouched. *(feasibility A5)*
> - **Fix wave-0 gate item 5.** *(feasibility A4, constraints A10)* `node scripts/ops/verify-runbook-topology.test.mjs` applies only to the W0-6 head; other wave-0 PRs do not contain the file.
> - **Correct the finding text:** `launch-evidence/` on main holds **23** files (AGPL packets, alert-delivery-drill receipts, libsignal bridge receipts, paid proofs), not three. Reuse `scripts/ops/run-alert-delivery-drill.mjs`'s receipt shape and `run-firestore-restore-drill.test.sh`'s `run_case` harness. *(feasibility A8)*
> - **Name the receipt by drill type.** *(A9)* `COMMERCIAL_ROLLBACK.md`'s checklist is a **Hosting/Remote-Config** drill; this is a **Cloud Run revision-pin** drill. Add it as a new "Rollback" row in the `TECHNICAL_READINESS.md` Evidence Boundaries table.
> - **estimatedAgentHours 4 → 7; Launch Readiness 0.2 → 0.05–0.10** until the live staging receipt exists.

**Fanout (6 agents):** 1 scout (enumerate every literal project id / region / cloudfunctions URL; check the tests asserting the openapi base URL) → 3 implementers → 1 adversarial verifier (re-introduce a wrong project id; the lint must exit 1) → 1 PR author.

**The change**
1. `scripts/ops/resolve-functions-base-url.sh --print-json` emitting `{project, stagingProject, region, baseUrl, emulatorProjectIds}` from `.firebaserc`.
2. `scripts/ci/check-runbook-topology.mjs` (extending the `scripts/ci/check-region-literals.mjs` pattern) failing on `<region>-openburnbar.cloudfunctions.net`, `--project openburnbar`, `firebase use openburnbar`, `projects/openburnbar/` in `docs/**`, non-test `scripts/**/*.{sh,mjs}`, `functions/**`, `.github/workflows/**`. Never scans `*.test.*` or `__tests__/`. Allowlist is **exact ids only**: `openburnbar-dev`, `openburnbar-rules-test`, `openburnbar-demo`.
3. Fix `docs/runbooks/rollback-automation.md:105` (`--project openburnbar` → `burnbar`) and `:110`, `functions-break-glass.md:18` (wrong script path), `functions/openapi.yaml` base URL, `docs/api/openapi.yaml:26` emulator server → `http://localhost:5001/burnbar/us-central1`.
4. `scripts/ops/rollback-revision.sh`: `--revisions-json <file>` / `ROLLBACK_REVISIONS_JSON` fixture input (mirroring `FUNCTIONS_LIST_JSON` in `resolve-functions-base-url.sh`), plus a `--drill` mode that records a receipt only from a real gcloud session. `scripts/ops/rollback-revision.test.sh` copying the `run_case` harness.
5. `docs/schemas/rollback-drill-receipt.schema.json` — redaction-safe by design.
6. `docs/TECHNICAL_READINESS.md` gains a **Rollback** row in Evidence Boundaries: *source guard = fixture dry-run + lint; live proof = staging/production revision-pin receipt (**PENDING**)*.

**doneCriteria**
```bash
node scripts/ci/check-runbook-topology.mjs                    # exit 0
node scripts/ci/check-runbook-topology.mjs --fixture bad-project-id   # exit 1
rg -n 'us-central1-openburnbar\.cloudfunctions\.net|firebase use openburnbar|scripts/rollback-revision\.sh|localhost:5001/openburnbar' \
   docs scripts functions --glob '!node_modules/*'            # only allowlisted emulator ids
bash scripts/ops/rollback-revision.test.sh                    # fixture -> exit 0; no gcloud & no fixture -> exit 1
node scripts/security/check-public-evidence-redaction.mjs     # exit 0 with the new file
node scripts/validate-launch-evidence-bundle.mjs              # bundle validator tolerates it
test -f launch-evidence/rollback-drill-2026-09-02.fixture-dry-run.json && \
  jq -e '.mode=="fixture" and .liveDrill==false' launch-evidence/rollback-drill-2026-09-02.fixture-dry-run.json
```
**evidence:** lint + test output; the fixture receipt; the fast-feedback run showing the new **step**.
**PR lane:** fast, one PR `ops(runbooks): topology source of truth + rollback drill as code`. Distinct theme from #2388 (which only touches `docs/CI_RELEASE_RUNBOOK.md`) — not stacked.
**CLI lane:** Grok 4.6; docs/tests Agy × Gemini; review `@codex review`.
**scoreDelta:** Documentation/Maintainability +0.20, Reliability/Ops +0.10, Launch Readiness +0.05 *(+0.15 more when the live staging receipt lands)*.
**Open item carried forward:** the #2195 hazard — `scripts/rollback.sh` should refuse when the target tag is behind the live deployed `OPENBURNBAR_SOURCE_COMMIT` unless `--force`. Either scoped into this PR or filed as a named follow-up issue; not silently dropped. *(constraints A7)*

---

## W0-7 — Toolchains pinned from one file

**Findings:** F24 (first half). **Branch:** `ci/toolchain-pins-20260901`. **Lane:** structured-large. **LANDS LAST.** **✅ AGENT-FEASIBLE TONIGHT.**

> ### ⚠ Verdict-forced changes — the original shape was not implementable
> - **`maxim-lobanov/setup-xcode` has no `xcode-version-file` input**, and `dtolnay/rust-toolchain` **hard-fails** with `'toolchain' is a required input` when the literal is removed — it does **not** read `rust-toolchain.toml`. Both of the winner plan's central mechanisms are fictional. *(constraints A1/A3)*
> - **The exact Xcode pin reverses a documented decision.** `.github/actions/openburnbar-test-matrix/action.yml:28-45` records diligence **P2-8** verbatim: *"no DEVELOPER_DIR pin anywhere… A hard path pin breaks on every image refresh"*, and implements a **major-version drift tripwire** instead. `macos-26` currently defaults to `/Applications/Xcode_26.6.app`. **Resolution:** `.xcode-version` holds a **major/range** (`26` or `^26.0`), read by the existing tripwire (replacing its hardcoded `expected="26"`), plus an ADR at `docs/ARCHITECTURE/006-toolchain-pins.md` that explicitly supersedes the P2-8 float note. *(feasibility A1, constraints A1)*
> - **Rust is deliberately two-toolchain.** `crates/burnbar-remote` pins 1.94.0 and the other three pin 1.96.0; `rust-sast.yml:70-80` is an intentional per-crate matrix (and `openburnbar-iroh` runs on `stable`, which the finding missed). **No root `rust-toolchain.toml`.** Keep per-crate files as the sources of truth; `check-toolchain-pins.mjs` asserts every `toolchain:` literal, every `rustup run X`, every `rust-sast` matrix entry, and the regexes in `scripts/windows-port/test-physical-release-certification.mjs:694-698` equal the channel of the crate they operate on. Aligning `burnbar-remote` to 1.96.0 is **out of scope** — it changes a shipping engine's compiler. *(feasibility A2, constraints A3)*
> - **`rg 'toolchain: "' == 0` is a vacuous criterion** — it misses the three floating `toolchain: stable` sites (`ci-cache-warm.yml:199`, `daemon-pr-gate.yml:68` and `:121`, `computer-use-loopback-test.yml:67`). Replaced with `node scripts/ci/check-toolchain-pins.mjs` plus a negative self-test. *(constraints A3)*
> - **Two Node 24 sites stay on 24**, but **the exemption may not live inside the checker.** *(feasibility A3, constraints A4)* `deploy-hosting.yml:183` and `domain-core-console-release-evidence.yml:97` are deploy/release code (classifier FULL pattern) and cannot be validated on a PR. Burying their paths as literals inside `check-toolchain-pins.mjs` ships a gate that arrives pre-exempted for the only two cases it cannot satisfy — the same shape as an optional-dependency check that passes by not running, and indistinguishable from it in review. **Required shape instead:** a separate committed file `governance/toolchain-pin-exceptions.json`, each entry `{path, line, pin, reason, owner, expiresOn}`; the checker **reads** it, prints every active exception in its normal output so an exempted gate can never look like a clean one, and **fails closed on any entry past `expiresOn`**. Both entries carry `expiresOn: 2026-12-01` and `owner: Ajnunezg`, with the stated exit condition *"convert when the deploy lane has one green `deploy-hosting` run whose Node version can be observed"* — i.e. after human queue items 11–14. A self-test asserts an expired entry fails the checker. The three Node 20 sites (`confidentiality-guard.yml:50`, `computer-use-loopback-test.yml:88`, `openburnbar-pr-harness.yml:1029`) convert to `.nvmrc` with no exception. *(`governance/` is deliberately not `budgets/`: `check-no-suppressions.sh:340` scopes its allowlist requirement to `budgets/*.json`, and `:343` to `*baseline*.{xml,yml,yaml}`, so this file needs no suppression-allowlist entry and creates no suppression — see the W0-11 note on the same point.)*
> - **`global.json` pins the 10.0 floor with `rollForward: latestFeature`, and every `8.0.x` install line stays** — 54 `.csproj` files still target `net8.0`. *(feasibility A4, constraints A7)*
> - **`renovate.json` leaves the doneCriteria.** Dependabot cannot bump `.nvmrc` / `rust-toolchain.toml` / `global.json` / `.xcode-version`, and Renovate has **no Xcode manager**. Installing the app is human queue item 25. Until then, satisfy the need with a read-only `toolchain-freshness` job in `nightly-health.yml` that reports image versions vs pin files as an artifact — **no PR generation**. *(feasibility A5, constraints A5)*
> - **`full-ci` label required.** `.github/workflows/` is `SAFE_NO_PRODUCT` in `classify-ci-impact.mjs:92`, so Daemon/Android/Windows gates would report `skipped` and prove nothing. *(feasibility A7, constraints A6)*
> - **Lands LAST.** *(feasibility A6)* ~84 workflow files against a strict-up-to-date main with six other open workflow PRs. Budget one extra full-CI cycle for the rebase.
> - **scoreDelta Testing/CI 0.2 → 0.08, Reliability/Ops 0.1 → 0.05.**

**Fanout (6 agents):** 1 scout → 3 implementers (node+dotnet / rust+checker / xcode tripwire+ADR+docs) → 1 adversarial verifier (inject `toolchain: stable` and a `macos-15` job using the composite; the lint must reject both) → 1 PR author.

**doneCriteria**
```bash
node scripts/ci/check-toolchain-pins.mjs                       # exit 0; PRINTS the 2 active exceptions
node scripts/ci/check-toolchain-pins.mjs --self-test           # injected `toolchain: "1.95.0"` -> non-zero
#   self-test also covers: an exception whose expiresOn is in the past -> non-zero
#   and: an exception naming a path/line that no longer matches -> non-zero (no stale grandfathering)
jq -e 'length==2 and all(.[]; has("path") and has("line") and has("pin") and has("reason") and has("owner") and has("expiresOn"))' \
   governance/toolchain-pin-exceptions.json
rg -n 'deploy-hosting\.yml|domain-core-console-release-evidence\.yml' scripts/ci/check-toolchain-pins.mjs && exit 1 || echo 'no path literals inside the checker'
rg -n 'node-version: ' .github/workflows                       # exactly the 2 allowlisted Node-24 hits
rg -nE 'toolchain: *("?1\.[0-9]|stable)' .github/workflows     # 0 hits
node scripts/windows-port/test-physical-release-certification.mjs
actionlint $(git ls-files '.github/workflows/*.yml')
gh pr checks <n>   # Daemon PR Gate, Android PR Gate, PR Windows Gate, PR Native Gate all conclusion=success, NOT skipped
```
**evidence:** checker output; the `full-ci` PR check rollup showing every runner-family lane green and none skipped; `gh run view --log` of one `macos-26` job showing the tripwire reading `.xcode-version`.
**PR lane:** structured-large `ci(toolchains): one pin per language`. Review map: composite/tripwire → node sweep → rust pins → dotnet → lint script → docs/ADR. Invariants: **no `DEVELOPER_DIR` hard pin**; no change to privileged `pull_request_target` / `workflow_run` provenance; `burnbar-remote` stays 1.94.0. Validation matrix per runner family. Body must list the lanes that do **not** run on `pull_request` and are therefore unproven until nightly (`release.yml`, `app-pr-gate`, `headless-app-build`, `nightly-e2e`, `openburnbar-pr-harness`, `ci-cache-warm`). Rollback = revert the single commit.
**CLI lane:** Grok 4.6; tests Agy × Gemini; review `@codex review`.
**scoreDelta:** Testing/CI +0.08, Reliability/Ops +0.05. *(The remaining +0.12/+0.05 is credited to W1-6, which actually adds tests.)*
**Risks:** a wrong pin fails every Mac lane at once. Fix wave-0 gate item 5 so `check-toolchain-pins.mjs` runs only on this branch. Estimated 8–10 agent-hours.

---

## W0-8 — Supply-chain truth (branch-provable half only)

**Findings:** F15; **F08 partial (checksum manifest only)**. **Branch:** `security/supply-chain-vendor-integrity-20260901`. **Lane:** structured-large. **✅ AGENT-FEASIBLE TONIGHT** (runtime proof deferred to the next tag).

> ### ⚠ Verdict-forced changes
> - **The end-to-end proof is impossible tonight, by workflow design.** *(feasibility A1, constraints A1)* `supply-chain-provenance.yml:48-53` **refuses** any `workflow_dispatch` whose `GITHUB_REF` is not `refs/tags/<tag>` — so a dispatch "against the latest v* tag" executes **the tag's copy** of the YAML, still carrying the broken `cosign attest --predicate-type` at `:135-143`, never main's fix. The only path that exercises the merged fix is `workflow_run` after a **successful** "OpenBurnBar Release" — and `release.yml` has failed at *Release Preflight* on the last six tag pushes, which is why the last 8 provenance runs are `skipped`.
> - **The evidence line "attestation verify logs from a dispatch on the branch" is unobtainable** — none of these workflows has a branch test lane, and a dispatch publishes real release assets. *(A2)*
> - **Drop `domain-core.yml` entirely.** *(feasibility A3, constraints A3)* `domain-core.yml:745-748` **already** runs `scripts/build-domain-core-android-aar.sh --check-artifact`, which rebuilds and byte-compares (`cmp -s`, `SOURCE_DATE_EPOCH`, pinned NDK, `kotlin.sha256` provenance) inside the merge-queue-required Domain Core PR Gate. The finding's premise (b) is stale.
> - **`burnbar-remote` AAR byte-gate is a separate follow-up PR.** The committed AAR is **stale** (`Cargo.lock` changed 2026-08-20; the AAR is from 2026-08-18), so adding the gate now reddens the theme. If it is not byte-reproducible, that hunk carries `OPEN_WITH_NAMED_BLOCKER: burnbar-remote AAR not byte-reproducible (toolchain drift)` and the rest of the theme still lands — the workflow is a path-scoped `pull_request`, not a required context.
> - **Prefer deleting the mislabelled step over adding a second one.** *(constraints A4)* `release.yml:2419-2420` already attests SBOM and VEX with the `openburnbar.dev` predicate and `verify-release-attestations.sh` already verifies both. So `supply-chain-provenance.yml` should either drop its own SBOM attest and become a pure post-release **verifier**, or use `actions/attest-sbom`. **Do not** wire its failure into any PR/merge-group required context.
> - **The checksum manifest is written by the existing build scripts**, not by a parallel tool, so a legitimate AAR refresh never goes red on the door. *(constraints A5)*
> - **Verify backward compatibility first — and widen the accepted-identity set only with a written sunset.** *(constraints A6)* Extend `verify-release-attestations.sh` to accept **both** predicate identities and self-test it against the already-published latest v* release (which has only the `openburnbar.dev` predicate) **before** adding `attest-build-provenance` to the release workflows.
>   **This is a verifier relaxation and must be labelled as one.** Widening an attestation verifier's accepted-identity set inside a workstream titled *"supply-chain truth"* is exactly the move a hostile reviewer flags, and the existing negative test (*"swapped predicateType still rejected"*, `:195-208`) does **not** constrain it, because after the change both types are accepted. The dual-accept window therefore ships with all three of:
>   1. **A named sunset in the code and the PR body:** `openburnbar.dev/sbom` is accepted **only** for tags at or before the last release that used it; from the **second** tag after this lands, `https://slsa.dev/provenance/v1` is the sole accepted predicate for DMG/ZIP/AppImage/MSIX/checksums subjects, and the legacy branch is deleted, not merely unused.
>   2. **A committed expiry constant** `LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG` in `verify-release-attestations.sh`, with a self-test asserting the verifier **rejects** the legacy predicate for a tag newer than that constant. That is the assertion the old negative test used to provide, restored in the new shape.
>   3. **A row in `docs/security/SUPPLY_CHAIN_PROVENANCE.md`** naming which predicate each artifact class carries today, which it carries after the sunset, and the tag at which the switch happens.
>   Without (1)–(3) this hunk does not land; the vendor-checksum and mislabelled-attest-deletion commits land without it.
> - **Remove F08 from the headline coverage** or rename it "F08 partial"; Series A Diligence 0.2 → 0.1. *(feasibility A7)*
> - **estimatedAgentHours 16 → 26; fanout 8 → 7** (no domain-core implementer).

**Fanout (7 agents):** 1 scout (reproduce the cosign `unknown flag --predicate-type` failure; read `verify-release-attestations.sh` predicate expectations) → 4 implementers → 1 adversarial verifier (tamper an AAR byte in a temp worktree; the door check must exit 1) → 1 PR author.

**Commit order — branch-provable work first, release-workflow hunk last with its own rollback SHA:**
1. `supply-chain-provenance.yml` no longer calls `cosign attest` on a file path (stop labelling an SBOM attestation as SLSA provenance).
2. `Vendor/CHECKSUMS.sha256` covering the three AARs and the four xcframeworks; `scripts/supply-chain/verify-vendor-checksums.sh` (`sha256sum -c`) added as a **fast** fast-feedback job (a few seconds over ~100 MB) in the `Fast Feedback Gate` needs list; `scripts/build-iroh-android-aar.sh`, `build-burnbar-remote-android-aar.sh`, `build-domain-core-android-aar.sh` write their manifest entry as their last step.
3. `Vendor/GRDB-SQLCipher/UPSTREAM.md` — upstream tag `v6.29.3`, tarball sha256 `256b4f2eb33a712c95eb3e4c7f7c7acdebc8df778c80d1e05d161830c6dd2d08`, `SQLCipher.swift` 4.16.0 pin, system-SQLCipher link mode, CSQLite shim — plus one generated `patches/0001-openburnbar-sqlcipher.patch` produced with `diff -ruN -w` to strip the 8,000+ whitespace-only lines.
4. `verify-release-attestations.sh` accepts both predicate types; self-test proves it still rejects a swapped `predicateType` (already tested at `:195-208`) **and** verifies the existing latest release.
5. **Last commit:** `actions/attest-build-provenance@v3` (SHA-pinned, with the repo's `# vX.Y.Z (node24-native)` comment convention) over DMG/ZIP/AppImage/MSIX/checksums in `release.yml`, `linux-release.yml`, `openburnbar-release-windows.yml`; confirm **job-level** `attestations: write` (not only top-level) at each insertion point (`openburnbar-release-windows.yml` has `id-token` at `:1080` and `attestations` at `:1334-1336`).
6. `docs/security/SUPPLY_CHAIN_PROVENANCE.md` matrix (artifact × attestation type × verifier), checked by an `rg`-based test.

**doneCriteria**
```bash
bash scripts/supply-chain/verify-vendor-checksums.sh          # exit 0
# tamper test in a TEMP worktree (never commit tampered bytes):
( cd $(mktemp -d) && cp <repo>/Vendor/burnbar-remote.aar . && printf '\x00' | dd of=burnbar-remote.aar bs=1 seek=1024 conv=notrunc && \
  bash <repo>/scripts/supply-chain/verify-vendor-checksums.sh ) ; test $? -ne 0
bash scripts/ci/verify-release-attestations.test.sh           # both predicate types accepted inside the window
#   NEW cases, without which the widening is an unconstrained relaxation:
#     legacy openburnbar.dev predicate on a tag <= LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG -> accepted
#     legacy openburnbar.dev predicate on a tag AFTER that constant                    -> REJECTED
#     a predicateType that is neither identity, on any tag                             -> REJECTED
grep -q 'LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG' scripts/ci/verify-release-attestations.sh
rg -q 'sunset|LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG' docs/security/SUPPLY_CHAIN_PROVENANCE.md
bash scripts/ci/verify-release-attestations.sh <latest-v-tag> # backward-compatible against the existing release
actionlint .github/workflows/supply-chain-provenance.yml .github/workflows/release.yml \
           .github/workflows/linux-release.yml .github/workflows/openburnbar-release-windows.yml
node --test scripts/ci/verify-supply-chain-doc-matrix.test.mjs
sha256sum -c <(grep GRDB Vendor/CHECKSUMS.sha256)             # UPSTREAM.md tarball checksum matches
```
**Deferred to the next tag (recorded in the PR as Known Risks, not claimed):** the `workflow_run` of `supply-chain-provenance.yml` after the next OpenBurnBar Release concludes `success` and `gh attestation verify --signer-workflow --deny-self-hosted-runners --predicate-type https://slsa.dev/provenance/v1` passes on every asset. **Human queue item 14** is the prerequisite (fix Release Preflight, then cut a tag).

**PR lane:** structured-large `security(supply-chain): real provenance + vendor integrity`. Invariants: (1) no PR/merge-group required context is added or changed; (2) `domain-core.yml` and `burnbar-ci-gate.yml` untouched; (3) `verify-release-attestations.sh` stays strict on predicate identity; (4) no new secrets (keyless OIDC). Validation matrix must state per row whether it is **proven on branch** or **proven at next tag release**. Rollback: the attestation commit is independently revertable before the next tag; its SHA goes in the PR body.
**CLI lane:** Codex GPT-5.6 Sol xhigh; workflow plumbing Grok; tests/docs Agy × Gemini; review `@codex review`.
**scoreDelta:** **on merge** Security +0.10; **at first verified tag release** Security +0.20 and Series A Diligence +0.10.
**Risks:** `build-iroh-android-aar.yml` is flaky (UniFFI `invalid utf-8 sequence` at 2026-09-01T16:10Z, pass at 16:20Z); touching `.github/workflows/build-*-aar.yml` re-triggers those 12–23 min lanes and a flake must be **re-run, not skipped**.

---

## W0-9 — Security docs as machine-checked claims  → **DEFERRED TO WAVE 1**

**Findings:** F16. **Both lenses moved this out of wave 0.** It contributes to no wave-0 gate condition, and it forces **full CI** via three separate `classify-ci-impact.mjs` FULL_PATTERNS (`security-pr.yml`, `storage.rules`, CODEOWNERS). Its slot is taken by the grafted W0-10 / W0-11 / W0-12. Full spec appears under **[Wave 1 → W0-9](#w0-9-deferred--security-docs-as-machine-checked-claims)**.

The corrections that carry forward are recorded there, most importantly: **`scripts/ci/check-security-claims.sh` + `scripts/ci/_extract_security_claim_paths.py` already exist on main** (dead — their input `security/threat-model/security-claims.md` was removed in `ab4caa0985`, wired into zero workflows), and `.github/CODEOWNERS:60` names a `scripts/ci/verify-security-claims.sh` that does not exist. The winner plan would have created a third same-stem script beside two dead ones.

---

## W0-10 — Swift SAST: CodeQL Metal toolchain + Semgrep observing

> **Grafted in** from plan-3 W0-G on the explicit instruction of **all three judge panels**, and forced out of W0-2 by the W0-2 feasibility verdict.

**Findings:** F06. **Branch:** `ci/swift-sast-20260901`. **Lane:** fast, **own PR**. **✅ AGENT-FEASIBLE TONIGHT.**

**Why it is separate:** each CodeQL Swift iteration is a **60–120 minute** hosted `macos-26` run. The 2026-09-01 run `33517666151` hits the Metal error **75 minutes in**, after the entire non-Metal build completes. Bundled with W0-2 it would hold the nightly-honesty theme hostage for the whole night.

> ### ⚠ Verdict-forced changes
> - **No `push-to-main` trigger.** *(W0-2 feasibility A3)* The 2026-07-31 cost hardening removed it; the public repo shares 5 concurrent macOS jobs with Daemon PR Gate in the merge queue. **schedule + `workflow_dispatch` only.**
> - **Add a preflight `xcrun -f metal` check** so a toolchain miss fails in **seconds**, not at minute 75.
> - **Do not switch the traced build to arm64** on F06's "the arm64 cryptex is already present" theory — it is **unconfirmed**; the successful arm64 `app-pr-gate` run `33326737617` shows **no** `CompileMetalFile` lines. *(W0-2 feasibility A4)*
> - **If the 150-minute cap is hit, park as `OPEN_WITH_NAMED_BLOCKER: traced Swift build exceeds cap`.** Never raise `timeout-minutes`.
> - **Never remove `swift` from the codeql matrix** to make the lane green. That is on the fake-green blacklist.

**Fanout (3 agents):** 1 implementer (Metal toolchain caching + `codeql-config.yml` + traced build factored into `scripts/ci/codeql-swift-build.sh`) → 1 implementer (Semgrep swift job, observing-only, SARIF artifact, **not** in the Fast Feedback Gate needs list) → 1 PR author.

**doneCriteria**
```bash
gh workflow run codeql.yml --ref ci/swift-sast-20260901
gh run view <id> --log | grep -q 'cannot execute tool metal' && exit 1 || echo 'metal ok'
gh run view <id> --json jobs --jq '.jobs[]|select(.name|test("swift"))|.conclusion'   # success, SARIF uploaded under /language:swift
gh run view <id> --log | grep -c 'xcrun -f metal'   # preflight ran first
actionlint .github/workflows/codeql.yml
git diff 9503b490b0 -- .github/workflows/codeql.yml | grep -E '^\+.*timeout-minutes|^-.*swift' && exit 1 || echo 'no cap raise, swift still analyzed'
```
**evidence:** the dispatch run URL with SARIF uploaded; the Semgrep SARIF artifact.
**PR lane:** fast, `ci(sast): Swift CodeQL Metal toolchain + Semgrep observing`.
**scoreDelta:** Security +0.10, Launch Readiness +0.10 *(this is the **only one of the six launch blockers** an agent can fully close tonight)*.
**Risks:** the lane may move from a deterministic red to a **timeout** red; the June 2026 note records a cap timeout on this same traced build. That outcome is a named blocker, not a cap raise. 3–4 dispatch cycles is the whole night.

---

## W0-11 — Data room, root-inventory ratchet, and the generated release-status block

> **Grafted in** from plan-3 W0-A/W0-B and plan-0 W0-05, on the instruction of **all three judge panels**. Pulls the cheapest real points forward from W1-5 and W1-7.

**Findings:** F09 (status block), F34 (root hygiene), F35 (handover skeleton). **Branch:** `docs/data-room-and-release-status-20260901`. **Lane:** fast. **✅ AGENT-FEASIBLE TONIGHT.**

**Fanout (6 agents):** 1 scout (inventory the 57 tracked root blobs and every inbound link) → 3 implementers → 1 link-fixer → 1 PR author.

**The change**
1. **`docs/data-room/INDEX.md`** with eight diligence sections — clone/layout, claims vs ledgers, CI health, deploy proof, security harness, supply chain, bus factor, depth — and **`scripts/ci/verify-data-room.mjs --check`**. Every wave-0/1 PR from here on deposits one row: `claim | evidence path or --check command | last-verified | owner`. **`verify-data-room --check` joins every wave gate.**
2. **Root hygiene as a shrink-only ratchet, not an absolute allowlist — and deliberately NOT under `budgets/`.** *(W1-7 constraints verdict, plus the fake-green review of this plan's own first draft)* "Root contains only allowlisted files" is **unachievable**: `git ls-tree origin/main | awk '$2=="blob"' | wc -l` = **57** tracked root blobs (119 entries − 62 directories), ~30 of them tool-mandated there (`package.json`, `package-lock.json`, `firebase.json`, `firestore.rules`, `firestore.indexes.json`, `storage.rules`, `Makefile`, `project.yml`, `ruff.toml`, `.swiftlint.yml`, `index.html`, `REUSE.toml`, `knip.json`, `osv-scanner.toml`, `docker-compose.yml`, `.node-version` …).

   > **⚠ Shape correction — the first draft of this item committed the exact move this document's own blacklist forbids.** It created `budgets/root-clutter-baseline.json` **and** added its path to the single `<!-- BEGIN:suppression-allowlist -->` block in `docs/LINT_RATIONALE.md` specifically so `check-no-suppressions.sh` would not reject it — while the blacklist scores *"adding `budgets/*.json` entries"* at **zero** and W0-12 states the rule *"do not touch `budgets/*.json` … or add any suppression."* A plan cannot blacklist a move and then book the largest wave-0 delta for it. **The manifest moves out of `budgets/` entirely.**
   >
   > `scripts/ci/check-no-suppressions.sh` §4 (`:337-345`) requires an allowlist entry for exactly two file classes: `budgets/*.json` (`:340`) and basenames matching `*baseline*.{xml,yml,yaml}` (`:343` — note `.json` is **not** in that extension list). A file at **`governance/root-inventory.json`** matches neither rule, needs **no** `docs/LINT_RATIONALE.md` entry, and creates **no** suppression. `governance/` already houses exactly this kind of committed policy state (`branch-protection.main.json`, `burnbar-ci-gate*.json`, `workflow-reachability.json`). The word "baseline" is also dropped from the filename so the file never reads as a lint baseline in review.

   **Final shape:** `governance/root-inventory.json` records the current 57 paths with a one-line purpose each; the check fails only when a **new** unlisted root path appears; the list may only shrink, and a shrink must be accompanied by the deletion or move in the same commit. Enforced by a **new** `scripts/ci/check-root-inventory.sh` (bash, matching the `check-*-budget.sh` idiom) wired as one more **step** in the existing `Debt budgets (shrink-only ratchets)` job — `fast-feedback.yml:1481-1526` already enumerates thirteen such steps — and one more line in the `Makefile:314` `debt-check` target. **No new fast-feedback job, no new aggregator `needs` entry, no new required context, no `budgets/` file, no suppression-allowlist entry.**

   > **Why not extend `check-no-committed-build-artifacts.sh`,** as the first draft proposed: that script is 25 lines of bash that walks `git ls-files -z` for `*.pcm` / `ModuleCache` / `DerivedData` / `.derived-data` paths and **takes no arguments**. It is not a root-hygiene checker and cannot become one without changing what its name promises — and the criterion the draft wrote for it (`node scripts/ci/check-no-committed-build-artifacts.sh --fixture …`) is wrong three ways over: it is bash not node, it accepts no flags, and it does not look at the root.
3. **Move** `DILIGENCE_REPORT_2026-06-10/06-11/07-12/07-14.md`, `TECH_DEBT_AUDIT_2026-06-11/06-30.md`, `SECURITY_REVIEW_2026-06-17.md`, `HANDOFF_MERGE_TO_MAIN_2026-06-12.md` → `docs/audits/<yyyy-mm>/` with a generated `docs/audits/INDEX.md`. **Delete** `tmp-utm-desktop.png` (5,001,686 B) and `docs/linux-port/evidence/mission-001-shell-ux/OpenBurnBar_0.1.0_arm64.deb` (7,108,984 B). Rewrite inbound links **only** in `docs/**`, `plans/**`, `.agents/**`, `README`, `AGENTS.md` — leave the comment-only references in `scripts/diff-coverage.sh:33,180`, `scripts/diff-coverage-ts.sh:96`, `.github/workflows/fast-feedback.yml:195` and `ops/firestore-ttl-policies.json:25` untouched (`scripts/diff-coverage*` matches a macOS LANE_PATTERN and a comment edit there wakes the macOS lane).
4. **Generated README release-status block.** `docs/status/release-status.json` + `scripts/release/render-release-status.mjs --check` writing between `<!-- release-status:start -->` markers, plus `docs/status/surfaces.json` listing exactly eight surfaces (`macos, ios, android, windows, linux, daemon, extension, cli`) each with a tier and an evidence link.
   > **Two hard invariants forced by the W1-5 verdicts:** (a) the renderer reads **only committed files, never `git tag`** — the enforcing job's checkout is `filter: blob:none` with **no tags**, and `git tag -l 'v*' --sort=-v:refname | head -1` returns `v2026.7.30` (34 local / 20 remote CalVer tags) while `--sort=-creatordate` returns `v1.0.40+repair.37`; neither is "1.0.40". (b) the block **must preserve the literal shape** `**Status:** … macOS \`X.Y.Z\`` with X.Y.Z taken from `project.yml` `MARKETING_VERSION`, because `scripts/verify-version-consistency.sh:54` extracts it with `.*Status:.*macOS \`([^\`]+)\`.*` and hard-fails the required Fast Feedback Gate on mismatch. *(`:54`, not `:56` — `:56` is the extension `package.json` check, and an implementer editing the wrong line finds a passing regex and a failing job.)* Also preserve README's AGPL-3.0-only declaration and MIT upstream-boundary sentences (`scripts/ci/check_burnbar_license_posture.py:152-159`, `scripts/ci/verify-agpl-compliance.sh:99`).
   > Store-facing claims render as **`operator-asserted (last confirmed <date>)`** from `docs/status/release-status.input.json`, which **Alberto authors** (human queue item 16) — no repo file encodes Apple review state.
5. `docs/runbooks/HANDOVER.md` + `docs/ops/ACCESS_INVENTORY.md` with explicit `UNSET` slots + `scripts/ops/verify-access-inventory.sh --schema` (validates the document is well-formed; the credentialed `--live` mode is expected to fail until a second human exists). *(grafted from plan-0 W0-13, per judges 1 and 3)*
6. **Confidentiality precondition:** before committing anything into `docs/`, run `node scripts/security/scan-internal-content.mjs`. `FABLE-DILIGENCE_REPORT_2026-09-01.md` and `TECH_DEBT_AUDIT_2026-09-01.md` are **untracked** and carry no `BurnBar-Confidential` banner — this is a **public** repo, and the `guard` context scans the full tracked tree. Leave them untracked unless banner-ed. *(W1-7 feasibility verdict)*

**doneCriteria**
```bash
node scripts/ci/verify-data-room.mjs --check                # exit 0
node scripts/release/render-release-status.mjs --check      # exit 0
# mutation proof: the block really reads the ledger, it is not a hardcoded string
jq '.productParityClaim=true' docs/mobile-parity/mobile-parity-ledger.json > /tmp/l.json && cp /tmp/l.json docs/mobile-parity/mobile-parity-ledger.json
node scripts/release/render-release-status.mjs --check ; test $? -ne 0 ; git checkout docs/mobile-parity/mobile-parity-ledger.json
bash scripts/verify-version-consistency.sh                  # exit 0 — the README status-line regex at :54 still matches

# no suppression is created by this PR: the root manifest lives OUTSIDE budgets/
bash scripts/ci/check-no-suppressions.sh                    # exit 0
git diff 9503b490b0 --name-only | grep -E '^budgets/' && exit 1 || echo 'no budgets/ file added'
git diff 9503b490b0 -- docs/LINT_RATIONALE.md | grep -E '^\+' | grep -v '^\+\+\+' && exit 1 || echo 'no allowlist entry added'

# the root ratchet, with a real mutation proof
bash scripts/ci/check-root-inventory.sh                     # exit 0 against the committed 57
bash scripts/ci/check-root-inventory.sh --self-test         # temp tree + an unlisted root file -> non-zero
#   and: a listed path removed from the manifest while the file still exists -> non-zero (shrink must be real)
#   and: growing the manifest by one entry                                    -> non-zero (shrink-only)
python3 -c "import json;m=json.load(open('governance/root-inventory.json'));assert len(m['paths'])==57, len(m['paths'])"

# runs inside the existing Debt budgets job — assert the wiring, do not assume it
grep -q 'check-root-inventory.sh' .github/workflows/fast-feedback.yml
grep -q 'check-root-inventory.sh' Makefile
# NOTE: `make debt-check` also runs scripts/ci/update-tech-debt-metrics.sh, which REWRITES the tracked
# docs/TECH_DEBT_METRICS.md (Makefile:325). Run it, then commit the regenerated file in this same PR:
make debt-check && git status --porcelain docs/TECH_DEBT_METRICS.md   # must be empty after the commit

bash scripts/ops/verify-access-inventory.sh --schema        # exit 0
node scripts/security/scan-internal-content.mjs             # exit 0
python3 -c "import json;s=json.load(open('docs/status/surfaces.json'));assert sorted(x['id'] for x in s)==['android','cli','daemon','extension','ios','linux','macos','windows']"
```
**PR lane:** fast, `docs(diligence): data room, root ratchet, generated release status`.
**CLI lane:** Grok 4.6; bulk moves + link fixes Agy × Gemini; wording Fable (small); review `@codex review`.
**scoreDelta:** Documentation/Maintainability +0.35, Overall Professionalism +0.15, Series A Diligence +0.15, Launch Readiness +0.05.
**Risks:** low. This is the highest points-per-hour item on the board and the first thing a reviewer reads. Estimated 14 agent-hours.

---

## W0-12 — BOLA strict-gap ledger: measure the real denial code

> **Grafted forward** from plan-3 W0-F, on the instruction of **all three judge panels**, and re-shaped by the W1-1 feasibility verdict. This is the largest no-human security delta available tonight.

**Findings:** F11 (harness half). **Branch:** `security/bola-strict-gap-ledger-20260901`. **Lane:** structured-large. **✅ AGENT-FEASIBLE TONIGHT.** No Mac dependency, no new npm dependency.

**Current state:** `BOLA_STRICT_CODE_ENDPOINTS` in `functions/src/__tests__/bola/callableBolaHarness.ts` has exactly **7** entries (`burnBarHermesGateway`, `cancel`/`complete`/`consumeCredentialTransfer`, `pollCliLink`, `triggerVoIPCall`, `validateOpenTimestampsProof`) — roughly 5% of the surface. Everything else accepts **any** denial code via `ANY_CALLABLE_DENIAL_CODE` plus message regexes, so a cross-tenant id that leaks existence through `invalid-argument` reads as a pass.

> ### ⚠ Verdict-forced shape (from the W1-1 feasibility and constraints verdicts)
> - **Scout first, fanout second.** Run `npm run test:bola` with `expectCallableDenial` forced strict and report the actual failing-endpoint list. **That number, not a guess, sets the implementer count.** Do not size this workstream in advance.
> - **Measure, then shrink — do not redden the door tonight.** Record the measured per-endpoint code into a **shrink-only `BOLA_STRICT_CODE_PENDING` ledger**; `bolaCoverage.test.ts` fails if the list **grows**. Delete `ANY_CALLABLE_DENIAL_CODE` and the message regexes now. W1-1a then drains the pending list rather than starting from zero.
> - **Ship a committed decision table.** `functions/scripts/generate-endpoint-catalog.mjs` emits `bolaExpectedCodes.generated.ts` mapping each of the **95 objectId endpoints** to exactly one expected code (`not-found` vs `permission-denied`), so "exact code" is a checkable artifact. `bolaCoverage.test.ts` asserts every objectId entry has an `expectedCode`.
> - **Reuse `snapshotTenantPaths` / `expectTenantPathsUnchanged`** for the zero-write assertion instead of inventing a ledger.
> - **Scope fence: `functions/**` only.** No TypeSpec, no zod, no Swift/Kotlin generated models — those pull native and Android lanes into the PR and turn a functions security fix into a merge-queue-wall PR.
> - **Uniform denial contract, not literal ordering.** *(W1-1 constraints A6)* Require the **same** `HttpsError` code and generic message for malformed, foreign and missing ids on each objectId endpoint; format/length checks may still run first as long as they emit the code the harness asserts, so unvalidated strings never reach a Firestore read.
> - **Correct the facts the winner plan carried:** **23** `*.bola.test.ts` files (not 24); `strictCode` is passed at 6 sites in `linuxAppCheckMintHandler` / `phoneControlPairingBinding` / `linuxAppCheckDevices` tests, none in the bola dir; **213** catalog entries, **95** objectId endpoints.
> - **Do not touch `budgets/*.json`, `.jscpd.json` thresholds, or add any suppression.** Put shared helpers under `functions/src/security/**` (excluded from the hand-maintained TS count) so `tools/schema-sync/check-drift.sh` and `scripts/ci/knip-ratchet.sh` stay green.

**Fanout (5 agents + scout-determined implementers):** 1 scout (the strict run + failing list) → N implementers (N = measured, expect 3–6) → 1 adversarial verifier (craft a cross-tenant id that currently leaks existence via `invalid-argument`) → 1 PR author.

**doneCriteria**
```bash
cd functions && npm run lint && npm run test:unit && npm run test:security      # all exit 0
rg -n 'ANY_CALLABLE_DENIAL_CODE|DENIAL_MESSAGE_PATTERNS' functions/src          # 0 hits
node functions/scripts/generate-endpoint-catalog.mjs && git diff --exit-code \
  functions/src/security/endpointAuthorizationCatalog.generated.ts functions/src/__tests__/bola/bolaExpectedCodes.generated.ts

# The coverage test is at functions/src/__tests__/bolaCoverage.test.ts (NOT .../__tests__/bola/), it
# imports { describe, expect, it } from "vitest", and it is the file that already imports
# BOLA_STRICT_CODE_ENDPOINTS from ./bola/callableBolaHarness.js. `node --test` cannot run it.
# Extending what exists is this workstream's own stated rule, so extend that file — do not add one.
npx --prefix functions vitest run src/__tests__/bolaCoverage.test.ts
#   every objectId entry has an expectedCode
#   BOLA_STRICT_CODE_PENDING is shrink-only: adding an entry fails the test

# ...and it must actually run on the door. functions/package.json:38 `test:security` today lists
# src/__tests__/bolaCoverageValidators.test.ts but NOT bolaCoverage.test.ts, so the pending ledger
# would be enforced by a test no required context executes. Add it in this PR and assert the wiring:
node -e "const s=require('./functions/package.json').scripts['test:security'];process.exit(s.includes('src/__tests__/bolaCoverage.test.ts')?0:1)"
bash scripts/ci/verify-resilience-wiring.sh
bash scripts/ci/check-no-suppressions.sh
bash tools/schema-sync/check-drift.sh
```
**evidence:** the scout's strict-run failing list (pasted verbatim in the PR body); before/after `BOLA_STRICT_CODE_PENDING` counts; the vitest + BOLA logs.
**PR lane:** structured-large `security(functions): BOLA strict-gap ledger — measured denial codes`. Review map by callable domain. Invariant: **client-visible error strings preserved or explicitly enumerated** with the Swift/Kotlin call sites that consume them.
**CLI lane:** Codex GPT-5.6 Sol xhigh (harness); per-file fixes Grok; review `@codex review`.
**scoreDelta:** Security **+0.10**, Testing/CI **+0.15**. Weighted on merge: **3.75**.
> **Why Security was cut 0.20 → 0.10, and the 0.10 moved to W1-1a.** The first draft booked the **largest wave-0 security delta** for *recording* the gap. That is the wrong ratio and it is worth saying out loud: this workstream deletes `ANY_CALLABLE_DENIAL_CODE` and the message regexes — real — but then parks every currently-failing endpoint in `BOLA_STRICT_CODE_PENDING`, so **day-one enforcement across the ~88 non-strict endpoints is roughly unchanged**. What genuinely changes tonight is that the gap becomes *measured, committed and unable to grow*, and that a per-endpoint `expectedCode` decision table exists. That is measurement, and measurement is worth about half of a fix. **W1-1a, which actually drains the ledger to empty and gives every failing handler the uniform denial contract, takes Security +0.30 → +0.40** — the same 1.5 weighted points, booked where the endpoints actually get fixed. Net effect on the plan's total: zero. Net effect on honesty: the wave-0 number no longer claims a security improvement the code does not yet make.
>
> The one thing the ledger buys immediately and unconditionally: **it cannot grow.** `bolaCoverage.test.ts` fails if an entry is added, and it now runs in the required `Functions (security vitest)` context (see doneCriteria). New endpoints therefore ship strict from birth.

**Risks:** `Functions (security vitest)` is a **required** context, so this cannot go fake-green — but it also means any endpoint whose handler must change lands in the same PR. If the scout's failing list is large (>15), the ledger absorbs the remainder tonight and W1-1a drains it. Estimated 16–24 agent-hours depending on the measured list.


---

# WAVE 1 — Security and backend truth (nights of 2026-09-02 → 09-05)

**Preconditions, all hard:**
- Human queue items **1–7** cleared. Without item 1 nothing merges at all.
- **No wave-1 PR opens before #2466 merges.** Every merge-queue candidate currently fails closed on OSV.
- `app-pr-gate.yml` must be **green at least once on main** before any workstream claims Swift evidence. It has failed **12 of its last 17 main runs**, and its scheduled runs failed on 2026-08-28/29/30/31 and 09-01, every time at `Enforce real macOS idle/occluded CPU budget (P-PERF-3)` inside `AgentLens Rust + Swift build/test prerequisites`, so `App build + test (AgentLens)` aborts in 3 seconds. **W0-2 implementer (e) owns that root cause.**
- **Approve → merge → approve, serialized.** Every merge into main dismisses the other PRs' approvals.

## Wave-1 exit gate — corrected

The winner plan's gate named three artifacts that **do not exist on main**. Corrected:

1. `deploy-production.yml` on a tag concludes `success` **with job `deploy-functions` executed** (`gh run view --json jobs` shows `deploy-functions conclusion=success`, not `skipped` — the 2026-08-04 "last success" had it skipped), and `ops-confidence` deploy-freshness reports `cloudFunctions` age < 2 days.
2. `ci/nightly-health.json` on main shows all six lanes green for **2 consecutive nights** *(artifact created by W0-2; the winner plan cited it before it existed)*.
3. `circuitBreaker.mode=enforce` merged in **both** governance files **and two** subsequent `merge_group` runs carry the breaker annotation — one on the flip PR itself (evaluated under main's observe copy) and one on the next PR merged after it *(both gate configs are read from the trusted base tree, so one run proves nothing)*.
4. `npm --prefix functions run test:security` green with `BOLA_STRICT_CODE_PENDING` **empty** and every objectId endpoint asserting its `expectedCode`.
5. **`bash scripts/verify-version-consistency.sh` exits 0 on main** *(corrected: `scripts/release/verify-version-consistency.mjs` does not exist — there is no `scripts/release/` directory, and a shell script has no "report mode")*, **and** `node scripts/ci/verify-release-versions.mjs --strict` exits non-zero only on entries present in `versions.json` `allowedDrift`, each carrying `{surface, expected, actual, reason, owner, expiresOn}` and failing closed past `expiresOn`.
6. `ops-plane-verify.yml` **`alert-plane-drift` job** concludes `success` via WIF with no environment wait *(the `verify` job keeps its `environment: production` — see W0-5)*.
7. `node scripts/ci/verify-data-room.mjs --check` exits 0 with a row from every wave-1 workstream.
8. Every wave-1 PR is MERGED or `OPEN_WITH_NAMED_BLOCKER`.

---

## W0-9 (deferred) — Security docs as machine-checked claims

**Findings:** F16. **Branch:** `docs/security-claims-manifest-20260902`. **Lane:** **full-CI PR (classifier-forced)**, not fast. **✅ AGENT-FEASIBLE.**

All four contradictions are live on main: `SECURITY.md:54` says Signal paths are "wired/readiness-gated, not marketed as live production coverage" while `README.md:73` and `:454` market on-device sealing as shipped; `SECURITY.md:63` claims no staging environment while `functions/.env.burnbar-staging` + `deploy-staging*.yml` exist; `SECURITY.md:70` carries an accepted cross-tenant avatar risk that `storage.rules:31` (`allow read: if isActiveOwner(userId)`) already closed; `README:468` and `THREAT_MODEL:142` present the 12-key denylist as a guarantee rather than a tripwire.

> ### ⚠ Verdict-forced changes
> - **Replace, do not duplicate.** Delete the dead `scripts/ci/check-security-claims.sh` + `scripts/ci/_extract_security_claim_paths.py` (input file removed in `ab4caa0985`, wired into zero workflows) and take the same name for the new checker. Fix `.github/CODEOWNERS:60`, which names a nonexistent `scripts/ci/verify-security-claims.sh`. *(feasibility A2, constraints A3)*
> - **JSON manifest, not YAML.** Root `package.json` has **zero** dependencies and there is no root `js-yaml`/`yaml`; the only `js-yaml` lives under `functions/`. Adding a root dep trips syncpack / Unused Dependencies / Dependency Review and turns a docs PR into a manifest PR. Use `governance/security-claims.json`. *(feasibility A3)*
> - **Drop `storage.rules` from fixTouches** — even a comment-only edit forces full CI via the `storage\.` FULL_PATTERN. Express the cross-reference from the manifest predicate instead. *(feasibility A4)*
> - **No `continue-on-error`.** *(constraints A4)* "Advisory" means a **new, fail-closed job** whose context name is deliberately **absent** from both governance configs; the wave-2 flip is then a one-line governance addition. A `continue-on-error` step is a permanently green step that proves nothing.
> - **Strike calendar-driven red.** *(feasibility A8, constraints A5)* `last-verified` / `stale-after` may **warn** or be checked in `nightly-health.yml`; it may never fail a PR context on a date with no diff.
> - **Exactly one PR** — docs + manifest + checker + self-test + rules-test case. The "rewrite PR kept separate from the lint job" language is deleted. *(constraints A2)*
> - **Preserve `SECURITY.md`'s `repo metadata (\`…\`)` line** matched by `scripts/verify-version-consistency.sh:135`, or the required "Version consistency" job goes red. *(feasibility A11)*
> - **The documented-gap rules test extends `firestore-rules-tests/rules-consolidation-parity.test.js`** next to the existing apiKey denial at `:158`. Do not add a new file — the `test:ci` runner list is a hardcoded `&&` chain. *(feasibility A12)*
> - **The scout must ground the "sealed content, plaintext routing metadata" rewrite in code** before any wording lands: enumerate exactly which plaintext fields reach Firestore/OpenRouter. `functions/src/insightsHostedAnswer.ts` carries only `modelDisplayName`; the "project/device display names" claim is **unverified**. *(feasibility A9)*

**Fanout (4 agents):** 1 scout (claim-vs-code inventory across **four** surfaces: `README.md`, `SECURITY.md`, `docs/THREAT_MODEL.md`, `docs/security/BurnBar-threat-model.md`) → 2 implementers → 1 adversarial verifier → PR author folded in.

**doneCriteria**
```bash
node scripts/ci/check-security-claims.mjs                              # exit 0
node --test scripts/ci/check-security-claims.test.mjs                  # includes a --root <tmpdir> fixture
#   fixture: flip storage.rules to public-read in the temp copy -> checker exits 1
rg -n 'check-security-claims|verify-security-claims' .                 # only the .mjs + workflow + CODEOWNERS
test ! -f scripts/ci/check-security-claims.sh && test ! -f scripts/ci/_extract_security_claim_paths.py
npm --prefix firestore-rules-tests run test:ci                         # incl. the KNOWN GAP nested-map case
bash scripts/verify-version-consistency.sh                             # SECURITY.md repo-metadata line intact
git diff 9503b490b0 -- .github/workflows/ | grep continue-on-error && exit 1 || echo clean
node scripts/ci/classify-ci-impact.mjs                                 # verdict recorded in the PR body (expected: full)
```
Manifest predicates that must be encoded:
- `SECURITY.md` Accepted Risks must **not** match `/no staging environment|readable cross-tenant/`
- `README.md` and `docs/THREAT_MODEL.md` must not match `/reject(s)? plaintext-looking secret field/` unless the same line also matches `/tripwire|defense-in-depth/`

**PR lane:** one PR `docs(security): claims manifest + retired-risk ledger`. **CLI lane:** Grok 4.6; prose/tests Agy × Gemini; wording Fable (small); review `@codex review`.
**scoreDelta:** Security +0.10, Documentation/Maintainability +0.30, Overall Professionalism +0.15. Estimated 8 agent-hours.
**Risks:** the KNOWN GAP rules test must be named as a gap and linked to **one filed issue in the PR body**, so a green test is never read as coverage.

---

## W1-1 — Callable boundary authority

**Findings:** F11 (remainder), F12. **Split into three units by the feasibility verdict — the winner plan's single 20-agent PR was refuted.**

> ### ⚠ Verdict-forced changes
> - **"Catalog becomes enforcement" is deleted from wave 1 entirely.** *(feasibility A4)* `functions/scripts/generate-endpoint-catalog.mjs` (1,334 lines) is **hand-authored prose**: `authMethod` / `ownershipCheck` are free-text per entry, `CATALOG_OVERRIDES` is hand-maintained, `exportedNames()` is a regex over `export { } from` lines. Making it a runtime authority means re-authoring 213 entries from prose into structured fields, and enforcing from it is a production behaviour change for every export that the BOLA suite **cannot prove** — **20 of the 23** `*.bola.test.ts` files `vi.mock` `enforceAuthAndAppCheck`/`enforceHighRiskOwnerAction`, so a wrapper that moves enforcement inside either bypasses those mocks (red for unrelated reasons) or is itself mocked (fake-green). Proving it needs a staging/prod deploy.
> - **The TypeSpec canon has no callable RPC surface.** `tools/schema-sync/manifest.json` maps only `functions/src/types/generated/*.ts` document types. "Derive zod from the TypeSpec canon" is a new project, not an extension. `fast-check` is absent from every `package.json`. *(feasibility A5)*
> - **The no-zod decision is a committed decision.** `functions/src/validation/callableSchema.ts:19` records it deliberately, and the finding itself says the gap is **adoption** (9 of 113 sites). Self-ratifying a reversal overnight with `needsHuman:false` is wrong → **human queue item 18**. Default if unratified: extend `parseCallableInput` with `.strict()`-style unknown-key rejection, discriminated unions and an issue→field-message mapper, **zero new runtime dependencies**. *(constraints A3)*
> - **Scope fence.** *(constraints A1)* `functions/**` + `docs/architecture` + `docs/security` only. Swift/Kotlin generated models and `tools/schema-sync` move to a later wave, or the classifier selects native/Android lanes and the merge-queue walls.
> - **Drop `attest-build-provenance` from W1-1** *(constraints A2)* — privileged release-workflow permissions guarded by `scripts/ci/verify-release-provenance-boundaries.mjs`.
> - **Hours 104 → ~140**, spread across nights 2–4, PR kept **draft** (drafts run no BurnBar CI Gate) until functions lint / test:unit / test:security / verify-resilience-wiring are green locally. Mark ready **once**, not per-partition. *(constraints A7)*

### W1-1a — Harness strictness (wave 1) ✅
Drains the `BOLA_STRICT_CODE_PENDING` ledger W0-12 created. Deletes `BOLA_STRICT_CODE_ENDPOINTS` from `callableBolaHarness.ts` and `bolaCoverage.test.ts`; every failing handler gets the uniform denial contract in the same PR.
```bash
cd functions && npm run lint && npm run test:unit && npm run test:security
rg -n 'BOLA_STRICT_CODE_ENDPOINTS|ANY_CALLABLE_DENIAL_CODE|DENIAL_MESSAGE_PATTERNS' functions/src   # 0
node functions/scripts/generate-endpoint-catalog.mjs && git diff --exit-code functions/src/security/endpointAuthorizationCatalog.generated.ts
node -e "const l=require('./functions/src/__tests__/bola/pending.json');process.exit(l.length===0?0:1)"
bash scripts/ci/verify-resilience-wiring.sh
```
**Fanout:** scout-determined (24–40 agent-hours once the failing count is known). **scoreDelta:** Security **+0.40** *(0.30 + the 0.10 moved here from W0-12, where recording the gap was over-credited relative to closing it)*, Testing/CI +0.20, Code Quality +0.10. Weighted: **10.00**.

### W1-1b — Callable boundary wrapper (wave 2, not wave 1) 🕐
Extend the **existing** `onCallProduction` / `wrapCallableHandler` (`functions/src/logging.ts`) and `callableSchema.ts` — not a new `defineCallable`/zod stack. Add an **AST-based** check (`ts-morph` or the TypeScript compiler API in a `scripts/ci` script, **not** the regex generator) that counts `onCall(` call sites outside the wrapper module and fails when >0, plus an ESLint `no-restricted-imports` entry. Migrate the **16 files with no shared guards first** (`cliLink`, `deviceLinks`, `hermesGatewayApprove`, `irohControllerRouteCallables`, `signalPrekeyDirectory`, `misc`, +10). **Do not move auth/App Check enforcement into the wrapper until the 20 mocking bola suites are re-plumbed**, and verify on `deploy-staging.yml` before production. 40–60 agent-hours. **scoreDelta:** Security +0.20, Code Quality +0.20.

### W1-1c — Catalog re-authoring (wave 3+) 🕐
Prose → structured fields, with a validation step that diffs catalog claims against live handler behaviour. Runtime rollout depends on wave-1 gate 1 and a staging soak. 60+ hours.

**Ordering note:** `deploy-staging.yml:222` also runs `test:security`, so W1-1a must be green **before** the wave-1 tag deploy or the deploy gate stalls.
**Invariants for the PR body:** client-visible error codes and messages preserved, or enumerated together with the Swift/Kotlin call sites that consume them (`OpenBurnBarMobile/Services/Tools/*.swift`, `android/`). No `budgets/*.json` edits, no `.jscpd.json` threshold change, no suppression tokens; `tools/schema-sync/check-drift.sh`, `scripts/ci/knip-ratchet.sh functions` and `jscpd` all pass without cap changes.

---

## W1-2 — Split: public-surface budget model / consent-first diagnostics

**Findings:** F13, F32. **Split into two workstreams along the validation lane** — their evidence lands in different CI clocks, and bundling parks the door-provable half behind a nightly.

> ### ⚠ Verdict-forced changes (this workstream had the largest set — 20 amendments)
> - **The catalog test was vacuous.** `generate-endpoint-catalog.mjs` reads `functions/src/index.ts` only for **export names** (`exportedNames()`, line 17); every `appCheck:` value comes from the hand-written `CATALOG_OVERRIDES` table **in the same file**. A test asserting "every non-mint callable carries `enforceAppCheck:true`, generated from the catalog" asserts a hand-maintained literal **against itself**, and `functions/src/__tests__/endpointAuthorizationMatrix.test.ts` (41 lines) already does exactly that. **Rewritten:** the generator must derive `entry.appCheck` by **parsing the `CallableOptions` object literal at the callable's definition site**; `CATALOG_OVERRIDES` may no longer set `appCheck`; and a **mutation check** proves the drift test fails when `enforceAppCheck` is removed from one callable.
> - **"14 exceptions" is a miscount from grep noise.** `enforceAppCheck: false` matches 15 lines in `functions/src`, but **10** are `vi.mock("../config.js", () => ({ getConfig: () => ({ enforceAppCheck: false }) }))` in `__tests__`. Real callable sites: **5** — `callables/linuxAppCheck.ts:246`, `linuxAppCheckDevices.ts:232` and `:312`, `windowsAppCheck.ts:555` and `:597`. The original report's "5" was right. The catalog partition is **148 `required` / 8 `not-required` / 57 `not-applicable`**, and 3 of the 8 are health probes (`healthCheck`, `healthLive`, `healthReady`), so "non-mint" is not the real partition. `benchAssistant`'s row is `not-applicable`, not `not-required`.
> - **Delete the reCAPTCHA human item — it is already provisioned.** `website/src/lib/firebaseClient.ts:26-27` ships site key `6Ld3bAkt…`, `:43` already calls `initializeAppCheck` with `ReCaptchaEnterpriseProvider`, `:33-40` implements the `PUBLIC_APPCHECK_DEBUG_TOKEN` DEV path, and `website/scripts/update-csp-hashes.mjs:122-129` already allowlists the recaptcha origins. The workstream gated itself on a satisfied prerequisite.
> - **Add the two human items that actually block it** — F13's claim that "anonymous-auth gating needs no human action" is **false**: (a) **enable the Anonymous sign-in provider** for project `burnbar` (`signInAnonymously` appears nowhere in `website/` or `apps/console/`; the only public anonymous surface, `website/src/scripts/bench-arena.ts:154-172`, deliberately builds an `arena-public` app **without** App Check and uses `signInWithPopup`); (b) **turn on App Check enforcement for Cloud Functions**. Until (b) lands, `enforceAppCheck` on `benchAssistant` is a **no-op at the edge** and an attacker can mint unlimited anonymous UIDs — so the per-uid bucket is not a control and the **global USD bucket is the only server-side stop**. Say that plainly in the PR body.
> - **The API-key drift check cannot run as specified.** `gcloud services api-keys describe` needs the key **resource name** (`projects/…/locations/global/keys/<id>`); `git grep 'locations/global/keys'` returns **nothing** repo-wide — only the `AIzaSy…` display string is committed, and it is not addressable. It also needs `apikeys.googleapis.com` enabled plus `roles/serviceusage.apiKeysViewer`. **Rewritten:** ship an **offline self-test** wired into `ops-plane-verify.yml`'s existing creds-free `drift-check-selftest` job; the live comparison is registered **non-gating** until the key resource id and the viewer role exist. And **it may not be added to any nightly counted by the wave gate** — a fail-closed check in a nightly directly contradicts gate item 2.
> - **The `ops-plane-verify` "existing WIF identity" claim is false.** That workflow uses `secrets.GCP_SA_KEY` + `environment: production` and is **weekly** (`cron: 0 14 * * 1`); only `deploy-*`, `ops-confidence` and `domain-core-promotion-observation` carry a `workload_identity_provider`. Depend explicitly on W0-5, or target `ops-confidence.yml`.
> - **"Screenshot of the onboarding card from the nightly Mac build" is unproducible** — no lane emits screenshots and the standing rule is no GUI driving. **Replaced:** `OpenBurnBarTests` already links **ViewInspector and SnapshotTesting** (`project.yml:901-903`), so require a ViewInspector assertion that the consent card renders both decision buttons plus a committed SnapshotTesting reference image, run via `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/<name>`.
> - **"SentrySDK never starts while consent is undecided" is untestable as written.** `OpenBurnBarTests` is **app-hosted** (`project.yml:884-888`, `BUNDLE_LOADER`/`TEST_HOST = OpenBurnBar.app`), so `SentrySDK.isEnabled` is a process-global the host app may already have touched; `SentrySDK` is referenced in **zero** test files today. **Replaced:** assert the **pure consent gate** returns `.undecided` for a fresh injected `UserDefaults`, and that `configureSentryIfAvailable` / `daemonSentryDSNForLaunch` return **before any SDK call** for `.undecided` and `.denied` — following the existing pattern in `AgentLensTests/Active/MacSentryScrubberTests.swift`.
> - **"Privacy toggle rendered from the scrubber allowlist" is fictional.** `MacSentryScrubber.sensitiveKeyFragments` is a **denylist** of fragments to redact (`token`, `secret`, `email`, `prompt`, `name`, `uid`, …). **Replaced:** add `MacSentryScrubber.disclosedPayloadFields` (an explicit allowlist of what Sentry *receives*), render the consent copy from it, and unit-test that every disclosed field survives `redactDictionary()` unredacted.
> - **Extend, do not invent.** `AgentLens/Services/Analytics/AnalyticsConsentStore.swift` is **already** the tri-state model (`enum AnalyticsConsent { unset, granted, declined }`, `hasDecided`, `grant`/`decline`/`revoke`, `UserDefaults`-backed `@MainActor ObservableObject`) and `AgentLens/Views/Onboarding/AnalyticsConsentPromptView.swift` is already the first-run card. Model `MacCrashReportingConsent` on the store, add the toggle to the **existing** Privacy pane `AgentLens/Views/Settings/PrivacyIndexingSettingsView.swift` (which already carries "Share Usage Analytics" at `:62-66`), and generalize the existing prompt view.
> - **Two paths in F32 do not exist:** `OpenBurnBarMobile/Views/Settings/*` (the tree is `OpenBurnBarMobile/Settings/`) and `GeneralSettingsView.swift` (the Privacy pane is `PrivacyIndexingSettingsView.swift`).
> - **MDM back-compat is mandatory:** the tri-state reader must still consult the legacy Bool key `crashReporting.enabled` (`MacCrashReportingPrivacy.swift:25`, `MobileSentryScrubber.swift:13`) — an explicitly-set `false` maps to `.denied` and **wins**, with a managed-profile unit test.
> - **Daemon revocation:** `OpenBurnBarDaemonManager+Lifecycle.swift:507-519` computes `daemonSentryDSNForLaunch` **once**, when the LaunchAgent plist is written, so consent revoked while the daemon runs leaves Sentry live in a separate process. Revoking must rewrite the plist and restart/signal the daemon, with a test. (Also strike the fix shape's "on iOS, mirrored to an App Group" — the daemon is **macOS**.)
> - **Drop the `packages/firebase-web-config` extraction.** Root `package.json` declares **no workspaces**, neither `website/package.json` nor `apps/console/package.json` consumes any local package via `file:`/`workspace:`, and `website/scripts/test-firebase-config.mjs` **hard-asserts** the literal apiKey and reCAPTCHA key in built `dist/` while documenting the committed fallback as the intended pattern.
> - **Emulator criterion made runnable:** `firebase.json` declares only `emulators.hosting.port 5500` (no auth/functions ports) and no workflow runs website + auth + functions emulators together. Require `website/scripts/test-bench-assistant-callable.mjs` under `firebase emulators:exec --only functions,auth`, added to the website `test` script so the required **Website** context runs it. **Note in the PR:** the Auth emulator accepts anonymous sign-in regardless of console config, so an emulator pass is **not** evidence that production anonymous auth is enabled.
> - **Website door checks omitted by the original ciRisk:** switching `bench-dashboard.ts` from `fetch('/api/bench/assistant')` (line 1401) to `httpsCallable` pulls `firebase/auth` + `firebase/app-check` onto the marketing bundle, which must clear `size` (size-limit), `test:inline-budget`, `csp:check`, `test:security-headers`, `test:firebase-config` and `test:lazy-assets`. Run `npm --prefix website run verify` before the PR.

### W1-2a — `security(public-surface): owner-funded budget model + App Check posture` ✅
**Provable on the merge door** (`Functions (security vitest)`, `Website`). **Fanout 6:** 1 scout + 3 implementers + 1 adversarial verifier (drain attempts against the ledger) + 1 PR author.
```bash
cd functions && npm run test:security                 # anonymous-uid bucket, global USD cap trip, App Check rejection
node functions/scripts/generate-endpoint-catalog.mjs && git diff --exit-code   # appCheck derived from the call site
node --test functions/src/__tests__/appCheckCatalogDrift.test.ts
#   mutation check: remove enforceAppCheck from one callable -> the drift test FAILS
#   the 5 production exceptions are named explicitly, not "14"
npm --prefix website run verify
npx firebase emulators:exec --only functions,auth 'node website/scripts/test-bench-assistant-callable.mjs'
node --test scripts/ops/check-api-key-restriction-drift.test.mjs   # offline self-test only; live check non-gating
```
**scoreDelta:** Security +0.15 on merge; **+0.15 more** only after `deploy-functions` succeeds *and* the console-side API-key restriction lands (verified by `curl` without `X-Firebase-AppCheck` returning 401/permission-denied against production).

### W1-2b — `privacy(diagnostics): consent-first crash reporting` 🌙
**`ciRisk` raised from "Low" to `merge-door-blind`.** Neither `App build + test (AgentLens)` nor `Mobile build + unit test` appears in `governance/burnbar-ci-gate.json` **or** `.fast.json`. Label the PR body **nightly-verified**. **Fanout 6.**
```bash
./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/MacCrashReportingConsentTests   # local, attached to the PR
xcodegen generate && git diff --exit-code OpenBurnBar.xcodeproj/project.pbxproj                  # drift gate
# post-merge: first green app-pr-gate run id recorded in the PR
```
**scoreDelta:** Overall Professionalism +0.20.

---

## W1-3 — Cloud trust root as an epoch-versioned root

**Findings:** F14. **Split: W1-3a server (wave 1) / W1-3b clients (NOT wave 1).**

> ### ⚠ Verdict-forced changes
> - **Two paths in fixTouches do not exist:** `docs/ARCHITECTURE/009-…` (real: `docs/architecture/`, lowercase — resolves on APFS, **fails on Linux CI**) and `functions/src/computerUseSecurity.ts` (real: `functions/src/callables/computerUseSecurity.ts`; the constant is defined at `callables/computerUseSecurityCrypto.ts:59`). Add `functions/src/appCheckAttestation.ts` and `functions/src/computerUseRemoteConfig.ts`.
> - **Delete the email limb.** `functions/src` has **zero** email transport (no nodemailer/sendgrid/resend/postmark/SMTP), `firebase.json` has no `extensions` block, there is no `mail` collection, and `recoveryEmail` returns nothing repo-wide. Fan-out is **APNs + FCM only**; email is filed as `OPEN_WITH_NAMED_BLOCKER: no email transport`.
> - **Extend `functions/src/callables/recovery.ts`, do not build `trust_root.recoveryCodeArgon2id` in parallel.** That 349-line file **already** implements the Apple-ADP delayed-confirmation pattern — `setupRecovery` / `confirmRecovery` / `listRecovery` over the server-write-only `account_recovery_methods` collection (already in `packages/data-domains/registry.json:217`), `RECOVERY_SCHEMA_VERSION 2`, and a one-way `SHA-256(salt||verificationHash)` commitment so a doc reader cannot replay confirmation. A parallel recovery secret is an AGENTS.md violation and a review reject.
> - **Drop argon2 and bip39.** Neither is in any `package.json`; `argon2` is a native node-gyp addon (Cloud Functions deploy hazard); adding manifests flips the classifier to **full CI** and adds Dependency Review + OSV + syncpack + Unused Dependencies + Dependency Boundaries surface into a queue already wedged on OSV. Reuse `recovery.ts`'s `node:crypto` scrypt/SHA-256 scheme and a repo-local wordlist. **doneCriteria: "no new runtime dependency in `functions/package.json`."** If dependencies are unavoidable, prefer `@scure/bip39` + `@noble/hashes` (audited, zero native build).
> - **Replace "property tests" with table-driven vitest state-machine tests**, or add `fast-check` as an explicitly-approved devDependency with its own OSV/Dependency-Review note and a **named committed seed file** so the evidence is a file you can `cat`.
> - **`byte-for-byte in tests` is not observable.** Replaced: extend `functions/src/__tests__/computerUseSecurityRefactor.char.test.ts` with a trust-root-flag-off characterization case, and `git diff` must show **zero edits** to existing assertions in `approveEscrowDeviceTrustHandler.test.ts`.
> - **The named proofs do not run in the named lane.** `Functions (security vitest)` runs `npm run test:security`, whose hardcoded vitest list (`functions/package.json:38`) contains **neither** `approveEscrowDeviceTrustHandler.test.ts` nor `escrowDeviceTrustChainSignature.test.ts` — they run only under `test:unit`. Add all three to the `test:security` list and cite **two** commands.
> - **`auth_time` appears nowhere in `functions/src`** and no client has a re-auth path, so an `auth_time <= 5min` gate can only be exercised with synthetic tokens. State that the flag stays **OFF in staging** until W1-3b ships client re-auth, and delete "staging first, then production" from the wave-1 risks — production enablement is a console action.
> - **17 files are missing from fixTouches.** 42 files reference `approveEscrowDeviceTrust|revokeEscrowDeviceTrust`; add `OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift`, `apps/console/components/escrow/EscrowFlow.tsx`, `apps/console/lib/api.ts`, `packages/data-domains/registry.json` + its five generated consumers, `docs/mobile-parity/mobile-schema-boundary.json`, `functions/src/__tests__/bola/bolaVictimSeeds.generated.ts`, `escrowDeviceTrustFingerprint.test.ts`, `firestore-rules-tests/{escrow-grants,rules-consolidation-parity}.test.js`, `functions/src/callables/panic.ts`, `cloudVaultRotationResilience.ts`, `scripts/commercial-launch-gate.mjs`.
> - **`trust_root` appears 0 times in `registry.json`.** Better: **avoid a new collection entirely** by storing `epoch`/`bootstrappedAt` on the existing `device_trust_keys` domain paths already registered at `registry.json:217`. If a new path is added, it needs a registry entry, five regenerated consumers, and a `mobile-schema-boundary.json` entry (a door check).
> - **`firestore.rules` is 222 KB / 4,984 lines with `BEGIN GENERATED` / `END GENERATED` blocks** guarded by `node tools/gen-rules-entitlements.mjs --check`. The `trust_root` deny block goes **outside** those markers, and that check is named in doneCriteria.
> - **"Native client changes stay off the merge door" is false.** `android/**` fires Android PR Gate (35 min, in the merge_group config) plus ktlint; `AgentLens`/`OpenBurnBarCore` fire PR Native Fast Gate and "Swift twin basenames". Only the app **build** is nightly. → **W1-3b does not merge in wave 1**: nightlies run 08:00–10:00Z, so a client commit landing the night of 09-05 gets its first nightly on 09-06, **outside the window**.
> - **Ordering vs W0-12/W1-1a is mandatory.** Both mutate `endpointAuthorizationCatalog.generated.ts`, `bolaVictimSeeds.generated.ts` and the BOLA strict list. **W1-3 lands AFTER** the BOLA work, and re-runs `npm run generate:bola-seeds --prefix functions` + `node functions/scripts/generate-endpoint-catalog.mjs` after every rebase — never hand-edited.
> - **The 24h expiry needs an `onSchedule` function**, i.e. a new Cloud Scheduler job created only by `deploy-production.yml` — Alberto's approval. doneCriteria must prove expiry with **vitest fake timers over the handler**, not a deployed schedule.
> - **The product decision is a blocker, not a pre-decision.** The winner plan marked `needsHuman:true` *and* pre-decided 24-word BIP39 + passkey + 24h in the fix shape. Resolution: mark **BLOCKED-UNTIL-DECISION** (human queue item 17), make the window a single named constant `TRUST_ROOT_REBOOTSTRAP_DELAY_MS`, and drop the specifics from doneCriteria.
> - **scoreDelta split:** Security +0.05 / Architecture +0.10 **at merge** (flag OFF); the remaining Security +0.25 only when human queue item 20 (production Remote Config enablement after a staging soak) closes.
> - **Scout starts from a fresh worktree** — `feat/living-glass-sweep` has a 13-line local delta in `escrowDeviceCallables.ts` versus main.

**W1-3a fanout (12):** 1 scout → 6 implementers → 1 table-test author → 1 adversarial verifier (phished-SSO + attacker-own-device + attacker-driven revoke-to-empty must all be rejected without a UV assertion or recovery secret) → 1 generated-artifact owner (catalog + seeds + registry regen) → 1 rules author → 1 PR author. 60–80 agent-hours over two nights.

```bash
npm --prefix functions run test:security        # incl. approveEscrowDeviceTrustHandler + chainSignature, newly added to the list
npm --prefix functions run test:firestore-rules
node tools/gen-rules-entitlements.mjs --check
node scripts/mobile-parity/check-mobile-schema-boundary.mjs
node functions/scripts/generate-endpoint-catalog.mjs && npm --prefix functions run generate:bola-seeds && git diff --exit-code
git diff 9503b490b0 -- functions/src/__tests__/approveEscrowDeviceTrustHandler.test.ts | grep -c '^-' | grep -q '^0$'
grep -c 'argon2\|bip39\|fast-check' functions/package.json   # 0
```

---

## W1-4 — Firestore hot paths — split into three

**Findings:** F17 *(the report carries no finding IDs; the matching narrative is **item 7 at line 151**)*.

> ### ⚠ Verdict-forced changes
> - **`with firestore.indexes.json loaded in the emulator` is unobservable and proves nothing.** Every named test is a hand-rolled in-memory fake (`rollupDirtyClearRace.test.ts` uses `class FakeDocRef`; `rollupPagination.test.ts` uses `class FakeQuery`); no vitest test starts an emulator; the only `FUNCTIONS_EMULATOR` script (`functions/package.json:70 test:integration`) passes the **Jest-only** `--testPathPattern` to vitest 4.1.8 and is invoked by **no workflow**. And the Firestore emulator **does not enforce composite or COLLECTION_GROUP index requirements at all** — a green run would be byte-identical with an empty index file. **Replaced by a new static checker** `scripts/ci/check-firestore-index-coverage.mjs` that parses every `collectionGroup(...).where(...)/.orderBy(...)` chain in `functions/src` and fails if `firestore.indexes.json` lacks a matching COLLECTION_GROUP-scoped index or fieldOverride.
> - **The index entries do not exist and must be written literally:** a `fieldOverrides` entry for collectionGroup `burnbar_attachments` fieldPath `state` with a COLLECTION_GROUP ASCENDING index; a COLLECTION_GROUP composite on `burnbar_attachments (state ASC, updatedAt ASC)`; a fieldOverride + COLLECTION_GROUP index on `hermes_gateway_attachments.expiresAt`. **A single-field `in` filter on a collection group is not auto-indexed.**
> - **Deploy ordering is mandatory and human-gated.** `deploy-firestore.yml:50` declares `environment: production`, which carries **required reviewers + a wait timer**. The index must be READY **before** any tag ships the rewritten reaper, or the hourly reaper throws `FAILED_PRECONDITION` in production. Ship the reaper behind a **runtime kill switch** that falls back to the current full-scan-with-in-memory-filter when the index is absent, with the fallback unit-tested.
> - **Reconcile with the dirty tree first.** `functions/src/scheduled/reapBurnbarAttachments.ts` is **already modified (uncommitted)** on `feat/living-glass-sweep` with exactly this fix — state where-clause, `startAfter`, `batchSize`/`maxBatches`/`timeoutMs`, `hasMore` — and `burnbarAttachments.test.ts:350-360` already has a two-run pagination test. **A scout diffs that working tree read-only and exports a patch** (`git diff -- <path> > <scratch>/reaper.patch`); W1-4b either cherry-picks it onto a fresh branch or is **cancelled as already-done**. Never re-implement blind, never `git add`/`stash`/`commit` in that tree.
> - **fixTouches omitted the files that own the invariant.** `dirtiedAt` is load-bearing in `functions/src/rollupJobs.ts` (`:27`, `:349`, `:400`, `:410-413`, `:480-486`, transactional clear `:523-553`), `rollupTaskQueue.ts:96` (the Cloud Tasks **task-id derivation**, i.e. the scheduler-retry idempotency key), `scheduled.ts:72/:101-103`, `guards.ts:307`, `types/legacy/quota-usage.ts:441`. **Five** test files depend on it, not one: `rollupDirtyClearRace`, `rollupTaskQueue`, `rollupRebuildSkip`, `rollupFullRebuildCircuitBreaker`, `rollupRefactor.char`.
> - **Add a Cloud Tasks idempotency criterion.** `rollupTaskQueue.ts:96` hashes `dirtiedAt`; replacing it with max-drained-createdAt silently changes dedupe and can produce **concurrent duplicate rebuilds**. Assert: two enqueues for the same drained epoch → same taskId; a newer epoch → different.
> - **Mutation proof required.** A rewritten test for a deleted mechanism passes trivially. The adversarial verifier's **sole deliverable** is: the new race test **FAILS** when the coalescing guard is reverted, with the failing output pasted in the PR body.
> - **The resumable backfill silently breaks the all-or-nothing persist guard.** `rollupCompute.ts:111-112` early-returns on any present `dailyTokens` map, so a partially persisted map becomes **permanently authoritative** and under-reports lifetime tokens forever. Required: partial pages write to a staging field + cursor and are promoted in a **single final transaction** under the existing `updatedAt`-moved guard; a test asserts an interrupted backfill leaves `dailyTokens` **absent** so the next compute re-scans.
> - **Delete the `collectionGroup("providers")` + `__name__` prefix-range proposal.** The providers subcollection is per-tenant, the admin SDK bypasses `firestore.rules`, and a `__name__` prefix range across a collection group is a **cross-tenant read by construction** in a repo with a required BOLA gate. Keep the per-day query and only bound/paginate it (`BACKFILL_QUERY_CONCURRENCY=25` already exists at `rollupCompute.ts:182`).
> - **Move the unbounded-`.get()` lint out of wave 1.** "274 sites" is not 274 problems: ~92 are single-doc `.doc(...).get()`, only ~39 are same-line collection queries, leaving ~140 multi-line chains needing per-site classification — far beyond one "lint author" slot. When it runs it needs `budgets/unbounded-firestore-get-baseline.json` in the style of `budgets/raw-firestore-baseline.json` **plus** an exact-path entry in `docs/LINT_RATIONALE.md`, or `scripts/ci/check-no-suppressions.sh` §4 fails closed.
> - **The Swift half names the wrong owner and a nonexistent path.** `DownloadSyncService` and `UsageStore` live **only** in the AgentLens app target (`AgentLens/Services/CloudSync/`, `AgentLens/Services/DataStore/`); `OpenBurnBarCore` has neither. `AgentLensTests/Active/CloudSync/DownloadSyncServiceTests.swift` does not exist — the real files are `AgentLensTests/Active/DownloadSyncServiceMattersTests.swift`, `DownloadSyncServiceRollupTotalsTests.swift`, `RemoteSyncWatermarkTests.swift` (which owns VAL-PERSIST-010). **Best fix:** move `insertRemoteUsages(_ rows:)` into `OpenBurnBarCore` (it already links GRDB-SQLCipher, `Package.swift:1602`), leaving AgentLens a thin caller, so `swift test` in PR Native Gate becomes real merge-door proof.
> - **Add the `UsageTableWriteMarker` invariant:** `insertRemoteUsages` bumps the marker exactly once per batch, asserted by a test. `scripts/debt/check-usage-refresh-tick-budget.sh` enforces `rawTokenUsageWriteStatements=0` outside `UsageStore*` precisely because a writer that skips the marker renders stale data until the next time-window boundary. Add `make debt-check` to the local checks.
> - **The "5.5 GB fixture" does not exist.** It is Alberto's live SQLCipher store (`FABLE-DILIGENCE_REPORT_2026-09-01.md:54`, `docs/PRODUCT_TRUTH_AND_ACTIVATION_PLAN.md:62`), and no downloaded-rows/sec harness exists (`budgets/usage-refresh-tick-baseline.json` is a **call-site ratchet**, not throughput). **Replaced:** an XCTest that seeds N=5,000 synthetic remote rows into a temp GRDB store and asserts **one `dbQueue.write` transaction per 500-row page** — a transaction-count assertion, not wall clock — with before/after counts in the PR body.
> - **Do NOT implement the report's own remediation at line 167** ("write only on false-to-true"). `triggers.ts:44-47` documents that refreshing `dirtiedAt` on every event is exactly what makes `writeUserRollups`'s clear-guard safe; the report's fix would silently drop the last events of a session.
> - **agentHours 22 → 35–40.**

**W1-4a — `perf(functions): rollup dirty-signal + resumable backfill`** (functions TS only). 1 scout + 2 implementers + 1 test author (all five suites) + 1 adversarial verifier (mutation proof) + 1 PR author.
**W1-4b — `perf(functions): attachment reaper + composite indexes`** (functions TS + `firestore.indexes.json`). 1 reconciler + 1 implementer + 1 index-checker author + 1 PR author. **Merges only after the index deploy concludes.**
**W1-4c — `perf(sync): batched remote-usage inserts`** (Swift only, `swiftpm-native` provable after the Core move).

```bash
npm --prefix functions run test:unit                       # all five dirtiedAt suites
node scripts/ci/check-firestore-index-coverage.mjs          # new; fails on any uncovered collectionGroup chain
node --test functions/src/__tests__/rollupTaskQueue.test.ts # taskId idempotency across drained epochs
# mutation proof, pasted in the PR body:
git stash && npm --prefix functions run test:unit -- rollupDirtyClearRace   # must FAIL with the guard reverted
swift test --package-path OpenBurnBarCore --filter InsertRemoteUsages       # transaction-count assertion
make debt-check
```
**scoreDelta:** Performance/Scalability +0.30, Reliability/Ops +0.10.
**Blocker:** `blockedBy: ["#2466"]`, plus "index deployed and READY" for W1-4b.

---

## W1-5 — Release status generated, versions from one file, hotfix channel named

**Findings:** F09 (remainder), F25. **Split into two; re-laned from fast to structured-large.**

> ### ⚠ Verdict-forced changes
> - **`prLane: "fast lane"` is factually impossible.** `scripts/ci/classify-ci-impact.mjs:81` FULL_PATTERNS already contains `^scripts/release/` and `^scripts/lib/`; `:83` matches `.github/workflows/release*`; `:80` matches `build.gradle.kts`, `gradle.properties`, `Directory.Build.props`, `package.json`. **Every file this workstream touches forces FULL CI.**
> - **`scripts/verify-version-consistency.sh` is a protected control-plane seed and must not be deleted or renamed.** `scripts/lib/domain-core-native-control-plane-seeds.mjs` lists it (plus `release.yml` and `android/app/build.gradle.kts`); the seeds test asserts the list is sorted+unique, that every seed `lstatSync().isFile()`, and that `discoverControlPlaneClosure` over both release workflows is fully seeded. It also runs today in the **hard-required** `version-consistency` job (`fast-feedback.yml:906-931`, a `needs:` of the required Fast Feedback Gate), in `pr-windows-dist.yml:193`, and at tag time in `openburnbar-release-windows.yml:238`, and is spawned three times by `scripts/ci/verify-ops-script-hardening.test.mjs`. **"Report-only on PR" is a net removal of enforcement.** Keep the `.sh` hard-enforcing exactly what it covers today; add the **new** checker as an additional job covering only the newly-covered surfaces.
> - **The enforcing job physically cannot see the renderer's inputs.** `version-consistency` uses a **blob-less sparse checkout with a 13-path allowlist** and **no fetch-depth override** (default 1, **no tags**). `versions.json`, `scripts/release/**`, `docs/status/**`, `docs/mobile-parity/mobile-parity-ledger.json`, `windows/packaging/msix/Package.appxmanifest`, `android/app/build.gradle.kts` and `functions/package.json` are all absent, and `git tag` returns nothing there. → **the renderer reads only committed files**; tag-derived facts move to a separate `--refresh-tags` mode run in a tag-aware job.
> - **"zod-checked" is impossible.** Root `package.json` is `{name, private, license}` — **zero dependencies** — and every `scripts/ci/*.mjs` imports only node builtins. Use a dependency-free `scripts/release/versions-schema.mjs` with `node:assert` plus `node --test`.
> - **The tag criterion is false on its face.** `release.yml` triggers only on `refs/tags/v*` and its grammar `^v[0-9]{1,3}\.[0-9]+\.[0-9]+(-…)?(\+…)?$` (`:511-517`) **rejects** `windows-v1.0.38`, which `openburnbar-release-windows.yml` handles. And `v1.0.40-hotfix.1` **already** classifies as prerelease under `:549-556` — **no `release.yml` logic change is needed**, only the fixture test, `docs/RELEASE_VERSIONING.md`, and the runbook naming rule.
> - **No agent may create or push a `v*`/`windows-v*`/`linux-v*` tag.** Ruleset 16177860 is active with `deletion` + `non_fast_forward` and **zero bypass actors** — a mistakenly pushed release tag is **permanently undeletable** and immediately fires the release pipeline. Tag creation is *not* restricted. Fixtures exercise the extracted grammar in a **temp git repo**.
> - **Gate item 5 was vacuous** ("report mode exit 0" is true by construction) — replaced by the `allowedDrift` scheme above, seeded with the six real mismatches: `project.yml` 1.0.40/build 83; iOS 1.0.2/build 84; android `versionCode` 48 (`versionName` defaults to "1.0.40" at `build.gradle.kts:57-59`); `windows/app/OpenBurnBar.App/app.manifest` **1.0.40.0**; `windows/packaging/msix/Package.appxmanifest` **0.1.0.0**; `functions/package.json` 1.0.0 — against newest tags `v1.0.40+repair.37` / `windows-v1.0.38`.
> - **Fence the Windows manifests.** `app.manifest` is already enforced equal to `MARKETING_VERSION` by the existing gate — **do not edit it**. Leave `Package.appxmanifest` alone (or bump it only in the PR that plans `windows-v1.0.40`), because `openburnbar-release-windows.yml:238` enforces consistency with `OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION=1`.
> - **Do not touch `scripts/commercial-launch-gate.mjs` or `scripts/validate-launch-evidence-bundle.mjs`.** `commercial-launch-gate.mjs:50` requires `launch-evidence/final-launch-evidence.json` and is a `needs:` of two `nightly-e2e` jobs. "Retire the dead requirement" without a criterion proving the gate still fails on a missing/NO_GO bundle is **gate deletion**. Add only a dated superseded banner to `docs/TECHNICAL_READINESS.md`.
> - **The "seven surfaces" list enumerates eight.** Name them: `macos, ios, android, windows, linux, daemon, extension, cli`.
> - **Sequencing:** land after #2395 (`android/app/build.gradle.kts`) and #2396 (`project.yml`) merge, or stack onto them.
> - **agentCount 8 → 13–15**, with a CI-mechanics scout whose **sole deliverable** is the enforcement wiring map (seeds list, sparse-checkout list, fetch-depth/tags availability, classifier FULL_PATTERNS impact, the three README assertions, the ops-script-hardening test) delivered **before any implementer starts**.

**W1-5a — `release(status): generated status block`** (renderer, README marker block, `docs/status/surfaces.json`, RELEASE_ARCHITECTURE table, TECHNICAL_READINESS superseded banner). *Much of this ships early in W0-11.* **Blocked on human queue item 16.**
**W1-5b — `release(version): single-source versions + tag grammar`** (`versions.json`, XcodeGen, Gradle, MSBuild/MSIX, functions, the new checker). Five implementers, one per build system.

```bash
node scripts/release/render-release-status.mjs --check ; echo $?
node --test scripts/release/versions-schema.test.mjs scripts/release/*.test.mjs
node --test scripts/lib/domain-core-native-control-plane-seeds.test.mjs
node --test scripts/ci/verify-ops-script-hardening.test.mjs
bash scripts/verify-version-consistency.sh
node scripts/ci/verify-release-versions.mjs --strict
node scripts/ci/classify-ci-impact.mjs        # expect FULL — reviewer should expect the merge-queue door
bash scripts/ci/check-no-suppressions.sh
```
**scoreDelta:** Overall Professionalism +0.20, Launch Readiness +0.10, Documentation/Maintainability +0.10.

---

## W1-6 — Migration fixtures at schema checkpoints

**Findings:** F24 (second half).

> ### ⚠ Verdict-forced changes
> - **`swift test --filter FixtureMigration passes on Linux` is impossible twice over.** (a) Swift Testing is **not available** to `OpenBurnBarDataTests` on Linux — `OpenBurnBarCore/Package.swift:588-601` sets `swiftTestingAppleDependencies = []` under `#if os(Linux)`, so `import Testing` there breaks the Linux build of the whole target. (b) `swift test` is **banned** on the Linux lane: `scripts/linux-port/verify_linux_swift_tests.py:132-136` fails the contract if `run-linux-swift-tests.sh` contains the string `"swift test"`. → **XCTest with `func test…` names**, and the Linux proof is `bash scripts/linux-port/run-linux-swift-tests.sh` in the docker image.
> - **The suite would not execute on Linux at all.** Linux runs only what `scripts/linux-port/linux-swift-test-manifest.json` lists, and the OpenBurnBarData entry is pinned to `OpenBurnBarDataTests.OpenBurnBarDataLinuxTests` with `minimumExecutedTests: 6`. **Register a new manifest suite with an explicit `filter` and `minimumExecutedTests`** — otherwise the lane stays green having run nothing. `declared_test_count` counts only `func test…`, so `@Test` names score **zero**.
> - **`OpenBurnBar.xcodeproj/project.pbxproj` must be regenerated.** `project.yml:802-810` globs `AgentLensTests/Active` and `AgentLensTests/Fixtures`, so any new test or fixture without a committed regeneration fails the **XcodeGen pbxproj drift** job.
> - **The DBByteCompat hash assertion is unimplementable from the Core package.** The vector lives at `AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-vector.json`, the algorithm at `AgentLensTests/Support/DatabaseByteCompatVector.swift`, and `scripts/check-migrator-parity.mjs:73` hard-codes that path. SwiftPM cannot reach it. Either drop the assertion or commit a **new** vector inside `OpenBurnBarCore/Tests/.../Fixtures/Migrations/` and extend `check-migrator-parity.mjs` to pin it, so the repo does not gain an ungated fourth schema mirror.
> - **Prove the gap before writing a new gate.** `check-migrator-parity.mjs:935-943` already hard-fails on registerMigration count/endpoint drift vs the committed vector, and `scripts/ci/verify-migration-rollback-catalog.mjs` already forces per-migration coverage inside the required **Debt budgets** job. All three pass on main today (`✓ Migrator parity holds: 65 migrations`). The PR body must state which drift class survives both and only the new script catches.
> - **The guard's semantics are wrong and expensive.** Checkpoint fixtures are frozen by definition, and the last-release version does not change mid-cycle, so "exit 1 when a `registerMigration` is added without a regenerated last-release fixture" forces regeneration on **every** migration PR — and the SQLCipher variant is a documented **manual macOS** loop (`DatabaseByteCompatVectorTests.swift:33-42`). Redefine: fail when `git describe`'s newest release tag names a migrator endpoint not represented by any committed fixture manifest entry.
> - **Wire as an extra STEP inside an already-required job** (Debt budgets, or SQLite schema doc drift), never a new context — a new context requires editing both governance configs, and a mismatch between a job's `name:` and the config string **wedges every merge_group run fail-closed**.
> - **Size budget:** each fixture ≤ 128 KB (`PRAGMA page_size=4096` + `VACUUM`), total ≤ 6 fixtures by rotating checkpoints. The existing vector is **1,146,880 bytes**; ~1 MB per migration forever is unreclaimable without a history rewrite. Exemptions must be **mechanical** (compare normalized `sqlite_master` hashes), never an allowlist file. Precisely: `check-no-suppressions.sh:340` requires an allowlist entry for any tracked `budgets/*.json`, and `:343` for any basename matching `*baseline*` with extension `.xml`, `.yml` or `.yaml` — **`.json` is not in that extension list**, so a `*baseline*.json` outside `budgets/` slips both rules. That is a hole, not a licence: this plan treats it as one (see the blacklist carve-out) and puts committed policy state in `governance/` under a name that does not contain "baseline".
> - **Fixture provenance.** The report asks for a fixture "from a real old-version database". Head-generated fixtures are produced by the same code under test, so a historical edit to an old migration cancels out on both sides. Generate at least the last-release checkpoint from a `git worktree` of the newest release tag's migrator, and state the limitation in the fixture README for the v1/v20/v40 checkpoints.
> - **The Linux lane is red now** — `Linux Nightly Matrix` failed six consecutive nights (2026-08-27 … 09-01; latest `33522206852` fails in `ubuntu-gnome-x11-xvfb` on shell-session/evidence/perf-budget scripts, **not** the Swift suites). Restate the Linux evidence as "the linux-swift-tests results JSON inside the nightly artifact shows the new suite executed with 0 failures", which is harvestable from a failing run. Also note `Linux fast package and parity gate` is `needs:`-gated on a macOS perf job and was **skipped** in run `33530451099` when that job failed.
> - **Correct two facts the plan reasons from:** PR Native Fast Gate's SwiftPM job runs on **macos-26** (`pr-native-fast.yml:124`), not ubuntu; and **`Swift↔Windows↔Linux migrator parity` is in neither gate config** — it can run red without blocking a merge. If a blocking guard is the goal, the cheapest correct change is adding `migrator-parity` to the `fast-feedback-gate` `needs:` list.

**Fanout (5):** scout → 3 implementers → verifier → PR author.
```bash
cd OpenBurnBarCore && swift test --filter OpenBurnBarDataFixtureMigrationTests 2>&1 | tee fixture-migration.log
grep -qE 'Executed [1-9][0-9]* tests' fixture-migration.log     # executed-count floor: a renamed filter runs 0 and exits 0
docker run … bash scripts/linux-port/run-linux-swift-tests.sh   # new suite present at its declared minimum
node --test scripts/ci/verify-migration-fixtures.test.mjs       # synthetic tree with an extra registerMigration -> exit 1
xcodegen generate && git diff --exit-code OpenBurnBar.xcodeproj/project.pbxproj
du -b OpenBurnBarCore/Tests/**/Fixtures/Migrations/* | awk '$1>131072{exit 1}'
```
**scoreDelta:** Testing/CI +0.12, Reliability/Ops +0.05.

---

## W1-7 — Split: hygiene / enforce flip

**Findings:** F04 (enforce), F34, F08 (**dropped — see below**).

> ### ⚠ Verdict-forced changes
> - **Split into W1-7a (hygiene, any wave-1 night) and W1-7b (the enforce flip, alone).**
> - **W1-7b has an undeclared hard dependency:** `governance/burnbar-ci-gate.json` on main has **no `circuitBreaker` key** — its keys are `[context, cancelled_grace_seconds, stalled_check_grace_minutes, poll_interval_seconds, timeout_minutes, component_runtime_budget_minutes, required_contexts]`. The key is a **W0-3** deliverable. `dependsOn: [W0-3]`.
> - **The stated precondition is not reachable as written.** `ci/` does not exist on main, and 4 of 5 lanes are 100% red — `openburnbar-pr-harness`, `linux-nightly`, `codeql` all failure over their last 5; `app-pr-gate` failure over its last 4 on main; **`nightly-e2e.yml` is `disabled_manually`** and has not run since 2026-07-30. **Rewritten as an agent-evaluable condition:** `ci/nightly-health.json` exists AND six entries show `conclusion=success` with `consecutive_red=0` on two successive dates AND `nightly-e2e.yml` state ≠ `disabled_manually`. If unmet by the last night of the wave, W1-7b ends `OPEN_WITH_NAMED_BLOCKER` — it does **not** flip anyway.
> - **Enforce would deadlock the wave's own gate item 8.** `app-pr-gate` is push-triggered on main and takes **32–44 minutes** (measured: 44/32/34/44 on the last four main runs), so for 30–45 minutes after every merge the base SHA has no completed verdict. This is exactly why W0-3's rewritten evaluator treats *missing* as **pass with an annotation** rather than fail-closed.
> - **The breaker's signal is fake-greenable.** Run `33326737617` (main, 2026-08-30 17:58Z) shows `App build + test (AgentLens)` `conclusion=success` **in one minute** with `AgentLens Rust + Swift build/test prerequisites` = **skipped** and `Mobile build + unit test` = **skipped**. Required criterion: *a check-run whose lane did not execute is UNKNOWN, not PASS*, proven by a self-test case built from that exact run.
> - **The self-test runs in no lane.** `git grep await-burnbar-ci-gate.test` returns **zero** hits in `.github/workflows`, `scripts` and the Makefile. Add `node --test scripts/ci/await-burnbar-ci-gate.test.mjs` as a step in `workflow-lint.yml`.
> - **Two `merge_group` runs are required**, not one — both configs are read from the trusted base tree.
> - **The dependabot deliverable is part no-op, part human-gated.** `.github/dependabot.yml` already has **28** `package-ecosystem` entries, each `interval: weekly` with `groups: all-updates patterns ["*"]` (live PRs #2425/#2431/#2432/#2433/#2165 are literally "bump the all-updates group"), and groups cannot span ecosystems. **Rewritten:** prune the 28 entries to those with real manifests, cap `open-pull-requests-limit` to 1 per ecosystem, and close the ~21 superseded bot PRs with `@dependabot close`. **"Auto-merge on green" is deleted** — it does not exist anywhere in the repo, and with `dismiss_stale_reviews` + a required approval it either no-ops or requires a bot approval, which is a review waiver only Alberto may grant.
> - **Three deliverables had no doneCriteria.** Added for changelog fragments (`bash scripts/tag-release.sh --dry-run <version>` — a new flag — assembles `changelog.d/*.md` into a `## [X.Y.Z]` section **without cutting a tag**; `scripts/verify-version-consistency.sh` exits 0), dependabot (the diff plus a dropping open-PR count), and TODOS.md (each of the ~11 items maps to a `gh issue` URL listed in the PR body; the file is deleted and its 4 inbound references updated).
> - **Two path errors:** nothing matching `root-allowlist` exists under `scripts/` today, and the version gate is `bash scripts/verify-version-consistency.sh` (the README status-line regex is at **`:54`**, not `:56`). The root check is **W0-11's `bash scripts/ci/check-root-inventory.sh`**, reading `governance/root-inventory.json` — deliberately not a `budgets/*.json`, so it creates no suppression; W1-7a consumes it rather than building a second one.
> - **"Root contains only allowlisted files" is unachievable** — the root-ratchet shape from W0-11 replaces it.
> - **Confidentiality precondition** before committing the 2026-09-01 reports (both untracked, no banner, **public repo**, `guard` scans the full tracked tree).
> - **`branch-reaper.yml` construction constraints:** every action SHA-pinned (`scripts/ci/verify-github-action-pins.mjs` runs in `workflow-lint.yml`), no workflow-level `paths:` filter, a `governance/workflow-reachability.json` entry only if a job can inherit a skip. `delete_branch_on_merge` is live `false` and **admin-only**, so the deliverable is *"manifest artifact + a comment on the human-queue issue with the exact `gh api -X DELETE` list"*, never a deletion.
> - **F08 is dropped from this workstream.** Nothing in the fanout addresses it: the pack is **485,241 objects / 8.62 GiB**, `Vendor/*.aar` has 70 revisions, `tmp-utm-desktop.png` (5,001,686 B) is still tracked at root, and there is no forward large-blob guard. As packaged, the gate would report F08 **closed** without a single F08 fix landing. The two zero-risk pieces (delete `tmp-utm-desktop.png` and the 7 MB `.deb`, add a >5 MB new-blob check to the same ratchet) are already in **W0-11**; everything needing `filter-repo`, LFS billing, or a Maven registry stays in the human queue (items 21–22).
> - **The hygiene half is not fast lane** — it adds a job to a required aggregator's `needs`, relocates 8 tracked root documents, changes the CHANGELOG/release contract consumed by five workflows and `scripts/linux-port/check-linux-docs.mjs`, and adds a scheduled workflow. **agentCount 6 → 8** plus a separate single-agent W1-7b.

```bash
# W1-7b, both runs required:
gh run list --workflow burnbar-ci-gate.yml --event merge_group -L2 --json conclusion,url
node --test scripts/ci/await-burnbar-ci-gate.test.mjs   # incl. the "skipped lane == UNKNOWN, not PASS" case from run 33326737617
# W1-7a:
bash scripts/tag-release.sh --dry-run 1.0.41 && bash scripts/verify-version-consistency.sh
bash scripts/ci/check-root-inventory.sh && bash scripts/ci/check-root-inventory.sh --self-test
gh pr list --author app/dependabot --state open | wc -l   # dropped
node scripts/security/scan-internal-content.mjs
```
**scoreDelta:** Overall Professionalism +0.20, Testing/CI +0.10 *(the enforce flip is where W0-3's withheld +0.15/+0.10 is finally booked)*.


---

# WAVE 2 — Measured quality and performance (2026-09-08 → 09-19)

**Hard precondition added by the verdicts:** `App PR Gate (Swift)` must go **green on a scheduled run** before any wave-2 workstream claims Swift evidence. It failed **5 consecutive nightlies** (runs `33209873038`, `33257628486`, `33316776033`, `33417409206`, `33517590357`) at the *same* step — `Enforce real macOS idle/occluded CPU budget (P-PERF-3)` — and the 09-01 run also failed `Build mobile app + unit tests for testing`. **W0-2 implementer (e) and W2-4 jointly own that repair; if it is not green, wave-2's Swift halves are re-planned, not shipped blind.**

## Wave-2 exit gate — corrected

1. `make debt-check` green with the unified `budgets/swift-debt-ledger.json` and every count ≤ the wave-1 baseline — **and** its exact path present in the `docs/LINT_RATIONALE.md` allowlist block (`check-no-suppressions.sh:340` fails closed otherwise).
2. `app-pr-gate.yml` scheduled run green with **all three** jobs `success` — `AgentLens Rust + Swift build/test prerequisites`, `Mobile build + unit test`, `App build + test (AgentLens)` — on **3 consecutive nights**. *(`headless-app-build` green is explicitly **not** sufficient: its own header says it runs `xcodebuild build` **only** and compiles no test target, and it is green today while the test lane is red.)*
3. `perf-nightly.yml` uploads `perf-report.json` with p50/p95 for the package benchmarks and criterion benches, all within budget. *(The proc_pidinfo idle-CPU number is produced only by the currently-red `app-pr-gate`; it enters this gate only once condition 2 holds.)*
4. `Task.sleep` occurrences in Swift test files, counted by `scripts/ci/check-test-hygiene.mjs` over its declared glob, **≤ 130** — 50% of the **261 measured across 85 files at 9503b490b0** (the plan said 259/83). The script prints both the baseline SHA and the live count.
5. `.app` bundle-size ratchet passes in `headless-app-build.yml` with the starter pet set. *(Replaces "DMG size assertion in release.yml": `release.yml` triggers **only** on `push: tags: v*` / dispatch-with-tag, has zero cron, needs Developer ID + notarytool + `SPARKLE_PRIVATE_KEY`, and is 23 failure / 6 success over its last 40 runs.)*
6. `terraform fmt -check` + `terraform validate` pass on an ops-plane module with a **local** backend, and its generated-policy fixture test asserts one `google_monitoring_alert_policy` per displayName (**27** in `ops-alert-policy-definitions.mjs` + **9** in `billing-alert-policy-definitions.mjs` = **36**). *(Replaces "`terraform plan -detailed-exitcode` exits 0 against production": no `terraform/` dir exists, `apikeys`/billing IAM is human-only, no Cloud Billing budget exists anywhere in the repo, and importing 36 live policies is a state **write** — contradicting "read-only creds".)*
7. `node scripts/ci/verify-data-room.mjs --check` exits 0 with a wave-2 row per workstream.

---

## W2-1 — One SwiftSyntax debt ledger; test targets to Swift 6

**Findings:** F20, F21, F28.

> ### ⚠ Verdict-forced changes
> - **The tool has no lane.** `rg 'setup-swift|swift-actions|swiftlang/swift:|swiftly' .github/workflows/` returns **zero** hits — no Linux runner in this repo has Swift, and every Swift lane is `macos-26`. The job the ledger would replace, **Debt budgets (shrink-only ratchets)**, is `ubuntu-latest` with only `setup-node` and completed in **36 seconds** on its most recent run. Bolting a Swift toolchain plus a from-source swift-syntax 600.0.1 build into a workflow literally named "Fast Feedback (<5 min)" is a CHEAP_FAST violation. → **Keep the ledger scanner in Python/bash** on the existing ubuntu job. If a SwiftSyntax analyzer is genuinely required, it belongs on the existing `macos-26` SwiftPM job or nightly, with a measured cold/warm build delta and an explicit acceptance threshold — and swift-syntax is currently only a **transitive** swift-testing resolution, never a build target, so it is new compile cost.
> - **New `budgets/*.json` requires the `docs/LINT_RATIONALE.md` exact-path allowlist entry in the same PR.** Four are proposed (`swift-debt-ledger`, `type-size-baseline`, `try-optional-baseline`, `concurrency-escapes-baseline`); none appeared in fixTouches. Worse in substance: `scripts/debt/check-try-optional-budget.sh:24-30` today asserts `live == 0`, so converting it to a shrink-only ledger baselined at ~1,600 untagged `try?` is **threshold expansion**.
> - **Evidence was read off the dirty tree.** `nonisolated(unsafe)` is **104** on main vs 103 in the worktree (delta in `OpenBurnBarCore/Sources/OpenBurnBarLaunchServices/CLIAuthDiscovery.swift`); `DispatchQueue.main.async` is **42** vs 40. F28 quotes the worktree numbers as fact, and its cited `ComputerUseSessionCoordinator.swift:210-211` does **not exist on main** (main `:210-211` is `let sessionID: String` / `let requestedAt: Date`; the file is ` M` dirty). F21's `ComputerUseRuntimeController.swift` "branch-local untagged `try?`" is dirty-tree-only — the gate is **green on main**. **Re-derive every count from a clean checkout of `origin/main 9503b490b0`.**
> - **`check-type-size-budget.sh` does not exist** — you cannot "remove" it; F20 proposes creating it.
> - **The file_length claim is wrong.** The largest linted Swift file is `OpenBurnBarDaemon/Tests/…/OpenBurnBarMissionControlServiceTests.swift` at **6,126** lines, then `OpenBurnBarHTTPGatewayServerTests.swift` 6,102, `OpenBurnBarMobileTests.swift` 5,970, `ProviderQuotaServiceTests.swift` **5,959** (not 6,129 — the `.swiftlint.yml:212-221` comment is stale). `.swiftlint.yml` `excluded:` does **not** exclude `OpenBurnBarDaemon/Tests` or `OpenBurnBarMobileTests`, so splitting `ProviderQuotaServiceTests` alone moves the ratchet by **zero** lines. The honest ratchet is restorable to ~5,970 **today** with zero source changes.
> - **"Daemon try?/String-Any budgets at 0" conflates two incompatible metrics.** `check-string-any-boundary-budget.sh` counts **occurrences** (live: 448 in Daemon/Sources, 702 in Core/Sources), and its own baseline note records sites that **must stay untyped** (the AI Inbox state-write payloads, because merge-clears need `FieldValue.delete()`); `count-error-debt.py` counts **untagged `try?`**. One bullet, two meanings, no single command. Split into two measurable bullets; `[String: Any]` becomes **shrink-only**, not zero.
> - **Job names must stay byte-identical in PR-1.** `governance/burnbar-ci-gate.fast.json` names both `Debt budgets (shrink-only ratchets)` and `Structural Debt Ratchets`, and `burnbar-ci-gate.yml` checks out the **base** sha — a PR that renames or deletes a named context is judged against main's config and **fails closed**. PR-1 may change job *internals* and remove names from the config; only PR-2, based on merged PR-1, may rename.
> - **Sequence the SwiftLint custom rule LAST.** `--strict` runs tree-wide in PR Native Fast Gate; a `try?-ok(<reason>)` rule matches ~1,600 sites on day one (Daemon alone: 475 in Sources, 0 tagged) and reddens the door immediately.
> - **`check-unchecked-sendable-budget.sh` is not a plain ratchet** — it validates a 17-entry reason-id registry cross-referenced in `docs/security/UNCHECKED_SENDABLE_REMEDIATION.md` and is wired in **both** `fast-feedback.yml` and `openburnbar-pr-harness.yml`. Deleting it without porting the registry silently weakens a security gate under a CODEOWNERS tree.
> - **Test-target Swift 6 is out of the wave.** Measured: **1,164 test files / 386,222 lines** (AgentLensTests 467/181,498; OpenBurnBarCore/Tests 353/76,201; OpenBurnBarDaemon/Tests 215/85,685; OpenBurnBarMobileTests 116/41,049), plus 19 `.swiftLanguageMode(.v5)` targets and 5 `SWIFT_VERSION: "5.10"` blocks. If any part stays, restrict it to the SwiftPM test targets the `macos-26` PR lane already compiles (Core + Daemon) and explicitly defer the **5 Xcode targets**, which compile only on the currently-red nightly.
> - **Minor corrections:** `nonisolated(unsafe) … = Tool(` statics are **30** (21 + 9), not 36; `FieldValue` appears **0** times in `OpenBurnBarDaemon/Sources`, so the `FirestorePatch<T>` motivation belongs to AgentLens/Mobile, not the daemon.
> - **Fanout discipline:** assign each sweep implementer a **disjoint directory root**, each in its own worktree off `origin/main`, and forbid touching `AgentLens/Services/Media/MercuryRouter.swift` or `ComputerUseSessionCoordinator.swift` (both dirty) until that branch is reconciled — 131 dirty Swift files sit under exactly those roots.
> - **Grafted (judges ×3):** the per-type budget sums every `extension T` body; the `try?-ok(<reason>)` vocabulary is a **closed enum enforced by the checker**, not a comment convention; an anti-rubber-stamp criterion — a PR adding more than N new tags without a corresponding count reduction fails.
> - **Grafted (plan-2 W0-9, judges ×3):** land the typed `indirect enum JSONSchema: Codable & Sendable` for Tool definitions **early**, with byte-equal golden fixtures for the provider tool payloads. It removes 30 `nonisolated(unsafe)` statics cheaply, seeds the concurrency ledger at the lower number, and is reused by the RPC schema exporter in W3-3.

**PRs:** PR-1 ledger tooling + baselines (no source edits, fast-door verifiable) → PR-2 Daemon privileged-path `try?` conversions with `swift test` evidence → PR-3 Core/Views/Mobile tag-and-ratchet. PR-2/PR-3 open only after PR-1 merges.
```bash
python3 scripts/debt/debt_scan.py --check budgets/swift-debt-ledger.json
bash scripts/ci/check-no-suppressions.sh          # ledger path allowlisted in docs/LINT_RATIONALE.md
python3 tools/error-debt/count-error-debt.py --metric try-optional   # untagged == 0 for Daemon+Core Sources
bash scripts/debt/check-string-any-boundary-budget.sh               # shrink-only from 448 / 702
# mutation check: reintroduce one untagged try? / nonisolated(unsafe) / oversized type on a scratch branch -> gate goes RED
```
**scoreDelta:** Code Quality +0.40, Architecture +0.10, Security +0.05.

---

## W2-2 — Foundation layer — split into five, not three

**Findings:** F22, F23.

> ### ⚠ Verdict-forced changes
> - **The headline detector is vacuous — but the scope is 26 sites, not "1 func".** `git grep -n "func nilIfEmpty" -- '*.swift'` returns **exactly one** hit (`MercuryConsentStore.swift:310`), which is why a `func`-shaped criterion is vacuous. It does **not** follow that the duplication is one site: `git grep -cE '(var|func|let) +nilIfEmpty' origin/main -- '*.swift'` returns **26** — 1 `func nilIfEmpty()`, **21** plain `var nilIfEmpty` computed properties, and 4 renamed variants: `nilIfEmptyToken` (`InteractiveTerminalLauncher.swift:391`), `nilIfEmptyForFocusFollow` (`AgentFocusFollowController.swift:251`), `nilIfEmptyForMercury` (`MercuryRouter+SupportingTypes.swift:46`), `nilIfEmptyForCapture` (`ScreenCapturePipeline.swift:338`). They span AgentLens Services and Views, `OpenBurnBarCore` (Iroh relay, Kernel, LogParsers ×2, Quota), `OpenBurnBarDaemon` and `OpenBurnBarMobile`. **W2-2a's real scope is 26 declaration sites across four SwiftPM/app boundaries, and the report's "25 copies" was substantially right** — the earlier framing *"1 `func`, not 25"* corrected the detector and accidentally shrank the finding, which is the same error in the other direction. Deleting one `func` makes the naive criterion return 0 with the duplication fully intact, and the proposed SwiftLint rule inherits the identical hole. **Use `(var|func|let) +nilIfEmpty`, name all four renames, and state the count as 26.**
> - **Mutation-check every custom rule** before it counts as done: a recorded run showing the rule **firing** on a deliberately reintroduced violation, then passing after removal. A rule whose regex matches nothing on main is not enforcement.
> - **Move `JSONDecoder()` out of W2-2 into its own workstream.** **870 occurrences across 452 Swift files** (Core 163, Daemon 106, AgentLens 93, Mobile 42, AgentLensTests 34, Vendor 3, tools 2, scripts 2) — none in fixTouches, and an error-severity lint keeps the required PR Native Gate red until every one migrates, so rule and migration must ship atomically. Stage: JSONCoding + Kernel/Core → Daemon → AgentLens/Mobile → rule. **Sanction `Vendor/**` explicitly** (5 vendored GRDB files contain `JSONDecoder()`).
> - **Factories, not singletons.** `OpenBurnBarCore/Package.swift` declares `swiftLanguageModes: [.v6]` and `OpenBurnBarKernel` has no `.v5` override, so a `static let` of non-Sendable `JSONDecoder`/`JSONEncoder` is a **concurrency-safety error**. Use `enum JSONCoding { static func makeDecoder(_ style: Style) -> JSONDecoder }`; `nonisolated(unsafe)` is forbidden as the workaround.
> - **The repo has no pnpm workspace.** No `pnpm-workspace.yaml`/`pnpm-lock.yaml` outside `.deepsec/`; the root lockfile is `package-lock.json`; root `package.json` declares **no `workspaces`** field; `packages/*` are standalone `tsc` packages scoped `@openburnbar/*`. → **`packages/guards` as a standalone `@openburnbar/guards`** following `packages/entitlements`' shape, consumed via `file:` deps, with explicit sub-tasks for syncpack, Dependency Boundaries and Unused Dependencies (all required contexts) plus every `npm ci` invocation that must learn it.
> - **The "21 `*Logger` types" are not one concern** — audit sinks (`ComputerUseAuditLogger`, `IrohTransportAuditLogger`), DI protocol seams (`QuotaLogger`, `CloudVaultDomainCoreLogging`, `BurnBarDaemonLogging`), test doubles, two platform shims, and **two distinct `AppLogger` types in different SwiftPM targets** (`AgentLens/Services/AppLogger.swift:13` vs `OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDataLogger.swift:3`) that cannot merge across the app/package boundary. **Scope to:** replace the 20 `NSLog(` sites and the `debugTrace` helper with `os.Logger`/`AppLogger`, add `no_nslog` and `no_print_in_library_targets` rules, and state that audit sinks and protocol seams are out of scope.
> - **The keychain claim must be downgraded.** The only product `kSecAttrAccessGroup` is `AccountManager.swift:850` with team-prefixed `4Y367DF25B.com.openburnbar.app`; access-group items need a **signed entitlement** that hosted-runner test bundles do not have. CI parity is **dictionary-shape only**. Add a **named human step**: Alberto runs a signed local build once and confirms existing daemon/mobile secrets still resolve before the keychain PR merges. Also: 216 Swift files reference Keychain, including `CursorConnector/KeychainStore.swift` and `PetCompanion/Agents/PetKeychainStore.swift`, neither in fixTouches — an unabsorbed second wrapper defeats the point.
> - **Resolve the `kSecClass` ban vs the parity tests:** the rule must `excluded:` the parity tests and `KeychainItemStore.swift`, which must contain raw queries to compare against.
> - **The CPD swap is a category error.** `.jscpd.json` `threshold: 6` is a **percentage**; PMD CPD reports duplicated **tokens/lines**. The proposed config is deliberately **more** sensitive (`--ignore-identifiers --ignore-literals`) over a **larger** corpus (tests back in scope, versus jscpd's ignores of `**/Tests/**`, `**/*Tests/**`, `scripts/**`, `Vendor/**`), so a lower CPD number is impossible. **Replaced:** run PMD CPD over the *same* corpus, record its first-run output as the baseline, and lower it in the same PR by the exact duplicated-token count removed. Also retarget or delete `scripts/ci/verify-jscpd-report.mjs` + its test, executed by `workflow-lint.yml:410`. Note neither jscpd nor CPD is in either gate config today, so this swap is what **promotes** it to a required ratchet.
> - **The `ComputerUseE2E` "stdout contract" has zero consumers.** `git grep ComputerUseE2E` returns only the two `print(` **producers** (`ComputerUseSessionCoordinator.swift:228`, `ComputerUseRuntimeController.swift:192`) — no workflow, script or harness parses it, and `computer-use-loopback-test.yml`'s `paths:` filter excludes `AgentLens/**` so this diff would not even trigger it. **Delete the "loopback green" criterion**; requiring a green run of two `macos-26` jobs (libsignal FFI + Playwright `--runs 5`) as PR evidence puts a nightly-class Mac job on the fast door. If an `E2EEvidenceSink` is still wanted, it is its own workstream gated on **first proving a consumer exists**.
> - **QuickSwitch snapshot tests are green-by-skip.** `AgentLensTests/Support/SnapshotTestSupport.swift:21-28` returns true whenever `GITHUB_ACTIONS=true`, `RUNNER_OS` is set, or the path contains `/Users/runner/work/`, and the assert helpers early-return at `:99`/`:130`. **Never accept a skipped snapshot test as evidence.** Either assert the pure `QuickSwitchCore` reducer output, or add a CI-executable snapshot path with committed goldens and an opt-in env var — and make "the guard no longer skips" its own criterion. QuickSwitch is split out as its own PR because its only proof is the nightly lane, and a regression there resets wave-2 gate item 2's three-night counter.
> - **Line citations are stale:** `ComputerUseSessionCoordinator.swift` is **764** lines on main (the plan cites `:796-804`); the dead `stringArrayValue` copy is at `:750` with its live twin at `+ScopeAudit.swift:510`. Counts: `kSecClassGenericPassword` **76** lines / 33 files (not 77), `JSONDecoder()` **870** (not 863), TS `isRecord` **38** (not 37), `formatTokens` **8** (not 7). **Locate by symbol via `rg`, never by the plan's line numbers.**
> - **Any new file under `AgentLens/`, `AgentLensTests/` or `OpenBurnBarMobile/` requires `xcodegen generate` + a committed `project.pbxproj`.**
> - **`needsHuman` corrected to true** (the signed-build keychain confirmation), and PRs serialize behind #2466.

**Five PRs:** W2-2a Kernel string/format helpers + rules · W2-2b `KeychainItemStore` **alone** (credential storage) · W2-2c unified logging · W2-2d `JSONCoding` staged per module · W2-2e `QuickSwitchCore`.
**scoreDelta:** Code Quality +0.35, Security +0.05.

---

## W2-3 — No main-thread I/O, no free-running timers, bounded capture pipeline

**Findings:** F33, F18. **Split: W2-3a (usage/dashboard, ships now) / W2-3b (media, BLOCKED).**

> ### ⚠ Verdict-forced changes
> - **F18's evidence was read off the forbidden dirty tree.** `BitrateController.swift:91-108 apply(sample:)` — on `origin/main` those lines are `stepUp()`; `apply(sample:)` is at **:68** and has **no `pathConstrained` clamp**. The clamping ladder exists only uncommitted (`BitrateController` +54, `VideoEncoder` +52/−16, `MediaSessionCoordinator` +17). `MediaGOP.swift` and `MediaBweFeedbackPayload.swift` do not exist on main at all. **Re-ground every citation with `git show origin/main:<path>` in a clean worktree.**
> - **W2-3b is `needsHuman: true` → human queue item 29.** Named blocker: *"the feat/living-glass-sweep media diffs are uncommitted (210 dirty paths, 45 behind main); only Alberto can land or abandon them"*. The winner plan's "rebases … once it lands or waits" hid a human dependency inside a `needsHuman:false` workstream — and the first draft of *this* document then left that dependency off the numbered queue entirely, which meant **F18's only mapped workstream could never start.** It is now **queue item 29**, with both branches specified (land and rebase, or abandon and re-plan from `origin/main` at ~3× the hours). Until item 29 is answered, F18's honest status is `BLOCKED-ON-OWNER`, not "covered".
> - **W2-3a carries the half of F18 that ships regardless, and the coverage table credits it.** `ScreenCapturePipeline.swift` is **clean** vs `origin/main`, so its bounded-AsyncStream change — which is the direct answer to F18's *"unbounded per-frame Task spawn"* — proceeds independently of the dirty tree and of item 29. Booking that under W2-3a rather than leaving F18 mapped to a blocked workstream alone is the difference between a finding that is covered and one that only looks covered.
> - **The governor fix is factually wrong.** `ParserResourceGovernor` is **already** `public final class … : Sendable` with `private let state = Locked(State())`. Converting it to an actor forces **~82 call sites** to await, including the synchronous `checkpoint()` hot path. Instead add `reserve(bytes:) -> Bool` / `release(bytes:)` inside the existing `Locked<State>` critical section.
> - **No new `budgets/*.json` without the `docs/LINT_RATIONALE.md` entry**, and it collides with the wave-2 gate's unified ledger — extend the ledger instead of adding `budgets/main-thread-io-baseline.json` and `budgets/timer-loop-baseline.json`. Extend the already-allowlisted `budgets/usage-refresh-tick-baseline.json` for the timer counters.
> - **The new check is never wired to the door it claims.** `scripts/debt/check-main-thread-io-budget.sh` was added to fixTouches but neither `fast-feedback.yml` (whose `debt-budgets` job enumerates each script as an explicit step) nor the Makefile `debt-check` target was — so "exit 0" is satisfiable by hand while CI never invokes it. Require a **mutation check** proving a deliberately-introduced violation fails that job.
> - **The proposed enforcement cannot measure what it claims.** A grep cannot see `@MainActor` isolation, and AgentLens has **1,145** `@MainActor` annotations across 369 files. Live counts: `Timer.publish` = 3 in AgentLens of which **only `CastleGreatHallView.swift:20` is code** (the other two are doc comments in `DashboardChromeComponents.swift:83,86`); `FileManager.default.enumerator(` = **1** app-wide; `Data(contentsOf:)` = 43 app-wide, 3 under Views. And `.swiftlint.yml` `custom_rules` are single-line regex matchers with **no loop/AST context**, so a rule for `Task.sleep(nanoseconds: 1_000_000_000)` "inside `while` loops" matches nothing or all 158 sleep sites. → Use SwiftSyntax rules in W2-1's ledger (`mainActorFileIO`, `freeRunningTimer`), and make the timer criterion countable: **`Timer.publish` in AgentLens/Views = 0** (baseline 1, excluding comments) and the three named 1 s loops (`MercuryRouter+RoutingRuntime.swift:295`, `AutoSummaryEngine.swift:122`, `PixelClockController.swift:390`) registered with `BackgroundCadenceCoordinator`.
> - **A wall-time benchmark may not go on the fast door.** `PR Native Gate`'s `swiftpm-native` job is `macos-26` with `timeout-minutes: 40`, already above the fast gate's 30-minute component budget. Keep only deterministic allocation/transaction-count tests on the door; any timing assertion moves to the nightly lane.
> - **The "5.5 GB fixture" and the "committed fixture corpus" do not exist.** The whole test `Fixtures` dir is 120 KB and the largest tracked file is 81 MB. Replace with a runtime **synthetic generator** (≤ 500 MB, temp dir) asserting the byte-budget deferral path, with peak footprint asserted as a **ratio to budget**, not wall clock.
> - **Add a deferral-determinism criterion.** With `withThrowingTaskGroup` fan-out, the invariant documented at `RefreshBackgroundWork.swift:188-198` (checkpoint **not** advanced when the byte budget deferred any of a provider's files) becomes race-dependent under a shared budget. Either give each provider a fixed slice or serialize budget draw in a stable order, proven by running the same fixture set 20× and asserting an identical advanced-checkpoint set.
> - **The stated SwiftLint risk is false:** `RefreshBackgroundWork.swift` is **596** lines against a `file_length` warning of 6,130. The real constraint is `budgets/swift-file-size-baseline.json`, which does not list it. Keep the extraction on architecture grounds.
> - **`BackgroundCadenceCoordinator` has 15 `register(` sites across 12 files**, not "only 6 services".
> - **Strike the MetricKit/`MXHangDiagnostic` clause** — `docs/architecture/macos-performance.md` (2,257 lines) contains no such reference, so it is not "already implied", and MetricKit payloads arrive from **user devices on next launch** and can never feed a CI lane.
> - **Any new `@unchecked Sendable` in the frame gate** must reuse the existing `apple-media-buffer` reason-id and keep `check-unchecked-sendable-budget.sh` at ratchet 0, with `docs/security/UNCHECKED_SENDABLE_REMEDIATION.md` updated.
> - **New Swift files require `xcodegen generate` + committed `pbxproj`** (`project.yml:186` globs all of `AgentLens`, `:750` globs `AgentLensTests/Active`).
> - **`perf-nightly.yml` does not exist** — it is W2-4's deliverable. Declare the dependency explicitly.
> - **`FrameBackpressurePolicy` must be proven without a display.** ScreenCaptureKit needs Screen Recording TCC on a GUI session no hosted runner has, and `MercuryRouterTests.swift:2317` already proves display tests `XCTSkip` on CI — which `burnbar-ci-gate` counts as **passing**. Prove drop/coalesce/hysteresis with a clock-injected unit test over a synthetic 60 fps sequence in `OpenBurnBarMedia`, asserting exact drop counts.

**scoreDelta:** Performance/Scalability +0.35, Architecture +0.05.

---

## W2-4 — Performance as versioned contracts; ops plane as code — split in two

**Findings:** F27, F02 (remainder). **Split: W2-4a perf (agent-feasible) / W2-4b ops plane (human-gated). They must not share a gate.**

> ### ⚠ Verdict-forced changes
> - **The ops-plane fix is blocked by a required merge-door gate the workstream never listed.** `scripts/ci/verify-ops-plane-workflow-boundary.mjs` runs at `fast-feedback.yml:1262-1264` inside the `no-suppressions` job — a `needs:` of the required Fast Feedback Gate — and hard-asserts, byte-for-byte, that `ops-plane-verify.yml`'s `verify` job carries `environment: production`, authenticates with `credentials_json: ${{ secrets.GCP_SA_KEY }}`, and that `${{ secrets.GCP_SA_KEY }}` appears **exactly twice**. F02's "WIF-only `verify` job with NO environment gate" violates all three, and none of the gate files were in fixTouches. **W0-5 already resolves this correctly** by adding a *new* job and extending the boundary gate as an invariant swap.
> - **The terraform criterion is self-contradictory and human-gated.** No `terraform/` or `infra/` dir; **zero** terraform references across all 84 workflows; `terraform`/`tofu` not installed; and `rg -i 'google_billing_budget|budgets.googleapis|billingbudget'` matches only the diligence report — **no Cloud Billing budget exists**. `plan` exit 0 would require `terraform import` of 36 alert definitions plus channels and SLOs (a state **write**, contradicting "read-only creds") and a budget only `roles/billing.admin` can create. Corrected in wave-2 gate item 6.
> - **Retiring `check-ops-alert-plane-drift.mjs` is a net loss of merge-door coverage.** Its self-test runs at `fast-feedback.yml:1270` (required `no-suppressions`) and at `scripts/ci/verify-ops-readiness.sh:38-39` (`make ops-check`). `terraform plan` needs GCP creds bound to the approval-gated `production` environment, and secrets are unavailable on `pull_request`. **Retain it**; re-point it to diff live `gcloud` state against the Terraform-generated policy set.
> - **The ops-plane evidence path is dead and only Alberto can revive it** — human queue item 7. Land the **per-job concurrency split as the very first commit** so it cannot recur.
> - **F02 is marked `agentFeasibleOvernight: false`** by the pack itself; the winner plan bundled it into an 8-agent wave-2 workstream anyway.
> - **`burnbar-turbo.yml` already runs the real measurement.** F27's "burnbar-turbo.yml:152 runs only the self-test" is **false**: `:177-179` runs `node scripts/ci/macos-idle-occlusion-gate.mjs --output …` after a full Debug xcodebuild on the owner-authorized ephemeral Mac group. **Use one dispatched Turbo run as the interim idle-CPU evidence path** instead of waiting on the red `app-pr-gate`.
> - **Do not touch `app-pr-gate.yml` without `scripts/ci/verify-pr-harness-aggregate-gates.test.mjs`** — it runs on the fast door (`fast-feedback.yml:1273`) and pins exact step names and run strings at `:418-465`, including asserting `continue-on-error` is **absent** on the three P-PERF-3 steps. Relaxing that verifier to make an edit pass is the forbidden fake-green.
> - **`scripts/ci/macos-idle-occlusion-gate.test.mjs:67` hard-asserts `budget.gate.type === "behavioral-assertion"`.** Either keep `gate.type` and add the measured contract under a **new** key, or change both files together **and** record explicit Alberto sign-off — `budgets/macos-idle-cpu.perf.json`'s own `trendPolicy` says the tripwire "may only be relaxed with A5 sign-off and a written rationale in the PR body".
> - **`humanAction` corrected:** strike "fix the self-hosted macOS runner / hosted-runner minutes". `docs/CI_COST_CONTROLS.md:69-70` **forbids** granting this public repo the persistent self-hosted group or paid larger-runner pools, and `app-pr-gate` already runs on hosted `macos-26`. The agent-owned task is: diagnose the real failure from the last 8 run logs and name the root cause.
> - **Android Macrobenchmark is its own workstream, not one of six slots.** `android/macrobenchmark/build.gradle.kts` sets `baselineProfile { useConnectedDevices = true }` and its header states *"Both commands need a connected device… Nothing in here runs during normal app builds, unit tests, or CI lint gates."* `android/app/build.gradle.kts` declares only `debug` and `release` — no `benchmark` variant, no `testBuildType`, and `release` is gated on `hasReleaseSigningConfig` (signing is human-only). No workflow invokes any `:macrobenchmark` task.
> - **New `budgets/*.perf.json` files need `docs/LINT_RATIONALE.md` allowlist entries** — `docs/OPERATION_9_PLAN.md:236` already records this invariant as P-PERF-3.
> - **`on: schedule` fires only from the default branch**, so `perf-nightly.yml` yields no scheduled run until it merges. Give it `workflow_dispatch` too, and make the PR-time proof a dispatch artifact plus `node --test scripts/ci/check-perf-ratchet.test.mjs` failing on a committed synthetic 20%-regression fixture.
> - **New-workflow gates omitted from fixTouches:** `governance/workflow-reachability.json` (+ schema) and `scripts/ci/verify-workflow-reachability.mjs` (skip-propagation + paths-coverage of every transitively-imported local script), and `scripts/ci/verify-github-action-pins.mjs` (`benchmark-action/github-action-benchmark` and `hashicorp/setup-terraform` must be SHA-pinned).
> - **"Benchmark dashboard URL" is not a completion criterion** — `git ls-remote --heads origin gh-pages` is empty and `GET /repos/:owner/:repo/pages` returns **404**. Use the `perf-report.json` artifact plus a committed criterion baseline.
> - **`linux-product-parity.yml` cannot simply gain a `schedule:`** — it has three `required: true` dispatch inputs (including a 20-option `requirement` choice) and `macos-26` producer jobs. Either supply defaults or extract only `run-perf-budget.mjs` + `budgets/linux-desktop.perf.json` into `perf-nightly.yml` on ubuntu.
> - **Dependency cost:** `apple/swift-benchmark` (needs jemalloc) churns **both** `OpenBurnBarCore/Package.resolved` and the app workspace's `Package.resolved` (gated by `scripts/check-openburnbar-app-swiftpm-lock.sh`, needing a macOS `xcodebuild -resolvePackageDependencies`); `criterion` in the AGPL `crates/burnbar-remote` workspace must clear Rust fmt/clippy/cargo-deny, OSV, Unused Dependencies, Dependency Boundaries, AGPL posture, and `check-cargo-dependency-confusion.mjs`. Sequence after #2466.
> - **`prLane` corrected to structured-large** (a Terraform production ops plane + WIF SA swap + boundary-verifier rewrite is not fast-lane), and **`agentCount` 8 → 13** to match its own fanout string.
> - **Policy count corrected:** **36** policies (27 + 9), not "12+".
> - **PR-time runs benchmark code in correctness mode only** (compile + one iteration, thresholds disabled). All p50/p95 comparison happens in `perf-nightly.yml`. This resolves the winner plan's own contradiction between "neither adds a merge-door perf lane" and "PR-time keeps the cheap deterministic package benchmarks".

**scoreDelta:** W2-4a Performance/Scalability +0.25, Testing/CI +0.05. W2-4b Reliability/Ops +0.20 (**contingent** on human queue items 8–9).

---

## W2-5 — Deterministic tests

**Findings:** F26.

> ### ⚠ Verdict-forced changes
> - **All three PRs force full CI, and the plan never says so.** `functions/package.json` hits FULL_PATTERNS `(^|/)package\.json$` and is **not** in the exemptions; splitting the mega files requires `OpenBurnBar.xcodeproj/project.pbxproj` (also FULL); a `.csproj` is FULL; and even the cheap ratchet PR falls to `ambiguous` (`budgets/` and `scripts/debt/` are neither lane-owned nor `SAFE_NO_PRODUCT`). The classifier's own comment warns a full wake includes *"the ~90 minute macos-26 libsignal FFI rebuild"*. **Do not** add `functions/package.json` to the exemptions to dodge it — bundle every wave-2 `functions/package.json` edit into the single vitest PR so the cost is paid once.
> - **The attempts change as scoped is a CI no-op that breaks a required check.** CI never uses the script's default of 4: `app-pr-gate.yml:166`, `release.yml:851/:881` and `scripts/test-openburnbar-release-smoke.sh:45` all pin `OPENBURNBAR_APP_TEST_ATTEMPTS=2`. And `scripts/ci/verify-pr-harness-aggregate-gates.test.mjs:486` **asserts** `/OPENBURNBAR_APP_TEST_ATTEMPTS=2/u`, running on the merge door via `fast-feedback.yml:1273` and `workflow-lint.yml:572`. Change only `app-pr-gate.yml` (owned-paths, not full); leave `release.yml` at 2; update the verifier **and** `scripts/ci/macos-rust-static-link-boundary.test.mjs:82` in the same commit.
> - **The rationale is wrong.** `scripts/lib/openburnbar-app-test-classifier.sh` retries **only 11 named infrastructure hang substrings** and fails fast on concrete XCTest failures (*"Real test failures fail fast — no retry storms"*). `attempts>1` never masked a flaky assertion; setting it to 1 removes protection against a documented Xcode runner-launch hang family. State the real trade.
> - **"App PR Gate on main green 2 consecutive runs" is unreachable and proves nothing.** It failed 8 of its last 10 main runs, the newest on a **build/prereq** failure no retry masks, and the gate only runs the **11-class bounded smoke catalog** in `scripts/lib/openburnbar-release-app-test-filters.sh` — and all 11 classes contain **zero** `Task.sleep`. **Replaced:** zero attempt-2+ rescues across 5 consecutive runs read from `.derived-data/test-openburnbar-app-attempts.jsonl`, plus a non-dropping executed-test count.
> - **Vitest 4 removed `test.workspace`** and throws on `vitest.workspace.*` files — `functions` pins **vitest 4.1.8**. Use `test.projects` inside `functions/vitest.config.ts`; sharding stays available via `vitest run --shard`.
> - **`functions npm test` is unobservable** — no workflow runs it. Prove the four real entry points instead: `test:unit` (`fast-feedback.yml:83`), `test:guards` (`:91`), `test:security` (`:1133`, a required context) and `test:firestore-rules` (`deploy-firestore.yml:75`, `deploy-staging.yml:111`, `release.yml:382`). **Exclude `test:firestore-rules` from the vitest workspace entirely** — it is a `firebase emulators:exec` run backing a branch-protection-required context. Five harnesses are invoked as individual steps at `fast-feedback.yml:1447-1463` in the required *Functions (money + compliance harnesses)* job; `security-pr.yml:353` and `computer-use-loopback-test.yml:98` invoke two more. Migrate those workflow steps in the same PR and keep job names byte-identical.
> - **`File.ReadAllText of *.cs in tests = 0` is not greppable.** Only **1** of the 118 `windows/tests` occurrences has a same-line `.cs"` literal — paths are multi-line `Path.Combine`. And the exemplar `WindowsFullGateCompositionTests.cs` also reads `functions/src/callables/windowsRuntimeSafetyConfig.ts`, which a `.cs`-only metric misses and **no Roslyn analyzer can replace**. Use a Roslyn analyzer resolving multi-line `Path.Combine` chains across **all** languages, as a shrink-only ratchet from a measured baseline — not an absolute 0 in one wave. Carve the cross-language cases out separately.
> - **Counts corrected:** `Task.sleep` **261 across 85 files** (not 259/83); `#filePath` test files **87** (29 Core, 24 Daemon, 23 AgentLens, 10 Mobile, 1 UITests) — the plan's "34" is wrong and the report's 86 was right, so it under-scoped by 53 files; TS `readFileSync` in functions test/harness files **43** (not 9); `windows/tests File.ReadAllText` 118 across 41 files (this one holds).
> - **23 Swift test files exceed 2,000 lines, not 4.** Next after the named four: `ProjectionPipelineServiceTests` 4,343, `HermesServiceTests` 3,867, `OpenBurnBarDatabaseMigrationTests` 3,160, `PhoneControlReceiverTests` 3,106, `SwitcherCrossFlowTests` 3,014, `CLIBridgeTests` 2,826, `OpenBurnBarOperatingComposerTests` 2,771, `MercuryRouterTests` 2,691, `OpenBurnBarRunServiceTests` 2,627 … State "split the top 4, baseline the other 19" or raise the fanout.
> - **The test-file size ratchet cannot live in `budgets/swift-file-size-baseline.json`.** `tools/error-debt/count-swift-file-size.py` **excludes** every path part `== "Tests"` or ending in `Tests`, its ROOTS omit `AgentLensTests`/`OpenBurnBarMobileTests`, and `scripts/debt/check-baseline-monotonic.sh` **fails** when a new numeric entry appears in an existing baseline. Create `budgets/swift-test-file-size-baseline.json` as a brand-new file **plus** its `docs/LINT_RATIONALE.md` entry.
> - **Nothing enforces that a new rules test actually runs** — `firestore-rules-tests/package.json`'s `test:ci` is a hand-maintained `&&` chain. Add a gate asserting every `firestore-rules-tests/*.test.js` appears in it, or ~200 new coverage tests can land and never execute.
> - **`.xctestplan` does not exist anywhere** (only vendored swift-testing copies). Use the sanctioned `AgentLensTests/Quarantine` + `QUARANTINE_MANIFEST.md`, policed by `scripts/ci/check-quarantine-freshness.sh` — every quarantined suite lands with Status, Reason, Owner, Revival Criteria and a Target Date inside the wave-3 horizon, plus a tracking issue. Add a shrink-only ratchet on quarantine size.
> - **The split must not create a silent false-green.** `scripts/ci/check-executed-test-count.sh`'s own header warns that a test file missing pbxproj membership *"compiles to nothing and the bundle runs zero tests while the lane stays green"* — so post-split executed count per target must be ≥ pre-split.
> - **`session-log-backup` has 3 documented pre-existing failures** run under `continue-on-error: true`. They stay non-blocking and **must not** be turned green by `.skip`, deletion, assertion loosening, or flipping that flag.
> - **75% of the modified corpus has no pre-merge lane.** Of the 261 sleeps only **58** are pre-merge covered (Daemon/Tests 41 via Daemon PR Gate, Core/Tests 17 via PR Native Gate); 141 are in `AgentLensTests/Active` and ~62 in `OpenBurnBarMobileTests`. **Land the Daemon+Core 58 first as PR 1** (real pre-merge proof), then AgentLens/Mobile as PR 2 with mandatory local evidence per suite.
> - **Clock injection alone is insufficient.** Sampled waits are on FSEvents/DispatchSource (`ClaudeStatuslineWatcherTests` 400 ms–1.2 s), pipe reads (`AsyncPipeLineReaderTests.swift:128`) and latency inside test fakes (`ChatSessionControllerSearchStateTests.swift:480,524`) — none reachable from a Kernel `TestClock`. Either add the production seams (injectable file-watch event source, injectable line-reader signal) or restate as "Daemon+Core sleeps to zero, AgentLens/Mobile shrink-only".
> - **Gate the Swift Testing conversion behind a pilot.** `import Testing` appears in **exactly one file** repo-wide and never in the xcodebuild app-host bundle. One merged pilot suite must prove `check-executed-test-count.sh` still reads a non-zero total from the xcresult **and** that `-only-testing:OpenBurnBarTests/<Suite>` still selects it.
> - **`scripts/ci/check-test-hygiene.mjs` must be registered** as a step in the `Debt budgets` job and in the Makefile `debt-check` target; it does not exist today, so its criterion is otherwise unobservable.
> - **Recommend moving the 87-file `#filePath` walker conversion into its own workstream.** 16 agents / 60 hours is under-scoped against the corrected inventory.

**scoreDelta:** Testing/CI +0.40, Code Quality +0.15.

---

## W2-6 — Signed pet asset pack off the bundle

**Findings:** F05.

> ### ⚠ Verdict-forced changes
> - **The headline compression lever is aimed at 3% of the payload.** Parsing the glTF JSON chunk of all **119** tracked GLBs (304.4 MB) gives: images **9.56 MB = 3.14%** (every file already carries `EXT_texture_webp`; the largest file holds a single 146,696-byte webp = 3.8% of itself), **animation sampler data 153.48 MB = 50.4%**, Draco-compressed mesh payloads 108.68 MB = 35.7%. `extensionsUsed`: `EXT_texture_webp` ×119, `KHR_draco_mesh_compression` ×119. `--texture-compress ktx2` addresses **3.14%**, and KTX2/Basis of an already-webp 146 KB texture routinely **grows**. The 50% that is animation keyframe data is never mentioned. → **Replace with `gltf-transform resample` + `quantize`, and make de-bundling — not re-compression — the primary lever.** Require a scout to report measured before/after bytes per lever on 5 sample GLBs **before** any pipeline code is written.
> - **KTX2 output would not load in the app.** `project.yml:85-87` consumes GLTFKit2 `from: 0.5.15` as a **prebuilt `.binaryTarget`**; `KHR_texture_basisu` decoding lives behind `#ifdef GLTF_BUILD_WITH_KTX2` and upstream requires adding `deps/libktx/ktx.xcframework` to the **framework target**. GitHub code search over the upstream repo returns **0** hits for `weak_import` and **0** for `dlopen` — there is no runtime fallback, and an agent cannot set a compile-time macro inside a prebuilt binary target. If KTX2 is kept it needs its own workstream to fork/vendor GLTFKit2.
> - **`gltf-transform`'s ktx2 path spawns the external KTX-Software `toktx` binary** — not in the repo, no `@gltf-transform/*` entry in any `package.json`, and no CI step installs it.
> - **`--compress meshopt` is a SWAP for the Draco all 119 files already use**, changing the registered `OpenBurnBarDracoDecompressor` runtime path (BUILD-NOTES §2c, DracoSwift pinned `exactVersion 1.5.7`). If kept, it must list the decompressor registration and the `project.yml` dependency in fixTouches plus a load-parity test over every re-encoded asset.
> - **The DMG criterion is unobservable.** `release.yml` is the only workflow with `hdiutil`/`create-dmg`, triggers only on `push: tags: v*` / dispatch-with-tag, has **zero cron**, needs Developer ID + notarytool + `SPARKLE_PRIVATE_KEY` + a signed `domain_core_profile` input, and is 23 failure / 6 success over its last 40 runs. **Replaced by** an `.app` payload budget asserted in `headless-app-build.yml` (push-to-main + cron 47 10 * * *), plus a tracked-bytes budget under `AgentLens/PetCompanion/Resources/**` ≤ 15 MB checked by a pure-bash script in the existing ubuntu `Debt budgets` job.
> - **The offline first-launch criterion names a lane that does not exist.** `git grep OpenBurnBarUITests -- .github/` returns **nothing**; the macOS UI bundle runs only via `scripts/test-openburnbar-ui.sh --local` or a physical Mac mini requiring hand-granted Accessibility + Screen Recording TCC and an auto-logged-in Aqua desktop. Replaced by an XCTest with an injected fake store and `URLProtocol` stubbed to fail all requests.
> - **`actionlint` cannot evaluate trigger reachability.** Replaced by: `verify-pr-secret-boundaries.mjs` **extended** to cover `publish-pet-asset-pack.yml` (it is hardcoded to the QA and Android surfaces today) and passing; a grep asserting no `pull_request`/`pull_request_target` trigger; and `push.paths` covering `scripts/pets/build-asset-pack.mjs` and every module it transitively imports so `verify-workflow-reachability.mjs` stays green.
> - **The product surface is missing from the plan.** `AgentLens/PetCompanion/UI/FormPicker.swift:40-63` builds the **entire pet roster** by enumerating `Bundle.main Models/<id>/petdef.json`. With **110** petdefs and a 2.56 MB mean / 2.67 MB median GLB, a 15 MB starter set leaves ~5–13 pets and the picker **silently loses ~100 pets**. `FormPicker.swift` appears nowhere in the workstream. Required criterion: the picker lists all 110 from the signed manifest with per-pet downloaded/available state and falls back to the bundled starter roster offline.
> - **`docs/LINT_RATIONALE.md` must be in fixTouches** for the bundle-size budget, or the fail-closed "No new suppressions" context rejects it.
> - **The validating lane is red** — the 09-01 scheduled `app-pr-gate` failed all three Mac jobs and `OpenBurnBar Full Harness` failed six consecutive scheduled runs. Because `project.yml` folder-reference changes are validated **post-merge only**, a broken `type: folder` reference would land invisibly. **Precondition: `app-pr-gate` green on the merge-base commit.**
> - **Split into three sequenced units** so the human-gated half cannot block the rest: **W2-6a** (agent-complete: `PetAssetStore` actor + manifest + locator protocol + FormPicker roster + tests against a locally test-signed manifest) · **W2-6b** (agent-complete: shrink `Models/` to the starter set, delete the `Sync Imagine 3D Pets` preBuildScript and `scripts/sync-imagine-pets.sh`, regenerate the pbxproj, rewrite `BUILD-NOTES.md` — which documents the bundled layout at lines 22, 117-140, 364, 440-446 — and `BRIDGE.md:10`, add the ratchet + allowlist entry, wire the size assertion into `headless-app-build.yml`) · **W2-6c** (**human-blocked**: `publish-pet-asset-pack.yml`, the R2 prefix, the production signing key). Only a and b belong in the window.
> - **A dedicated worktree is mandatory:** `OpenBurnBar.xcodeproj/project.pbxproj` is currently ` M` dirty on `feat/living-glass-sweep`, and this workstream regenerates exactly that file.
> - **Remove `.gitattributes` LFS from fixTouches.** Zero workflows pass `lfs: true`; main's `.gitattributes` LFS-tracks only `website/public/downloads/*.dmg|*.zip`. LFS-tracking `.glb` would leave **pointer stubs** in every CI checkout including the release build that stages the `.app`, undetectable because no pre-merge lane launches the app.
> - **The 432 MB history purge is an explicit non-goal** (force-push on a protected branch, `required_linear_history=true`) — human queue item 22.
> - **Restate the score basis:** the delta comes from de-bundling ~290 MB out of the ~448 MB DMG, measurable in `headless-app-build`, **not** from asset re-compression.

**scoreDelta:** Performance/Scalability +0.15, Overall Professionalism +0.15, Launch Readiness +0.10.

---

## W2-7 — Firestore as a generated artifact

**Findings:** F31, F12 (remainder). **Split into W2-7a (IDL + generated rules/indexes/models) and W2-7b (functions repositories + zod contracts), ordered.**

> ### ⚠ Verdict-forced changes
> - **The proposed byte budget is a RELAXATION of a live, incident-derived, PR-blocking ratchet.** `scripts/ci/check-firestore-rules-size.mjs` already fails at **150 KiB (153,600 B)** and warns at 146 KiB **on the compacted form**, and runs in the required *Firestore Security Rules Tests* context. Measured today via the repo's own `compactFirebaseRulesSource`: **145,703 compacted bytes** (222,413 raw) — headroom **7,897 B (5.1%)**, not "57% of 256 KB". The script's header records that on 2026-08-10 staging accepted 155,997 B but **rejected a valid 161,581-byte candidate at release activation**. A 200 KB fail bar green-lights rulesets production **cannot activate**. → **Keep FAIL at 153,600 and WARN at 149,504; they may only ratchet DOWN**, and generated `firestore.rules` must stay ≤ **145,703** compacted bytes.
> - **Add a byte-budget kill switch to the design.** With 5.1% headroom, the generator must emit a **per-domain byte delta report**, and the ADR must prove **net shrink** before any hand-written validator is replaced — the fix shape's central move (replacing terse validators like `validEscrowDeviceUpdate` with generated `hasOnly`/type predicates) is byte-**expanding**. If it cannot come in at or under budget, ship the IDL + indexes + zod + client models **only** and defer rules emission. That fallback is an explicit branch, not a discovered failure.
> - **`deploy-drift hash re-baselined at the trusted staging deploy (human)` is not a doneCriterion** — `check-firestore-deploy-drift.mjs` authenticates via `gcloud auth print-access-token` and runs only inside `deploy-staging-trusted.yml` (`environment: staging`, `id-token: write`), which has **zero runs**. → Ship the generator in **byte-neutral mode** (output byte-identical to committed `firestore.rules` at first landing, proven by a `--check`), so no re-baseline is needed. Any byte-layout change is a separate follow-up parked `OPEN_WITH_NAMED_BLOCKER: awaiting trusted staging deploy`, explicitly **not** counted toward the wave gate.
> - **Do not retire `check-ops-alert-plane-drift`-style checks by replacement.** Same principle: `scripts/ci/check-firestore-deploy-drift.mjs` and `check-firestore-rules-size.mjs` are **retained**; new checks are added beside them.
> - **Name the lane for the coverage work.** ~98 match blocks with positive+negative tests plus an emulator rules-coverage pass cannot go in the fast-door *Firestore Security Rules Tests* job (`security-pr.yml:569`, `timeout-minutes: 15`, context #26 of 60, 30-min component budget; last green run took **2m18s**). Coverage runs **nightly**; the fast door keeps `test:ci` + storage rules + the size guard and must stay under 6 minutes, measured and recorded.
> - **The coverage report has zero prior art** — `git grep -rn "ruleCoverage|coverage.html|emulator/v1"` returns nothing. It is a **build item**: `scripts/ci/rules-coverage-report.mjs` fetching the emulator `:ruleCoverage` JSON and mapping expression hit counts to match blocks with allow/deny polarity. Java 21 and firebase-tools 15.23.0 are present and all 24 suites share `projectId: PROJECT_ID`, so one aggregate run works. Set a first-wave threshold (the 98 blocks reachable from the 15 IDL domains), not "every generated match".
> - **`gen --check` does not exist and the drift set is wrong.** The real entrypoints are `npm --prefix tools/schema-sync run emit` and `./tools/schema-sync/check-drift.sh`, which diffs exactly **three** dirs (`functions/src/types/generated`, `OpenBurnBarFirestoreModels`, `android/.../models/generated`) — rules, indexes, zod and C# are **not** in the drift set and must be added.
> - **C# has no emitter.** `manifest.json` emits typescript/swift/kotlin for all 15 domains; C# exists only as `csharpHandMirror`. A C# emitter writes into `windows/cloudsync/…/Models/`, compiled by PR Windows Gate/Dist/Full — so it is its own deliverable with "the Windows solution builds with the generated records" as a criterion, or C# stays a hand mirror this wave.
> - **The hand-mirror burn-down understates the work and fights a fail-closed ratchet:** 22 mirror entries carry **5 `knownDrift` tokens plus 17 `tspOnlyModels`**, and `manifest.json` fails closed **both** on new drift **and** on a stale grandfather, and explicitly forbids converging `legacy.ts` inside that gate. Sequence one domain per commit and name which of the 15 are in scope.
> - **The TypeSpec canon is NOT an emitter.** `tools/schema-sync/emit/generate.mjs` is 2,141 lines of hand-written TS/Swift/Kotlin **string literals** in a `domains` registry, commented *"kept in sync with typespec/domains/*.tsp"*; `check-tsp-canon.mjs` compiles `main.tsp` and asserts parity, but **nothing is generated from the `.tsp`**. Adding `@collection`/`@ownerScoped`/`@serverOnly`/`@immutable`/`@query` plus six emitters is **authoring a decorator library and a codegen backend from scratch**, not extending one.
> - **`functions/src/domains` colocation collides with an exact-cap ratchet.** `budgets/hand-maintained-ts-baseline.json` pins `exportedInterfaces` LOC at exactly **2706** for `functions/src`, **excluding** `types/generated/**` and `security/**`, enforced by `check-legacy-budget.mjs` on the fast door. Emit schemas into `functions/src/types/generated/**`, or the wave gate's "every count ≤ wave-1 baseline" fails.
> - **`index.ts` becomes `--check` only in wave 2**, not generated: it is 269 lines / 213 re-exports and is uncommitted-dirty on a branch 42 commits ahead. Emit only after the sweep lands.
> - **Index pruning leaves agent scope.** `firestore.indexes.json` reaches production only via the human-approved deploy lane and deletion is not revertible without a rebuild window; queries also originate in `DownloadSyncService.swift`, `FirestoreRepository.swift/.kt` and the Windows REST gateway. Replace with a **report-only** provenance check ("every one of the 95 composite indexes maps to a declared `@query`; unmapped ones are listed, not deleted") — and the generated file must be a strict **superset** of the 95 on main, with `check-collection-group-coverage.mjs` and `collectionGroupIndexCoverage.test.ts` passing.
> - **The ESLint `firebase-admin/firestore` boundary lands in the SAME PR as the last migrated importer**, never before, and **no `eslint-disable … -- description` may satisfy it** — the real scope is **112** non-test importers under `functions/src`, not 67 callables, and `check-no-suppressions.sh` accepts a native ESLint description, so 112 described disables would pass CI while defeating the rule.
> - **The 24 rules suites carry a documented known-red.** `security-pr.yml` runs `test:session-log-backup` with `continue-on-error: true` and a comment naming **3 pre-existing failures** (Pro-entitlement manifest accept/refresh/overwrite). doneCriteria must say whether those 3 are in scope or the carve-out is preserved — they may **not** be made green by skip/deletion/loosening.
> - **Serialize W2-7a and W2-7b** rather than running them concurrently: both must clear 10 required contexts on a strict/up-to-date branch, and every merge dismisses the other's approval.

**scoreDelta:** Architecture +0.30, Security +0.15, Code Quality +0.15.


---

# WAVE 3 — Structural architecture and bus factor (2026-09-22 → 10-27)

## Wave-3 exit gate — corrected

1. **Pricing runs `rust` on internal/beta with the protected attestation prepared.** *(The "zero shadow mismatches over 7 days of candidate-bound V3 evidence" clause is **deleted** — see W3-1.)*
2. `budgets/singleton-baseline` and the new Views `.shared` budget ratcheted down ≥30% **measured repo-wide** (AgentLens + OpenBurnBarCore/Sources + OpenBurnBarDaemon/Sources), with `app-pr-gate` green.
3. `contracts/burnbar-rpc.schema.json` generated with **185/185** methods typed (0 placeholder params) and the zod/TS client generated from it; canon `--check` green. *(The plan said 216 — see W3-3.)*
4. Total Swift LOC of **all** mission files under `AgentLens/Services/CloudSync` (glob `*Mission*`) down ≥40%, **and** `grep -rn "Process()" AgentLens/Services/CloudSync` down from 7 to 0, **and** the splitbrain script widened from basename-prefix to whole-directory matching.
5. `docs/runbooks/HANDOVER.md` + `scripts/ops/verify-access-inventory.sh --schema` exit 0; the monthly bus-factor workflow runs and reports honestly. *(Green requires human queue item 23 — this half is **excluded** from the agent gate.)*

---

## W3-1 — Rust domain core as the single source of truth (pricing first)

**Findings:** F10.

> ### ⚠ Verdict-forced changes
> - **"UniFFI bindings replace the hand-maintained C ABI" is a false premise.** There is no hand-maintained C ABI: `domain-ffi/Cargo.toml` already pins `uniffi = "=0.28.3"`, `lib.rs` already has **61** `#[uniffi::export]` sites plus `Record`/`Enum`/`Error` derives, `union-abi-manifest.json`'s symbol list is literally keyed **`uniffiExports`** and already contains `calculate_token_cost_nano_usd`, and the Swift (4,784 LOC), Kotlin and C# bindings are all UniFFI output. The only real work is a **0.28.3 → 0.29 bump**, which the plan never scoped.
> - **A UniFFI major bump is its own strictly-serial milestone (W3-1a)**, because it changes the FFI scaffolding checksum and therefore `abiVersion`, hard-coded as `3` in ~19 places (`CloudVaultDomainCoreAdapter.swift:760`, `PensieveVectorCloak.swift:213/226/237/252`, `CloudVaultDomainCore.kt:88`, `CloudVaultDocumentRewrapDomainCore.kt:45`, `CloudVaultSearchDomainCore.kt:44`, `HermesDomainCoreAdapter.kt:53`, plus `NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION` in `apps/console/lib/domainCoreBuildProfile.ts`). It also requires repinning `uniffi-bindgen-cs` from `v0.9.2+v0.28.3` to a `v*+v0.29.x` tag in **both** `csharp-binding-drift.yml` and `domain-core.yml` — and that upstream tag must exist first. **Weakening the drift gate to accommodate 0.29 is forbidden.**
> - **The "7 days of V3 evidence" gate is invented and unsatisfiable.** `docs/runbooks/shared-rust-promotion-evidence.md:3-6` says verbatim that runtime telemetry *"is not a gate and no duration, daily continuity, user count, or sample count is required"*, `:232-233` says the evaluator *"intentionally has no minimum duration or sample target and always reports `ready: false`"* (exit 2, `authority: diagnostic-only`), and `docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md:266-268` says V3 surfaces *"must not be cited as promotion authority regardless of sample volume or collection duration"*. **No 7-day requirement exists anywhere.** Either cite the repo's actual authority (the protected deterministic attestation) or amend the runbook first as a separately-reviewed governance change.
> - **The gate is self-contradictory.** `DomainCorePricingAdapter.swift:52` is `let legacyMeasurement = mode == .shadow ? measure(legacy) : nil`, and `functions/src/domainCorePricing.ts:143/:211` return the rust value directly in `rust` mode — so flipping to `rust` **terminates** shadow measurement. Restate as an ordered sequence: (i) shadow on internal/beta while evidence accrues → (ii) attestation → (iii) flip.
> - **The real blocker is undiagnosed and it is not missing adapters.** All 11 rows are `activation_annulled` and `pricing.token_cost` is at `authorityGeneration: 3`. `config/domain-core-legacy-deletion-receipts/pricing.token_cost/3/annulment.json` gives the cause verbatim: `"reason": "release_train_advanced_before_stable_receipt"`, `"replacementCandidateRequired": true`, approved by @Ajnunezg 2026-08-04. Main advanced past candidate `99ba1f66` before the stable receipt landed. **Add a mandatory blocking milestone W3-1-M0 "root-cause the annulment"** with a written fix for the candidate→activation→stable-release race and a test in `tests/test_domain_core_legacy_deletion_gate.py` proving a fourth candidate cannot be annulled by main advancing. **No new candidate is cut until M0 lands.** Otherwise 320 agent-hours buy generation 4 of the same annulment. Open **draft PR #2430** already sits on this theme.
> - **The fanout targets consumers the gate does not govern and omits one it does.** `config/domain-core-legacy-deletion.json`'s `pricing.token_cost` row declares exactly three targets, and `verify-domain-core-legacy-deletion.py:195-215` sets `ROW_RELEASE_CONSUMERS["pricing.token_cost"] = {apple, linux, functions}`. **Android is in neither pricing nor quota** (quota = `{apple, linux, windows}`), yet the plan spends its headline capacity on Android adapters and 11 Windows call sites and **never mentions linux**, which has its own signer workflow. → Delete Android/Windows pricing+quota from this workstream; **add linux**. Restate doneCriteria's "all consumers" as **apple, linux, functions** (the canonical allowlist is apple/windows/android/console/functions/local-mcp/remote-mcp, so "all" as written demands console/local-mcp/remote-mcp adapters that appear nowhere).
> - **Slow work would land on the fast door.** `Rust (fmt + clippy + cargo-deny)` **is** a required fast context (15-min job budget, already stretched from 8) running `cargo clippy --workspace --all-targets -D warnings` and sparse-checking-out `tests/fixtures/domain-core` because the crate `include_str!`s it. Growing the corpus, compiling a `legacy-oracle` proptest feature, and adding cargo-fuzz targets all land inside `--all-targets`. → **corpus ≤ 250 KB total; the job stays under 12 minutes measured; the proptest oracle is gated by `required-features` so the fast clippy job does not compile it.**
> - **Drop cargo-fuzz, or state its prerequisites.** Zero references in the tree; `rust-toolchain.toml` pins **stable 1.96.0** (cargo-fuzz needs nightly), the workspace sets `unsafe_code = "deny"`, and both profiles set `panic = "abort"`. Bounded fuzzing **already exists** as `domain-ffi/tests/fuzz_smoke.rs`, run by `domain-core.yml:198` — extend that. If kept, fuzz must be a **workspace-excluded** crate never reachable from `--all-targets`.
> - **Drop cargo-semver-checks or replace it.** Zero references; it reads rustdoc JSON of the **Rust** API (not the FFI surface) and needs a nightly rustdoc the pinned toolchain lacks. The guarantee consumers depend on is already enforced by `union-abi-manifest.json` via `tests/test_domain_core_union_gate.py` and `domain-core-union-gate.py --check-abi` (`domain-core.yml:216-220`).
> - **Drop cargo-dist.** The workspace is `publish = false`, AGPL-3.0-only, and its outputs are a staticlib/cdylib/xcframework/AAR/wasm consumed inside app builds. Provenance is already wired: `actions/attest-build-provenance` at `domain-core-promotion-proof.yml:175`, `domain-core-promotion-observation.yml:206`, `domain-core-post-deletion-completion.yml:134`.
> - **No new suppressions:** the domain-core workspace sets `unwrap_used`/`expect_used`/`panic = deny`, so proptest and fuzz harnesses must be written without them; `#[allow(...)]` is a flagged token under the fail-closed gate.
> - **The roadmap "landing state" cannot be regenerated from build profiles.** No generator exists (`git grep -l SHARED_RUST_DOMAIN_CORE_ROADMAP` across `scripts/`, `.github/`, `tests/` returns nothing), and the section is **PR/branch ancestry** (#1590, #1591, #1592, #1722, #1594, #1602, #1615 …) that `config/domain-core-build-profiles.json` cannot produce — regenerating would **delete information**. → `scripts/ci/render-domain-core-landing-state.mjs` emits **only** the per-domain mode-by-profile table into a delimited `<!-- generated:landing-state -->` block; the ancestry prose stays hand-written above it, with a `--check` drift job.
> - **Fanout 14 → ≤6, serial crate lane + parallel consumer lane.** One `sourceSha256` (`1c4bc3ef9f…`) is committed simultaneously in `union-abi-manifest.json` and `functions/vendor/openburnbar/domain-core-wasm/openburnbar-domain-core-source.sha256`; the wasm binary itself is committed and checked by `domain-core.yml:527`; the Swift/Kotlin/C# bindings are all committed generated files. Any two agents touching `crates/openburnbar-domain-core` conflict on those artifacts, and `strict=true` + ALLGREEN + `dismiss_stale_reviews` forces a single rebase chain anyway.
> - **Add the missing consumers to fixTouches:** `apps/console/lib/domainCoreBuildProfile.ts` + its test, `apps/console/vendor/openburnbar-domain-core-wasm/` (a **second** committed wasm copy, KAT'd at `domain-core.yml:549-552`), `.github/workflows/csharp-binding-drift.yml`, and the three `scripts/build-domain-core-*.sh`.
> - **Correct the scope claims:** `functions/src/domainCorePricing.ts` already exists at **478 LOC** with legacy/shadow/rust modes and V3 sampling — not new work. Windows already runs the Rust core for quota/CloudVault. Android already ships UniFFI Kotlin bindings via a JNA-loaded AAR, so *"native adapter build steps lengthen Android CI"* is **not** a real risk; the real risk is that all binding artifacts are **fingerprint-locked** to the crate source, so every crate PR must regenerate and commit all of them in the same PR.
> - **Extend the coverage policy explicitly:** `config/domain-core-shadow-diagnostic-policy.json` currently declares pricing V3 producers as *"token cost on Apple and Functions, plus legacy Kimi in Functions"*. Adding producers requires editing it.
> - **Corpus path is versioned per domain:** `tests/fixtures/domain-core/pricing/**v2**` (quota/cloudvault/hermes are v1). The plan's `.../v1` would be a stale duplicate.
> - **No W3-1 change may set or rely on `MACOS_GATE_POOL = fleet | paid`** — both are forbidden for the public repo.
> - **Correct `humanAction`:** the required human steps are (a) approve the protected attestation via `domain-core-promotion-proof.yml`, (b) cut signed releases for **apple, linux and functions** to produce schema-v2 release predicates, (c) sign the `deletionReview` receipt. Drop "Play internal track" and iOS App Store — they belong to the cloudvault/hermes rows.
> - **Grafted (judges ×3, plan-2 W0-4):** a fast-door **pricing readiness** stream in wave 1 — a test-only `legacy-oracle` cargo feature + proptest differential suite at the documented 0.5-nano tolerance over the shared corpus, executed by the Swift and Functions consumers with a fixture-count test — so F10's evidence collection is ready the moment Alberto cuts signed builds.

**scoreDelta:** Architecture +0.50, Code Quality +0.25, Series A Diligence +0.25.

---

## W3-2 — Phased composition root and SPM feature packages

**Findings:** F19, F20 (remainder).

> ### ⚠ Verdict-forced changes
> - **It directs an agent into the forbidden dirty tree.** "MacKeepAwakeController singleton removed on whichever branch carries it" — `git status --porcelain` returns `?? AgentLens/Services/KeepAwake/` (**untracked**) and `git ls-tree -r origin/main` on that path is **empty**. It exists in exactly one place: the uncommitted working tree of `feat/living-glass-sweep`. The task is impossible or a direct violation. **Deleted**, with an explicit non-goal: the singleton-baseline failure observed there is branch-local; on `origin/main` the gate is green (`staticSharedSingletons=55`, baseline 55, verified by running the script against a main snapshot).
> - **"Local xcodebuild + relevant AgentLensTests log attached" per PR, plus "2 local xcodebuild verifiers (mandatory per PR)", puts a 90-minute-class build on the merge clock** — the lanes rule says verbatim *"Do not run the full Mac app build as a merge prerequisite"*, `app-pr-gate.yml:62` budgets 90 min for the AgentLens prerequisites job and `:211` 120 min for mobile, and `scripts/test-openburnbar-app.sh` retries with backoff. **Replaced by ONE shared integration verifier running xcodebuild once per landed batch**, plus the fast door (Fast Feedback Gate, PR Native Gate, XcodeGen drift, Structural Debt Ratchets, No new suppressions) per PR. Fanout 12 → ≤5.
> - **Make the Swift half provable on the door, or stop claiming it is.** Move the DI/assembler types into `OpenBurnBarCore` (which already links GRDB-SQLCipher) so `swift test` in PR Native Gate is real merge-door proof. The `@main` App cannot move, so the assembler must be a package type the App merely calls. If it stays in `AgentLens/`, doneCriteria must read: *"PR-time proof is compile + XcodeGen drift only; behavioural proof is the next `app-pr-gate` push-to-main run, whose id the wave gate records."*
> - **"DI graph validation unit test on the fast door" is unmeetable as written** — the only pre-merge Swift compile is `swiftpm-native` (macos-26, 40 min) over Core + Daemon, and `OpenBurnBarRuntimeContext` lives at `AgentLens/Services/OpenBurnBarStartupRecovery.swift`, in neither package.
> - **The singleton criterion is relocation-proof only if the scan root is widened.** `scripts/debt/check-singleton-budget.sh` hardcodes `agentlens_root = repo_root / "AgentLens"`, so a `git mv` into a package lowers the count **without retiring one singleton** — satisfying the ≥30% wave gate with zero architectural change. **Widening the scan root is the first PR of the workstream**, then re-baseline and ratchet from there.
> - **"core-target-membership baseline never up" is unsatisfiable alongside SPM carving.** `budgets/core-target-membership-baseline.json` gives `OpenBurnBarUI` a **planned ceiling of 160 files / 40,000 lines** and it is already at **150 / 36,415** (3,585 lines of headroom), while `AgentLens/Views` alone is **421 files / 150,654 lines** and AgentLens totals 340,195. Carving needs new siblings, which needs edits to the hardcoded **26-entry `siblingTargets` array** plus new `PLANNED_CEILINGS`. **Worse: a target directory absent from `siblingTargets` is silently ungated** (`ceilings()` iterates only that array), so the criterion can read green over an unbounded new package. → Each new target is added to `siblingTargets` with a ceiling **in the same PR**, plus a meta-check asserting every `OpenBurnBarCore/Sources/` directory with `.swift` files appears in that array; and the criterion becomes "the OpenBurnBarCore **main** target never rises (11 files / 127 LOC today)".
> - **The feature-package names collide with assert-zero pure siblings.** `scripts/debt/check-core-ui-purity-budget.sh` lists `OpenBurnBarMedia` and `OpenBurnBarComputerUseCore` as **zero SwiftUI/AppKit imports** — moving SwiftUI feature code there is an instant hard fail. Reconcile against the End-state target map in `docs/CORE_DECOMPOSITION_PROGRAM.md` (62 KB, marked *"PROGRAM COMPLETE — Core floored to shims-only"*) **before** any code moves, and adopt its packet-card + integrator-ratchet model rather than inventing a parallel one.
> - **The two new budgets trip the fail-closed meta-gate.** `budgets/` holds 19 files; there is no Views `.shared` budget and no type-size budget; `check-no-suppressions.sh:340` flags any tracked `budgets/*.json` absent from the single `docs/LINT_RATIONALE.md` allowlist block (18 of 19 are listed today; `budgets/rpc-methods-baseline.json` is the sole miss and is currently **untracked** — committing it turns the required context red).
> - **Every carve PR must report the `swiftpm-native` wall clock** and must not push it past 30 min (fast component budget) or 40 min (job timeout). Moving 150 K lines of Views into the package graph without this reddens the fast door **for every PR in the repo**.
> - **Split every carve into two PRs:** (1) a **pure `git mv`** PR — it earns the `refactor:pure-move` safe harbor in `scripts/diff-coverage.sh` (the `--no-renames` move pool at `:1094-1105`) and passes the 80% packages-scope diff-coverage gate; (2) a behaviour PR with `swift test` coverage ≥80% on changed package lines. A mixed move+rewrite PR fails `Enforce package diff coverage` (`DIFF_COVERAGE_SCOPE=packages`, `COVERAGE_THRESHOLD` default 80).
> - **XcodeGen is pinned to 2.45.4** (`pr-native-fast.yml:243-244`) while the local toolchain is 2.46.0 — regenerating locally with 2.46.0 reddens the drift job.
> - **F20's `swift run type-budget` adds a new SPM dependency:** swift-syntax is a dependency of **no** `Package.swift` today (only transitive via swift-testing), so it brings Dependency Review, Unused Dependencies and `swiftpm-lock-refresh` plus a cold compile inside the 15-minute Debt budgets job. Prefer a bash/python per-type counter matching the existing `check-*-budget.sh` idiom, or budget a cached SwiftPM step and **prove** the job stays under 15 minutes.
> - **Hard constraints so `--strict` does not go red:** every extracted file **< 2,000 lines** (`budgets/swift-file-size-baseline.json` is `{target 2000, total 0, files []}`), and SwiftLint `--strict` runs **first** in the native job with `file_length` 6130/6200 and `type_body_length` 4700/4800. Do not lower `type_body_length` until the decomposition lands; split the four files above 5,950 first.
> - **PR shape.** "2–3 leaf services per PR" against ~37 post-construction optionals implies 13–19 slice PRs plus 5 god-type PRs plus 6 package PRs = 24–30 PRs, which CHEAP_FAST bans. **One themed PR per runtime phase** (all Phase-1 services, then Phase-2, then Phase-3) — at most three W3-2 PRs total, one in flight at a time.
> - **Explicit branch policy** (the workstream had none): every PR from a fresh worktree off `origin/main`; the `/Volumes/DevSSD/Developer/BurnBar` checkout is read-only for this workstream.
> - **New collaborator basenames must clear `scripts/ci/check-twin-basenames.sh`** (a categorized allowlist entry in `docs/LINT_RATIONALE.md`).

**scoreDelta:** Architecture +0.40, Code Quality +0.20.

---

## W3-3 — Typed RPC IDL; mission execution into the daemon

**Findings:** F29, F30. **Split: W3-3a (F29 typed IDL) / W3-3b (F30 mission consolidation, `needsHuman: true`).**

> ### ⚠ Verdict-forced changes
> - **The headline number is wrong, so the gate is unsatisfiable.** `BurnBarRPCMethod` (`BurnBarRPCContracts.swift:12-226`) has **185** cases, not 216: `sed -n '12,226p' | grep -cE '^\s+case [a-zA-Z0-9_]+ = "'` = 185. The 216 is the **file-wide** count of `case X = "…"` across all string enums (`BurnBarLinuxAuthState`, `BurnBarMembershipState`, `DaemonMediaSessionPhase`, …). The canon has exactly 185 entries and `comm -13` of canon vs method ids is **empty** — nothing is missing. Real debt: **120** entries with `params: "BurnBarRPCRequestEnvelopeWithParams<Codable request>"`, 120 with `result: "Codable …"`, and **15 legitimately bare** `BurnBarRPCRequestEnvelope` (parameterless, not placeholders). Fix the report at lines 11/126/148/199 too, so the number stops propagating.
> - **Two of three doneCriteria run on no pull_request lane.** `OpenBurnBarDaemonManager` and the M1 characterization tests are AgentLens app-target code; `app-pr-gate.yml` is push/schedule/dispatch (its own header: *"intentionally not a pull_request wall"*) and `openburnbar-pr-harness.yml` is cron/dispatch only. Neither context is in either gate config. Worse, **F30's 4,323-line GUI rewrite gets zero pre-merge compile signal** — `swiftlint --strict` is the only thing that reads `AgentLens/` on a PR. → **Move `BurnBarProtocolVersion.negotiate` / the health verdict into `OpenBurnBarKernel`** as a pure `func healthVerdict(daemonProtocolVersion:supportedMethodSet:) -> Verdict` with tests in Core, so the criterion becomes merge-door provable; leave `OpenBurnBarDaemonManager` a thin caller.
> - **`json-schema-diff` on the fast door would need a Swift toolchain there.** `fast-feedback.yml` is 100% `ubuntu-latest`, every job `timeout-minutes: 15`, **zero** Swift setup, and today's check at `:1555` is a pure `node tools/ipc/generate-burnbarrpc-canon.mjs --check` regex scan. → `contracts/burnbar-rpc.schema.json` is a **checked-in artifact**; the fast door runs only a **pure-node** freshness + breaking-change check; the Swift **exporter** runs on the existing macos-26 job or nightly.
> - **`@RPCMethod` may only be introduced under a measured budget.** Zero `Package.swift` depends on swift-syntax today; `pr-native-fast.yml`'s SwiftPM job (macos-26, timeout 40) is already over the 30-min component budget. Criterion: cold `swift build` for Core+Daemon stays **under 25 minutes**, measured and pasted in the PR; otherwise generate descriptors with a non-macro generator emitting checked-in Swift.
> - **The app-brokered signing RPC does not fit the transport.** Every canon entry is `owner: "OpenBurnBarDaemon"`; `BurnBarUnixDomainSocket.readRequest` reads to a trailing `0x0A` under `maxRequestBytes` and the handler does exactly one read → respond → return. Single-shot, newline-delimited, **no multiplexing, no daemon→client push, no subscribe/stream method in the canon**. → Use **app-polled brokering**: `client.attestation.pending` and `client.attestation.submit` on the existing envelope. Daemon-initiated calls need a transport ADR and an app-side listener with peer code-signature verification — its own milestone.
> - **The framing change is a flag day for installed clients.** Length-prefixed frames break the installed LaunchAgent daemon (`~/Library/LaunchAgents`), the CLI, the Tauri desktop and the extension, and **no doneCriterion mentioned backward compatibility**. Split it out with: *"the daemon accepts BOTH newline-terminated and length-prefixed frames for one release; a daemon test replays a newline-framed request from the current `OpenBurnBarCLISocketClient` and gets a valid response."*
> - **"Mirror-based schema encoder walking `Encodable`" is not implementable** — neither `Mirror` nor `Encodable` can enumerate coding keys from a **metatype**; both need an instance. Use per-method **golden fixture values** round-tripped through `JSONEncoder`, with the JSON Schema authored alongside and verified against the fixture by a Core test. *(Grafted from plan-2, per judges ×3: a compile-time **exhaustiveness test over all 185 cases** plus golden request/response wire fixtures replayed through the Swift decoder, keeping the canon generator byte-identical for already-typed methods.)*
> - **Golden fixtures are mandatory, not optional.** `scripts/diff-coverage.sh` defaults to `COVERAGE_THRESHOLD=80` and `swiftpm-native` enforces it with `DIFF_COVERAGE_SCOPE=packages` on every PR; 120 newly typed structs in Core are changed package source and fail without instantiating fixtures.
> - **Three canon consumers, not two.** Add `docs/linux-port/generated/burnbar-rpc-ipc-canon.linux.json`; `--check` runs in **three** places (`fast-feedback.yml:1555`, `linux-pr-gate.yml:269` — path-filtered but the filter includes `OpenBurnBarCore/**` and `OpenBurnBarDaemon/**`, so every IDL PR triggers it — and `Makefile:376`).
> - **New deps and a new context:** `json-schema-diff` appears nowhere in the tree and `zod` is not in `extensions/openburnbar/package.json`. Wire the schema gate as a **step inside the existing job** that already hosts `check-mission-splitbrain-budget.sh` (`:1526`) and the canon `--check` (`:1555`) — **no new required context**, no edit to `governance/burnbar-ci-gate*.json`.
> - **The Tauri deliverable conflates two artifacts.** `apps/linux-desktop/src/tauriBridgeTypes.ts` (1,843 lines) is **TypeScript**; the Rust bridge is pass-through (`daemon_data_commands.rs`: 110 `serde_json::Value` uses, **zero** `#[derive(… Deserialize)]`). Generating serde types is a **new typed-decode coupling**, not a replacement. Scope to generating the TS file and keeping Rust pass-through, or make typed serde its own milestone.
> - **The splitbrain metric is gameable and the script's own header proves it.** `check-mission-splitbrain-budget.sh` matches only basenames starting `CLIAgentMission` under `AgentLens/Services/CloudSync`; its header records **PR #2362 renaming files out of the prefix, which the gate reported as a 1,387-line IMPROVEMENT while the same code grew to 2,076 lines**. Today `MissionRemoteAuthorizationEnforcement.swift` (254) + `MissionRemoteAuthorizationShadow.swift` (691) = **945 lines of mission-authority code in the same directory, invisible to the ratchet**, plus `MacWandMissionDispatcher.swift`. → Widen the script to whole-directory `*Mission*` matching **in the same PR**, add the `Process()` 7→0 criterion, and add an anti-evasion clause: no line reduction may be achieved by renaming or relocating; every PR touching the baseline shows `git log --diff-filter=D` deletions or net-negative daemon-side moves.
> - **A third mission plane is missing entirely.** `OpenBurnBarMobile/Services/CLIAgentMission*.swift` is **2,045 lines**, outside the ratchet's directory and absent from both findings' fixTouches — *"GUI becomes a projection"* is false while it stands. Add it, or declare it explicitly out of scope with a named follow-up.
> - **`ComputerUseE2E` has no consumer** (same finding as W2-2): only the two `print(` producers exist. Leave those sites byte-identical; do not require a green `computer-use-loopback-test.yml` (two macos-26 jobs building libsignal FFI + Playwright `--runs 5`) as PR evidence, and note its `pull_request` `paths:` do not even include `AgentLens/**`.
> - **W3-3b hits two human gates, not one.** Beyond the Secure-Enclave/provisioning question, `functions/src/callables/cliAgentMissions.ts:52/:113` run under `onCallProduction(..., { enforceAppCheck: getConfig().enforceAppCheck })` and attestation is App Attest **bound to the app bundle**. A separately-signed LaunchAgent daemon **cannot mint an App Check token**; registering it is a Firebase-console change. **Until Alberto rules, the daemon must not call the callables directly.** Any `firestore.rules` or `cliAgentMissions.ts` change ships as its own PR parked pending his deploy go.
> - **W3-3b needs a pre-merge AgentLens compile gate first (milestone M0)**, or it must stay a spike-lane draft. A 4,323-line rewrite would otherwise merge type-unchecked and surface in the 09:17 UTC nightly.
> - **Visible-terminal execution needs `#if os(macOS)` fences** — `CLIAgentMissionRequestListener+VisibleTerminalExecution.swift` shells `open -a Terminal` and the cluster imports FirebaseFirestore, while `OpenBurnBarDaemon` must keep building on the Linux SwiftPM lane. Decide explicitly whether it moves at all (a LaunchAgent can `open -a`; a LaunchDaemon cannot).
> - **Deferred generated-artifact churn:** `functions/src/index.ts` becomes `--check` only, not generated, in this wave.

**scoreDelta:** Architecture +0.40, Security +0.15, Reliability/Ops +0.05.

---

## W3-4 — Bus-factor kit, daemon launchd supervision, history-rewrite packet

**Findings:** F35, F08, F34 (remainder). **Split into three.**

> ### ⚠ Verdict-forced changes
> - **The "the plist path is only covered by the nightly Mac target" premise is FALSE, and the change as written turns a MERGE-DOOR test red.** `OpenBurnBarDaemon/Tests/OpenBurnBarRemoteAccessAgentCoreTests/PrivilegedInputKillSwitchWatchdogPlistTests.swift:24` asserts `XCTAssertEqual(plist?["KeepAlive"] as? Bool, true)` and `pr-native-fast.yml:189` runs `swift test` on OpenBurnBarDaemon for **every PR** (`AgentLens/` and `AgentLensTests/` are in its native path filter). The same assertion exists at `AgentLensTests/Active/ComputerUse/RemoteUnlockExecutionLaunchAgentTests.swift:26`. The plan did not know these tests exist, so the implementer's cheapest path is to **loosen `as? Bool`** — a suppressed security assertion. **Explicit anti-fake-green clause:** those tests may be rewritten only to assert the **new** dictionary shape field-by-field, never loosened to `as? Any`, never deleted, never quarantined, and no `swiftlint:disable` / `budgets/*.json` / baseline entry may be added to land it.
> - **The uniform `KeepAlive` dict is a SECURITY REGRESSION on one of the three plists.** `OpenBurnBarDaemon/Resources/PrivilegedInputKillSwitch/com.openburnbar.privileged-input-killswitch-watchdog.plist` is the **root LaunchDaemon** for the privileged-input kill switch (release-signing-verified via `scripts/ci/verify-daemon-release-signing.sh`, called at `release.yml:1947`). Today `KeepAlive: true` restarts it unconditionally; `SuccessfulExit:false` means a clean `exit(0)` **permanently stops restarting it** and `ThrottleInterval` opens a respawn gap. **Exclude it: it keeps `KeepAlive: true`.** `scripts/macmini/com.openburnbar.uitest-runner.plist` installs on a physical Mac mini no agent can reach — also excluded.
> - **The golden test must run on the merge door by moving the code, not the door.** Extract a `LaunchAgentPlist` Codable/dictionary-builder and a `LaunchdExitStatus` parser into `OpenBurnBarCore`, with tests in `OpenBurnBarCore/Tests`, so `PR Native Fast Gate` proves them; `OpenBurnBarDaemonManager+Lifecycle.swift:478-487` becomes a caller.
> - **Enumerate every `KeepAlive` producer** rather than leaving it implicit: `RemoteUnlockVirtualHIDBridgeInstaller.swift:242` and `:260`, `scripts/install-virtual-hid-bridge.sh:50`, `scripts/install-remote-access-agent.sh:47`, `scripts/macmini/com.openburnbar.uitest-runner.plist:19`. State which convert now and which are deferred — a typed builder covering one of six producers is not the invariant the criterion implies.
> - **An ADR is required.** `docs/AI_INBOX_PLAN.md:34,48`, `docs/AI_INBOX.md:115` and `BurnBarAIInboxService.swift:10` all justify the in-daemon sleep loop by *"the daemon is always-on KeepAlive"*. Changing that contract requires updating those three docs and filing an ADR.
> - **"Attached to the human queue" is not observable.** Replaced by a named artifact: `docs/decisions/2026-XX-XX-history-rewrite-packet.md` (or a `packet.json` with `blobList[]`, `totalBytes`, `pinnedShaConsumers[]`, `mirrorSteps[]`, `rollbackSteps[]` validated by a CI check), linked from `docs/audits/INDEX.md`.
> - **The packet MUST be produced in a throwaway mirror.** `git-filter-repo --help`: *"It refuses to do any rewriting unless either run from a clean fresh clone, or --force was given."* An agent reaching for `--force --dry-run` inside the working repo (9.9 GB `.git`, 210 dirty paths) can **destroy it**. Mandate `git clone --mirror … $TMPDIR/burnbar-rewrite.git`; **no `filter-repo` invocation may name the live checkout as its cwd.** (948 GiB free on the volume, so the mirror is viable.)
> - **The access-inventory script must be split so its success is observable without a second human:** `--schema` validates the document is well-formed (the agent-verifiable criterion, exit 0); `--live` performs credentialed probes and is expected to fail until Alberto provisions the backup identity. *"Runs (fails honestly)"* proves nothing and cannot distinguish a correct script from a broken one.
> - **The monthly bus-factor workflow must be `GITHUB_TOKEN`-only and must NOT use the `production` environment** — that environment carries a required reviewer plus a wait timer, and the scheduled `ops-plane-verify` run has been `pending` **>28 hours**. Scope it to `/collaborators` + `/branches/main/protection` with an explicit `permissions:` block (repo `default_workflow_permissions` is `read`). GCP/Firebase/ASC probes stay in `--live`, run by Alberto.
> - **It must not sit permanently red.** Either `continue-on-error: true` with a single `bus-factor`-labelled tracking issue, or its own lane key **excluded** from `codex-nightly-ci-repair.yml`'s daily 12:45Z red-lane sweep (which *"sweeps every red lane at once"*) — otherwise it generates daily repair PRs against a condition no agent can fix, and pages on `SOLO_OPERATOR_POLICY.md`'s Monday triage.
> - **Drop the CODEOWNERS deliverable — it is a no-op.** `.github/CODEOWNERS` already lists `@Ajnunezg @emilio3435` on all 86 lines including every ring-0 path; the missing control is the human-only `require_code_owner_reviews=true` flip. If any line is touched, re-run `bash scripts/ci/verify-codeowners-security-trees.sh` — it enforces `EXPECTED_FINAL_RULES` ("keep security-sensitive rules last") and any rule appended after the security block flips the final match and fails the gate.
> - **A mandatory first deliverable:** reconcile `docs/SOLO_OPERATOR_POLICY.md` with live state. It asserts protection *"requires one code-owner approval … requires approval of the latest push, and has zero standing PR-review bypass allowances"*, while `node scripts/ops/check-branch-protection-drift.mjs` exits **1** today with `[CRITICAL] enforceAdmins desired=true live=false` and `[CRITICAL] bypass actors ADDED live (must be zero): ["User:125839313:always"]`. Agents edit the **doc** to describe live state and file the flip as human queue item 24; **agents may NOT edit `governance/branch-protection.main.json` down to match live** — that is gaming the gate.
> - **F34 needs real deliverables or must leave this workstream** — as packaged, its only output is the rewrite packet. The root-move / allowlist / audits-index work is in **W0-11**; `delete_branch_on_merge` is admin-only.
> - **F35's second-owner characterization is wrong and the kit's framing depends on it.** `reviewed-by:emilio3435 updated:>=2026-08-01` = **17 PRs** (latest #2318, 2026-08-18), 3 commits, 2 authored PRs, permission `push` (not admin). The honest statement is *"the second owner reviews but has lapsed since 2026-08-18 and holds no admin/deploy/cloud access"* — the gap is **deploy/cloud access**, not review access.
> - **Retarget the SLO fixTouch:** root `GOVERNANCE.md` is a 5-line redirect stub; the canonical file is `docs/GOVERNANCE.md`.
> - **Bound the branch-reaper output:** 1,798 remote heads. Deliver **one artifact + one issue** with per-prefix counts and a proposed policy (delete merged branches; delete branches with no open PR and no commit in 90 days; exempt `preserve/*` (327), `release/*`, and anything with an open PR) — not a per-branch review list.
> - **Lane and fanout:** the launchd/supervisor half is **structured-large** (launchd respawn semantics of a privileged daemon), with a rollback note and a manual `launchctl print gui/$UID/com.openburnbar.<label>` verification step in the validation matrix. Fanout 6 → 9, split across the three units. Every agent works in a worktree off `origin/main`.

**scoreDelta:** Reliability/Ops +0.15, Series A Diligence +0.30.


---

# The fake-green blacklist

**Every item below scores ZERO and is forbidden in every wave.** Most are mechanically caught by `scripts/ci/check-no-suppressions.sh` (fail-closed, required context "No new suppressions"); all are found by a diligence engineer diffing the workflows.

### Threshold and gate manipulation
- Raising `OPENBURNBAR_APP_TEST_ATTEMPTS`, or keeping the 4-attempt loop so one pass in four reads as green.
- Adding `continue-on-error` or raising `timeout-minutes` on any lane to turn it green. *(Existing values in `linux-nightly.yml:37/:47` are pre-existing upload retries and stay as-is; the diff must show no new ones.)*
- Raising `.swiftlint.yml` `file_length`, `type_body_length`, `function_body_length`, or any `budgets/*.json` ceiling. `.swiftlint.yml:30` already says *"Do NOT raise any error threshold to make room; lower the code instead."*
- Raising `check-firestore-rules-size.mjs`'s FAIL (153,600 B) or WARN (149,504 B). They may only ratchet **down**.
- Removing contexts from `governance/burnbar-ci-gate.json` / `.fast.json` `required_contexts`.
- Editing `governance/branch-protection.main.json` **down** to match live state so `check-branch-protection-drift.mjs` goes green.
- Relaxing or removing the OSV gate instead of bumping the dependency.
- Adding `functions/package.json` to `classify-ci-impact.mjs`'s `FULL_PATTERN_EXEMPTIONS` to dodge full CI.

### Suppression and coverage evasion
- Any new `eslint-disable`, `@ts-ignore` / `@ts-expect-error` / `@ts-nocheck`, `# noqa` (bare), `@Suppress` / `@SuppressLint` / `@SuppressWarnings`, `// detekt:`, `swiftlint:disable`, `#[allow(...)]`, without a `reason: <8+ chars>` token or an exact-path `docs/LINT_RATIONALE.md` entry.
- **Any new `budgets/*.json` at all, whatever the allowlist says.** The check (`check-no-suppressions.sh:340`) requires an exact-path entry in the single `<!-- BEGIN:suppression-allowlist -->` block for `budgets/*.json`, and `:343` requires one for `*baseline*.{xml,yml,yaml}` — but *satisfying* that requirement is not the bar. **This plan adds zero `budgets/*.json` files and zero allowlist entries in wave 0.** Writing a new budget file and then allowlisting it so the required "No new suppressions" context goes green is the move this list exists to forbid, and it does not stop being that move because the plan is the one doing it.
  > **Carve-outs, both explicit, both deliberately outside `budgets/`.** Two wave-0 workstreams need committed policy state, and neither may buy it with an allowlist entry:
  > - **W0-11's root ratchet → `governance/root-inventory.json`.** Not `budgets/`, no "baseline" in the name, `.json` is not in `:343`'s extension list — so it matches neither rule, needs no allowlist entry, and creates no suppression. Enforced by `scripts/ci/check-root-inventory.sh` as a step in the existing `Debt budgets` job.
  > - **W0-7's two Node-24 exemptions → `governance/toolchain-pin-exceptions.json`.** Same reasoning, plus a mandatory `expiresOn` per entry that fails the checker when passed, and the checker prints every active exception so an exempted gate never reads as a clean one.
  >
  > Any wave-1/2/3 workstream that believes it needs a `budgets/*.json` (W2-1 proposes four, W2-3 two, W2-5 one, W3-2 two) must first justify why `governance/` will not do, and land the allowlist entry **and** the mutation proof that the new ratchet fires, in the same commit. Absent both, it scores zero.
- Re-pointing `--baseline` / `baseline = file()` in gradle/detekt/swiftlint/workflow config.
- Adding 112 individually-described `eslint-disable` lines to satisfy the `firebase-admin/firestore` boundary rule (the native description escape hatch passes CI while defeating the rule).
- Re-running `check-mission-splitbrain-budget.sh --update` to absorb growth, or renaming files out of the matched prefix (**PR #2362 already scored a phantom 1,387-line improvement this way** — the script's own header records it).
- Adding a token to `check-callable-validation.mjs`'s `INPUT_VALIDATOR_TOKENS` array to reclassify an unvalidated callable as validated.

### Signal removal disguised as a fix
- Dropping `swift` from the `codeql.yml` matrix instead of fixing the Metal toolchain.
- Deleting or descheduling any of the four 0-for-20 nightlies.
- Retiring `scripts/ops/check-ops-alert-plane-drift.mjs` "in favour of terraform plan" — `plan` needs production-environment creds unavailable on `pull_request`, so this is a net loss of merge-door coverage.
- Making `scripts/verify-version-consistency.sh` "report-only on PR". It is hard-required today and is a protected control-plane seed.
- Editing `scripts/ci/verify-pr-harness-aggregate-gates.test.mjs` to accommodate an `app-pr-gate.yml` change, rather than updating both together.
- Loosening `PrivilegedInputKillSwitchWatchdogPlistTests.swift:24`'s `as? Bool` to accommodate a new plist shape.
- Turning the 3 known-red `session-log-backup` tests green by `.skip`, deletion, assertion loosening, or flipping `continue-on-error`.
- Blanket `known-red-named-blocker` labels applied to lanes nobody triaged.

### Evidence fabrication
- Accepting a **skipped** snapshot test as evidence. `AgentLensTests/Support/SnapshotTestSupport.swift:21-28` skips on `GITHUB_ACTIONS=true` / `RUNNER_OS` / `/Users/runner/work/`.
- Accepting a `--filter` run that selected **zero** tests (always assert an executed-test-count floor).
- Accepting a check-run `success` for a lane the classifier **skipped** (run `33326737617`: `App build + test (AgentLens)` success in one minute with both prerequisite lanes skipped).
- Committing a `--dry-run` rollback receipt produced without gcloud and citing it as rollback evidence.
- Claiming `headless-app-build` green as proof the app's tests pass — it runs `xcodebuild build` **only** and compiles no test target.
- Citing a `supply-chain-provenance.yml` tag-ref dispatch as proof of a fix on main (the dispatch runs the **tag's** YAML).
- Presenting a `cursor[bot]` approval as review evidence. The constraints declare explicitly it is not.

### Authority violations
- An agent approving a PR with Alberto's `gh` token.
- Using the ruleset bypass actor (user 125839313) to merge around the queue while a required check is red.
- Force-pushing or rewriting history on `main` or any protected branch.
- Pushing any `v*` / `windows-v*` / `linux-v*` tag. Ruleset 16177860 has `deletion` + `non_fast_forward` with **zero bypass actors** — a mistakenly pushed release tag is **permanently undeletable** and fires the release pipeline immediately.
- Editing the rubric or its weights.

---

# Findings coverage — all 35

| ID | Subject | Wave | Workstream(s) | Human? |
|---|---|---|---|---|
| F01 | Deploy lane dead since 2026-06-18 | 0→1 | W0-4 (ancestor guard stacked on #2349), W0-2 (lane-health) | 🔒 items 11–14 |
| F02 | Alert plane unverified; no billing budget | 0→2 | W0-5, W2-4b | 🔒 items 7–9 |
| F03 | Rollback runbooks name the wrong project | 0 | W0-6 | 🔒 item 15 (live drill) |
| F04 | Merge gate cannot see a red main | 0→1 | W0-3 (observe), W1-7b (enforce) | — |
| F05 | 304.4 MB of `.glb` in the app bundle (119 files under `AgentLens/PetCompanion/Resources/Models/**`; 121 / 309.2 MB tracked repo-wide incl. two 2.53 MB copies under `windows/` and `apps/linux-desktop/`) | 2 | W2-6a/b (W2-6c blocked) | 🔒 item 19 |
| F06 | Swift has no working SAST | 0 | W0-10 | — |
| F07 | Nightlies red, repair bot silently no-op | 0 | W0-1, W0-2 | 🔒 items 5–6 |
| F08 | 9.9 GB `.git`, vendored binaries | 0→3 | W0-11 (2 deletions + >5 MB guard), W0-8 (checksums), W3-4 (packet) | 🔒 item 22 |
| F09 | README contradicts the parity ledger | 0→1 | W0-11, W1-5a | 🔒 item 16 |
| F10 | Rust core promoted nowhere | 3 | W3-1, gated on **W3-1-M0** (root-cause the `release_train_advanced_before_stable_receipt` annulment) + wave-1 pricing-readiness graft | 🔒 **item 30** (attestation approval, signed apple/linux/functions releases, `deletionReview` signature) |
| F11 | BOLA harness accepts any denial code | 0→1 | W0-12 (ledger — measurement only, day-one enforcement ~unchanged), W1-1a (drain — the actual fix) | — |
| F12 | No schema validation on callables | 2 | W1-1b *(wave **2** per its own header, not wave 1)*, W2-7b | 🔒 item 18 (ADR) |
| F13 | Public unauthenticated LLM endpoint | 1 | W1-2a | 🔒 item 10 |
| F14 | Trust re-bootstrap without a second factor | 1 | W1-3a (W1-3b deferred) | 🔒 items 17, 20 |
| F15 | SBOM attestation mislabelled as SLSA | 0 | W0-8 | 🔒 item 14 (tag) |
| F16 | SECURITY.md contradicts the code | 1 | W0-9 (deferred out of wave 0) — **not started tonight**; contributes to no wave-0 gate condition, so if the plan is truncated after wave 0 this finding is untouched | — |
| F17 | Hot-document write + unbounded scans | 1 | W1-4a/b/c | 🔒 index deploy |
| F18 | Unbounded per-frame Task spawn | 2 | **W2-3a** (partial, ships regardless — `ScreenCapturePipeline.swift` is clean against main and its bounded-AsyncStream change needs nothing from the dirty tree) · **W2-3b** (the bitrate-clamping half, `BLOCKED-ON-OWNER`) | 🔒 **item 29** — land or abandon the `feat/living-glass-sweep` media diffs |
| F19 | 337 K-LOC monolith, service locator | 3 | W3-2 | — |
| F20 | God types; no per-type size gate | 2→3 | W2-1, W3-2 | — |
| F21 | `try?` debt gate scoped to one directory | 2 | W2-1 | — |
| F22 | **26 `nilIfEmpty` declaration sites** (1 `func`, 21 plain `var`, 4 renamed variants); 76 raw keychain lines / 33 files | 2 | W2-2a/b | 🔒 signed-build keychain check |
| F23 | Unconditional `NSLog` in the security coordinator | 2 | W2-2c | — |
| F24 | No toolchain pins; no migration fixtures | 0→1 | W0-7, W1-6 | 🔒 item 25 (Renovate) |
| F25 | Version drift across 6 manifests | 1 | W1-5b | 🔒 item 16 |
| F26 | 261 `Task.sleep`; 4-attempt retry masking | 2 | W2-5 | — |
| F27 | Perf budgets are behavioural tripwires | 0→2 | W0-2 (P-PERF-3 exit codes), W2-4a | — |
| F28 | 104 `nonisolated(unsafe)`, concurrency escapes | 2 | W2-1 | — |
| F29 | RPC v1, 120 untyped params | 3 | W3-3a | — |
| F30 | Mission execution split-brain | 3 | W3-3b | 🔒 entitlement + App Check |
| F31 | 222 KB rules, 76 collections, hand-written | 2 | W2-7a | 🔒 staging deploy re-baseline |
| F32 | Crash reporting default-on; unrestricted API key | 1 | W1-2b | 🔒 item 10 |
| F33 | Main-thread I/O on a 3 s timer | 2 | W2-3a | — |
| F34 | 92 open PRs, 1,798 branches, root clutter | 0→1→3 | W0-11, W1-7a, W3-4 | 🔒 items 21–22 |
| F35 | Bus factor 1 | 0→3 | W0-11 (kit skeleton), W3-4 | 🔒 item 23 |

**Coverage: 35/35 mapped.** Nine findings are `agentFeasibleOvernight: false` in the grounded pack (F01, F02, F08, F10, F19, F26, F29, F30, F35) and are scheduled accordingly — none is claimed as an overnight win.

**Coverage is not the same as progress, so the three weak cells are named here rather than left for a reviewer to find:**

| ID | Why the mapping is thinner than the table implies | What was done about it |
|---|---|---|
| **F18** | Its only wave-2 workstream, W2-3b, is `needsHuman: true` on an owner action that appeared in **no numbered queue item** — the `feat/living-glass-sweep` media diffs. Nothing in the earlier draft would ever have caused F18 to be fixed. | **Human queue item 29** now owns the land-or-abandon decision, and W2-3a is credited explicitly for the `ScreenCapturePipeline` half that ships without it. F18 is therefore **partially** covered by agent work and **partially** `BLOCKED-ON-OWNER`. |
| **F10** | Its 🔒 cell read *"attestation, signed builds"* with no item number; queue item 13 covers tags and environments but names no attestation dependency. | **Human queue item 30**, with the W3-1-M0 prerequisite stated so the approval is not requested before the annulment root cause is fixed. |
| **F16** | Covered only by W0-9, which wave 0 **deletes** and wave 1 re-adopts. It contributes to no wave-0 gate condition. | Marked **not started tonight** in the table. If the engagement stops after wave 0, F16 is untouched and the morning memo says so. |

---

# Grafts applied

Every graft the three judge panels named, and where it landed.

| Graft | Source | Landed in |
|---|---|---|
| `docs/data-room/INDEX.md` + `verify-data-room.mjs`, every workstream deposits an evidence row, `--check` in every wave gate | plan-3 W0-A (all 3 panels) | **W0-11**, and all four wave gates |
| BOLA strict-gap ledger pulled into wave 0; delete `ANY_CALLABLE_DENIAL_CODE` now; W1-1 drains rather than starts | plan-3 W0-F (all 3 panels) | **W0-12** → W1-1a |
| Split Swift SAST into its own PR so 60–120 min CodeQL iterations block nothing; add Semgrep swift observing | plan-3 W0-G (all 3 panels) | **W0-10** |
| Generated README release-status block + version-consistency report pulled forward from W1-5 | plan-0 W0-05 / plan-3 W0-B (panels 1, 3) | **W0-11** |
| Sequencer / pace controller (`≤3` ready, landing-order file, toolchain PR last) + standing cross-PR adversarial verifier posting Cross-agent receipts | plan-0 W0-01 + W0-14 (panels 1, 3) | **W0-0** |
| Observe-first circuit breaker with mode read from governance in the base tree | plan-1 W0-3 (panel 2 named it the winner's best idea) | **W0-3** (already the winner's; hardened) |
| `prepare-functions-deploy` ancestor guard on the live deployed sha | plan-1 W0-4(c) / plan-3 W0-H(c) (panel 2) | **W0-4** |
| Root-allowlist gate + `docs/audits/<yyyy-mm>/` relocation pulled forward from W1-7 | plan-3 (panel 3) | **W0-11** |
| Store-facing claims rendered as `operator-asserted (last confirmed <date>)` | plan-3 W0-B (panel 2) | **W0-11** |
| Per-type budget sums every `extension T` body; closed `try?-ok(<reason>)` vocabulary enforced by the checker; baseline stored so `check-no-suppressions.sh:340` does not reject it | plan-2 W0-1 (panels 1, 3) | **W2-1** |
| Typed `indirect enum JSONSchema: Codable & Sendable` for Tool definitions with byte-equal golden fixtures — removes 30 `nonisolated(unsafe)` statics, seeds the concurrency ledger lower, reused by the RPC exporter | plan-2 W0-9 (all 3 panels) | **W2-1**, reused in **W3-3a** |
| Fast-door pricing readiness: `legacy-oracle` cargo test feature + proptest differential at 0.5-nano tolerance over the shared corpus, executed by Swift and Functions consumers with a fixture-count test | plan-2 W0-4 (all 3 panels) | **wave-1 stream feeding W3-1** |
| RPC method-descriptor structs + compile-time exhaustiveness test over every `BurnBarRPCMethod` case + golden wire fixtures; canon generator byte-identical for already-typed methods | plan-2 W0-2 (panels 1, 3) | **W3-3a** (case count corrected 216→185) |
| Bus-factor kit (`HANDOVER.md`, `ACCESS_INVENTORY.md` with UNSET slots, `verify-access-inventory.sh`, typed `LaunchAgentPlist` + golden test) pulled forward from W3-4 | plan-0 W0-13 (panels 1, 3) | **W0-11** (kit) + **W3-4** (plist) |
| "Approve #2466" as the first line of the posted ops-unblock issue; wave-0 gate reads MERGED **or** `OPEN_WITH_NAMED_BLOCKER: human-approval` | all 3 panels | **Human queue item 1**, wave-0 gate item 1 |
| Absorb open PRs #2349 and #2430 rather than opening parallel slices | plan-2 W0-5 (panel 3) | **W0-4** (#2349), **W3-1** (#2430 noted) |
| emilio3435 / Lionsfan4 can supply the approving review — the night is not single-threaded on Alberto | panel 3 | **Human queue item 2** |
| Correction: `ops-plane-verify` pending run is `33432321267`, not `30831297265` | panel 2 | **Human queue item 7** |
| Correction: extend the existing `check-security-claims.*` and `check-firestore-rules-size.mjs` rather than creating parallel scripts / a looser 180 KB budget | panel 3 (all plans shared this defect) | **W0-9 (deferred)**, **W2-7a** |

---

# What changed from the winner plan

The winner plan (`plan-ops-first`, 245 pts, judged best by 2 of 3 panels) supplied the wave structure, the ops-first ordering, the observe-first breaker and the fail-closed discipline. Every one of its 27 workstreams was then refuted by both adversarial lenses. The structural changes:

**Deleted outright** (the work does not exist, or the mechanism is fictional)
- W0-4 PR A — the "prod-ahead functions deltas" exist only in an uncommitted working tree. → human queue item 11.
- W0-4 PR B's attested-manifest-digest policy — logically inert; it restates the byte-match `verify-domain-core-control-plane.mjs:299` (committed manifest == trusted-main digest) together with `:302` (candidate file == trusted-main digest) already enforces.
- W0-1's OpenBurnBarCore notification-category registry and its classifier implementer — one is scope creep with no oracle, the other is a no-op.
- W0-7's exact Xcode pin (reverses documented decision **P2-8**) and its root `rust-toolchain.toml` (Rust is deliberately two-toolchain); `setup-xcode` has no `xcode-version-file` input and `dtolnay/rust-toolchain` does not read `rust-toolchain.toml`.
- W1-1's "catalog becomes enforcement" and TypeSpec-derived zod — the catalog is hand-authored prose and the canon has no callable RPC surface.
- W1-3's email fan-out — `functions/src` has **zero** email transport.
- W2-6's KTX2 texture compression — it addresses **3.14%** of the payload and would not decode at runtime.
- W3-1's cargo-fuzz / cargo-semver-checks / cargo-dist and the "hand-maintained C ABI" premise — none exists or applies.
- W2-2's `ComputerUseE2E` stdout-contract sink — the contract has **zero consumers**.

**Split** (mixed goals, or evidence landing in different CI clocks)
W0-2 → W0-2 + W0-10 · W1-2 → W1-2a (door) + W1-2b (nightly-blind) · W1-3 → W1-3a (server) + W1-3b (clients, out of wave) · W1-4 → three · W1-5 → two · W1-7 → two · W2-1 → three PRs · W2-2 → five · W2-3 → two (one blocked) · W2-4 → two · W2-6 → three · W2-7 → two · W3-1 → M0 + serial crate lane · W3-3 → two · W3-4 → three.

**Corrected numbers that would have made a gate unsatisfiable**
`BurnBarRPCMethod` cases **216 → 185** · `Task.sleep` **259/83 → 261/85** · `#filePath` test files **34 → 87** · `nonisolated(unsafe)` **103 → 104** · `DispatchQueue.main.async` **40 → 42** · App Check exceptions **14 → 5** · `nilIfEmpty` **25 → 26 declaration sites** (1 `func`, 21 `var`, 4 renamed — the detector was wrong, the *count* was nearly right) · `JSONDecoder()` **863 → 870 across 452 files** · compacted `firestore.rules` **"57% of 256 KB" → 145,703 B with 5.1% headroom** · alert policies **"12+" → 36** · Swift test files > 2,000 lines **4 → 23** · `ProviderQuotaServiceTests` **6,129 → 5,959** · `.glb` payload **304 MB → 304.4 MB across 119 files** under the pet Models tree (121 / 309.2 MB tracked repo-wide) · `is_xcode_false_negative_pass` assertions to invert **12 → 11** · `verify-version-consistency.sh` README regex **`:56` → `:54`** · `verify-domain-core-control-plane.mjs` byte-match **`:297` → `:299` + `:302`** · open PRs **91 → 92** · remote branches **5,468 → 1,798** · `+repair` tags **37 → 69**.

**Corrected arithmetic, after the completeness review of this document itself**
The first published draft claimed a four-wave ceiling of **80.95** and wave checkpoints of 73–77 and ~81. None of those reproduced from the document's own `scoreDelta` lines, which sum to **138.25 weighted (74.6)** on merge and **158.25 (76.6)** with every contingent. The priority table summed to +3.88 against a wave-0 delta sum of +3.47 and omitted W0-4 entirely; the row labelled "honest ceiling 64" was really the all-eleven-merge case while its stated assumption was 4–6 PRs. All of it is now derived in one place — the [Score ledger](#score-ledger) — and every projection is a transcription from it. The conclusion (*85 is not reachable tonight, and not by this plan either*) survived the correction and got stronger: the gap at week 8 is **8.4 points**, not 4.

**Constraint file overruled, deliberately and on the record**
`constraints.json` `gateFacts` states *"65 contexts = fast set + 5, including Signal cross-device KATs"*. That is **wrong on two counts** and this plan does not follow it: `governance/burnbar-ci-gate.json` has **64** `required_contexts` and `governance/burnbar-ci-gate.fast.json` has **60** (`python3 -c 'import json;print(len(json.load(open("governance/burnbar-ci-gate.json"))["required_contexts"]))'` on `9503b490b0`), a difference of **exactly four** — `{Android PR Gate, Daemon PR Gate, Domain Core PR Gate, PR Windows Full Gate}` — and `Signal cross-device KATs` is in the **fast** set, so it is not one of the four. Overruling a binding constraint document deserves to be stated in its own paragraph rather than buried in a lane-corrections bullet, which is where the first draft left it: **every count in this plan is derived from the two governance files at `9503b490b0`, not from `constraints.json`.**

**Evidence paths replaced because they were unobservable**
Emulator index loading (the emulator does not enforce indexes) · nightly screenshots (no lane emits them) · "5.5 GB fixture" (Alberto's live store) · `gh-pages` benchmark dashboard (Pages returns 404) · tag-ref provenance dispatch (runs the tag's YAML) · `swift test` on Linux (banned by the Linux contract) · a `merge_group` run proving its own governance change (read from the base tree).

**Lane corrections**
`PR Native Fast Gate`'s SwiftPM job runs on **macos-26**, not ubuntu · `Signal cross-device KATs` is in the **fast** set · `governance/burnbar-ci-gate.fast.json` has **60** contexts and `burnbar-ci-gate.json` **64**, differing by exactly `{Android PR Gate, Daemon PR Gate, Domain Core PR Gate, PR Windows Full Gate}` · `Swift↔Windows↔Linux migrator parity` is in **neither** config and is therefore non-blocking today.

---

## Closing note

The plan buys **honesty first and speed second**, because on this repo the two are the same thing. Four nightlies have been red for weeks while a repair bot reported 5/5 green; a production deploy lane has been dead for 75 days behind an approval nobody clicked; a BOLA harness accepts any denial code for 95% of endpoints; a perf gate calls itself a "behavioral-assertion" and cannot fail. Every one of those is a **green dashboard over a red system**, and the source report names that as its second alarm. Fixing the dashboards makes the number go *down* before it goes up — `nightly-health` will show six lanes red, the repair bot will fail closed, and the alert plane will report `wif-not-provisioned`.

That is the correct direction. A reviewer who can trust a green light is worth more than four points of score, and it is the only foundation on which the eight-week path to 85 stands.

---

*Prepared 2026-09-01 from `plan-ops-first` (245 pts) with grafts from `plan-diligence-narrative` (235), `plan-fastest-to-85` (231) and `plan-structural` (175), amended against 54 adversarial verdicts and reconciled against three independent ceiling analyses. Base commit `9503b490b0`. No file in `/Volumes/DevSSD/Developer/BurnBar` was modified in the production of this document.*
