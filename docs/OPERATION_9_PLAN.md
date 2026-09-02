# Operation 9: BurnBar Diligence Remediation Program

**Goal:** take every diligence lane from the 2026-07-14 scores (Architecture 8, Code Quality 7.5, Reliability/Ops 5, Security 7, Performance 7, QA/Delivery 6.5) to **≥9/10 in a fresh adversarial swarm re-audit**, with a plan explicit enough that weaker implementation models cannot degrade quality.

**Acceptance bar (user-confirmed):**
1. Every lane independently re-scores ≥9 in a fresh 6-lane adversarial re-audit (same method as `audits/2026-07/DILIGENCE_REPORT_2026-07-14.md`).
2. "Mechanisms now, soak tracked": the plan completes when every fix is landed, first green proofs exist, and monitoring/gates are live. Time-series evidence (weeks of green runs and mission-enforcement observations) accrues on a tracked checklist (`docs/OPERATION_9_SOAK_LEDGER.md`) after plan completion.

**Source of truth for findings:** `audits/2026-07/DILIGENCE_REPORT_2026-07-14.md` (the committed audit archive) + the six lane reports in this session. Every packet below cites its originating finding.

**On approval, first action:** commit this plan into the repo as `docs/OPERATION_9_PLAN.md` (per house convention — plans live as committed repo markdown), plus the empty `docs/OPERATION_9_SOAK_LEDGER.md`, so every implementing agent reads the same contract from the tree rather than from a chat transcript.

---

## Context

A 6-lane diligence swarm (2026-07-14, vs origin/main `994bc55288`) scored the repo 74/100. The deficits are concentrated and named:

- **Ops (5):** production Cloud Functions frozen at 6/18; the unblocking fix (PR #1572) merged but never exercised; no deploy-freshness monitoring; alert issues rot open; no paging path.
- **QA (6.5):** Full Harness 0-green in 200 runs on main; nightly E2E never green; mobile XCTests never run pre-merge; no merge queue; test topology mid-relocation.
- **Security (7):** merged server-side fixes not deployed; hosted-Insights E2EE metadata leak; dead gateway rate limit with a lying test; 0-human-approval scanner governance; V-47 pre-push guard never installed.
- **Performance (7):** macOS `fetchCloudTotal` downloads 90 days of docs up to 2×/min; conversation indexing re-parses the full corpus every tick; no macOS CPU/energy regression gate.
- **Code Quality (7.5):** enforcement is Swift-first; linux-desktop TS never typechecked (live TS2386 on main); GL-engine fork dropped the low-power fix; Android dead-by-construction quota refresh; Windows dead Browse buttons; no shared C# analyzer infra.
- **Architecture (8):** zero Rust domain-core promotions; mission-authority enforcement unflipped; Windows cloud-sync wire schema ungated; Kernel at 99.7% of its ceiling.

The program converts every finding into a work packet with exact anchors, invariants, verification commands, and stop-conditions.

---

## Definition of "9" per lane (re-audit rubric)

| Lane | The re-audit must find |
|---|---|
| Ops | Proven prod deploy path (green functions + Cloud Run deploys, incl. one dry-run + one real), deploy-freshness monitoring that would catch a repeat freeze, alert→action loop closed (June issues closed with dispositions), paging path exists, release requires ≤2 attempts or has a documented retry-free path |
| QA | Full Harness green on main (first green + required/informational split so red can't be ambient), nightly E2E green once, mobile XCTests executing pre-merge as a required check, merge queue or strict-base, test relocation train landed |
| Security | No merged-but-undeployed security fixes; Insights digest sends no sealed-domain plaintext; rate limits wired + honest tests; scanner governance has a human/CODEOWNERS gate; V-47 tags extracted+deleted+rotated with guard installed |
| Performance | Rollup-based cloud totals (no 90-day fan-out); indexing incremental or explicitly bounded; a macOS CPU/energy regression gate exists in CI |
| Code Quality | linux-desktop typecheck+lint gated (TS2386 fixed); gl-engine de-forked with parity gate; Android/Windows edge defects fixed with regression tests; C# shared build props + analyzers; enforcement parity table documented (which gate binds which stack) |
| Architecture | ≥1 Rust domain promoted to `rust` mode on ≥1 platform via the evidence gate; mission authorizeRemote enforcement flipped (or divergence-zero soak evidence + dated flip plan); C# schema mirror gated; Kernel ceiling headroom restored via extraction not bump |

---

## Execution model (how packets are run without quality loss)

These rules exist because weaker models fail in predictable ways: they widen scope, weaken assertions to make tests pass, trust green badges, and invent APIs. Every rule below blocks one of those failure modes.

### Hard rules for every packet
1. **Branch from fresh `origin/main`** in an out-of-tree worktree (`git fetch origin && git worktree add <dir> origin/main`). Never work in the primary checkout; never branch from another packet's branch unless the DAG says so.
2. **Touch only the files listed in the packet.** If the fix seems to require touching an unlisted file, STOP and escalate — do not improvise. (Exception: adding new test files in the packet's stated test directory is always allowed.)
3. **Never weaken an assertion, delete a failing test, raise a budget/baseline, or add a suppression to get green.** If a gate fails, the fix is wrong — escalate. Raising any `budgets/*.json` value or lint threshold requires explicit sign-off from Alberto and a written rationale in the PR body.
4. **Every behavior fix ships with a regression test that fails on the pre-fix code.** Prove it: run the new test against the unfixed tree (stash the fix or `git stash`) and paste the failing output into the PR body, then show it passing post-fix.
5. **Run the packet's Verification block locally before opening the PR.** Paste actual command output (not "passed") into the PR body under `## Validation`.
6. **PR structure per factory rules** (`docs/SOFTWARE_FACTORY_PR_LOOP.md`): one packet = one PR; body includes scope, validation output, risks, rollback note; label for the factory review loop. Big packets need a review map.
7. **Stop-and-escalate conditions (comment on the tracking issue, do NOT push a workaround):** a listed anchor doesn't exist at your commit; a verification command fails for a reason unrelated to your change; the fix requires >1.5× the listed file set; any secret, credential, or production resource would be touched; any instruction here conflicts with what you find in the repo.
8. **New CI checks land observing-first:** a new gate/workflow runs non-required for its first PR, is verified green on a real PR, and only then is added to `governance/branch-protection.main.json` `required_status_checks.contexts` (there is NO auto-apply — live branch protection must be updated by Alberto per `governance/README.md`, then `scripts/ops/check-branch-protection-drift.mjs` confirms match).
9. **budgets/*.json tripwire:** any NEW `budgets/*.json` file must be added to the `docs/LINT_RATIONALE.md` allowlist block in the same PR or `check-no-suppressions` fails (known gotcha).
10. **Evidence integrity:** never fabricate evidence files, never hand-edit generated snapshots (e.g. `docs/TECH_DEBT_METRICS.md` must be regenerated by its script, not edited).

### Actions only Alberto can perform (the plan schedules these; agents must not attempt them)
- **A1.** Trigger production deploys (`deploy-production.yml`, `deploy-cloud-run.yml`). **Prerequisite (discovered in PR #1773):** no existing `v*` tag contains the PR #1572 unblocking fix (`bf7462683c`); a new immutable release tag containing `bf7462683c` is required before A1 deploys. Do NOT move or reuse `v1.0.29`. **Two-phase fail-closed deploy sequence (resolves the dry-run-before-tag impossibility):** both workflows trigger on `push.tags: v*` with `dry_run=false` and require `workflow_dispatch` to run from a tag ref — so a dry-run requires a tag that already auto-deploys. The fix is a two-phase mechanism: (1) push a non-tag release-candidate branch (e.g. `release-candidate/v1.0.30`) at the exact current `main` SHA containing `bf7462683c`; (2) modify both deploy workflows to accept `workflow_dispatch` with `dry_run=true` from a non-tag branch ref, but only when an explicit `candidate_sha` input matches the checkout SHA AND `origin/main` HEAD (fail-closed: reject if the SHA is not reachable from `origin/main` or if it does not match); (3) run both dry-runs from the candidate branch; (4) only after both dry-runs pass, push the future `v*` tag at the same SHA — its `push.tags` triggered runs ARE the real deploys (do NOT run a redundant manual `dry_run=false`); (5) non-dry-run manual retries remain tag-ref-bound (dispatch from the tag ref with `dry_run=false`). No tag movement or auto-deploy bypass is authorized.
- **A2.** Edit live branch protection / org ruleset (add required contexts, CODEOWNERS review toggle, merge queue).
- **A3.** Rotate secrets (Android keystore passwords, `IROH_SERVICES_API_SECRET`) and delete the 35 local `preserve/*` tags; run `scripts/hooks/install-git-hooks.sh` in the primary clone (local machine).
- **A4.** Set the `FACTORY_API_KEY` repo secret (or decide to retire the wiki-refresh lane).
- **A5.** Approve any change to `.gitleaks.toml`, `firestore.rules`, or `budgets/*` baselines (as reviewer).
- **A6.** Configure paging (Slack webhook / PagerDuty key as repo secret).

### Sequencing DAG (packets defined below)
- **Wave 0 (do first, hours — day 0):** P-OPS-1 (prove deploy plane) · P-SEC-1 (V-47 guard+rotation) — both Alberto-led with agent prep.
- **Wave 1 (parallel, independent):** P-OPS-2 (freshness monitor) · P-OPS-3 (issue triage) · P-QA-1 (harness triage) · P-SEC-2 (rate limits) · P-SEC-3 (Insights digest) · P-CQ-1 (linux-desktop gate) · P-CQ-2 (gl-engine de-fork) · P-CQ-3 (Android quota fix) · P-CQ-4 (Windows fixes) · P-PERF-1 (rollup totals) · P-ARCH-3 (C# schema mirror gate).
- **Wave 2 (depends on Wave 1):** P-QA-2 (mobile tests pre-merge; needs P-QA-1's harness split) · P-QA-3 (merge queue; needs A2) · P-OPS-4 (paging; needs A6) · P-PERF-2 (indexing incrementality; needs P-PERF-1 patterns) · P-PERF-3 (perf gate).
- **Wave 3 (deterministic shared-Rust cutover):** P-ARCH-1a lands the trusted deletion guard (#1805); P-ARCH-1b lands the atomic shared Rust migration (#1804) after the trusted guard evaluates it; P-ARCH-1c activates Rust and deletes legacy code only after the candidate, promotion, activation, signed stable-release, reviewer, and deletion receipts agree. P-ARCH-2 keeps the mission-enforcement mechanism behind its separately tracked divergence gate.
- **Wave 4:** P-META-1 (re-audit swarm) after the deterministic Rust cutover lands and Waves 0–2 first proofs are green.
- **Elapsed-time note:** the program's critical path is current-main CI, trusted release evidence, deterministic activation/deletion receipts, and Alberto-owned production/governance actions. The shared Rust cutover proceeds immediately when those proofs pass because no user traffic exists.

## Work packets

Each packet is self-contained: originating finding, exact files (paths corrected to origin/main post-decomposition), the change, invariants an implementer must not violate, the required regression test, and the local verification that must pass before PR. **Every line-number reference is ±a few lines — locate by symbol name, not by line.**

---

### Wave 0 — Prove the plane (Alberto-led, agent-prepped)

#### P-OPS-1 — Prove the production deploy plane (closes LB-1) → Ops
- **Finding:** Ops §LB-1. Cloud Functions frozen at 6/18; `deploy-production.yml` fix (PR #1572) never exercised.
- **Agent prep (no prod access needed):** produce `docs/ops/UNDEPLOYED_FUNCTIONS_AUDIT_2026-07.md` enumerating `git log 994bc55288 --since=2026-06-18 -- functions/` grouped by security-relevant vs. other; flag any auth/appCheck/rate-limit/validation change as **must-verify-before-deploy**. Confirm `functions/.env.burnbar.production` present and `SENTRY_DSN` wired (deploy step requires both).
- **Workflow change (agent, part of P-OPS-1 scope):** modify both `deploy-production.yml` and `deploy-cloud-run.yml` to add a `candidate_sha` workflow_dispatch input (string, required when `dry_run=true`); in dry-run mode, accept dispatch from a non-tag branch ref but fail-closed if the input SHA does not match the checkout SHA AND `origin/main` HEAD (reject if not reachable from `origin/main`). Tag-ref dispatch (`push.tags: v*` or `workflow_dispatch` from a tag with `dry_run=false`) stays unchanged. Add a focused verifier/test that asserts: dry-run from a non-tag branch with matching SHA succeeds; dry-run from a non-tag branch with mismatched SHA fails (exit 1); tag push still triggers `dry_run=false` real deploy.
- **Alberto actions (A1), two-phase fail-closed sequence:**
  1. Push a non-tag release-candidate branch (e.g. `release-candidate/v1.0.30`) at the exact current `main` SHA containing `bf7462683c`.
  2. `deploy-production.yml` `workflow_dispatch` with `dry_run=true` + `candidate_sha=<SHA>` from the candidate branch → must pass build + `check-firestore-deploy-drift.mjs` + health gate (no deploy).
  3. `deploy-cloud-run.yml` `dry_run=true` + `candidate_sha=<SHA>` from the candidate branch → must pass build + Docker smoke (no deploy).
  4. Only after both dry-runs pass: push the future `v*` tag at the same SHA. Its `push.tags` triggered runs ARE the real deploys — do NOT run a redundant manual `dry_run=false`. `functions-health-gate` job must go green (`HEALTH_GATE_REQUIRE_SENTRY=1`, source-metadata required); `Read back hosted MCP deployment` must confirm 100% traffic on latest ready revision with no env drift.
  5. Non-dry-run manual retries remain tag-ref-bound (dispatch from the tag ref with `dry_run=false`).
  6. Close issue #1091 with the run URLs as disposition.
- **Verify (post-deploy, read-only):** `gcloud functions list --project burnbar --format='value(name,updateTime)'` shows today’s date; prod `healthReady` returns the new commit hash.
- **Invariant:** the July-rules/June-functions skew (Security §S1) means the dry-run drift-check must be clean before the tag push. If the audit finds a stranded security fix, verify it deploys and re-run the relevant firestore-rules-tests against the new functions. The `candidate_sha` fail-closed check prevents deploying from an unreviewed or stale SHA.
- **Done:** one green real functions deploy + one green Cloud Run deploy (via tag push after dry-run) + #1091 closed + dry-run-from-branch workflow change merged with focused verifier test. Soak ledger tracks "N consecutive green scheduled deploys."

#### P-SEC-1 — V-47 close-out (secrets) → Security
- **Finding:** Security §S5. 35 `preserve/*` tags carry live secrets; pre-push guard never installed; rotation unverified.
- **Alberto actions (A3), local machine:** run `scripts/hooks/install-git-hooks.sh` (chains a guard wrapper before the existing LFS hook — verify `.git/hooks/pre-push` now contains the `preserve/* tags` marker); extract the secrets, **rotate** them (Android upload keystore password, `IROH_SERVICES_API_SECRET`), then delete all 35 tags locally (`git tag -d $(git tag -l 'preserve/*')`).
- **Verify:** `git tag -l 'preserve/*'` empty; `.github/workflows/preserve-tag-leak-tripwire.yml` still present as backstop; run `scripts/hooks/pre-push.test.sh` (the existing hook self-test) which feeds the hook the exact git stdin shape and asserts it blocks `refs/tags/preserve/*` creation, allows normal release tags, allows branch pushes, allows preserve-tag deletions, and blocks renamed-ref preserve pushes. Do NOT verify with a bare `git push --tags` after deleting the tags — that has no preserve ref for the guard to reject and would falsely pass. If the self-test is unavailable, feed the installed hook an explicit dummy line on stdin: `printf 'refs/tags/preserve/dummy ${sha} refs/tags/preserve/dummy ${zero}\n' | scripts/hooks/pre-push` and confirm exit 1.
- **Done:** tags gone, guard installed and proven, rotation recorded (privately) in the soak ledger as complete.

---

### Wave 1 — Independent fixes (parallel)

#### P-OPS-2 — Deploy-freshness monitor (genuine gap: no existing utility) → Ops
- **Finding:** Ops §"alerting fires into a void; no freshness detection." The company's signature failure (26-day silent freeze) is undetectable today.
- **Build:** `scripts/ci/check-deploy-freshness.mjs` — reads live Cloud Functions/Cloud Run `updateTime` (reuse the auth/token pattern from `scripts/ci/check-firestore-deploy-drift.mjs`) and fails if the newest prod deploy is older than a threshold (default 14 days, env `DEPLOY_FRESHNESS_MAX_AGE_DAYS`). Wire into a new job in `ops-confidence.yml` (`name: Ops Confidence`, weekly Mon cron) using the existing `./.github/actions/ops-failure-issue` (lane `deploy-freshness`, `mode: open`/`close`).
- **Also fix the relaxation:** `scripts/ci/post-deploy-health-gate.sh` synthetic lanes run with `HEALTH_GATE_REQUIRE_SOURCE_METADATA=0` "until the deploy lands." After P-OPS-1, flip nightly-e2e + ops-confidence synthetic checks back to `=1` (or document why not) so compliance metadata is asserted live.
- **Invariant:** reuse `ops-failure-issue`; do not invent a second issue-filing path. Threshold is a constant + env override, never hardcoded per-service.
- **Verify:** run the script locally against a mock `updateTime` fixture (recent → exit 0; 30-days-old → exit 1); unit-test the age comparison.
- **Done:** freshness job green in `ops-confidence.yml`; a synthetic old-timestamp test proves it would have caught the 6/18 freeze.

#### P-OPS-3 — Close the alert→action loop → Ops
- **Finding:** Ops §"alerts accumulate as unread issues"; June P0 issues (#327/#308/#317/#304/#565/#1091) still open.
- **Do:** triage every open `P0 - Critical` / `area: infra` issue; each gets a disposition comment (fixed-by-PR / superseded / won't-fix-because) and is closed or relabeled. Record the sweep in `docs/ops/ALERT_TRIAGE_2026-07.md`.
- **Invariant:** no mass-close without a per-issue disposition; #1091 is closed by P-OPS-1, not here.
- **Done:** zero stale (>30-day) open P0 infra issues without a disposition.

#### P-QA-1 — Full Harness triage: required-vs-informational split + infra fixes → QA
- **Finding:** QA §LB-A / Ops §"0/200 green." `openburnbar-pr-harness.yml` (`name: OpenBurnBar Full Harness`) never green; failures are a mix of real gates and unattended infra rot.
- **Split:** introduce a **`harness-required` aggregate** (the deterministic, infra-light jobs: Platform Misc, Functions Integration, Windows, Swift Core, App XCTest, Supply Chain) vs **`harness-informational`** (jobs with external/emulator/virtualization deps: `android-hermes-smoke`, `android-e2e`-class, `hermes-gateway-e2ee-proof`, hermes-iroh, mercury-media). Only the required aggregate blocks "harness green" status; informational failures alert but don't define red.
- **Fix the deterministic failures so the required aggregate can go green:**
  - **Platform Misc / "Refresh tech debt metrics snapshot":** run `scripts/ci/update-tech-debt-metrics.sh` and commit the regenerated `docs/TECH_DEBT_METRICS.md` (never hand-edit — item 11). This is a stale-snapshot gate; regenerate, don't weaken.
  - **Functions Integration / Windows:** run their suites locally/via CI; fix real failures per the code packets (P-SEC-2 etc.); if a failure is environmental (emulator JVM, dotnet SDK download), harden the setup step (pin, retry) — do not skip tests.
- **Fix the emulator infra rot (informational, but fix anyway):** `android-e2e` and `android-hermes-smoke` use `reactivecircus/android-emulator-runner@a421e438…` with `arch: arm64-v8a` on `macos-26` and fail on hardware virtualization (`HV_UNSUPPORTED`). Switch to an emulator config that boots on the available runner (x86_64 image on an Intel runner label, or the runner class that supports nested virtualization), or gate these behind a self-hosted runner label. Prove one green emulator boot.
- **Invariant:** splitting required/informational is NOT allowed to drop coverage — every job stays running; the split only changes what defines "harness red." Document the split rationale in the workflow header.
- **Verify:** one green `harness-required` aggregate run on a branch; the tech-debt snapshot regenerates to a clean diff.
- **Done:** required aggregate green once; informational jobs still run and alert. Soak ledger tracks consecutive green required-aggregate runs on main.

#### P-SEC-2 — Wire the dead rate limits + honest tests → Security
- **Finding:** Security §S3 + MEDIUM. `burnBarHermesGateway` per-IP limit declared but the gateway wrapper adds only CORS; three `onCall` callables unthrottled; inventory test only asserts array membership.
- **Files (corrected):** `functions/src/callables/publicRateLimit.ts`, `functions/src/callables/hermesGatewayRoutes.ts`, `functions/src/callables/voipPush.ts`, `functions/src/callables/knowledgeSearch.ts`, `functions/src/callables/agentNotifications.ts`, `functions/src/__tests__/publicEndpointRateLimitInventory.test.ts`.
- **Change:** for each of `triggerVoIPCall`, `searchKnowledge`, `submitAgentNotificationReply`, add a per-uid limiter **copying the exact pattern of `checkHostedInsightsAnswerRateLimit(uid)`** (`publicRateLimit.ts:165-176`): define a `*_RateLimitAction`, a `*_LIMITS` record (burst + daily), and an exported `check…RateLimit(uid)` calling `incrementRateLimit(rateLimitDocId(uid, action), …)`; call it at the top of each callable after auth+AppCheck. For the gateway HTTP path, confirm whether device-start (`hermesGatewayDeviceRoutes.ts:101`) + bearer (`hermesGatewayRoutes.ts:180`) limiters already cover the routes; if any gateway route reaches Firestore without a limiter, add one at `dispatchHermesGatewayRequest`.
- **Honest test:** extend the inventory test to assert **call-site coverage** for `onCall` endpoints (a new catalog dimension or an explicit list that fails when a listed callable has no limiter import/call), not just array membership. The test must fail on today's code.
- **Invariant:** reuse `incrementRateLimit`/`rateLimitDocId`; do not invent a new store. Do not throttle so tightly that legit Pro usage breaks — mirror the Insights limits' order of magnitude.
- **Verify:** `npm --prefix functions test -- publicEndpointRateLimitInventory` fails pre-fix, passes post-fix; a unit test drives each callable past its limit and expects `resource-exhausted`.
- **Done:** three callables throttled, gateway routes confirmed covered, inventory test asserts call sites.

#### P-SEC-3 — Close the Insights E2EE metadata leak → Security
- **Finding:** Security §S2. Hosted Insights digest sends plaintext project folder names + inferred task titles to OpenRouter/MiniMax.
- **Files (corrected):** `OpenBurnBarCore/Sources/OpenBurnBarInsights/Services/InsightDigestBuilder.swift`, `.../SharedModels/InsightDigest.swift`, `docs/PRIVACY.md`, parity mirror `android/.../data/insights/services/InsightDigestBuilder.kt` + `.../data/insights/InsightDigest.kt`, tests `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Insights/InsightDigestPrivacyTests.swift`.
- **Change:** hash/omit the two leaking fields before they enter the hosted payload. Project display: `makeProjectSnapshots` sets `displayName = lastPathComponent(projectName)` (~:305/:319) — route through the existing `hashedProjectID(_:)`/`shortHash(raw:salt:)` (~:704/:724) or drop `displayName` from the hosted path. Task titles: provider (~:229) and model (~:280) `topInferredTaskTitles` are passed unhashed — hash them or gate them behind an explicit opt-in. Apply the identical transform in the Android builder to keep parity.
- **Disclosure:** update `docs/PRIVACY.md:118` to state exactly what the digest contains (hashed project ids, no cleartext project names or task titles) — the wording must match the code after the fix.
- **Invariant:** the hosted payload must contain NO cleartext value that the sync path seals; `privacyMode=localOnly` already blocks egress and stays as-is. Extend `InsightDigestPrivacyTests` to assert no cleartext project/task string survives into the hosted digest — test fails pre-fix.
- **Verify:** the parity test + a new assertion that the encoded digest for a known project/title contains neither the cleartext folder name nor the title.
- **Done:** digest sealed, disclosure exact, Swift+Kotlin parity, test proves it.

#### P-CQ-1 — Gate the linux-desktop TS app (fix the live TS2386) → Code Quality
- **Finding:** Code Quality §SERIOUS-1. `apps/linux-desktop` never typechecked; `tauriBridge.ts` has duplicate interface members that `tsc` rejects, on main.
- **Change:** (a) fix `src/tauriBridge.ts` interface (~:608-676): remove the duplicate declarations of `toolApprovalRespond`, `memorySetStatus`, the `computerUse*` members, and reconcile `computerUsePanicHalt` to a single correct signature (the required, typed `Promise<ComputerUsePanicHaltResult>` one). (b) add `"typecheck": "tsc -p tsconfig.json --noEmit"` to `apps/linux-desktop/package.json`. (c) add a typecheck step to `linux-pr-gate.yml` `linux-fast` job (after `npm ci --prefix apps/linux-desktop`). (d) since `tsconfig.json` includes `packages/gl-engine/src`, this also typechecks gl-engine — coordinate with P-CQ-2.
- **Invariant:** fixing the duplicates must not change runtime behavior — pick the signature that matches the actual Tauri command handler; verify against the Rust command definitions. New CI step lands observing-first (Rule 8), then promoted.
- **Verify:** `cd apps/linux-desktop && npx tsc -p tsconfig.json --noEmit` — errors pre-fix (TS2300/2717/2687), clean post-fix.
- **Done:** typecheck script + gate exist; main typechecks clean.

#### P-CQ-2 — De-fork the GL engine (restore the dropped low-power fix) → Code Quality
- **Finding:** Code Quality §SERIOUS-2 / Perf. `packages/gl-engine` and `apps/console/lib/gl/engine` bidirectionally diverged; the package ships `powerPreference: "high-performance"` and lacks the occlusion `setHostVisible` fix the console has.
- **Change:** converge to ONE source. Port the console's improvements into `packages/gl-engine` (occlusion handling: `hostVisible` field + `setHostVisible(bool)` + the rAF guard `if (!this.visible || !this.pageVisible || !this.hostVisible) return`; `powerPreference: "low-power"`; 300ms `harvestObstacles` throttle) AND re-add the package's `swarmEmber` kernel + palette API to the console copy so nothing regresses. Then make the console import from `packages/gl-engine` (single source) or add a parity gate that diffs the two `engine/` dirs and fails on drift.
- **Invariant:** neither side may lose a feature it currently has (console keeps occlusion/low-power; package keeps swarmEmber/palette). If full unification is too large for one PR, ship the low-power + occlusion port first (the perf-critical half) and the parity gate second — but say so in the PR.
- **Verify:** grep both `BackdropEngine.ts` for `low-power` and `setHostVisible` (both present post-fix); if unified, console builds against the package.
- **Done:** low-power + occlusion in the package; a parity gate or single-source import prevents re-drift.

#### P-CQ-3 — Fix Android self-hosted quota refresh (dead-by-construction) → Code Quality
- **Finding:** Code Quality §SERIOUS-3 / Android lane. `QuotaStore.kt:196-225` runs blocking OkHttp on Main inside a swallowing catch; new client per call; unescaped JSON.
- **Files:** `android/app/src/main/java/com/openburnbar/data/stores/QuotaStore.kt` (+ `data/firebase/FirestoreRepository.kt:278-323`, `data/stores/ActivityStore.kt:106-124` for the cancellation swallows).
- **Change, copying named in-repo patterns:** wrap the network call in `withContext(Dispatchers.IO) { … }` (pattern: `AndroidHermesInsightAnalysisGateway.kt:106-111`); use a shared/injected `OkHttpClient` (pattern: same file `:311` `defaultClient()`); build the JSON body with `JSONObject().apply { put(...) }.toString().toRequestBody(...)` (pattern: `:209,223`), not string interpolation; rethrow `CancellationException` before the catch (pattern already in this file at `:68,:90`). Surface a real error state to the UI instead of swallowing. Apply the cancellation-rethrow fix to the two `FirestoreRepository` catches and the `ActivityStore.updateSearch` catch.
- **Invariant:** never leave a `catch (_: Exception)` that can swallow `CancellationException`; the feature must produce an observable success/failure signal.
- **Verify:** a JVM unit test (Robolectric or coroutine-test) proving `refreshSelfHostedRunner` dispatches off Main and surfaces failure; the JSON body escapes a provider id containing a quote.
- **Done:** feature works on-device (IO dispatch), errors surfaced, cancellation preserved, JSON safe, tests prove it.

#### P-CQ-4 — Windows: fix dead Browse buttons + shared build props → Code Quality
- **Finding:** Code Quality §SERIOUS-4 / Windows lane. `ResolveOwnerHwnd()` returns `IntPtr.Zero` on two pages (dead file picker); no `Directory.Build.props`; flagship app lacks `TreatWarningsAsErrors`.
- **Files:** `windows/app/OpenBurnBar.App/Settings/DataSourceSettingsPage.xaml.cs:80-83`, `Onboarding/Steps/ProvidersStepPage.xaml.cs:102-105`, new `windows/Directory.Build.props`, `windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj`.
- **Change:** replace both `ResolveOwnerHwnd` stubs to resolve the real handle via `WindowChrome.GetHandle(window)` (`Interop/WindowChrome.cs:20`), using the injected-`Func<IntPtr>` `WindowHandleProvider` pattern from `DataControlCenterView.xaml.cs:35,345` (wire the provider where the page is constructed). Add `windows/Directory.Build.props` centralizing `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>` (+ the standard `Nullable=enable`, `LangVersion=latest` block quoted from `OpenBurnBar.App.Presentation.csproj:31-40`) so all ~94 projects inherit it and the flagship app gap closes.
- **Invariant:** adding `TreatWarningsAsErrors` repo-wide may surface latent warnings — fix them properly, do NOT add per-project `NoWarn` to paper over (escalate if the warning count is large). The picker fix must be verified to actually open a dialog.
- **Verify:** build `windows/OpenBurnBar.sln` warnings-as-errors clean (CI Windows job); manual/automated check that Browse opens a picker (or a UI test if feasible).
- **Done:** pickers work, `Directory.Build.props` inherited by all projects, flagship builds warnings-as-errors.

#### P-PERF-1 — macOS cloud totals from rollups (kill the 90-day fan-out) → Performance
- **Finding:** Perf §SERIOUS-1. `fetchCloudTotal` downloads 90 days of `usage` docs up to 2×/min; iOS already reads `usage_rollups`.
- **Files (corrected):** `AgentLens/Services/CloudSync/DownloadSyncService.swift:66-94`, `AgentLens/Services/CloudSyncService.swift:122-126,233-240`.
- **Change:** replace the collection scan + client-side sum with a single read of `users/{uid}/usage_rollups/90d` → `totals.costUsd`, copying the iOS pattern (`OpenBurnBarMobile/Services/FirestoreRepository.swift:516-533`). The shared `UsageRollupDoc` / `RollupWindowKey` types are already in `OpenBurnBarKernel` (`SharedModels/UsageRollupTypes.swift`). Firestore rules already allow the owner to read `usage_rollups` (`firestore.rules:1785`) — no rules change. Remove the redundant double-invocation (download path calls `fetchCloudTotal` and `DownloadSyncService.sync` calls it again).
- **Invariant:** behavior parity — the total shown must match within rounding (`costUsd` is server-rounded to 1e-6); handle the rollup-missing case (fall back gracefully, don't crash). Do not change the sync cadence in this packet.
- **Verify:** with a seeded `usage_rollups/90d` doc, macOS shows the same total as before; instrument to confirm one document read replaces the collection scan.
- **Done:** 90-day fan-out gone; total sourced from the rollup iOS already uses.

#### P-ARCH-3 — Gate the Windows C# Firestore schema mirror → Architecture
- **Finding:** Architecture §F8. `tools/schema-sync` covers Swift/Kotlin/TS; no C# mirror → Windows cloud-sync wire drift ships silently.
- **Files:** `tools/schema-sync/manifest.json`, `tools/schema-sync/check-hand-mirror.mjs`, register `windows/cloudsync/OpenBurnBar.CloudSync/Models/Firestore*Models.cs`.
- **Change:** add `csharpHandMirror` arrays to the manifest domains pointing at the `Firestore*Models.cs` files; implement `extractCsharpMirrorFields(source)` and wire it into `extractNativeMirrorFields`'s dispatch (currently throws for non-swift/kotlin). Reuse the existing `diffMirror` + `knownDrift` machinery. There's already a local `ModelParityTests.cs` + fixtures — align field extraction with those.
- **Invariant:** C# drift must be a hard failure like Swift/Kotlin (new drift AND stale grandfather both fail). Do not add `knownDrift` entries to mask real current drift — if the C# models already diverge, fix the models, escalate if the delta is large.
- **Verify:** `node tools/schema-sync/check-hand-mirror.mjs` now parses C# and passes; introduce a deliberate field mismatch locally and confirm it fails.
- **Done:** C# mirror gated in the canon check.

---

### Wave 2 — Depends on Wave 1

#### P-QA-2 — Mobile XCTests execute pre-merge → QA
- **Finding:** QA §S-1/S-2. Mobile XCTests never run pre-merge; 5 known failures; test topology mid-relocation.
- **Prereqs:** first fix the known failures (needed for a green required gate):
  - **ToolUseLoop -34018:** add the existing `XCTSkip` keychain guard to `HermesServiceToolUseLoopTests.swift`, copying `EscrowCryptoRoundTripTests.swift:17-18` (`catch … where status == errSecMissingEntitlement { throw XCTSkip(...) }`).
  - **AssistantPendingThread singleton:** clear `AssistantPendingThread.shared` in test `setUp`/`tearDown` to remove order dependence (`OpenBurnBarMobileTests.swift:219-228`).
  - **Type-identity dual-load:** inspect the two `OpenBurnBarCore` productRefs in `project.pbxproj` (`A72002AF…`, `D50FA015…`); ensure the package links as a single dynamic product (not statically into both app + test host) so `T.self == TokenUsage.self` (`FirestoreRepository.swift:184`) holds. If decomposition already made this dynamic, add a regression test asserting `TokenUsage.self` identity across the module boundary.
- **Then:** make a compile+unit mobile job (fast subset, no device farm) a **required** check (`app-pr-gate.yml` mobile job currently compile-only and not required). Full `OpenBurnBarMobileTests` stays in the harness (informational per P-QA-1) until reliably green, then promote.
- **Invariant:** XCSkip is only for genuinely unavailable-in-CI entitlements, never to hide a logic failure. Landing the relocation train (#1750–#1761) is the clean path — prefer merging those over patching the monolith test target.
- **Verify:** the three known failures pass or legitimately skip; the required mobile job runs XCTests on a PR.
- **Done:** mobile tests execute pre-merge as a required check; known failures resolved.

#### P-QA-3 — Merge queue / strict base → QA (needs A2)
- **Finding:** QA §M-1. No merge queue; `strict: false`; stale-base greens have landed breakage.
- **Change:** 21 workflows already have `merge_group` triggers. In `governance/branch-protection.main.json`, plan the move to enable the merge queue (or set `required_status_checks.strict: true`). **A2 (Alberto):** apply to live branch protection / org ruleset; then `scripts/ops/check-branch-protection-drift.mjs` must show match.
- **Invariant:** governance file is source of truth (no auto-apply); the file and live state must agree after A2. Enabling the queue must not bypass required checks.
- **Done:** merge queue active (or strict base), drift checker green.

#### P-OPS-4 — Paging path → Ops (needs A6)
- **Finding:** Ops §"no paging path (Slack/PagerDuty)."
- **Change:** extend `./.github/actions/ops-failure-issue` (or add a sibling step) to POST to a Slack webhook / PagerDuty Events API on `mode: open` for `P0 - Critical` lanes. **A6 (Alberto):** add the webhook/routing key as a repo secret.
- **Invariant:** page only on genuine P0 opens (not on every skipped run); dedupe by the existing lane label so a flapping lane doesn't page-storm.
- **Verify:** a test dispatch fires one page to a test channel.
- **Done:** a real P0 open reaches a human out-of-band.

#### P-PERF-2 — Conversation indexing incrementality (or explicit bound) → Performance
- **Finding:** Perf §SERIOUS-2. Indexing re-parses the full corpus every 60s by design (`conversation: nil` cache).
- **Files (source):** `AgentLens/Services/ConversationIndexer.swift` (the indexer — skips unchanged files via `shouldSkipUpsert` but still fetches every conversation row per tick via `dataStore.fetchConversation(id:)`); `AgentLens/Services/DataStore/ParserCheckpointStore.swift` (contains `ParserCheckpointStore`, `CheckpointedParserWrapper`, and `AtomicIngestionTransaction` — all tested, zero production callers); `AgentLens/Services/UsageAggregation/RefreshBackgroundWork.swift:124-128` (the 60s tick that calls `ConversationIndexer.shared.index`); `AgentLens/Services/RefreshOrchestrator.swift:53-65` (the same call from the UI-triggered path); `OpenBurnBarCore/Sources/OpenBurnBarLogParsers/LogParser/ParserDiskCache.swift` (the `ParserDiskCache` / `ParserDiskCacheStore` that decodes+rewrites all entries per tick).
- **Files (tests):** `AgentLensTests/Active/CheckpointTests.swift` (existing checkpoint/`AtomicIngestionTransaction`/`CheckpointedParserWrapper` tests to extend); `AgentLensTests/Active/ConversationParsingTests.swift:276-323` (existing `ConversationIndexer` tests); `AgentLensTests/Active/CrossSurfaceUpgradeTests.swift:358-379` (existing re-index skip test).
- **Change (choose the smaller correct fix, document which):** either (a) make the indexer consume the existing but unused `CheckpointedParserWrapper` / `ParserCheckpointStore` so a byte-offset resume avoids full re-parse on append — wire `CheckpointedParserWrapper` into `RefreshBackgroundWork` and `RefreshOrchestrator` as the parse path so `AtomicIngestionTransaction` couples checkpoint advancement with usage persistence; or (b) if (a) is a multi-platform cache-schema change too large for this program, add an explicit bound: only re-parse files whose `CompositeFileSignature` changed (already computed by each parser's `ParserDiskCacheStore`) AND cap per-tick parse work in `ConversationIndexer.index`, and surface the cost. The prior lane flagged the checkpoint machinery exists with tests but has zero production callers — wiring it is the intended fix.
- **Invariant:** must not break the privacy scrubber or the `conversation: nil` cache-size contract. If choosing (b), `log()` the bound so it's not silent truncation.
- **Verify:** with indexing on and a large multi-file corpus, a steady-state tick does not re-parse unchanged files (measure parse count/time).
- **Done:** steady-state indexing cost is sub-linear in total history, or explicitly bounded and disclosed.

#### P-PERF-3 — macOS CPU/energy regression gate → Performance
- **Finding:** Perf §alarming-3. No macOS app-level CPU/energy gate; the 128–195% idle-CPU class has recurred twice, caught only socially.
- **Change:** add a CI check that launches the app headless in an idle/occluded state and asserts CPU stays under a budget (`budgets/macos-idle-cpu.perf.json`), following the existing perf-budget pattern (`budgets/linux-desktop.perf.json` + the linux perf gate). If a full app launch is infeasible headless, gate the backdrop/animation layer's frame/rAF behavior via a unit-level assertion (occlusion pause verified) — the goal is a mechanical tripwire for "an animated surface forgot its pause gate."
- **Invariant:** new budget file must be added to the `docs/LINT_RATIONALE.md` allowlist (tripwire, Rule 9); gate lands observing-first.
- **Verify:** the gate passes on current main and fails when a test surface removes an occlusion guard.
- **Done:** a mechanical macOS idle-cost gate exists in CI.

---

### Wave 3 — Deterministic shared-Rust cutover

#### P-ARCH-1 — Land and activate the shared Rust domain core → Architecture
**User-confirmed scope:** use deterministic cross-platform proof as the cutover authority because no user traffic exists. Complete the actual Rust activation and protected legacy deletion inside the program.
- **Finding:** Architecture §F6. Zero domain-core promotions; N-way duplication paid today.
- **P-ARCH-1a — establish trusted deletion authority:** merge PR #1805 so `pull_request_target` evaluates candidate bytes with default-branch code, candidate checkouts remain credential-free, and the immutable deletion ledger becomes mandatory as soon as it lands. Observe the guard against PR #1804, then add the proven context to live branch protection through A2.
- **P-ARCH-1b — land the canonical implementation:** merge PR #1804 with quota transforms, CloudVault crypto/search/rewrap/opaque IDs, Hermes crypto/prekeys, pricing, and Pensieve vector transforms wired to the same Rust source across Swift, Kotlin/Android, C#/Windows, browser and Node Wasm, and Python. Treat Pensieve transforms as an explicit CloudVault policy/inventory slice with named required consumers and deletion targets before activation. Preserve CloudVault's independent `OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE`, `OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE`, and `OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE` controls. Bind every generated artifact to the canonical ABI, source fingerprint, and build identity. Read the loaded candidate identity from the Rust binary itself on every native surface; exercise negative tests for stale, malformed, or mismatched identities. Preserve one FFI crossing per operation or file.
- **P-ARCH-1c — activate, release, and delete deterministically:** replace the unused elapsed-time/sample-count authority in the committed promotion policy, evaluator, roadmap, and runbooks with the versioned deterministic contract in the same atomic migration. Produce candidate, promotion, activation, signed stable-release, reviewer, and deletion receipts for the same exact commit and artifacts. Cross-bind workflow run ID/attempt, candidate commit, promotion proof, rollback proof, rollback artifact digest, release identity, and every predicate. Accept GitHub tag-push runs with `head_branch: null` only when `head_sha` and `refs/tags/<tag>` prove the exact release. Keep `legacy` and its rollback artifact available through one observed stable Rust-authoritative release; only then may the trusted exact-head deletion guard remove ledger-covered legacy code. Crypto-sensitive CloudVault and Hermes deletion rows require an independent qualified `security_crypto` review of the exact head.
- **Invariants:** diagnostic shadow evidence remains sanitized observability, never promotion authority. The deterministic contract must fail closed on required suite, benchmark, artifact, loaded-identity, artifact-digest, ABI, source-fingerprint, receipt, reviewer, rollback, or cross-predicate mismatch. CloudVault subdomain controls remain distinct. Crypto promotion/deletion requires KAT and cross-open coverage, wrong-key/AAD/tamper rejection, boundary fuzzing, and the independent security review; receipt agreement cannot substitute for those proofs.
- **Verify:** require #1805 and #1804 current-head CI to pass; reproduce the Rust, Swift, Android, Windows, Functions, Python, Wasm, control-plane, generated-artifact, crypto-negative, rollback, and deletion-guard matrices named in #1804; add the loaded-binary identity, rollback cross-binding/digest, predicate-consistency, distinct CloudVault controls, Pensieve policy coverage, security-review, observed-stable-release, and tag-push regression tests described above.
- **Done:** trusted guard merged and observed; shared Rust migration merged; deterministic activation and stable-release receipts agree; exact-head deletion approved; legacy implementations removed with the post-deletion proof green.

#### P-ARCH-2 — Flip mission `authorizeRemote` to enforce → Architecture / Security
- **Finding:** Architecture §F5 / Security §MEDIUM. `MissionRemoteAuthorizationShadow` observes only; no `.enforce` mode.
- **Mechanism (now):** add an `.enforce` case to `Mode` (`:104-107`) resolved from `OBB_MISSION_AUTHORIZE_SHADOW=enforce`; in enforce mode the fail-closed daemon verdict becomes authoritative (`daemonStricter` → stop; `guiStricter` → loosen), using the existing permissiveness ranking (`:134-146`). Keep shadow as default until soak.
- **Soak (ledger-gated):** collect the `mission_authorize_shadow DIVERGENCE` telemetry over a window; when divergence is zero/understood, flip default to enforce.
- **Invariant:** enforce mode must remain fail-closed if the daemon is unreachable per the security model (do NOT fall back to GUI-allows under enforce); ship enforce behind the env flag first, flip default only after the divergence window is clean.
- **Done (for plan):** `.enforce` implemented + tested behind the flag, divergence telemetry dashboarded. **Done (for ledger):** clean divergence window + default flipped.

---

### Cross-cutting hardening (fold into the nearest wave-1 PR or a small standalone)

- **P-SEC-4 — Scanner governance (needs A2/A5):** add `.gitleaks.toml`/`.gitleaksignore` to `.github/CODEOWNERS` security block; **A2:** enable `require_code_owner_reviews` (or ≥1 required approval) on `main` so the two-PR allowlist-weakening path is closed. Path-scope the global `key:\s+…` allowlist to Swift; tighten the `docs/linux-port/evidence/*` hex allowlist. Add a weekly full-history gitleaks cron.
- **P-CQ-5 — Enforcement parity table:** document in `docs/ENFORCEMENT_PARITY.md` which gate binds which stack (the Swift-first reality), and extend the duplication gate (`.jscpd.json` + `scripts/ci/verify-jscpd-report.mjs`) to include C# and Rust so `requiredFormats` isn't Swift/Kotlin/TS only. Fix the Android detekt `**/ui/**` complexity exclusion (scope it, don't blanket-exempt the largest code mass). Remove the false `generated-by` header on `SwarmBackground.kt`.
- **P-CQ-6 — Force-unwrap ratchet (the one documented debt with no burn-down):** seed `budgets/force-unwrap-baseline.json` at the measured count (~715), add `scripts/debt/check-force-unwrap-budget.sh` copying the shrink-only pattern (`check-mission-splitbrain-budget.sh --update` + `budgets/mission-splitbrain-baseline.json` shape), wire into the harness `check-*-budget.sh` steps, add a `TECH_DEBT_METRICS.md` row (item 11). Add the new budget to the `LINT_RATIONALE.md` allowlist (Rule 9).

---

## Verification & re-audit

### Per-packet gate (every PR)
1. New regression test fails on pre-fix code (paste the failing output).
2. Packet's local Verify block passes (paste output).
3. Relevant existing gates green: `npm --prefix functions test` (functions packets), `swift test` in the touched package (Swift packets), Windows solution build (C# packets), `npx tsc --noEmit` (TS packets), `./gradlew test` subset (Android packets).
4. No budget/baseline raised, no assertion weakened, no suppression added (Rule 3).

### Program-level exit criteria (plan is "done")
- Wave 0: one green real functions deploy + one green Cloud Run deploy (P-OPS-1); V-47 tags gone + guard installed + rotation done (P-SEC-1).
- Wave 1 + 2 packets: all merged; each shipped its regression test; first green proof exists (harness-required aggregate green once, mobile tests running pre-merge, freshness monitor live).
- Wave 3: **trusted deletion authority, the atomic shared Rust migration, deterministic activation, signed stable-release evidence, exact-head deletion approval, legacy removal, and post-deletion proof are complete (P-ARCH-1)**; mission `.enforce` mode is implemented and tested behind its flag (default flip may remain ledger-tracked until its divergence window is clean).
- `docs/OPERATION_9_SOAK_LEDGER.md` tracks consecutive green scheduled deploys, consecutive green harness-required runs on main, nightly-E2E green count, and the mission divergence window/default-flip date. It carries no quota sample-count or elapsed-time gate.

### Final re-audit (P-META-1)
Re-run the exact 6-lane adversarial swarm from `audits/2026-07/DILIGENCE_REPORT_2026-07-14.md` against the new `main`, with the per-lane "Definition of 9" table above as the rubric. Each lane must independently reach ≥9 with live evidence (not badges): live `gcloud` freshness, live `gh` run history for the harness/E2E green streak, executed gate scripts for the new C#/force-unwrap/perf gates, and a fresh gitleaks + governance-drift check. Publish `DILIGENCE_REPORT_<date>.md` as the successor. Any lane below 9 spawns a follow-up packet; the program isn't "9" until the re-audit says so.

### What could still hold a lane under 9 (honest risks)
- **Ops/QA** depend on time-series green streaks — a flaky emulator or a red scheduled deploy can still hold these lanes at 8.5 even after mechanisms are live.
- **Architecture** depends on the atomic #1805→#1804 trust chain and exact release-integrity proofs. A loaded-binary identity, generated-artifact, rollback, receipt, or cross-predicate mismatch blocks activation or deletion until the implementation is corrected; elapsed time and sample count do not substitute for those proofs.
- **Security 9** assumes no new findings in the re-audit; adversarial re-review may surface fresh issues that become new packets.
- **Perf 9** hinges on P-PERF-2's harder path (checkpoint wiring); if only the bounded fallback (option b) ships, the re-auditor may hold perf at 8.5 — prefer option (a) unless it genuinely explodes in scope.
