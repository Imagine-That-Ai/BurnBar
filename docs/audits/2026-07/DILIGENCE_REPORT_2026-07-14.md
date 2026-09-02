# Technical Diligence Report — OpenBurnBar / BurnBar

**Date:** 2026-07-14
**Scope:** Full-stack diligence review of the entire monorepo
**Tree reviewed:** `origin/main` @ `994bc55288` (2026-07-14), via a pinned read-only worktree
**Method:** Coordinated 6-lane specialist swarm (architecture, code quality, reliability/ops, security, performance, QA/delivery), with per-lane sub-lanes (Android, Windows C#, TS, functions, E2EE, daemon, secrets, rate-limit) and independent re-verification of every claim in the prior in-repo report (`DILIGENCE_REPORT_2026-07-12.md`) against live GitHub Actions state, live branch protection, live `gcloud` production state, and executed gate scripts. Green badges were not trusted; what they measure was checked.
**Confidence:** High. Every material claim is backed by file:line evidence, live `gh`/`gcloud` output, executed scripts, or an independent scan (e.g. a fresh full-tree gitleaks run).

---

## 1. Executive Summary

**The two-day-old verdict "genuinely impressive code on top of a broken deployment plane" is still the story — but both halves moved, and one of them moved a lot.**

Since the 2026-07-12 report, this team (effectively one person plus agents, 2,557 commits in 30 days) landed real, verified fixes to the majority of that report's headline findings:

- **The 95.7k-LOC Core god module is gone.** PR #1730 dissolved it into an acyclic graph of 11+ real targets with 127 lines of re-export shims left behind — verified on disk, with regrowth deny-gates that we executed ourselves and that run as required CI checks. This was the #2 rewrite risk; it is now closed and fenced.
- **Half of the launch blocker is fixed and provably so.** Firestore rules deploys are green since 7/13, and the deploy lane hash-verifies prod↔main parity — the 427-line production rules drift is closed.
- **CI green-washing is dead.** Repair bots now conclude `skipped`, not `success` (PR #1574, visible in live run history).
- **The app-side FTS5 CPU-burn fix landed** (v55 migration + rowid-targeted deletes + tests), the same class of fix the prior report flagged as stranded by database split-brain — and this time it was mirrored into both database layers.
- Money-path test harnesses became merge-blocking; port-file-size and migrator-parity ratchets now fence the previously unguarded edges.

**What did not move is the thing a diligence partner asks about first.** Production Cloud Functions are still frozen at 2026-06-18 — verified live via `gcloud`, with two Cloud Run services last deployed *manually from a personal gmail account*. 173 commits touching `functions/` are merged, CI-green, and not running in production. The environment-policy fix that supposedly unblocks the deploy lane merged on 7/12 and **has never been exercised — not even as a dry run**. Meanwhile the rules fix created a new, untested condition: production now enforces July-14 security rules against June-18 functions, a combination no CI lane ever tested and the most likely source of spontaneous `PERMISSION_DENIED` breakage. And the proof plane is still red: the Full Harness has 0 green runs in its last 200 on main (last green 2026-06-19), and the nightly E2E has *never* succeeded.

The swarm also broke new ground the prior report missed: the celebrated code-quality discipline is **Swift-first, not codebase-wide**. Where the gates reach (macOS app, daemon, Core, functions, Rust — roughly 70% of the code) the work is genuinely 9-grade. Where they don't, there are shipped, user-visible defects on main today: a compiler-rejected TypeScript file in the never-typechecked Linux desktop app, a 2-day-old GL-engine fork that already dropped the low-power GPU fix, an Android quota-refresh feature that cannot work on a real device (blocking network on the main thread, swallowed by an empty catch), and dead Browse buttons on two shipped Windows settings pages. Security review surfaced an honesty seam in the E2EE story (hosted Insights sends plaintext project names and task titles to a third-party LLM) and a declared rate limit that is dead code behind a test that lies green.

**True maturity:** a credible production system with a genuinely impressive, mechanically-enforced core, run by an operation that still cannot prove it can deploy its own backend — and whose enforcement machinery thins out exactly at the newest platform edges.

---

## 2. Final Verdict

- **Professionalism:** High, and higher than two days ago — the response to the 7/12 report was to *fix the findings within 48 hours and fence them with ratchets*, which is exactly what a strong team does. Held back from top marks by the gate-scope holes and by fixes that stop one button-press short of proof.
- **Launch readiness:** **Launchable with major caveats** (unchanged category, improved substance). Clients are live and healthy; prod rules now match main. But the backend compute plane is unproven-at-best, the July-rules/June-functions skew is untested, and there is no green end-to-end run anywhere.
- **Series A technical-diligence readiness:** **Strong startup-grade foundation, not yet diligence-clean.** The delta between the 7/12 and 7/14 states is itself a diligence asset — it demonstrates the team can consume an audit and close findings fast. The functions freeze, the never-green proof plane, and the single-operator bus factor remain the three findings that would surface in any competent diligence.

**If shown to excellent engineers and Series A investors tomorrow: impressed and nervous — now more impressed and slightly less nervous.** Impressed by the god-module dissolution, the enforcement culture, and the audit-response velocity. Nervous that the single known blocker has sat one un-pressed button from resolution for two days, which is the bus-factor risk in miniature.

---

## 3. Scorecard

| Category | Score /10 (was) | Maturity | Rationale |
|---|---|---|---|
| **Architecture** | **8** (7) | Credible production → impressive | God module dissolved for real, acyclic 34-target graph, executed regrowth gates; held back by zero Rust domain-core promotions, unflipped mission-authority split-brain, ungated Windows wire schema. |
| **Code Quality** | **7.5** (9) | Credible production | Gated core is 9-grade; prior score extrapolated it to the edges. Ungated linux-desktop TS carries a compiler-rejected file on main; Android/Windows edges shipped real defects. |
| **Reliability / Ops** | **5** (4.5) | Ambitious but messy | Rules plane fixed with hash-verified parity; green-washing killed. Functions/Cloud Run frozen 26 days, fix never exercised, no deploy-freshness monitoring, alert issues rot open. |
| **Security** | **7** (6.5) | Credible production | Top-decile as-written (fail-closed rules now verifiably live, daemon trust root, zero real secrets); functions-plane freeze strands merged security fixes; E2EE metadata leak; dead rate limit; 0-approval scanner governance. |
| **Performance / Scalability** | **7** (6.5) | Credible production | FTS5 burn class fixed app-side with tests; new surfaces power-disciplined; per-minute 90-day Firestore fan-out and full-corpus re-parse-on-index remain the growth time bombs. |
| **Testing / CI / Delivery** | **6.5** (6) | Ambitious but messy | Best-in-class PR gate wall (self-testing diff-coverage, byte-compat fixture proofs); post-merge proof plane 0-green in ~200 runs, mobile tests never execute pre-merge, test topology mid-relocation. |
| **Documentation / Maintainability** | **7.5** (7) | Credible production | 155 docs, real runbooks, dated perf-engineering log, honest CHANGELOG, NAMES.md decoder ring; wiki mirror dead since 7/9. |
| **Overall Professionalism** | **7.5** | — | Enforcement culture + audit-response velocity are the standout; gate-scope honesty is the remaining seam. |
| **Launch Readiness** | **5.5** (5) | — | Rules drift closed; compute plane unproven; proof plane red; new client-side dead features found. |
| **Series A Diligence Readiness** | **6.5** (6) | — | The 48-hour fix delta impresses; the un-pressed deploy button and bus factor would still headline the findings memo. |

**Overall weighted score: 74 / 100** (was 72 — weighting launch-blocking ops gaps heavily, as a diligence team would).

**Severity summary:** 1 systemic launch blocker (narrowed to its compute half) · ~12 serious weaknesses · ~20 medium concerns · numerous polish items.

---

## 4. What Inspires Confidence

All verified first-hand, not taken from docs or badges.

1. **The god-module dissolution is real and enforced.** 11 re-export shims / 127 LOC where 353 files / 95.7k LOC used to be; acyclic layered graph (Foundation-only Kernel leaf, UI-free Engine umbrella); we *executed* the membership gate (`baselined=11 files/127 lines, live=11/127 — OK`) and confirmed "Debt budgets (shrink-only ratchets)" sits in the 60-check required wall with `enforce_admins: true`.
2. **The team metabolizes audits.** Of the 7/12 report's Top-10, items 1(half), 2, 4, 5(partial), 7, and 10(half) were closed within 48 hours, each with a regression fence (rules-size tripwire, port-file-size ratchet, migrator-parity gate). Fix quality is high: the rules fix deleted the bespoke deployer rather than patching it, and added post-deploy drift verification so "green" means *prod hash-matches main*.
3. **The strangler machinery around risky migrations is world-class-adjacent.** Mission authority and Rust domain-core both migrate behind shadow modes with divergence telemetry, fail-closed target modes that never silently fall back, and evidence-gated promotion policies committed to the repo.
4. **The PR gate wall is the strictest we've seen at this stage.** Self-testing fail-closed diff coverage (positive-control before trusting its own verdict, written-reason waivers), a committed encrypted SQLCipher v55 fixture opened byte-for-byte from C#, 22 adversarial Firestore-rules emulator suites, base-ref-trusted gitleaks a PR cannot self-exempt, ~12,500 test cases across five platforms with behavioral assertions in every file sampled.
5. **Security engineering depth:** daemon with compiler-enforced per-method capability tables, code-signature peer auth, fail-closed App Check boot, KMS envelope secrets, an independent full-tree gitleaks scan returning zero credible secrets, and production rules parity now hash-verified on every deploy.
6. **Idle-cost discipline as a tested invariant:** occlusion→JS-bridge→rAF-cancel chain verified at every layer, self-calibrating N+1 query budgets, a 585-line dated perf-engineering log that candidly documents its own remaining hot paths.

---

## 5. What Would Alarm a Serious Reviewer

1. **The backend compute plane is frozen at June 18 and the claimed fix has never been run.** 116 of the last 200 `deploy-production.yml` runs failed; `deploy-cloud-run.yml` is 1-for-150; two Cloud Run services were last deployed manually from a personal account; zero deploy attempts since the unblocking config fix merged. "Can you ship a backend fix right now?" still has no proven answer.
2. **Production runs July rules against June functions** — merged, CI-green server-side security hardening isn't live, and the rules/functions combination now enforcing in prod was never tested together by any CI lane.
3. **The proof plane has never been green.** Full Harness: 0 successes in its last 200 main runs; nightly E2E: 0 successes ever; current failures include unattended infra rot (ARM runner can't virtualize Android; rustup download flakes). Red is the ambient color, and the harness isn't a required check, so nothing stops.
4. **Green CI does not mean checked code at the edges.** A file `tsc` rejects (duplicate interface members) lives on main in `apps/linux-desktop` because nothing typechecks it; the GL-engine fork silently dropped the low-power fix; Android's self-hosted quota refresh cannot work on a device and fails silently; Windows ships dead Browse buttons. All pass every current gate.
5. **Bus factor, now with receipts.** One effective operator; alert issues from mid-June still open; the wiki mirror dead since 7/9; the launch-blocking deploy fix waiting two days for a button press. The alerting works; the acting-on-it is the bottleneck — and no paging path (Slack/PagerDuty) exists anywhere.
6. **E2EE honesty seam.** The hosted Insights fallback sends plaintext project folder names and inferred task titles — the exact fields the sync path seals — to OpenRouter/MiniMax, disclosed only as "no raw transcripts." A researcher or journalist finding this frames it as "the E2EE app that ships your project names to a third-party LLM."

---

## 6. Launch Blockers

### LB-1 (carried, narrowed): Backend compute deploy plane unproven; production functions 26 days stale
- **Evidence (live):** every prod Cloud Function `updateTime` = 2026-06-18 (`gcloud functions list`); `openburnbar-quota-runner` last deployed 2026-05-09 and `openburnbar-ots-verifier` 2026-05-18, both `LAST_MODIFIER = alberto8793@gmail.com`; 173 undeployed `functions/` commits; issue #1091 open; zero `deploy-production`/`deploy-cloud-run` runs since 2026-07-06 despite the environment-policy fix (PR #1572) merging 7/12 with a free `dry_run` mode.
- **Why it blocks:** launching means operating a backend you cannot demonstrably update or roll back; rollback tooling routes through the same unproven plane; merged security/validation fixes are not protecting users.
- **New sub-risk:** July-14 rules enforcing against June-18 function write patterns (append-only escrow, spend caps, monotonic counters) is an untested combination — the most likely spontaneous production breakage.
- **Remediation:** hours. Trigger `deploy-production.yml` with `dry_run=true`, then real; same for Cloud Run; enumerate the undeployed functions diff for stranded security fixes first.

### Resolved since 7/12: LB-2 (Firestore rules drift) — **CLOSED, verified.**
Rules deploys green on every push since 2026-07-13T13:58 (PR #1572 + #1687), including post-deploy drift check and TTL readback; prod hash-matches main. The 236KB-file risk got its tripwire (230KB gate + consolidation).

*(Borderline, called out explicitly: the 0-green proof plane is not formally a blocker — clients gate on the PR wall — but no serious reviewer would sign a launch memo without one green end-to-end run. Treat it as blocker-adjacent.)*

---

## 7. Diligence Risks

1. **"Can you deploy a fix right now?"** — still no proven yes for functions/Cloud Run. First question, red answer, 26 days running.
2. **No end-to-end proof artifact** — nightly E2E 0-for-all-time; Full Harness 0-for-200; the new module graph, Windows C-ABI path, and domain-core union have never passed a green integration run.
3. **Bus factor** — ~66 workflows, 24 ratchet scripts, parity ledgers, bot mesh: a bespoke automation product with one maintainer; June's auto-filed P0s still open; no paging integration.
4. **Gate-scope honesty** — the quality/enforcement story is Swift-first; linux-desktop TS has no typecheck/lint at all (live TS2386 on main), C#/Rust are outside the duplication gate, detekt exempts `ui/`, and the celebrated "zero swallowed errors" counts only AgentLens+Daemon (Mobile: 388 untagged `try?`; Daemon: 262).
5. **E2EE claim vs hosted-LLM metadata egress** (project names, task titles) — under-disclosed in PRIVACY.md; independent of that, the E2EE proof gate is path-filtered (enumerated, not exhaustive).
6. **Dead controls with lying tests** — the gateway per-IP rate limit is declared, inventoried in a green test, and called from nowhere; three authenticated endpoints (VoIP push, vector search, notification reply) are unthrottled cost/abuse surfaces.
7. **Zero required human approvals on main** — machines review machines (droid-review + automated checks); `.gitleaks.toml` isn't CODEOWNERS-protected, so a two-PR sequence could weaken the secret scanner with no human in the loop.
8. **V-47 secrets, still** — 35 local `preserve/*` tags with Android keystore passwords + `IROH_SERVICES_API_SECRET`, verified not pushed, but the committed pre-push guard was **never installed** in the primary clone and rotation is unverified ~4 weeks on. One `git push --tags` from a live leak.
9. **5× platform bet, mid-convergence** — domain-core machinery is credible but 0 domains promoted; quota/pricing/crypto still hand-duplicated N ways; Windows cloud-sync wire schema has no drift gate at all.

---

## 8. Hidden Rewrite Risks

1. **The N-way port strategy (still highest, now with an exit ramp).** Convergence machinery exists and is good; but each domain promotion needs fixtures + shadow evidence + security review + atomic multi-platform releases, with one operator. If promotions stall — the repo's known pattern of excellent machinery, stalled operation — the Rust core becomes permanent triple-bookkeeping. Early warning already visible: Windows quota defaults to the hand-ported C# path; Android's quota math has already diverged from Swift.
2. **The per-stack enforcement machinery itself.** Every gate that made Swift excellent (file-size, empty-catch, try?-justification, duplication, suppression policing) must be rebuilt per language and mostly hasn't been — port quality diverges *structurally*, not accidentally. The ungated linux-desktop surface plus the GL fork is a mini-rewrite already queued.
3. **Parser cache contract.** `conversation: nil` disk caches + whole-file re-parse on change is load-bearing for correctness and the privacy scrubber; true incremental ingestion touches parser, cache schema, indexer, and checkpoint store across five platforms. The tested checkpoint machinery exists but has zero production callers.
4. **Mission-authority split-brain.** If the shadow telemetry reveals GUI and daemon authorizers materially diverge, collapsing two trust roots into one enforced path is non-trivial — and until the flip, daemon policy doesn't bind the GUI.
5. **Kernel as god-module 2.0, capped** — 46,109 LOC against a 46,250 ceiling (141 lines of headroom); watch whether ceiling bumps become routine. Downstream: AgentLens itself (~278k LOC single target) is the next decomposition program.
6. **The Full Harness** — a 0-for-200 gate isn't fixable test-by-test; it needs architectural triage (required-vs-informational split, runner re-platforming) before its green means anything.

---

## 9. Top 10 Highest-Leverage Improvements

1. **Press the button.** `deploy-production.yml` `dry_run=true`, then real; then `deploy-cloud-run.yml`; close #1091. First enumerate the 173 undeployed `functions/` commits for stranded security fixes and sanity-check the July-rules/June-functions skew. *Hours; clears LB-1.*
2. **Get one green end-to-end run.** Triage the Full Harness into required-vs-informational lanes; fix the two named infra rots (ARM/HVF Android runner, rustup flake). One green nightly E2E converts "never proven" into "proven once."
3. **Install `scripts/hooks/install-git-hooks.sh` in the primary clone today; then extract, delete, and rotate the 35 `preserve/*` tag secrets.** *Minutes for the guard; the class of risk it closes is catastrophic.*
4. **Wire the dead rate limit** (`checkPublicHttpEndpointRateLimit` into `hermesGatewayRoutes`), fix the inventory test to assert call sites, and throttle `triggerVoIPCall` / `searchKnowledge` / `submitAgentNotificationReply`.
5. **Close the E2EE honesty seam:** strip project names/task titles from the hosted-Insights digest (or hash them), and make PRIVACY.md disclosure exact either way.
6. **Gate the ungated app:** add `tsc --noEmit` + ESLint to `apps/linux-desktop` CI (fix the TS2386 duplicates), and de-fork `packages/gl-engine` (restore the low-power fix, add a parity check against the console copy).
7. **Point macOS at the rollups it already pays for:** replace `fetchCloudTotal`'s 90-day download with `usage_rollups` reads or a `sum()` aggregate, and stop double-invoking it per tick. *One day; kills the linear-growth read bill.*
8. **Fix the three shipped edge defects:** Android `QuotaStore` self-hosted refresh (dispatcher hop + surfaced error), Windows `ResolveOwnerHwnd` stubs (plumb `WindowChrome.ResolveHwnd`), and add `Directory.Build.props` + analyzers so the Windows flagship gets `TreatWarningsAsErrors` back.
9. **Put a human (or CODEOWNERS) in the loop where it counts:** require 1 approval or CODEOWNERS on `.gitleaks.toml`/`.gitleaksignore` and branch-protection governance files; make the mobile compile gate a required check; enable merge queue or `strict` base freshness.
10. **Flip the two shadows when evidence supports it:** promote the first Rust domain (pricing is the smallest) to `rust` mode on one platform, and flip `authorizeRemote` from observe to enforce after the divergence-telemetry soak — each converts impressive machinery into realized risk reduction.

---

## 10. Appendix — Method, Evidence, Calibration

**Swarm:** 6 specialist lanes + 8 sub-lanes; ~1.0M tokens; every prior-report claim re-verified rather than inherited. Live verification included: `gcloud functions list` / Cloud Run revisions (freeze confirmed), `gh api` branch protection (61 required checks, `enforce_admins: true`, 0 required approving reviews), `gh run list` across ~20 workflows (rules deploys green 7/13+; Full Harness 0/200; nightly E2E 0 ever; repair bots now `skipped`), executed gate scripts (core-membership budget, gitleaks boundary verifiers + 11-case self-test), and an independent gitleaks 8.30.1 full-tree scan (zero credible secrets).

**Prior-report leads re-verified:**
- Core god module (~95.5k LOC, 25% done) → **DISSOLVED** (PR #1730), regrowth-gated, required check.
- LB-2 rules drift (427 lines) → **CLOSED**, hash-verified parity on every deploy.
- LB-1 functions freeze → **STILL TRUE** (live gcloud), fix merged but never exercised.
- Proof plane red since 6/19 → **STILL TRUE** (0/200 harness; E2E 0 ever).
- Repair-bot green-washing → **FIXED** (`skipped` conclusions in live history).
- App-side FTS5 fix "unfixed" → **FIXED** same day the prior report shipped (PR #1578, v55 + tests, mirrored to Core).
- "Zero perf CI" → **OUTDATED** (Linux matched-perf PR gates + N+1 budgets; still no macOS CPU/energy gate).
- Code quality 9/10 → **RE-SCORED 7.5**: the 9 was earned by the gated core and extrapolated to edges that don't merit it (live TS2386 on main; GL fork dropped the low-power fix; Android dead-by-construction feature; Windows dead UI).
- V-47 → tags confirmed unpushed; **pre-push guard confirmed never installed**; rotation unverified.

**Notable new evidence files:** `OpenBurnBarCore/Sources/OpenBurnBarCore/*.swift` (11 shims), `budgets/core-target-membership-baseline.json`, `MissionRemoteAuthorizationShadow.swift`, `crates/openburnbar-domain-core/`, `tools/schema-sync/manifest.json` (no C# mirror), `apps/linux-desktop/src/tauriBridge.ts:651/:674` (TS2386), `packages/gl-engine/src/engine/BackdropEngine.ts:334` (`high-performance` fork), `android/.../QuotaStore.kt:195-230`, `windows/.../DataSourceSettingsPage.xaml.cs:80-83`, `functions/src/insightsHostedAnswer.ts` + `InsightDigestBuilder.swift:304-319`, `publicRateLimit.ts:56,238` + zero call sites, `scripts/ci/deploy` lanes + `check-firestore-deploy-drift.mjs`, `scripts/hooks/pre-push` (committed) vs `.git/hooks/pre-push` (stock LFS).

**Answering the framing question:** shown to excellent engineers and Series A investors tomorrow, this repo would make them **both impressed and nervous — with the ratio shifting toward impressed**. The 48-hour audit-response delta (god module dissolved, rules drift closed, green-washing killed, all fenced with ratchets) is the strongest possible answer to "can this team execute." The nervousness now concentrates on a single, legible thing: an operation of one person that builds excellent machinery and then leaves the final button un-pressed.

---

*Generated by a coordinated 6-lane diligence swarm with sub-lane fan-out and live-infrastructure verification. Successor to `DILIGENCE_REPORT_2026-07-12.md`; every carried claim was independently re-verified against the 2026-07-14 tree and live systems.*
