# Operation 9: BurnBar Diligence Remediation Program

**Goal:** take every diligence lane from the 2026-07-14 scores (Architecture 8, Code Quality 7.5, Reliability/Ops 5, Security 7, Performance 7, QA/Delivery 6.5) to **≥9/10 in a fresh adversarial swarm re-audit**, with a plan explicit enough that weaker implementation models cannot degrade quality.

**Acceptance bar (user-confirmed):**
1. Every lane independently re-scores ≥9 in a fresh 6-lane adversarial re-audit (same method as `DILIGENCE_REPORT_2026-07-14.md`).
2. "Mechanisms now, soak tracked": the plan completes when every fix is landed, first green proofs exist, and monitoring/gates are live. Time-series evidence (weeks of green runs, shadow soak) accrues on a tracked checklist (`docs/OPERATION_9_SOAK_LEDGER.md`) after plan completion.

**Source of truth for findings:** `DILIGENCE_REPORT_2026-07-14.md` (repo root, committed with this plan) + the six lane reports in this session. Every packet below cites its originating finding.

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
- **A1.** Trigger production deploys (`deploy-production.yml`, `deploy-cloud-run.yml` workflow_dispatch) — from the exact `refs/tags/<tag>` ref (tag-bound credential guard). **Prerequisite (discovered in PR #1773):** no existing `v*` tag contains the PR #1572 unblocking fix (`bf7462683c`); a new immutable release tag containing `bf7462683c` must be created before A1 deploys can run. Do NOT move or reuse the existing `v1.0.29` tag — create a new tag from the current `main` HEAD that includes the fix. **Do NOT push the new `v*` tag before completing the dry-run sequence:** both `deploy-production.yml` and `deploy-cloud-run.yml` trigger on `push.tags: v*` with `dry_run=false` for non-`workflow_dispatch` events, so pushing the tag auto-deploys before the rehearsal; run the `workflow_dispatch` dry-runs first, then push the tag for the real deploys.
- **A2.** Edit live branch protection / org ruleset (add required contexts, CODEOWNERS review toggle, merge queue).
- **A3.** Rotate secrets (Android keystore passwords, `IROH_SERVICES_API_SECRET`) and delete the 35 local `preserve/*` tags; run `scripts/hooks/install-git-hooks.sh` in the primary clone (local machine).
- **A4.** Set the `FACTORY_API_KEY` repo secret (or decide to retire the wiki-refresh lane).
- **A5.** Approve any change to `.gitleaks.toml`, `firestore.rules`, or `budgets/*` baselines (as reviewer).
- **A6.** Configure paging (Slack webhook / PagerDuty key as repo secret).

### Sequencing DAG (packets defined below)
- **Wave 0 (do first, hours — day 0):** P-OPS-1 (prove deploy plane) · P-SEC-1 (V-47 guard+rotation) — both Alberto-led with agent prep · **P-ARCH-1a (enable quota shadow mode on apple+windows immediately — the promotion policy's 14-day evidence clock must start on day 0 so the flip can land inside the program).**
- **Wave 1 (parallel, independent):** P-OPS-2 (freshness monitor) · P-OPS-3 (issue triage) · P-QA-1 (harness triage) · P-SEC-2 (rate limits) · P-SEC-3 (Insights digest) · P-CQ-1 (linux-desktop gate) · P-CQ-2 (gl-engine de-fork) · P-CQ-3 (Android quota fix) · P-CQ-4 (Windows fixes) · P-PERF-1 (rollup totals) · P-ARCH-3 (C# schema mirror gate).
- **Wave 2 (depends on Wave 1):** P-QA-2 (mobile tests pre-merge; needs P-QA-1's harness split) · P-QA-3 (merge queue; needs A2) · P-OPS-4 (paging; needs A6) · P-PERF-2 (indexing incrementality; needs P-PERF-1 patterns) · P-PERF-3 (perf gate).
- **Wave 3 (day ~14+, inside the program):** P-ARCH-1b (quota promotion flip to `rust` with legacy rollback preserved — REQUIRED for program completion, user-confirmed; gated on the evidence evaluator returning `ready`; legacy deletion follows one stable release later, still inside the program) · P-ARCH-2 (mission enforcement flip; mechanism ships in Wave 1–2, default-flip is ledger-tracked unless the divergence window is already clean by day 14).
- **Wave 4:** P-META-1 (re-audit swarm) after the quota flip lands and Waves 0–2 first proofs are green.
- **Elapsed-time note:** the program's critical path is the 14-day quota shadow soak, not the code fixes (days 1–10). Everything else parallelizes inside that window.

## Work packets

Each packet is self-contained: originating finding, exact files (paths corrected to origin/main post-decomposition), the change, invariants an implementer must not violate, the required regression test, and the local verification that must pass before PR. **Every line-number reference is ±a few lines — locate by symbol name, not by line.**

---

### Wave 0 — Prove the plane (Alberto-led, agent-prepped)

#### P-OPS-1 — Prove the production deploy plane (closes LB-1) → Ops
- **Finding:** Ops §LB-1. Cloud Functions frozen at 6/18; `deploy-production.yml` fix (PR #1572) never exercised.
- **Agent prep (no prod access needed):** produce `docs/ops/UNDEPLOYED_FUNCTIONS_AUDIT_2026-07.md` enumerating `git log 994bc55288 --since=2026-06-18 -- functions/` grouped by security-relevant vs. other; flag any auth/appCheck/rate-limit/validation change as **must-verify-before-deploy**. Confirm `functions/.env.burnbar.production` present and `SENTRY_DSN` wired (deploy step requires both).
- **Alberto actions (A1), in order, from a checked-out `refs/tags/<current-release-tag>`:**
  1. `deploy-production.yml` `workflow_dispatch` with `dry_run=true` → must pass build + `check-firestore-deploy-drift.mjs` + health gate (no deploy). 
  2. Same with `dry_run=false` → real deploy; `functions-health-gate` job must go green (`HEALTH_GATE_REQUIRE_SENTRY=1`, source-metadata required).
  3. `deploy-cloud-run.yml` `dry_run=true` then `dry_run=false`; `Read back hosted MCP deployment` must confirm 100% traffic on latest ready revision with no env drift.
  4. Close issue #1091 with the run URLs as disposition.
- **Verify (post-deploy, read-only):** `gcloud functions list --project burnbar --format='value(name,updateTime)'` shows today's date; prod `healthReady` returns the new commit hash.
- **Invariant:** deploy ONLY from the tag ref; the July-rules/June-functions skew (Security §S1) means step (1) drift-check must be clean before step (2). If the audit finds a stranded security fix, verify it deploys and re-run the relevant firestore-rules-tests against the new functions.
- **Done:** one green real functions deploy + one green Cloud Run deploy + #1091 closed. Soak ledger tracks "N consecutive green scheduled deploys."

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

### Wave 3 — Soak-gated flips (mechanisms now; flips tracked in the ledger)

#### P-ARCH-1 — Promote the first Rust domain (quota) to `rust` mode → Architecture
**User-confirmed scope: the actual promotion happens INSIDE the program.** The 14-day evidence clock is the program's critical path, so part (a) executes on day 0.
- **Finding:** Architecture §F6. Zero domain-core promotions; N-way duplication paid today.
- **P-ARCH-1a (day 0, Wave 0):** enable `shadow` mode on the two policy-required consumers so evidence starts accruing immediately: Swift `OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=shadow`, C# `OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=shadow` (internal/beta channels per `config/domain-core-promotion-policy.json`). Confirm the shadow comparison telemetry is flowing on both platforms within 24h; if it isn't, escalate immediately — every day of silence pushes the whole program's end date.
- **P-ARCH-1b (day ~14, Wave 3 — REQUIRED for program completion):** run the evidence export with all required arguments (the script exits with `Missing --project` if any are omitted): `node scripts/ops/export-domain-core-promotion-evidence.mjs --project burnbar --start <ISO8601-start> --end <ISO8601-end> --channel beta --core-version <core-version> --source-uri https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples --output /absolute/path/to/collected-evidence.json` (see `docs/runbooks/shared-rust-promotion-evidence.md:74-83` for the full canonical invocation and ADC requirements). Then run `node scripts/ci/evaluate-domain-core-promotion.mjs --evidence /absolute/path/to/collected-evidence.json --output /absolute/path/to/promotion-readiness.json` (policy floors: consumers `apple`+`windows`, **≥14d coverage, ≥10k samples, ≤500bps p95 regression**). On exit status `0` (`ready`): flip quota to `rust` on apple+windows, keeping the `legacy` rollback mode still available per `docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md` gate 6 ("one stable release observed with Rust authoritative and the explicit legacy rollback mode still available"). **Legacy deletion is a SEPARATE later step inside the program**, not in the same PR train as the flip — only after the stable-release soak gate passes may a separate deletion PR remove the legacy quota parsers (`ClaudeStatuslineQuotaParser.cs`, `CodexUsageQuotaParser.cs` C# path and the Swift legacy path it shadows).
- **Invariant:** never flip without the evaluator returning `ready` — if evidence fails a floor at day 14 (e.g. <10k samples), the fix is more soak time or more beta devices, never a policy edit. `rust` mode must fail closed (no silent legacy fallback). **The `legacy` rollback mode must remain available until one stable release has shipped with Rust authoritative** (roadmap gate 6); deletion is a separate PR after that release-soak gate, not the flip PR. This preserves the documented rollback path the roadmap requires. Fix the Android cloudvault env-var naming drift (`OPENBURNBAR_CLOUDVAULT_DOMAIN_MODE` vs canonical `OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE`) while in these files.
- **Escalation:** if the evaluator returns `not_ready` for a reason that cannot be cured by more soak (e.g. p95 regression >500bps — a real Rust perf problem), STOP and surface to Alberto: that's a genuine engineering decision, not a process delay.
- **Done:** evaluator `ready` + quota flipped to `rust` on apple+windows with legacy rollback preserved. **Eventual legacy deletion** (after stable-release gate) is a program exit criterion, not a ledger item.

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
- Wave 0: one green real functions deploy + one green Cloud Run deploy (P-OPS-1); V-47 tags gone + guard installed + rotation done (P-SEC-1); quota shadow mode live on apple+windows with telemetry flowing (P-ARCH-1a).
- Wave 1 + 2 packets: all merged; each shipped its regression test; first green proof exists (harness-required aggregate green once, mobile tests running pre-merge, freshness monitor live).
- Wave 3: **quota promoted to `rust` on apple+windows with legacy rollback preserved (P-ARCH-1b — user-confirmed hard requirement); eventual legacy deletion after one stable Rust-authoritative release, still inside the program**; mission `.enforce` mode implemented and tested behind its flag (default-flip may remain ledger-tracked if the divergence window isn't clean by then).
- `docs/OPERATION_9_SOAK_LEDGER.md` created and tracking: consecutive green scheduled deploys, consecutive green harness-required runs on main, nightly-E2E green count, mission divergence window and default-flip date.

### Final re-audit (P-META-1)
Re-run the exact 6-lane adversarial swarm from `DILIGENCE_REPORT_2026-07-14.md` against the new `main`, with the per-lane "Definition of 9" table above as the rubric. Each lane must independently reach ≥9 with live evidence (not badges): live `gcloud` freshness, live `gh` run history for the harness/E2E green streak, executed gate scripts for the new C#/force-unwrap/perf gates, and a fresh gitleaks + governance-drift check. Publish `DILIGENCE_REPORT_<date>.md` as the successor. Any lane below 9 spawns a follow-up packet; the program isn't "9" until the re-audit says so.

### What could still hold a lane under 9 (honest risks)
- **Ops/QA** depend on time-series green streaks — a flaky emulator or a single red scheduled deploy resets the streak; the 14-day quota-soak window conveniently doubles as the streak-accrual window, but a bad week can still hold these lanes at 8.5.
- **Architecture** risk is now schedule risk, not scope risk (promotion is in-program per user decision): if quota evidence misses a policy floor at day 14, the program end date slips — floors are never edited to fit (P-ARCH-1b invariant).
- **Security 9** assumes no new findings in the re-audit; adversarial re-review may surface fresh issues that become new packets.
- **Perf 9** hinges on P-PERF-2's harder path (checkpoint wiring); if only the bounded fallback (option b) ships, the re-auditor may hold perf at 8.5 — prefer option (a) unless it genuinely explodes in scope.
