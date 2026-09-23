# OpenBurnBar Technical Diligence Report — 2026-09-01

Read-only swarm review of `Imagine-That-Ai/BurnBar` at branch `feat/living-glass-sweep` (main is 35 commits ahead of the branch tip and the branch is 42 ahead of main). Six specialist reviewers (architecture, code quality, reliability/ops, security/privacy, performance, QA/delivery) plus an orchestrator. No files were modified and no CI runs were triggered. Live CI and PR data was pulled from GitHub on 2026-09-01.

---

## 1. Executive Summary

OpenBurnBar is a five-month-old, one-human, AI-swarm-built polyglot monorepo whose **engineering governance is well above what its stage warrants and whose operational reality is well below what its README claims.**

The spine is credible production code: incremental byte-offset log parsers with incident-dated design notes, checked-arithmetic pricing in Rust with known-answer tests, a typed 216-method daemon RPC with per-peer capability attenuation, default-deny Firestore rules with 24 emulator suites, an Ed25519-signed phone-control trust chain with persisted replay counters and Mac-side key pinning, and an idempotent Stripe webhook ledger. Zero `try!` in Swift, zero `!!` in Kotlin, zero `unwrap()` in Rust production code. Eighteen shrink-only debt budgets and a fail-closed lint-suppression gate are real and enforced.

Around that spine the picture changes. The macOS app is a 337K-line single module wired through a 75-slot service locator. Domain logic (pricing, quota, insights) is reimplemented four to five times across Swift, Kotlin, C#, and TypeScript while the Rust "shared core" has promoted zero domains to production. Firestore carries 76 collections and a 222 KB rules file acting as the server-side validator. The repo contains at least ten distinct products, 84 workflows, and 250K lines of automation scripts that outweigh the daemon.

The operational state is the most alarming part, and it is verifiable rather than a matter of taste:

- The production Cloud Functions deploy lane has failed on every tag since **2026-08-04**.
- The alert-plane verification workflow has not passed since **2026-08-03**; no GCP billing budget exists.
- The rollback runbook names the wrong Firebase project and the wrong script path.
- The post-merge macOS/iOS gate is red on `main` 12 of its last 17 runs, and the 1,596 iOS unit tests have not run green anywhere in the sample.
- Four nightlies (full harness, Linux, CodeQL Swift, DAST) are 0 for 20 while an auto-repair bot reports green every night.
- 37 hotfix tags (`v1.0.40+repair.N`) shipped in 14 days on a version the README calls a "commercial launch candidate".
- `.git` is 9.9 GB from committed static libraries and 70 revisions of an 83 MB Android AAR; a fresh clone is a ten-gigabyte event.
- The Mac app bundle ships 304 MB of 3D pet models.

Commit velocity collapsed from 2,345 in June and 1,912 in July to 217 in August. Bus factor is one.

**Would excellent engineers and Series A investors be impressed, nervous, or both? Both, in that order.** Impressed by the gate culture, the security engineering, and the honesty of the repo's own audits. Nervous that the dashboards are greener than the system, that one person plus AI agents built ten products in five months, and that the last month shows the process fraying.

---

## 2. Final Verdict

| Question | Answer |
|---|---|
| Professionalism | **Above startup median in discipline, below it in focus.** The measurement culture is unusual; the consolidation culture is missing. |
| Launch readiness | **Launchable with major caveats.** The local-first macOS direct-download product is real, shipping daily, and safe to use. The commercial cloud + iOS + subscription platform is **not launch-ready** until the deploy lane, alert plane, rollback runbook, and mobile test signal are repaired. |
| Series A technical diligence readiness | **Not diligence-ready today.** Bus factor 1, unresolved scope sprawl, a 10 GB clone, a dead production deploy lane, and README claims contradicted by the repo's own parity ledger would dominate any diligence conversation. Six to eight focused weeks could change that answer. |
| Overall weighted score | **61 / 100** (prior in-repo report of 2026-07-14 scored 74; the decline is driven by verified ops state, not code regression) |
| Confidence | **Medium-high** on code and architecture findings (evidence-based, file-cited). **Medium** on live ops state (GitHub data as of today; console-side App Check and GCP settings unverifiable from the repo). |

---

## 3. Scorecard

Weights: Architecture 15, Code Quality 10, Reliability/Ops 15, Security 15, Performance 10, Testing/CI 15, Docs 5, Professionalism 5, Launch 5, Diligence 5.

| Category | Score | Rationale | Severity summary |
|---|---|---|---|
| Architecture | **6** | Acyclic 59-target SwiftPM graph, typed RPC, schema canon with drift gates. But: 337K-LOC app monolith with service locator, 4–5x duplicated domain logic, Rust core promoting nothing, 76-collection Firestore schema, ≥10 products in one repo. | Serious ×5, Medium ×4 |
| Code Quality | **6.5** | Spine is 7–8 (parsers, pricing, dispatch, logging). Zero footgun idioms. But god types split into `Type+Ext.swift` families to pass the file-size gate (16 files / 4,365 lines for one controller), 25 copies of `nilIfEmpty`, 2,311 `[String: Any]` sites, 19 empty catches in C#, unconditional `NSLog` tracing in a security coordinator. | Serious ×6, Medium ×7 |
| Reliability / Ops | **5** | Designed model is strong (staging/prod split, WIF-only deploy auth, idempotent Stripe, jittered breakers, consent-gated Sentry, launchd-supervised daemon). Verified state is not: deploy lane dead 4 weeks, alert plane unverified 4 weeks, rollback runbook wrong, 22% of `main` runs red. | Blocker ×3, Serious ×6 |
| Security | **7.5** | Owner-scoped default-deny rules, server-only entitlements, signed phone-control envelopes with replay protection, code-signed daemon peers, token-gated loopback gateway, no secrets in git. Deductions: BOLA harness accepts any denial code for ~95% of endpoints, no schema-validation library, public unauthenticated LLM endpoint, account-only trust re-bootstrap, "SLSA" label on an SBOM attestation. | Serious ×5, Medium ×6 |
| Performance / Scalability | **6.5** | Ingestion is incremental and off-main, validated against a 5.5 GB DB at 1.2% CPU. But: per-event hot-document write in the usage trigger, O(lifetime-days) rollup rebuild, unbounded per-frame Task spawn in media, 304 MB models in the bundle, perf budgets are behavioral tripwires not measured gates. | Blocker ×1, Serious ×5 |
| Testing / CI / Delivery | **6** | ~21,000 tests, self-testing gates with negative controls, 80% diff coverage pre-merge, 20-minute merge queue, serious notarized release pipeline. But: app + iOS verified only post-merge and red most of the time, 4-attempt retry loop masks flakes, 260 `Task.sleep` in tests (worse than June), four chronic-red nightlies, 37 hotfix tags in 14 days. | Blocker ×2, Serious ×6 |
| Documentation / Maintainability | **6** | Real ADRs, runbooks, curated changelog, zero broken README links. But: 1,968 doc files (385 logs/images), 76% of markdown 30–90 days stale, runbooks with wrong project IDs, SECURITY.md accepted-risk entries that are stale, readiness page 8 weeks old and contradicted by the parity ledger. | Serious ×2, Medium ×4 |
| Overall Professionalism | **6.5** | Disciplined measurement with AI-scale accumulation. Audits are honest; closure rate is about one in three. | — |
| Launch Readiness | **4.5** | macOS local product: yes. Commercial platform: no, for the ops reasons above. | — |
| Series A Diligence Readiness | **5** | Strong answers on security and testing; weak answers on team, focus, ops, and repo hygiene. | — |
| **Weighted overall** | **61 / 100** | | |

---

## 4. What Inspires Confidence

These are verified strengths, not documentation claims.

1. **Security engineering is real and layered.** Firestore: `ownsUserNamespace()` is `request.auth.uid == userId` plus an erasure tombstone (`firestore.rules:35-38, 62-64`); the catch-all path is gated by explicit per-operation allowlists (`:1936-2014`); no `allow ... if true` exists; entitlements appear only in the read allowlist (`:1970`). 242 `assertFails` vs 115 `assertSucceeds` across 24 emulator suites, run as a required check. Phone control: Ed25519/P-256 signatures, strictly monotonic per-peer counters persisted to disk, ±5 s freshness, 120 s TTL, intent-hash binding (`PhoneControlAuthorityValidator.swift:12-30, 90-148`); TOFU key pin with safety-number confirmation on by default (`ControllerKeyPinStore.swift:93-104`); trust mode can only be lowered mid-session (`ComputerUseSetTrustModeDowngradeOnlyTests.swift`). A compromised Firebase account does **not** translate to code execution on the Mac.

2. **The log-ingestion hot path was engineered against real incidents.** `ClaudeCodeParser.swift:9-25` opens with a dated incident (4.2 GB / 3,804 files, 2026-07-16) and the design decisions it forced: byte-offset scan state with a 4 KB head digest for rewrite detection, autorelease pool per line, a resource governor (256 MB per pass, 1.5 GB soft / 4 GB hard). `BufferedLineSequence.swift` is a `memchr` cursor reader with a 16 MB line guard. `docs/architecture/macos-performance.md:2144-2147` records a 5.51 GB SQLCipher database at 1.249% median CPU and 385 MiB footprint after the fix, and the 86% and 128.7% CPU pathologies it replaced.

3. **Footgun idioms are absent.** `try!`: 0 across four Swift targets. Kotlin `!!`: 0 in 158K LOC. Rust non-test `unwrap()`/`expect()`: 0 in 21K LOC. TypeScript `functions/src`: 3 `: any`, 0 `as any` in 113K LOC. Empty `catch {}` in Swift: 0, enforced by a custom SwiftLint rule with error severity.

4. **Governance gates that test themselves.** `scripts/diff-coverage.sh` (1,319 lines) ships a 1,419-line self-test with explicit negative controls. `scripts/ci/check-no-suppressions.sh` fails closed unless a suppression carries an inline `reason:` or an exact-path allowlist entry in `docs/LINT_RATIONALE.md`. Result: 9 `swiftlint:disable` in non-vendor source, one of them in production code. Branch protection is codified in `governance/branch-protection.main.json` and drift-checked.

5. **Money paths are correct.** Stripe webhook: `constructEvent` first (`stripe.ts:658`), then a Firestore transaction on `stripe_webhook_events/{event.id}` with a processing lease; duplicates return `{duplicate:true}`, concurrent deliveries get 409 (`:154-215, 665-672`). `stripeWebhookOrdering.test.ts` (689 lines) covers same-second terminal-vs-resurrection ordering and watermark preservation. `pricing.rs:58-91` does checked `u128` arithmetic with a single rounding step and overflow/monotonicity tests.

6. **The daemon is a proper trust boundary.** Unix domain socket with restricted permissions (`OpenBurnBarDaemonServer.swift:1054-1076`); code-signature peer gate forced on in release with a DEBUG-only opt-out (`OpenBurnBarDaemonMain.swift:143-162`); the daemon verifies its own signature before binding; constant-time bearer check; 17 capability groups attenuated per peer before the rate limiter and any handler. `BurnBarDaemonServerRPCSearchTests.swift` drives a real socket against a real seeded SQLite database and rejects write statements and multi-statement injection through the actual dispatch path.

7. **The repo audits itself honestly.** `TECH_DEBT_AUDIT_2026-06-30.md:24` states "the dashboards say 'done' over debt that is merely relocated". `.swiftlint.yml:180-199` explains thresholds are ceilings set just above the measured max. `docs/OPERATION_9_PLAN.md:235` admits the idle-CPU regression class "recurred twice, caught only socially". This candor is rare and valuable.

8. **The in-flight branch is coherent.** The 170-file uncommitted diff wires a keep-awake lease through both coordinators with a shared helper, models an undetectable APS entitlement as a named reason rather than a silent `false`, and ships new tests alongside new files.

---

## 5. What Would Alarm a Serious Reviewer

1. **The production deploy lane is dead and has been paged about for weeks.** `deploy-production.yml` fails at "Verify protected promotion and exact rollback before build" on every tag since 2026-08-04 (attestation HTTP 404 in run 33480049007). Root cause is upstream: `domain-core-promotion-proof.yml` fails 4 of 4 since 08-18 because `DOMAIN_CORE_GOVERNANCE_READ_TOKEN` is missing. Issue #2195 was paged and the failure job now reports "already-paged". The only working path is the manual break-glass runbook. A governance ceremony designed to make deploys safer has made them impossible.

2. **Green dashboards over a red system.** `codex-nightly-ci-repair.yml` succeeds 5 of 5 because its job is to open PRs, while the four lanes it monitors are 0 of 20. `App PR Gate (Swift)` is excluded from the merge gate by design ("App/Headless are post-merge/nightly", `burnbar-ci-gate.yml:56`) and is red 12 of 17 on `main`. The merge queue keeps flowing regardless. The app test runner defaults to 4 attempts plus an inner 5-attempt loop (`scripts/test-openburnbar-app.sh:371`). A test passing one time in four is "green".

3. **Bus factor of one, building ten products.** Alberto's identities account for roughly 3,258 of 5,417 commits; 166 of 172 PRs merged in the last 30 days came from one login. Co-author trailers on the last 200 commits: Claude Opus 139, factory-droid 114, Codesmith 107, Claude Fable 105, Cursor 81. The average non-merge commit touches 26 files and adds 3,540 lines; the tree is written 16 times faster than it is deleted. No second human can currently review, operate, or continue this.

4. **The README oversells relative to the repo's own ledgers.** README: "Commercial launch candidate — macOS 1.0.40 … Windows 1.0.40 is the parity release line." The mobile-parity ledger (2026-08-18) says `productParityClaim: false` with physical-device rows blocked. The newest Windows tag is `windows-v1.0.38` and the MSIX manifest says `Version="0.1.0.0"`. `docs/TECHNICAL_READINESS.md` is dated 2026-07-08 and requires a `launch-evidence/final-launch-evidence.json` that does not exist. A diligence team will read this as either sloppiness or spin.

5. **Domain logic exists five times and the consolidation has stalled.** Files touching per-million-token cost arithmetic: Core 72, AgentLens 57, Android 50, iOS 25, Windows 22, functions 20, Rust crate 1. Insight engines are implemented five times. `docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md:3`: "no domain has completed production promotion and legacy deletion." Android does not call the Rust quota or pricing API at all. Every provider pricing change is currently four to five PRs plus fixtures.

6. **The security test that looks strongest proves less than it appears.** The 4,514-line `endpointAuthorizationCatalog.generated.ts` is a test fixture and inventory, not runtime enforcement. The BOLA harness (`callableBolaHarness.ts:118-129, 167-171`) accepts `invalid-argument`, `already-exists`, and `aborted` as "cross-user denied" for all but 7 strict endpoints. A handler with no ownership check that rejects the probe on an id-regex passes. Probes use fixed victim ids; it is not a property test.

7. **Repo hygiene that a diligence team will trip over in the first hour.** `.git` is 9.9 GB: a 278 MB, 150 MB, and 140 MB static library committed for the iroh xcframework, an 83 MB AAR committed 70 times, and three git pack files (226, 219, 100 MB) that were once committed under an audit directory. LFS is configured only for website downloads. 5,468 remote branches. 91 open PRs, oldest 2026-08-19. 23 markdown files at root including four prior diligence reports and two tech-debt audits. 313 tracked `.log` files. A 4.8 MB screenshot at repo root.

8. **Velocity fell off a cliff.** 2,345 commits in June, 1,912 in July, 217 in August. Whether that is a deliberate "cheap and fast" pivot, burnout, or work moving elsewhere, it coincides exactly with the ops decay above, and an investor will ask.

---

## 6. Launch Blockers

Fix before a commercial (cloud + subscription + mobile) launch. The macOS direct-download product is not blocked by items 1–4 but is by 5.

| # | Blocker | Evidence | Fix shape |
|---|---|---|---|
| 1 | Production Functions and Cloud Run deploy lanes blocked since 2026-08-04 | `deploy-production.yml:359-506`; `domain-core-promotion-proof.yml` 4/4 failures; issue #2195 | Provision `DOMAIN_CORE_GOVERNANCE_READ_TOKEN` or add a documented bypass profile; add a lane-health alert that re-pages weekly |
| 2 | Alert plane unverified since 2026-08-03; no billing budget | `ops-plane-verify.yml` last success 08-03; `ops-confidence.yml` waiting since 08-24; `rg billingbudget` empty | Unblock the environment approval; run `check-ops-alert-plane-drift.mjs` on a schedule that actually completes; add a GCP billing budget |
| 3 | Rollback runbook is wrong and undrilled | `rollback-automation.md` uses `--project openburnbar` (real: `burnbar`); `functions-break-glass.md:18` wrong script path; `COMMERCIAL_ROLLBACK.md:219` mandates quarterly drill, none recorded | Fix the docs, run one drill, record it in `TECHNICAL_READINESS.md` |
| 4 | macOS app and iOS tests verified only post-merge and red most of the time | `App PR Gate (Swift)` 5 ok / 12 fail on `main`; 1,596 mobile tests never green; nothing halts the merge queue | Put `xcodebuild build` (not tests) of the app target into the merge-group inventory on a hosted runner; fix the self-hosted runner (cmake/protoc); add a "main is red, freeze queue" rule |
| 5 | 304 MB of `.glb` models in the Mac app bundle | `project.yml:217-219`; `AgentLens/PetCompanion/Resources/Models` 304.4 MB | On-demand resources or a downloadable asset pack |
| 6 | Swift has no working SAST | `codeql.yml` `Analyze (swift)` 5/5 failures; `codeql-pr.yml` excludes Swift | Fix the Swift CodeQL build; this has been open since the July report |

---

## 7. Diligence Risks

Issues that will surface in fundraising or technical diligence even if launch proceeds.

- **Team and continuity.** One human. No second reviewer, no on-call rotation (`oncall.md` has no owner; `functions-break-glass.md` says "genuinely solo"). AI-agent co-authorship is the majority of recent commits.
- **Focus.** At least ten products (cost tracker, OpenAI-shaped gateway and model router, mission/agent runtime, Computer Use with privileged HID, Mercury media and calls, Hermes E2EE chat over libsignal and iroh, semantic memory and encrypted search, iOS, Android, Windows, Linux Tauri, four extension/MCP surfaces, smart-hub/PixelClock/Cast, billing across three stores). 216 RPC methods, 163 Cloud Function handlers, 84 workflows.
- **Clone and CI cost.** 9.9 GB `.git`, 14,516 tracked files, 2.9 GB tracked `Vendor/`. Every `actions/checkout` pays for it.
- **Authorization coverage is overstated** (BOLA harness, above). Diligence will ask for a strict-code-by-default rerun.
- **Trust bootstrap is account-only.** `escrowDeviceCallables.ts:219-224`: when no trusted native device exists, the first device self-approves. A phished Google/Apple SSO resets the cloud trust fabric. The Cloud Vault key is not recoverable and the Mac pin holds, so blast radius is bounded, but the design needs an out-of-band step.
- **Denial-of-wallet on a public LLM endpoint.** `benchAssistant.ts:44-56, 518` spends the owner's OpenRouter key with no auth and IP-only rate limits.
- **No schema-validation library.** 147 `onCall` sites; `parseCallableInput` has 10 call sites; 16 callable files match no shared guard idiom.
- **"SLSA provenance" is an SBOM attestation.** `supply-chain-provenance.yml:139-143` runs `cosign attest` on an SBOM with a provenance predicate type. No builder-generated provenance exists. Three tracked AAR binaries have no checksum manifest or rebuild-and-compare gate. The GRDB-SQLCipher fork is pinned to 6.29.3 (September 2024) with no documented divergence.
- **E2EE messaging consistency.** README markets sealing; `SECURITY.md:54` says Signal paths are "readiness-gated, not marketed as live"; `SECURITY.md:63` says there is no staging (there is); `SECURITY.md:70` lists an accepted cross-tenant avatar risk that `storage.rules:22-31` already closed. The true statement is "sealed content, plaintext metadata," and project/device display names do reach OpenRouter (`insightsHostedAnswer.ts:283-293`).
- **Release hygiene.** 37 `+repair` tags in 14 days, all non-prerelease, `latest` moved 7 times in 7 days, scheme undocumented. Two tag schemes (SemVer with `+repair`, CalVer locally). `website/public/downloads/release-metadata.json` still says 1.0.29. Version drift across five platforms with the consistency script exempting Windows and Android.
- **Toolchain pinning.** Xcode is not pinned in any of 84 workflows; Node is 20, 22, and 24 across workflows despite `.nvmrc` 22.22.1; no `rust-toolchain.toml`, no `.swift-version`, dotnet floating.
- **Audit closure rate.** Of five checked June-30 audit items, one closed, four open, one regressed (`Task.sleep` in tests rose from ~175 to 260).
- **Default-on crash telemetry** on the Mac (`MacCrashReportingPrivacy.swift:26-31`), mitigated by `sendDefaultPii=false` and scrubbing, but it needs first-launch disclosure for a product that reads every agent's session logs.

---

## 8. Hidden Rewrite Risks

Ranked by likelihood of forcing a re-architecture within 24 months.

1. **Firestore as the multi-product data model.** 17 top-level collections plus 59 subcollections under `users/{uid}`, 177 rule functions, nesting depth 6, 92 composite indexes, and rules used as a document validator (`validProviderAccountDocument`, `validComputerUseSessionDocument`). Four client sync layers (Mac, iOS, Android, Windows) mirror it. Any move to organizations, multi-tenancy, or a real backend rewrites rules, functions, and all four sync layers together.
2. **The AgentLens monolith.** 1,473 files, ~337K LOC, one Xcode target. `OpenBurnBarRuntimeContext` (`OpenBurnBarStartupRecovery.swift:198`) holds ~75 optional stored properties assigned post-construction; 59 `static let shared` singletons; `.shared` appears 812 times, 333 of them inside views. Retrofitting feature modules and DI is a multi-quarter effort.
3. **Four-way domain duplication with a stalled consolidation.** If the Rust promotion gates never close, the crate becomes a fifth implementation. Windows already depends on Swift-on-Windows via a C ABI for log parsing; if that toolchain breaks, Windows parsing goes with it.
4. **RPC protocol v1 with 216 methods and no payload IDL.** `BurnBarProtocolVersion.current = 1, supported = [1]`; the canon is regex-parsed from Swift source (`tools/ipc/generate-burnbarrpc-canon.mjs`) with param types as strings. Consumers span Swift, the TypeScript extension, and the Linux desktop. The first breaking change is a flag day.
5. **Privileged execution authority spread across GUI, daemon, and Functions.** `CLIAgentMission*.swift` (4,323 LOC, 14 process-spawn sites, no daemon authorization RPC references) does the same job as the daemon's mission control. The split-brain budget freezes 12 files but does not remove them. Consolidating is a security-sensitive rewrite.
6. **The media pipeline's backpressure model.** `ScreenCapturePipeline.swift:330-332` spawns an unstructured Task per captured frame; `VideoEncoder` is `@MainActor`; queue depth is 5; no drop policy. The adaptive bitrate controller is real but cannot help when the bottleneck is task fan-out on the main actor. Contained fix, but until it lands screen-share quality under load is set by OS starvation.
7. **Backend rollup scaling.** `triggers.ts:49-50` writes `rollup_jobs/current` on every usage event; a 400-event batch becomes 400 writes to one document. `rollupCompute.ts:118, 169, 182` scans lifetime days unbounded. Hosted encrypted search is a posting-list scan (`encryptedSearchQuery.ts:55-56, 173-183`) that will need a real index past a few thousand active searchers.
8. **CI and automation as a product.** 84 workflows, 32K lines of YAML, 250K LOC of scripts. It accelerates today and becomes its own maintenance surface the moment Swift, Xcode, Rust/UniFFI, Tauri, or .NET shift underneath it, which is exactly what the missing-cmake runner failure demonstrated.

---

## 9. Top 10 Highest-Leverage Improvements

Ranked by impact on professionalism and readiness per unit of effort.

1. **Unblock the production deploy lane and prove it.** Provision the governance token or add a bypass profile; ship one real deploy through `deploy-production.yml`; then make lane health itself an alert that re-pages. (Days. Removes blocker 1.)
2. **Make `main` red mean something.** Add `xcodebuild build` of the app target to the merge-group inventory on a hosted runner, fix the self-hosted runner, and add a freeze rule when the post-merge app gate is red. Set `OPENBURNBAR_APP_TEST_ATTEMPTS=1` and quarantine the `Task.sleep` suites instead of retrying them. Make the nightly repair bot report red when any monitored lane is red. (One to two weeks. Removes blocker 4 and the signal-inversion problem.)
3. **Fix the alert plane and add a billing budget.** Unblock the environment approval on `ops-plane-verify.yml`, get one green drift check, add a GCP billing budget, and correct the rollback runbook's project id and paths. Run one rollback drill and record it. (Days. Removes blockers 2 and 3.)
4. **Shrink the repository.** Move the three Vendor AARs and the xcframework libraries to LFS or release artifacts with checksum manifests, rewrite history to drop the committed pack files and static libraries, prune the 5,468 remote branches, and close or triage the 91 open PRs. A 10 GB clone is the first thing every diligence engineer will notice. (One week; requires a coordinated history rewrite.)
5. **Reconcile the README with the ledgers.** Either produce `launch-evidence/final-launch-evidence.json` and update `TECHNICAL_READINESS.md`, or change "commercial launch candidate" and "Windows parity release line" to what the parity ledger and tags support. Fix `SECURITY.md` lines 54, 63, and 70. Document the `+repair` tag scheme or stop using it. (Days. Removes the credibility gap.)
6. **Tighten the BOLA harness.** Make strict denial codes the default, assert on victim-store side effects, and randomize victim ids. Then re-run the 147-endpoint sweep and publish the result. Add `zod` and drive `parseCallableInput` adoption across the 16 unguarded callable files. (One to two weeks. Turns the strongest-looking security artifact into a real one.)
7. **Ship one domain through the Rust core end to end.** Pick pricing (250 LOC in the crate), promote it on all four platforms, and delete the legacy implementations. This proves the consolidation path and cuts the per-change multiplier from five to one for that domain. (Two to three weeks.)
8. **Move the 304 MB of pet models out of the bundle** to on-demand resources. Fix the per-event hot-document write in `triggers.ts` (write only on false-to-true) and wrap the download-sync page in one transaction. (Days. Removes blocker 5 and the first backend contention ceiling.)
9. **Pin the toolchain.** Xcode version in every macOS workflow, one Node major, `rust-toolchain.toml`, `.swift-version`, `global.json` for dotnet. Add a committed `.sqlite` fixture from a real old-version database and a migrate-forward test. (Days.)
10. **Declare a scope freeze and write it down.** Name the core (Mac + daemon + extension + one cloud plane), mark the rest experimental or paused in the README support-tier table, and stop adding surfaces until the deploy lane, the app gate, and the Rust promotion are green. This is the single change most likely to make the next 12 months accelerate rather than drag.

---

## 10. Appendix

### A. Answers to the seven specific questions

1. **What does this codebase feel like?** A credible production system at its core wrapped in an ambitious, messy startup platform. Not a hacky prototype (the gates and tests are far beyond that). Not a genuinely impressive foundation yet, because focus, ops hygiene, and continuity are missing.
2. **If this launched tomorrow, what would most likely go wrong?** A production Functions bug that cannot be fixed through the normal lane, discovered by users rather than alerts, rolled back by hand from a runbook with the wrong project id.
3. **What would worry a Series A diligence team most?** Bus factor one, the dead deploy lane, and the gap between README claims and the repo's own parity ledger. Then the 10 GB clone and ten-product scope.
4. **What creates confidence?** The security engineering (rules, phone-control trust chain, daemon boundary, Stripe idempotency), the incident-driven parser work, the self-testing gates, and the repo's own honest audits.
5. **Will the architecture accelerate or slow the team over 12–24 months?** With a scope freeze and one Rust domain promoted, the gates make the core unusually safe to refactor and it accelerates. Without a freeze, every change multiplies by platform count and velocity per engineer declines as headcount grows.
6. **How much hidden rewrite risk?** Moderate to high, concentrated in the Firestore data model, the AgentLens monolith, and the duplicated domain logic. The local-first core and the daemon do not need rewriting.
7. **Does the code reflect real engineering taste and discipline?** Yes in the spine, unevenly in the periphery. Roughly 60% curated, 40% accumulated. Discipline in measurement is strong; discipline in consolidation is weak.

### B. Key metrics

| Metric | Value |
|---|---|
| Repo age | 5 months (first commit 2026-04-04) |
| Commits | 5,417 total; 366 / 577 / 2,345 / 1,912 / 217 per month Apr–Aug |
| Tracked files | 14,516 (4,014 Swift, 1,416 C#, 1,148 TS, 1,125 Kotlin, 925 mjs, 313 .log, 531 .png) |
| `.git` size | 9.9 GB (pack 8.62 GiB, 483K objects) |
| Remote branches / open PRs | 5,468 / 91 |
| Workflows | 84 files; last-run 51 success / 18 fail / 9 never-run / 3 skipped / 2 hung |
| `main` last 60 runs | 38 success / 13 fail / 9 skipped |
| Required checks | 10 contexts; merge queue ALLGREEN, median 20 min, p90 52 min |
| Tests | ~21,000 across 9 surfaces; AgentLens Active 6,299; Core 3,228; Daemon 2,117; Mobile 1,596; functions 1,739; Windows 3,132; Android 1,916 |
| SwiftPM targets | 59 in Core (37 lib, 11 test, 5 exec, 3 binary), acyclic |
| RPC surface | 216 methods, 17 capability groups, protocol v1 |
| Cloud Functions | 163 handlers, 147 `onCall` sites, 140 `maxInstances` declarations |
| Firestore | 17 top-level + 59 user subcollections, 177 rule functions, 92 composite indexes, rules 222 KB |
| Largest production file | 1,930 lines (`LinuxComputerUseInputAdapter.swift`); size budget 2,000, 0 over |
| Largest type by extension family | `ChatSessionController*` 16 files / 4,365 lines |
| Footguns | `try!` 0; Kotlin `!!` 0; Rust `unwrap` 0; TS `as any` 0; Swift empty catch 0; C# empty catch 19 |
| `try?` untagged | Daemon 475, Mobile 428, Core 463, AgentLens/Views 230 (gate covers AgentLens/Services only) |
| `[String: Any]` sites | 2,311 (budget covers 1,190) |
| Concurrency escapes (non-test) | 129 `@unchecked Sendable`, 103 `nonisolated(unsafe)`, 58 `Task.detached` |
| Lint suppressions (non-vendor) | 9 swiftlint, 2 eslint, 20 `@Suppress`, 4 `#[allow`, 5 `@ts-ignore`, 37 `@ts-expect-error` |
| Hotfix tags on 1.0.40 | 37 in 14 days |
| Human authors | 1 |

### C. Claimed vs verified (ops and security)

| Claim | Verified? | Evidence |
|---|---|---|
| Staging/prod Firebase separation | Config yes; never exercised | `.firebaserc`; `deploy-staging-trusted.yml` has never run |
| Deploys gated on tests and health checks | Gates exist; lane dead since 08-04 | `deploy-production.yml:834-870` |
| Sub-minute rollback | Script exists, untested, wrong project id in docs | `scripts/ops/rollback-revision.sh`; `rollback-automation.md` |
| Ring rollout 1→5→25→100% | Server-side Remote Config only; no client ring code found | `scripts/rollout.mjs` |
| SLOs with alerts | Defined as code; live state unverified since 08-03 | `functions/scripts/ops-alert-policy-definitions.mjs` |
| Stripe webhooks idempotent | Yes | `stripe.ts:154-215` |
| `verify-resilience-wiring` enforced in CI | No required check runs it | only failing harness and blocked deploy lane |
| Per-user Firestore isolation | Yes | `firestore.rules:35-38, 1936-2014` |
| Entitlements server-only | Yes | `firestore.rules:1970` |
| Content sealed on-device | Content yes; metadata and display names plaintext | `SignalAtRestSealer.swift`; `insightsHostedAnswer.ts:283-293` |
| App Check enforced | Yes on callables; console side unverifiable | `.env.burnbar.production:40`; `auth.ts:53-61` |
| Phone control signed with replay protection | Yes | `PhoneControlAuthorityValidator.swift:90-148` |
| Daemon trusts only signed peers | Yes in release | `OpenBurnBarDaemonMain.swift:143-162` |
| SLSA build provenance | No; SBOM attestation | `supply-chain-provenance.yml:139-143` |
| Secrets never in repo | Yes | `defineSecret` everywhere; `.secrets/` ignored; baseline empty |
| Quarantined tests not compiled | Quarantine drained; ~100% of app tests compile | `AgentLensTests/Quarantine/` contains 0 Swift files |

### D. Representative evidence

- Split admitted to dodge the size gate: `MercuryRouter+Routing.swift:11` ("to satisfy the Swift file-size budget"); base file has 1 private member vs 67 internal.
- Ratchet contradiction: `.swiftlint.yml:212-214` raised `file_length` 5,950→6,130 after test growth, 30 lines below "do not raise".
- Tautological test: `AgentLensTests/Active/Parsers/ClaudeCodeParserTests.swift` defines its own fake parser and asserts the fake returns empty.
- High-value test: `OpenBurnBarDaemon/Tests/.../BurnBarDaemonServerRPCSearchTests.swift` (real socket, real SQLite, injection rejected).
- Duplication: `PopoverQuickSwitchView.swift` vs `DashboardQuickSwitchView.swift` share 525 identical lines; flagged 2026-06-30 item #19; unchanged.
- Data baked into three languages: `SwarmBackground.kt` (764 `ShapePoint` literals), `SwarmProviderLogoDotMap.swift`, and a committed 670 KB built bundle `windows/app/OpenBurnBar.App/Resources/SharedUi/assets/index-CeVJulmk.js`.
- Release tracing in a security coordinator: `ComputerUseSessionCoordinator.swift:24-26` unconditional `NSLog`, 78 call sites; `MercuryRouter.swift:41-45` correctly gates on `#if DEBUG`.
- Main-thread I/O timer: `CastleGreatHallView.swift:20` every 3 s → synchronous directory walk and `Data(contentsOf:)`.
- Version drift: `project.yml:16` 1.0.40; `project.yml:949` iOS 1.0.2; `windows/packaging/msix/Package.appxmanifest` 0.1.0.0; `functions/package.json` 1.0.0.

### E. Files inspected

Roughly 250 files across all six lanes, including: `OpenBurnBarCore/Package.swift`, `OpenBurnBarDaemon/Package.swift`, `project.yml`, `OpenBurnBarDaemonServer.swift` and the `RPC/` handler family, `BurnBarRPCContracts.swift`, `BurnBarRPCCapability.swift`, `ClaudeCodeParser.swift`, `CodexParser.swift`, `BufferedLineSequence.swift`, `ParserResourceGovernor.swift`, `UsageAggregator.swift`, `RefreshBackgroundWork.swift`, `DataStoreCoordinator.swift`, the `UsageStore+*` and migration files V1–V64, `UsageSyncService.swift`, `DownloadSyncService.swift`, `ComputerUseSessionCoordinator*.swift`, `PhoneControlAuthorityValidator.swift`, `PhoneControlReceiver.swift`, `ControllerKeyPinStore.swift`, `IrohPairingReplayGuard.swift`, `SignalAtRestSealer.swift`, `MercuryRouter*.swift`, `VideoEncoder.swift`, `ScreenCapturePipeline.swift`, `BitrateController.swift`, `OpenBurnBarStartupRecovery.swift`, `OpenBurnBarDaemonManager+Lifecycle.swift`, `AgentLensApp+Bootstrap.swift`, `GatewaySettings.swift`, `CloudSyncSettings.swift`, `firestore.rules`, `firestore.indexes.json`, `storage.rules`, `firestore-rules-tests/*`, `functions/src/{index,logging,sentry,resilience,resilienceHelpers,runtimeOptions,health,auth,triggers,rollupCounters,rollupCompute,rollupPendingDeltas,benchAssistant,insightsHostedAnswer}.ts`, `functions/src/callables/{stripe,escrowDeviceCallables,escrowDeviceRevoke,knowledgeSearch,encryptedSearchQuery,cliAgentMissions}.ts`, `functions/src/__tests__/bola/callableBolaHarness.ts`, `functions/src/security/endpointAuthorizationCatalog.generated.ts`, `functions/.env.burnbar.production`, `functions/.env.burnbar-staging`, `services/hosted-mcp/src/*`, `crates/openburnbar-domain-core/domain-core/src/{pricing,hermes}.rs`, `android/.../SwarmBackground.kt`, `android/.../FirestoreRollupMergerTest.kt`, `windows/app/OpenBurnBar.App/Chat/ChatSurfaceViewModel.cs`, `windows/tests/**`, `.github/workflows/{deploy-production,deploy-staging,deploy-staging-trusted,deploy-firestore,deploy-hosting,deploy-cloud-run,release,fast-feedback,burnbar-ci-gate,pr-native-fast,app-pr-gate,headless-app-build,openburnbar-pr-harness,codeql,codeql-pr,codex-nightly-ci-repair,ops-plane-verify,ops-confidence,supply-chain-provenance,domain-core*}.yml`, `governance/*.json`, `budgets/*.json`, `scripts/diff-coverage*.sh`, `scripts/test-openburnbar-app.sh`, `scripts/ci/check-no-suppressions.sh`, `scripts/debt/*.sh`, `scripts/rollout.mjs`, `scripts/ops/*`, `tools/ipc/generate-burnbarrpc-canon.mjs`, `tools/schema-sync/*`, `.swiftlint.yml`, `.gitleaks.toml`, `.gitleaksignore`, `.gitattributes`, `README.md`, `AGENTS.md`, `SECURITY.md`, `docs/THREAT_MODEL.md`, `docs/OBSERVABILITY.md`, `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md`, `docs/ARCHITECTURE/*`, `docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md`, `docs/TECHNICAL_READINESS.md`, `docs/TECH_DEBT_METRICS.md`, `docs/architecture/macos-performance.md`, `docs/runbooks/{slos,oncall,rollback-automation,functions-break-glass}.md`, `docs/mobile-parity/mobile-parity-ledger.md`, `TECH_DEBT_AUDIT_2026-06-30.md`, `DILIGENCE_REPORT_2026-07-14.md`, `CHANGELOG.md`, `NAMES.md`.

### F. Commands run (all read-only)

`git log`, `git shortlog`, `git ls-files`, `git rev-list --objects --all | git cat-file --batch-check` (blob sizes), `git count-objects -vH`, `git ls-remote --tags`, `git branch -r`, `git status`, `git diff --stat`; `gh api repos/Imagine-That-Ai/BurnBar/branches/main/protection`, `gh api .../rulesets`, `gh api .../actions/workflows`, `gh run list` (global, per-workflow ×84, `--branch main`, `--event merge_group`), `gh run view --json jobs` / `--log-failed` for the latest failed runs of the deploy, app gate, harness, CodeQL, DAST, and promotion-proof lanes, `gh pr list` (open and merged), `gh release list`; `rg` counts and searches excluding `.build`, `Vendor`, `node_modules`, `.claude`, generated directories; a link checker over README and 40 sampled docs. No CI runs were triggered, re-run, or cancelled.
