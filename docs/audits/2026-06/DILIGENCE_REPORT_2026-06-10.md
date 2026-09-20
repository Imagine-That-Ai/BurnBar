# OpenBurnBar — Full-Stack Technical Diligence Report

**Date:** 2026-06-10 · **Branch reviewed:** `perf/deferred-round-2-2026-06-10` (working tree as-is)
**Method:** 6 specialist review agents + 22 independent adversarial verification agents (28 agents, ~2.0M tokens, 927 tool invocations), including live checks against GitHub (branch protection, PR review history, CI run logs) and GCP (alert policies, deployed state).
**Verification ledger:** 11 findings confirmed exactly · 11 partially confirmed · 0 refuted · 4 severities downgraded on evidence · 1 claimed launch blocker downgraded to serious.
**Status:** Internal working document — do **not** commit (the review itself flags root-level self-review docs as hygiene debt).

---

## 1. Executive Summary

This is a ~10-week-old monorepo (first commit 2026-04-04, 1,365 commits, 5,225 tracked files across Swift/Kotlin/TypeScript/Python/Rust) built by effectively one person plus AI agents — and it is, by a wide margin, the most sophisticated solo-built codebase of this scale the review encountered. That is both the headline strength and the headline risk.

The quality is **bimodal**. At the security boundaries and in the delivery machinery, this code is genuinely impressive: a privileged macOS daemon split into seven least-privilege executables behind code-signature peer authentication with hardened-runtime checks; 4,179 lines of disciplined, owner-scoped Firestore rules backed by 373 rules-test files; App Check that fails closed in production; a store-and-forward gateway that provably never decrypts; a TypeSpec schema canon emitting three languages with CI drift gates; a release pipeline that re-runs the full test matrix at the tag before signing, notarizing, stapling, and attaching an SBOM; 40 append-only client DB migrations; and CI gates that treat *unexpectedly skipped security proofs as failures* — a pattern most Series B teams don't have.

At the edges, the seams show. The two iOS/macOS client surfaces are built from 45+ files exceeding 1,500 lines (HermesService.swift: 4,870). Quality enforcement is partly theater: SwiftLint provably never executes in CI, detekt is configured but never run, 4 of 6 "Code Quality" jobs pipe to `|| true`, the diff-coverage gate awards 100% to whole surfaces on test-file *name presence*, and a script once silenced detekt's MagicNumber rule by generating `const val VAL_3 = 3` across 79 Kotlin files. Most damning: the entire scheduled QA/monitoring plane (nightly E2E, prod health synthetic, DAST, weekly ops verification) has been red for its whole observable history — the nightly has executed **zero tests since inception** (missing protoc) — while daily merging continued. And **zero of all 211 merged PRs have ever had a human review**, despite branch protection nominally requiring one.

The verdict in one sentence: **the code would pass diligence; the operating process would not — yet.** Investors would be impressed *and* nervous, in that order.

## 2. Final Verdict

**Launchable with major caveats** — one focused sprint away from "Strong startup-grade foundation."

- **Professionalism:** High at the artifact level (top-decile for stage in security architecture, CI engineering, release rigor); mid at the process level (review bypass, ignored red monitoring, enforcement theater, hygiene scars).
- **Launch readiness:** Not yet. No confirmed launch-blocking *code* defect survived adversarial verification, but the launch *posture* has four genuine gates: a dead scheduled-monitoring plane with no uptime checks on any user-facing surface; no auto-update channel for a DMG that installs a privileged daemon; no CI deploy path for Firestore security rules/indexes; and a required security gate pinned to a mutable personal-fork branch.
- **Series A diligence readiness:** Survivable with pointed questions, not a fail. A strong diligence team's memo would read: "exceptional individual output, real cryptographic and infrastructure engineering, but we are underwriting a bus-factor-of-one operation whose safety systems are not currently governing what ships."

## 3. Scorecard

| Category | Score | Rationale | Severity profile |
|---|---|---|---|
| Architecture | **7/10** | Daemon isolation, schema canon, and ADR discipline are near-world-class; offset by 3–6× cross-language re-implementation of behavioral logic, a 288-file Core kitchen sink, and god-file concentration | 4 serious (2 confirmed, 2 partial) |
| Code Quality | **6/10** | Line-level code is disciplined (zero `any`, fail-closed crypto, 19 TODOs total, verified-low duplication); enforcement apparatus is partly cosmetic and was once gamed (`VAL_3`) | 3 serious (1 confirmed, 2 downgraded) |
| Reliability / Ops | **6/10** | Real alert plane, real rollbacks, exemplary daemon lifecycle — but single prod environment, rules with no CI deploy, 5 laptop-deployed services, no uptime checks, bus factor 1 | 6 serious (3 confirmed, 1 downgraded) |
| Security | **7/10** | Rules/App Check/gateway/peer-auth genuinely strong and verified in code; gateway crypto ships as bytecode with the provenance gate not in PR CI; Android lacks at-rest sender-auth parity | 3 serious (1 confirmed, 2 partially) |
| Performance / Scalability | **7/10** | Perf-literate (measured 65-finding sweep, cadence coordinator, index-coverage gate pinned to a real outage); rollup full-rebuild loop, zero retention/TTL, relay backpressure are the ceilings | 3 serious (1 upheld, 2 downgraded) |
| Testing / CI / Delivery | **5/10** | Best-in-class gate *engineering* undermined by operating reality: red nightly executing zero tests, presence-based coverage, no E2E tier, vacuous XPC auth tests, zero human reviews ever | 1 blocker→serious, 5 serious (4 confirmed) |
| Documentation / Maintainability | **7/10** | Real runbooks with quantified SLOs, 9 ADRs, curated TODOS.md; QUICKSTART points at the wrong repo, codename sprawl untaxed by any NAMES.md | mostly medium/polish |
| Overall Professionalism | **7/10** | The artifacts say senior staff engineer; the process says solo founder moving very fast | — |
| Launch Readiness | **5/10** | Four genuine pre-launch gates (monitoring, auto-update, rules deploy, fork pin) + money-path idempotency | — |
| Series A Diligence Readiness | **6/10** | Survives with pointed questions on bus factor, review bypass, and the out-of-repo crypto | — |

**Overall weighted score: 64/100** (weights: Security 20%, Architecture 15%, Reliability 15%, Testing 15%, Code Quality 10%, Performance 10%, Professionalism 10%, Docs 5%).
**Confidence: High.** Every top finding was independently adversarially verified against the working tree; several against live infrastructure (GitHub API, gcloud, CI run logs). Zero verifications refuted the reviewers outright; four downgraded severity.

## 4. What Inspires Confidence (verified, not vibes)

1. **Privileged-surface engineering.** Daemon split into 7 least-privilege executables (`OpenBurnBarDaemon/Package.swift`); XPC peer auth validates Apple anchor + Team ID + hardened-runtime + library-validation flags programmatically (`PrivilegedPeerAuthenticator.swift:142-166`); atomic `rename(2)` binary swaps with SHA256 skew detection in the upgrade path.
2. **Server-side security posture.** 4,179-line `firestore.rules` uniformly owner-scoped via `ownsUserNamespace()`, server-only collections locked `if false`, 373 rules-test files; App Check refuses to start in prod if disabled (`functions/src/config.ts:77`); Hermes gateway enforces PoP nonce replay protection + per-(uid,client) rate limits and *never decrypts* (sealed-only writes, plaintext rejected).
3. **CI gate engineering.** `targeted-e2e-gate` fails when an expected security proof is *skipped* (`openburnbar-pr-harness.yml:889-926`) — the classic skip-equals-green hole, closed. Hang-classifier retries only infra flakes and is itself tested. Index-coverage gate includes a negative-injection test pinned to a real June 2026 prod outage.
4. **Release rigor far above stage.** `release.yml` (985 lines): secret-scans the publishable tree, re-runs the entire multi-surface matrix at the tag, deterministic inside-out codesign, notarize + staple, SBOM/VEX/checksums/GPG.
5. **Honest privacy claims.** `website/src/data/crypto-claims.generated.ts` is CI-generated with a drift gate and candidly labels the gateway lane "homegrown Double Ratchet" and libsignal "wired in, not activated" — marketing that matches code is rare and diligence-grade.
6. **Reproducibility and craft signals.** Lockfiles in every ecosystem with CI drift checks; every GitHub action SHA-pinned; 40 append-only GRDB migrations; 19 TODO markers in the entire monorepo; jscpd-verified near-zero duplication; a real, measured 65-finding perf sweep (module cold-load 454→238ms, ~97% gateway write reduction).

## 5. What Would Alarm a Serious Reviewer

1. **The safety systems are not governing what ships.** Zero human reviews on 100% of all 211 merged PRs (verified via API, including crypto/privileged-input PRs #298/#299/#301/#302) despite `required_approving_review_count=1` + `enforce_admins=true` — implying routine toggle-bypass. Simultaneously, nightly-e2e failed 12/12 runs (zero tests executed — missing protoc), ops-confidence failed 2/2, DAST has been crashing on a permissions error its entire life, and merging continued daily. *Confirmed; the "no monitoring at all" framing was refuted — 9 channel-backed GCP alert policies are live — but nothing watches the web surfaces or the watchers themselves.*
2. **Bus factor 1, in code and in ops.** ~85% of commits from one person; 5 backend services deploy only from that person's laptop with no clean-tree guard; all rollbacks and runbooks assume one operator's credentials and memory.
3. **The flagship crypto's server half is outside the repo.** CI checks out `Ajnunezg/hermes-agent@ajnunezg/burnbar-gateway-e2ee` — a *mutable branch of a personal fork, not SHA-pinned* — pip-installs it, and feeds the result into the **required** PR check. The local gateway runtime exists only as `.pyc` bytecode (zero tracked files under `gateway/`). *Partially confirmed: source IS inspectable at the hash-pinned public fork commit, and the C-5 provenance gate exists and fails closed — but it runs only on a weekly cron, not PRs.*
4. **Quality-gate theater.** SwiftLint "informational," `continue-on-error`, provably never executed in CI (live log: "swiftlint not installed; skipping"); detekt configured, never run; diff-coverage awards `percent:100.0, method:'test_file_presence'` to whole surfaces (`scripts/diff-coverage.sh:108-148`); the privileged-peer "rejects" test never invokes the authenticator (`PrivilegedPeerAuthenticatorTests.swift:13-20`); `VAL_3 = 3` constants ×249 gaming detekt.
5. **Hygiene scars a reviewer finds in the first ten minutes.** `fix_silently.py` (broken regex-repair script for a botched mass edit, founder's home path hardcoded) at root; `verify-ops-plane-summary.json` committed with `"launchGateVerdict": "NO_GO"` under a commit titled "complete GTM launch readiness"; a 34MB `.aar` binary tracked in git; 20 tracked log files; QUICKSTART cloning the wrong repository.

## 6. Launch Blockers (fix before public launch)

After adversarial verification, none of these is a "the code is broken" defect — they are launch-posture gates. For a privacy-branded product installing a privileged daemon, all five should be treated as blocking:

| # | Gate | Evidence | Why blocking |
|---|---|---|---|
| LB-1 | **Dead scheduled-monitoring plane + zero uptime checks on user-facing surfaces** | nightly-e2e 12/12 red (zero tests run); no uptime policy targets burnbar.ai / app.burnbar.ai / relay; hosting auto-deploys to prod on merge with no post-deploy smoke (`deploy-hosting.yml:93-124`) | First outage is user-detected. The 9 live GCP policies cover functions only |
| LB-2 | **No update channel for the DMG** | No Sparkle/appcast/updater code anywhere (greps across release.yml, project.yml, AgentLens/) | An app that injects system-wide HID input has no fleet remediation path when (not if) a security fix ships |
| LB-3 | **Firestore rules & indexes have no CI deploy path** | Only `scripts/deploy-iroh-relay.sh:94-96` ever deploys rules; nothing deploys indexes; CI tests rules it may never ship | Repo can show a fixed, tested rule while prod enforces the old one indefinitely — confirmed exactly |
| LB-4 | **Required security gate consumes a mutable personal-fork branch** | `openburnbar-pr-harness.yml:683-697` checks out and pip-installs a branch ref with CI credentials in scope | Force-push silently changes what the required check proves; supply-chain vector on the E2EE proof |
| LB-5 | **Stripe webhook lacks event-level idempotency/ordering** | `stripe.ts:463-518` switches on event.type with no event.id ledger or created-comparison (contrast: App Store path does this right) | Out-of-order `subscription.updated` after `.deleted` re-grants paid entitlement (bounded by expiresAt) |

Also resolve before shipping this branch: the **uncommitted dirty-tree privileged-input changes** — the new `--dispatch-stdin` path authenticates via `getppid()` (race-prone vs. audit-token), and `typeCredential` (types the macOS login password) bypasses the capability-token gate that `input` operations require (`PrivilegedInputDispatchHandler.swift:34-40`). *Verifier judged exploitation unrealistic (entitlement + code-sign backstops) — but it contradicts the documented threat model and is the would-be-shipped code.*

## 7. Diligence Risks (what comes up in fundraising)

1. **Bus factor / key-person dependency** — the dominant theme; investors underwrite the operating capability, not just the code.
2. **Review bypass as standard practice** — 0/211 PRs reviewed; the gap between configured and operating controls invites discounting of *all* stated controls.
3. **E2EE auditability** — custom Double Ratchet + custom HPKE in production while official libsignal sits "wired in, not activated"; gateway runtime as bytecode; a diligence cryptographer must leave the repo to audit the headline feature.
4. **Single prod environment** — no staging/canary anywhere; console hard-codes prod Firebase config as build defaults; console ships from `main` while functions ship on tags (skew window confirmed: latest tag v2026.6.5 vs. hundreds of newer commits).
5. **Deploy credentials** — long-lived `GCP_SA_KEY` JSON in GitHub secrets with full-project rights; WIF declared (`id-token: write`) but unused.
6. **Cost curve** — zero retention/TTL anywhere (client purge hook is a literal no-op, `RefreshOrchestrator.swift:66-68`); dashboard-open rollup refresh costs up to ~360 reads; unit economics degrade with account age.
7. **Android crypto parity** — at-rest sender-auth and CloudVault trust-chain verification exist in Swift only; no Kotlin equivalent found (grep-verified).
8. **AGPL/licensing posture** — corresponding-source archive admittedly excludes the gateway runtime (`third_party/hermes-agent/manifest.json` auditNote); counsel engagement already underway (sensible).

## 8. Hidden Rewrite Risks (12–24 months)

| Area | Risk | Signal |
|---|---|---|
| iOS Hermes/media layer | **De facto rewrite required** before 5+ engineers can work in parallel | HermesService 4,870 / HermesTabView 4,518 / ScreenShareViewerView 4,497 lines; 46 files >1,500 lines |
| Cross-language behavioral logic | Per-feature 3–6× implementation tax; drift = platform-specific prod bugs | Relay fallback semantics held in sync by prose comments ("Matches the Android relay contract"); model catalog = 5+ hand-edited files |
| OpenBurnBarCore | 288-file kitchen sink at the bottom of every dependency graph; daemon links UI code | Confirmed exactly; "understated" per verifier |
| Remote-control stack | Gen-2 Rust engine (`crates/burnbar-remote`, 8 sub-crates, own ADR) in-tree, **built by no CI** — shadow architecture telegraphing a planned re-platform | Confirmed |
| Deploy plane | Staging project + WIF + CI for 5 services + config management (50 env keys inlined at deploy time) is effectively a rebuild | `deploy-production.yml:113-165` |
| Crypto consolidation | libsignal cutover = re-plumbing every gateway/at-rest lane + sealed-envelope migration | `runtime-readiness.json` status `not_ready` |
| Scheduled-worker backbone | Serial workers (~600 users/hr rollup ceiling) → Cloud Tasks fan-out; retention scheme | `scheduled.ts:55-101` |
| Daemon HTTP gateway | Hand-rolled 3,562-line HTTP/1.1+SSE server on Network.framework | A maturing team replaces this with a vetted server |
| CI harness | 950-line bespoke PR harness tuned to one founder; no Xcode pinning (macos-26 image default) | A hired team rewrites this for a merge queue |

**Net rewrite risk: moderate, and unusually well-telegraphed.** The data models (per-user Firestore subtrees, counter buckets, frame-capped transports, append-only migrations) are sound; the rewrites are orchestration-layer, not product-level.

## 9. Top 10 Highest-Leverage Improvements (ranked)

1. **Resurrect the scheduled QA/monitoring plane and make red loud** (LB-1) — protoc install in nightly; `if: failure()` paging; fix DAST permissions; uptime checks on all user-facing hosts; post-deploy smoke on hosting.
2. **Ship an auto-update channel** (LB-2) — Sparkle + appcast in release.yml, or launch App Store-only.
3. **CI deploy + drift detection for Firestore rules/indexes** (LB-3).
4. **Stand up staging + kill the laptop deploys** — second Firebase project, GitHub environments, WIF instead of GCP_SA_KEY, the 5 Cloud Run services into CI with clean-tree provenance.
5. **SHA-pin (then vendor) the hermes-agent dependency; run the C-5 provenance gate on PRs** (LB-4).
6. **Make the test gates measure reality** — real coverage instead of presence; behavioral XPC-auth negative tests; enable the E2E tier (Android instrumented, iOS UITests, red-team socket suite nightly).
7. **Get a second human (or structured external reviewer) on crypto/privileged/billing paths** — and stop toggling enforce_admins.
8. **Fix the rollup full-rebuild loop + add retention/TTL** (the verified perf ceiling and the COGS story).
9. **Decompose the god files and split OpenBurnBarCore** (UI-free kernel for the daemon).
10. **De-theater the quality lanes + hygiene sweep** — enforce SwiftLint/detekt or delete the configs; remove `|| true` tier or triage it weekly; `git rm` fix_silently.py, NO_GO artifact, screenshot, tracked logs, 34MB aar; fix QUICKSTART.

## 10. Specific Questions, Answered

1. **What does it feel like?** A credible production system wearing prototype scar tissue — world-class at the security boundaries and delivery machinery, ambitious-but-messy in the client god-files and ops process. Not hacky; not yet investor-clean.
2. **Launched tomorrow, what goes wrong first?** A bad merge auto-deploys to burnbar.ai/app.burnbar.ai (CSP hash drift or console/functions skew); nothing pages; users report it. Second: a heavy always-on user trips the rollup full-rebuild loop. Third: a security fix needs to reach installed DMGs and can't.
3. **What worries diligence most?** Bus factor 1 operating with the review requirement bypassed and the monitoring plane red — i.e., the controls exist but are not governing.
4. **What creates confidence?** The verified security architecture (rules, App Check, never-decrypt gateway, peer auth), the release pipeline, the schema canon, and the honesty of the crypto-claims page.
5. **Architecture: accelerant or brake?** The boundaries accelerate; the 3–6× duplication tax and god files brake. Net: accelerant for 1–3 people, brake at 5+ without the Phase-2 work.
6. **Hidden rewrite risk?** Moderate, well-telegraphed, orchestration-layer not product-layer (see §8).
7. **Real taste and discipline?** In the code, unambiguously yes (fail-closed crypto idioms, 19 TODOs, why-comments at point of use, zero `any`). In the enforcement layer, discipline is currently personal, not institutional — that is the thing to fix.

---

## 11. Detailed Improvement Plan

Severity sourced from verified findings only. Effort: S = <1 day · M = 1–4 days · L = 1–3 weeks.

### Phase 0 — Launch gates (do before any public launch; ~1–2 weeks total)

**P0-1. Turn the monitoring plane back on and point it at users** (LB-1) — Effort M
- Add the protobuf install step to `nightly-e2e.yml` / `.github/actions/openburnbar-test-matrix/action.yml` (copy from `openburnbar-pr-harness.yml:291-297`).
- Add `permissions: issues: write` + an `if: failure()` issue-creation/notification step to nightly-e2e, ops-confidence, and the ZAP jobs (fixes the 403 crash).
- Extend `functions/scripts/ops-alert-policy-definitions.mjs` with GCP uptime checks + alert policies for `burnbar.ai`, `app.burnbar.ai`, the relay WSS endpoint, and hosted-mcp.
- Append a post-deploy smoke job to `deploy-hosting.yml`: curl both hosts, assert 200 + key marker text + CSP header parses; fail the workflow (and notify) otherwise.
- **Done when:** a forced-red nightly opens an issue within minutes; a synthetic outage on app.burnbar.ai fires a channel-backed alert; a hosting deploy with a broken CSP fails the workflow.

**P0-2. Fleet remediation path for the DMG** (LB-2) — Effort L
- Integrate Sparkle: `SUFeedURL` + EdDSA keys in the app; appcast generation + signing in `release.yml`; serve appcast from hosting.
- Alternative if timeline forces it: launch App Store-only and gate direct-DMG distribution on Sparkle landing.
- **Done when:** an installed test build detects, downloads, verifies, and applies a signed update end-to-end.

**P0-3. CI deploy + drift detection for Firestore rules/indexes** (LB-3) — Effort S/M
- New `deploy-firestore.yml` (or a job in deploy-production.yml): on merge to main touching `firestore.rules`/`firestore.indexes.json`/`storage.rules`, run the emulator rules tests, then `firebase deploy --only firestore:rules,firestore:indexes,storage`.
- Add a weekly drift check: fetch deployed rules via API, hash-compare against repo, alert on divergence.
- **Done when:** a merged rules change reaches prod with zero human steps, and the drift check proves repo↔prod parity.

**P0-4. Pin the external fork in the required gate** (LB-4) — Effort S (pin) / M (vendor)
- Change `openburnbar-pr-harness.yml:683-687` checkout to an immutable commit SHA; document the bump procedure.
- Follow-up (Phase 2): vendor the gateway source under `third_party/` behind the existing C-5 manifest, and run `verify-vendored-agent-source.sh` in PR CI rather than the weekly cron.
- **Done when:** a force-push to the fork branch cannot change any required check's result.

**P0-5. Stripe webhook idempotency + ordering** (LB-5) — Effort S/M
- In `stripeBurnBarProWebhook` (`functions/src/callables/stripe.ts:463-518`): transaction-keyed `event.id` dedupe ledger (mirror the top-up pattern at `shared.ts:1151-1191`), and either compare `event.created` against the stored entitlement's event timestamp or re-fetch the subscription from Stripe before writing.
- **Done when:** a replay test delivering `subscription.deleted` then a stale `subscription.updated` leaves the entitlement canceled.

**P0-6. Settle the dirty-tree privileged-input changes** — Effort M
- Route `typeCredential` through `VirtualHIDBridgeCapabilityGate` like `input` (`PrivilegedInputDispatchHandler.swift:34-40`), or document precisely why the credential path is differently gated.
- Replace `getppid()`-based caller auth in `dispatchOneShotFromStandardInput()` with the audit-token path used by the XPC listener — or do not ship the `--dispatch-stdin` helper.
- **Done when:** every daemon-dispatched operation passes the capability gate; the red-team suite (`RUN_PRIVILEGED_INPUT_REDTEAM`) runs in nightly CI and passes.

**P0-7. Defuse the rollup full-rebuild loop** — Effort M
- `functions/src/rollups.ts:1268-1291` + `scheduled.ts:43-84`: set explicit `timeoutSeconds`/`memory`; paginate the `usageRef.get()` full scan; clear/age `lastErrorCode` outside the quiet window; cap consecutive rebuild attempts per user with a circuit breaker + alert.
- **Done when:** a synthetic user with a 100k-doc usage history either rebuilds successfully in pages or trips the breaker — no 5-minute delete/scan loop.

### Phase 1 — Diligence hardening (weeks 2–6)

**P1-1. Institutionalize review** — Effort S (policy) + ongoing
- Stop toggling `enforce_admins`. For crypto / privileged-input / billing paths, require one human review — an external security-literate advisor if no second engineer exists. Write the bypass policy down (when solo-merge is acceptable, what compensating checks apply).

**P1-2. Behavioral tests on the XPC auth boundary** — Effort M
- Refactor `PrivilegedPeerAuthenticator` for injectable SecCode evaluation; add negative tests: wrong Team ID, unsigned binary, missing hardened-runtime/library-validation flags → rejected. Replace the vacuous `test_rejectsWhenCodeSignatureValidatorFails`.

**P1-3. Make diff-coverage measure coverage** — Effort M
- Remove directory-existence auto-pass and stem-substring matching from `scripts/diff-coverage.sh:108-148`; produce real per-file coverage for Core/Daemon/Mobile lanes; ratchet thresholds; require justification strings on `cov:ignore`.

**P1-4. De-theater the quality lanes** — Effort M
- Install SwiftLint in CI (brew) and fail on new violations against a baseline; run detekt in the Android lane; add ruff/mypy for `tools/hermes-platform-burnbar/adapter.py`; cargo clippy for both crates.
- Delete `|| true` from `code-quality.yml` jobs one by one (knip, dependency-cruiser, size-limit, buildHealth) — promote to enforcing or remove the job; an advisory lane red >7 days gets promoted or deleted.
- Fix the `VAL_3` constants: rename to semantic names where a name exists, revert to literals + targeted suppression where it doesn't.

**P1-5. Environment separation + deploy identity** — Effort L
- Second Firebase/GCP project (`burnbar-staging`); deploy hosting+functions to staging on main-merge, prod on tag or environment-protected approval; GitHub Environments with protection rules.
- Replace `GCP_SA_KEY` with Workload Identity Federation (the `id-token: write` blocks already exist); delete the legacy `FIREBASE_TOKEN` fallback.
- Move the 5 Cloud Run service deploys (`scripts/deploy-*.sh`) into workflows with clean-tree guards and commit provenance labels.

**P1-6. Close the console/functions skew window** — Effort S/M
- Either deploy functions from main (post-staging) or add a contract check: console build asserts the deployed `FUNCTION_VERSION` exposes every callable it references; block hosting deploy otherwise.

**P1-7. Stand up a minimal real E2E tier** — Effort L
- Set `ANDROID_E2E_ENABLED` and let the instrumented smoke actually run nightly (drop its `continue-on-error`); un-skip one iOS UITest happy path; add Playwright auth/escrow flow tests for the console; schedule the privileged-socket red-team suite on a macOS runner.

**P1-8. Widen supply-chain gates** — Effort S/M
- Extend `security-pr.yml` OSV/npm-audit to all lockfiles (`services/*`, `packages/*`, `apps/*`, `firestore-rules-tests`); add cargo-deny for `crates/burnbar-remote`; pip-audit for the adapter's extras; CodeQL on PRs for changed languages.

**P1-9. Hygiene sweep (half a day, outsized diligence ROI)** — Effort S
- `git rm`: `fix_silently.py`, `apple-login.png`, `verify-ops-plane-summary.json` (regenerate as CI artifact), `pensieve-route-snapshot.md`, the 20 tracked `.log` files (→ release/run artifacts), the 8 root self-review reports (→ `docs/reviews/` or out of tree).
- Move `Vendor/openburnbar-iroh.aar` (34MB) to LFS or a release artifact fetched at build.
- Fix `QUICKSTART.md` (correct org/repo, `--recursive`, remove unpublished tap); add `NAMES.md` mapping Hermes/Mercury/Floo/Pensieve/Horcrux/AgentLens↔BurnBar.

**P1-10. Android security parity** — Effort M/L
- Implement at-rest sender-auth verification + fail-closed fallback policy and the CloudVault trust-chain verifier in Kotlin (ports of `SignalAtRestSealer`/`SignalAtRestFallbackPolicy`/`MobileCloudVaultTrustedDeviceChainVerifier`), or feature-gate those payload types off Android until parity lands. Also fix the `runBlocking` main-thread teardown (`ScreenShareViewerScreenMainSections.kt:275`).

### Phase 2 — Structural debt (months 1–3)

- **P2-1. God-file decomposition** (top 10 by size on product-critical paths: HermesService, HermesTabView, ScreenShareViewerView, ProjectsView, ProviderPlanWizardView, FunctionsRepository…): extract embedded classes (e.g., `HermesCompositeRelayTransport` out of HermesService:3785) first — mechanical, low-risk, immediately reviewable.
- **P2-2. Split OpenBurnBarCore**: UI-free kernel package (models, crypto, contracts) + UI package; daemon links kernel only. Verifier confirmed the daemon currently compiles 68 SwiftUI-importing files it can never execute.
- **P2-3. Extend the schema canon to behavior**: encode the relay fallback matrix and the model catalog as generated data (TypeSpec/JSON single source → Swift/Kotlin/TS emitters), with cross-platform conformance vectors, retiring the "Matches the Android relay contract" prose-parity regime and the 7-file model-launch checklist.
- **P2-4. Retention + fan-out**: Firestore TTL policies on `usage`/`hermes_gateway_events`; implement the client purge no-op; migrate rollup/quota/reaper scheduled workers to Cloud Tasks sharded fan-out (removes the ~600 users/hour ceiling).
- **P2-5. Relay backpressure**: `bufferedAmount` watermarks + per-socket byte budget + slow-consumer disconnect in `relay.ts`; revisit single-Redis/us-central1 once non-US users matter.
- **P2-6. Decide `crates/burnbar-remote`**: fund it (CI builds, tests, dependency updates, a cutover plan) or remove it from the tree until active. Shadow architecture rots and confuses diligence.
- **P2-7. Vendor the gateway source** (completes P0-4): in-repo `third_party/` source with the C-5 gate on PRs; include in the AGPL corresponding-source archive (closes the manifest's own auditNote).
- **P2-8. Toolchain pinning**: `DEVELOPER_DIR`/Xcode pin for all Swift lanes + release; `rust-toolchain.toml`; pinned actionlint.
- **P2-9. CSP automation**: generate the ~90 inline hashes at build (Astro integration) into firebase.json, verified by the P0-1 post-deploy smoke.
- **P2-10. Finish the error-observability migration properly**: SwiftSyntax-based codemod (not regex) for the ~305 statement-position `try?` swallows, driven down via the existing `budgets/try-optional-baseline.json` ratchet; delete `fix_silently.py` history note in CHANGELOG.

### Ongoing discipline (institutionalize, not heroics)

- **Weekly red-run triage ritual**: every scheduled workflow's last run reviewed Monday; any red >7 days is paged work, not background noise.
- **Advisory-lane budget**: a lane may be advisory for max 30 days, then it enforces or dies.
- **Quarterly restore drill**: roll back functions + hosting + one Cloud Run service from a laptop that is not the founder's.
- **Risk acceptance register**: document the deliberate calls (avatar cross-tenant read, single-region, fake-SSE polling) in SECURITY.md so external reviewers read them as decisions, not leaks.
- **enforce_admins stays on.** If a solo-merge is genuinely required, the compensating control (AI review + full gate pass + post-merge external review within 72h) gets written down and followed.

---

## 12. Appendix

**Method.** Orchestrator + 6 specialist reviewers (architecture, code quality, reliability/ops, security/privacy, performance, testing/delivery), each producing scored, evidence-cited structured findings; the top 22 launch-blocker/serious findings were each handed to an independent adversarial verifier instructed to refute them against the working tree, CI history, and live infrastructure. 28 agents total; 927 tool invocations; ~2.0M tokens.

**Verification ledger.** 11/22 confirmed exactly (several "worse than claimed": e.g., 0 reviews extends to all 211 merged PRs; Android E2E gate is dead code — the gating repo variable does not exist). 11/22 partially confirmed. 0/22 refuted. Severity downgrades: no-staging (serious→moderate: tag-gated functions + health gates mitigate), bytecode-crypto (serious→moderate: hash-pinned public source exists), relay backpressure (serious→moderate: heartbeat bounds the stall), try?-migration (serious→minor), red-monitoring-plane (launch_blocker→serious: 9 live GCP alert policies exist and were verified enabled in production).

**Repo statistics.** 5,225 tracked files; 2,122 Swift (~696k lines), 852 Kotlin, 375 TS, 67 Python, 16 Rust; 1,365 commits since 2026-04-04; contributors: Alberto Nunez ~967, factory-droid 170, other agents ~25; 211 merged PRs; 27 CI workflows; 11 required checks on main; single Firebase project `burnbar`; latest functions tag v2026.6.5.

**Representative evidence index.** `firestore.rules` (4,179 lines); `functions/src/config.ts:77` (App Check fail-closed); `functions/src/hermesGateway.ts` (never-decrypts + PoP replay + rate limits); `PrivilegedPeerAuthenticator.swift:142-166` (hardened-runtime peer auth); `OpenBurnBarDaemonManager+Lifecycle.swift:154-190` (atomic binary swap); `openburnbar-pr-harness.yml:683-697` (fork checkout), `:889-926` (fail-on-skipped-proof); `scripts/diff-coverage.sh:108-148` (presence-based pass); `nightly-e2e.yml` + run 27275491790 (zero tests executed; DAST 403); `deploy-hosting.yml:93-124` (no post-deploy verification); `scripts/deploy-hermes-realtime-relay.sh:74,135-140` (dirty-tree laptop deploys); `functions/src/rollups.ts:1268-1291` (unpaginated full rebuild); `RefreshOrchestrator.swift:66-68` (no-op retention); `relay.ts:200-208` (no outbound backpressure); `stripe.ts:463-518` (no event ledger); `fix_silently.py`; `verify-ops-plane-summary.json` ("NO_GO"); `android/.../CLIAgentMissionDispatcher.kt:28` (`VAL_3`); `PrivilegedPeerAuthenticatorTests.swift:13-20` (vacuous test); `crates/burnbar-remote/` (unbuilt gen-2 engine); `website/src/data/crypto-claims.generated.ts` (honest claims).
