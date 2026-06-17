# Top-10 Highest-Leverage Improvements — Implementation Plan

**Repo:** OpenBurnBar / BurnBar · **Branch base:** `feature/the-wand-gated-fanout` (cut PRs from `main`) · **Authored:** 2026-06-16

> Derived from the 2026-06-16 full-stack diligence review (74/100, "Strong startup-grade foundation, launchable with major operational caveats"). Every claim below was ground-truthed in-repo; cloud-API facts were doc-verified. Read the loophole ledger before executing.

---

## Context

The diligence review found the residual risk is **operational and organizational**, not architectural. This program executes the Top-10 highest-leverage improvements to reach **clean launch-ready + Series-A-diligence-ready**.

### First pass — three errors in the diligence report corrected (act on THESE)

1. **#5 was overstated.** There are **not "5 Cloud Run services."** `services/` has only two dirs (`hermes-realtime-relay`, `hosted-mcp`), and the launch gate (`scripts/commercial-launch-gate.mjs:90,846-858`) **asserts `hermes-realtime-relay` is RETIRED/absent** — deploying it in CI would self-fail the gate. `checkCloudRun` only requires `openburnbar-quota-runner` (already CI-deployed via the firebase lane). **Real CI-Cloud-Run scope = `hosted-mcp` (+ optionally `openburnbar-ots-verifier`).**
2. **#9's "`git rm --cached`" recommendation was WRONG** and would break a safety invariant. `scripts/rollback.sh:130-131` **refuses to roll back** if `functions/.env.burnbar.production` is missing; `deploy-production.yml:157` + `scripts/ops/deploy-health-functions.sh:12` read it. The file is intentionally committed (self-documents "NON-SECRET VALUES ONLY"). **Correct fix: keep it tracked; add a secret-scan guard.**
3. **#3 under-counted the doomed jobs.** The nightly pages on 6 jobs; **three** are environmentally doomed on hosted runners — `dast-website`, `dast-functions`, **and `privileged-socket-redteam`** (`sudo`-boots a root virtual-HID bridge; DriverKit HID can't load on hosted `macos-26`; no self-hosted runners exist; latest run = `failure`). Splitting only DAST out leaves the nightly red.

### Second adversarial pass — three more loopholes caught & fixed here

4. **#2 would deadlock.** `@emilio3435` is *already* a collaborator; there are exactly 2 writers. Enabling `require_code_owner_reviews=true` with a *sensitive-only* CODEOWNERS deadlocks every founder-authored *non-sensitive* PR (no eligible code-owner approver). **Fix:** blanket co-ownership default `* @Ajnunezg @emilio3435` (`count=1`+no-bypass already yields effective two-person with 2 writers). See 1.5.
5. **#4 was unbuildable.** GCP Cloud Monitoring has **no per-channel "send test notification" API** (doc-verified — only create/list/describe/verify). **Fix:** prove deliverability via VERIFIED-status (already coded) + an operator-run **synthetic canary-alert delivery drill** writing TTL'd evidence, mirroring the DR drill. See 1.3.
6. **#5 has an IAM prerequisite.** The functions-deploy WIF SA likely lacks `roles/run.admin` + `roles/cloudbuild.builds.editor` + `roles/iam.serviceAccountUser`; without them the CI Cloud Run deploy 403s. **Fix:** grant/verify first. See 1.4.

*Cloud-fact confirmation:* the #1 PITR restore command `gcloud firestore databases restore --source-database='(default)' --destination-database=<new> --snapshot-time=<RFC3339>` is correct; it creates a new DB within a 7-day retention window (RPO ceiling).

### Founder decisions locked

| Decision | Choice |
|---|---|
| #2 review policy | **Two-person via Code Owners** — `count=1` + require Code Owner review + blanket co-ownership `* @Ajnunezg @emilio3435`; **standing bypass removed**, replaced by logged break-glass |
| #2 reviewer handle | **`@emilio3435`** (already a Write collaborator — confirm/upgrade to Maintain) |
| #10 burnbar-remote | **Wire it** — UniFFI crate → xcframework + Android AAR + CI matrix (mirror the `openburnbar-iroh` pipeline) |

### Intended outcome
All 10 items shipped **with tests and docs**, sequenced so each PR is independently shippable, the three launch blockers + process fix land first, and the launch gate ends **GO/READY** with every new control failing closed.

---

## Sequenced program (PR-sized waves)

Effort: **S** ≈ hours · **M** ≈ 1–2 days · **L** ≈ 3–5 days · **XL** ≈ multi-PR/week+.

### WAVE 0 — Cheap high-signal wins (do first; clears noise from later gates)

#### 0.1 — #6 Wire the 2 orphaned regression tests · **S** · blocking
- **Why:** `firestore-rules-tests/shared-artifact-sealed.test.js` (V-10) and `cloud-vault-generation-monotonic.test.js` (V-41) are genuine `assertSucceeds/assertFails` + `process.exit(1)` harnesses, git-tracked, but **absent from the `test`/`test:ci` runner** — the hardened V-10 rule's regression guard is dark. (Verified: both align with current rules — `contentSealed==true`, monotonic `vaultGeneration` — so they pass.)
- **Do:** Run both locally green first. Append `&& node shared-artifact-sealed.test.js && node cloud-vault-generation-monotonic.test.js` to the `test`/`test:ci` chains in `firestore-rules-tests/package.json`; add the two convenience scripts the headers reference. **No `security-pr.yml` change** — line 463 already runs `npm run test:ci`.
- **Key files:** `firestore-rules-tests/package.json`.
- **Tests/verify:** Adversarial — relax the sealed-artifact rule in `firestore.rules`, re-run `test:ci`, confirm `shared-artifact-sealed.test.js` goes **red + exit≠0**, revert. No-op PR → "Firestore Security Rules Tests" runs **11** files green.
- **Fallback:** only if genuinely red on base — wire `continue-on-error` advisory + P0; never block all PRs on a pre-existing red.

#### 0.2 — #9a usage composite-index matrix · **S** · correctness win
- **Why:** `usage` has 6 composite indexes vs `session_logs`' 36; `FirestoreRepository.fetchUsagePage` composes `provider/model/deviceId` equality + `startTime` range freely → `FAILED_PRECONDITION` for real users.
- **Do:** Add 3 composites to `firestore.indexes.json` `usage` (COLLECTION scope), using the `provider+model+startTime` block as the JSON template: `{provider,model,deviceId,startTime DESC}`, `{provider,deviceId,startTime DESC}`, `{model,deviceId,startTime DESC}`. These + the existing 6 cover all 7 reachable subsets of `{provider,model,deviceId}` (verified against the query builder). `usage` is append-mostly, so the 4-field composite's per-write cost is acceptable.
- **Key files:** `firestore.indexes.json`; cross-check `android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRepository.kt`.
- **Verify:** `deploy-firestore.yml` `workflow_dispatch` `dry_run=true`; post-deploy `scripts/ci/check-firestore-deploy-drift.mjs` sha-compares. Functional: all-filters Android usage UI returns rows, not `FAILED_PRECONDITION`.

#### 0.3 — #9b env hygiene (CORRECTED: guard, don't untrack) · **S**
- **Why:** `functions/.env.burnbar.production` is **load-bearing** — `rollback.sh` refuses to roll back without it. Untracking it breaks the committed-reviewed-config rollback invariant. It self-documents "NON-SECRET VALUES ONLY".
- **Do:** **Keep it tracked.** Add a fail-closed secret-scan guard `scripts/ci/check-env-no-secrets.sh` (modeled on `scripts/ci/check-no-suppressions.sh`) failing CI if `sk_live`/`whsec_`/`-----BEGIN ... PRIVATE`/private-`AIza` patterns appear in `functions/.env.*.production`. Wire into `fast-feedback.yml`.
- **Key files:** new `scripts/ci/check-env-no-secrets.sh`, `.github/workflows/fast-feedback.yml`, `.gitleaks.toml`.
- **Verify:** Inject a fake `sk_live_...` into a scratch copy → gate exits 1 + names it; remove → exits 0. `rollback.sh` precondition still satisfied (file present).

---

### WAVE 1 — Launch blockers + process fix (the gate to launch)

#### 1.1 — #3 Re-lane the nightly so its alarm regains signal · **M**
- **Why:** Lifetime-red nightly (12/12 fail) = a disabled smoke detector; doomed-on-hosted-runner jobs mask real regressions.
- **Do:**
  1. New `.github/workflows/nightly-dast-sandbox.yml` (same `schedule`) holding `dast-website`, `dast-functions`, **and `privileged-socket-redteam`**, all `continue-on-error: true`, with their **own** `ops-failure-issue` open/close keyed on `lane: nightly-sandbox` (distinct from `lane: nightly-e2e` so per-lane dedupe never cross-suppresses).
  2. In `nightly-e2e.yml`, remove those 3 jobs and drop them from the `needs:` of `open-failure-issue` (line 188) + `close-resolved-issue` (line 207). Paged lane = `prod-health-synthetic` + `nightly-tests` + `commercial-launch-gate`.
  3. **Preserve the security control:** the socket peer-auth rejection logic is already proven by hosted-runnable **unit tests** (`OpenBurnBarCore/Tests/.../PrivilegedSocketTrustTests.swift`, `OpenBurnBarDaemon/Tests/.../BurnBarDaemonServerPeerAuthEnforcementTests.swift`, `.../PrivilegedPeerAuthenticatorTests.swift`) — demoting the *live-socket* nightly job loses no coverage. File a tracked follow-up to **arm a self-hosted privileged macOS runner** that restores the live-socket redteam as a paged hard gate.
  4. Replace the `|| true` emulator-readiness swallow in `dast-functions` with an explicit readiness assertion.
  5. Root-cause `nightly-tests` "cancelled" (90-min timeout / sibling-cancel) and confirm it goes green isolated.
- **Key files:** `.github/workflows/nightly-e2e.yml`, new `.github/workflows/nightly-dast-sandbox.yml`, `.github/actions/ops-failure-issue/action.yml`, `docs/SOLO_OPERATOR_POLICY.md`.
- **Verify:** `workflow_dispatch` both. Green core nightly closes the `lane:nightly-e2e` issue; DAST/redteam reds open only `lane:nightly-sandbox`. `nightly-tests` passes isolated.

#### 1.2 — #1 Firestore restore runbook + drill (LAUNCH BLOCKER; prereq for #4) · **M**
- **Why:** `docs/runbooks/firestore-disaster-recovery.md` is 22 lines with **zero restore commands** — recovery of the store holding entitlements, vault-key wrappers, audit logs is unrehearsed while a 5-min `recursiveDelete` runs against it.
- **Do:** Extend the runbook (reuse the `gcloud`+JSON idiom and `PROJECT='burnbar'`/`DATABASE_ID='(default)'` defaults from `scripts/ops/verify-firestore-disaster-recovery.sh`):
  1. **Restore procedure** (verified syntax): PITR `gcloud firestore databases restore --source-database='(default)' --destination-database=dr-drill-<ts> --snapshot-time=<RFC3339> --project=burnbar`; backup-based `--source-backup=projects/burnbar/locations/<loc>/backups/<id>`. Restores create a **new** DB; no staging project exists, so restore into a throwaway **named DB in `burnbar`**, then delete it (cost hygiene).
  2. **RTO/RPO** — RTO < 4h full restore; RPO ≤ 1h (PITR + daily backup), hard ceiling 7d (PITR retention). **Extend the verifier to assert the retention window**, not just `enabled`.
  3. **Drill** — quarterly, non-primary machine, restore→throwaway DB→schema/index spot-check→capture `launch-evidence/firestore-restore-drill-<ts>.json` + stable `latest-firestore-restore-drill.json`. Cross-link `SOLO_OPERATOR_POLICY.md:79`, `docs/RELEASE_ROLLBACK.md`.
- **Key files:** `docs/runbooks/firestore-disaster-recovery.md`, `scripts/ops/verify-firestore-disaster-recovery.sh`, `docs/SOLO_OPERATOR_POLICY.md`, `launch-evidence/`.
- **Verify (the real test):** Actually PITR-restore into `dr-drill-<ts>`, spot-check schema/indexes, confirm within RTO, capture evidence JSON, delete the drill DB. Re-run the verifier against `(default)` to confirm posture didn't regress.

#### 1.3 — #4 Gate live DR + alert-deliverability in the launch gate (LAUNCH BLOCKER) · **L**
- **Why:** `commercial-launch-gate.mjs`'s `checks` object (1403–1424) has `opsAlerts`/`billingAlerts`/`cloudRun` but **no `firestoreDisasterRecovery`**; the DR verifier runs only in a weekly cron.
- **Do:**
  1. Add `checkFirestoreDisasterRecovery()` (mirror `checkCloudRun`/`checkRedis`'s `run()`/`spawnSync`) shelling `bash scripts/ops/verify-firestore-disaster-recovery.sh`, returning `{ok, pointInTimeRecoveryEnablement, deleteProtectionState, backupScheduleCount, retentionWindow, failures}`; add to `checks`. `verdict()` already NO_GOs on any false check.
  2. **Alert-deliverability proof (CORRECTED — GCP has no per-channel "send test notification" API):** two-layer. (i) *Programmatic:* `checkAlertDeliverabilityEvidence()` reuses `ops-alerts-gate.mjs`'s `verificationStatus===VERIFIED` + non-placeholder + not-NXDOMAIN checks. (ii) *Delivery drill:* `scripts/ops/run-alert-delivery-drill.mjs` forces a dedicated **canary alert policy** condition true (reuse `ops-confidence.yml` synthetic mechanism if present), confirms receipt at the human endpoint, writes timestamped `launch-evidence/alert-channel-verified.json`. Gate requires that file **fresh (TTL ≤ 7d, env-tunable)** with all VERIFIABLE channels; NO_GO if stale/missing.
  3. **Latency:** if inline GCP API round-trips slow the gate, cache to a fresh-TTL evidence artifact.
  4. Update `scripts/test-commercial-launch-gate-commercial.mjs` fixtures.
- **Key files:** `scripts/commercial-launch-gate.mjs`, `scripts/lib/ops-alerts-gate.mjs`, new `scripts/ops/run-alert-delivery-drill.mjs`, `scripts/test-commercial-launch-gate-commercial.mjs`.
- **Verify:** Degraded DR posture → `NO_GO` + exit 1 + `firestoreDisasterRecovery.ok===false`; healthy + fresh alert proof → GO. Stale-date the alert evidence → NO_GO. Unit harness green.

#### 1.4 — #5 Cloud Run CI deploy + rollback (LAUNCH BLOCKER; CORRECTED scope) · **L**
- **Why:** `hosted-mcp` (and `ots-verifier`) deploy only from a laptop — no CI, no auto-rollback, no audit trail.
- **⚠ IAM prerequisite (verify first):** the existing functions-deploy WIF SA likely lacks Cloud Run roles. Grant `roles/run.admin` + `roles/cloudbuild.builds.editor` + `roles/iam.serviceAccountUser` + GCR/Artifact-Registry write (or a dedicated `cloud-run-deployer` SA bound to the WIF principal) **before** the lane can pass — a missing role = opaque `gcloud run deploy` 403.
- **Do:** New `.github/workflows/deploy-cloud-run.yml` on the same `v*` tags, reusing **verbatim** from `deploy-production.yml`: WIF/OIDC auth (lines 111-118), `submodules: recursive`, health-loop + step-summary + artifact. Per-service steps lifted from `scripts/deploy-hosted-mcp.sh` (verified: `npm ci/build/test services/hosted-mcp → gcloud builds submit → gcloud run deploy openburnbar-hosted-mcp --region us-central1 → /healthz loop`).
  - **Scope = `hosted-mcp` (→ `openburnbar-hosted-mcp`)** primary; **optionally `opentimestamps-verifier` (→ `openburnbar-ots-verifier`, from `tools/opentimestamps-verifier-service`)**. **EXCLUDE** `hermes-realtime-relay` (gate asserts RETIRED), `deploy-hermes-relay.sh` (doc stub), `deploy-iroh-relay.sh` (Firestore-rules+functions). Deploy **sequentially** for atomic per-service rollback. Consider adding `openburnbar-hosted-mcp` to the gate's required-present list so the gate enforces it deployed.
  - **Rollback:** before each deploy capture `gcloud run services describe <svc> --format='value(status.latestReadyRevisionName)'`; on failure auto-invoke the **existing** `scripts/ops/rollback-revision.sh <svc> <prev> --yes` (sub-minute, no rebuild — do **not** reinvent).
- **Key files:** new `.github/workflows/deploy-cloud-run.yml`, `scripts/deploy-hosted-mcp.sh`, `scripts/deploy-opentimestamps-verifier.sh`, `scripts/ops/rollback-revision.sh`.
- **Risk:** WIF token lifetime 900s vs sequential builds (5-10 min each) — fits 1-2 services; if tight, request longer `access_token_lifetime` or re-auth per service.
- **Verify:** Dispatch with a staging path → WIF auth + new revision + `/healthz` green. Broken image → health loop fails → auto-pin traffic to captured revision (`gcloud run services describe <svc> --format='value(status.traffic)'` = 100% prior). `checkCloudRun()` still passes (hosted-mcp ready; retired relay absent).

#### 1.5 — #2 Two-person review + remove standing bypass · **M**
- **Why:** Branch protection requires 1 approval but `Ajnunezg` is on the bypass list → REVIEW_REQUIRED is permanent theater; bus factor 1.
- **Verified live state:** `@emilio3435` is **already a collaborator** (push=true); the only 2 writers are `@emilio3435` and `@Ajnunezg` (admin). Current: `count=1`, `require_code_owner_reviews=false`, `bypass=[Ajnunezg]`.
- **⚠ Loophole fixed:** `require_code_owner_reviews=true` with a **sensitive-only** CODEOWNERS (default `* @Ajnunezg`) **deadlocks every founder-authored *non-sensitive* PR** (sole owner is the author; no self-approve; emilio doesn't own that path). With 2 writers, `count=1` + no-bypass *already* forces two-person review on everything. So use **blanket co-ownership**.
- **Do (deadlock-free):**
  1. Confirm `@emilio3435`'s access (already push; consider Maintain). No invite needed.
  2. `.github/CODEOWNERS`: default **`* @Ajnunezg @emilio3435`**. Keep explicit sensitive lines (security/, `auth.ts`, `appCheckAttestation.ts`, `ssrfGuard.ts`, `stripe.ts`, `dataExport/dataDeletion/accountDeletion/auditLog.ts`, `validators.ts`, `publicRateLimit.ts`, `hermesGateway.ts`, + crypto/`CloudVault*`/Signal-HPKE glob) listing both, as documentation + forward-compat.
  3. Branch protection: `required_approving_review_count=1`, **`require_code_owner_reviews=true`**, `enforce_admins=true`, **remove the standing `bypass_pull_request_allowances` entry for `Ajnunezg`**. (`count=2` is impossible with 2 writers — permanent deadlock.) Break-glass = the documented temporary-disable recipe (`docs/runbooks/functions-break-glass.md` / admin-merge), **logged, issue-first, 72h postmortem** — not a standing skip.
  4. **Code lockstep:** `checkProtection()` (`commercial-launch-gate.mjs:620`) keeps `===1` but **add assertions** `require_code_owner_reviews===true` and empty bypass; mirror in `scripts/ops/verify-github-governance.sh`. Update `docs/SOLO_OPERATOR_POLICY.md` so configured == operating.
- **Key files:** `.github/CODEOWNERS`, `scripts/commercial-launch-gate.mjs`, `scripts/ops/verify-github-governance.sh`, `docs/SOLO_OPERATOR_POLICY.md`.
- **Verify:** `bash scripts/ops/verify-github-governance.sh` → `count=1`, `require_code_owner_reviews=true`, `enforce_admins=true`, **zero** bypass, exit≠0 on drift. A founder PR (sensitive **or** routine) is un-mergeable until `@emilio3435` approves; an emilio PR until the founder approves — neither deadlocks. Gate `branchProtection.ok===true`.

---

### WAVE 2 — Architecture / performance debt (incremental, multi-PR)

#### 2.1 — #7a Twin-basename CI gate (.swift-only) — stop the bleeding · **M**
- **Why:** 63 Mac↔iOS `.swift` twins (0 still identical; security logic forked). (Verified: 124 twin basenames, **exactly 63 `.swift`, 60 assets**.)
- **Do:** `scripts/ci/check-twin-basenames.sh` modeled on `scripts/ci/check-no-suppressions.sh` (python heredoc, `git ls-files`, BEGIN/END allowlist in `docs/LINT_RATIONALE.md`, fail-closed, forbid globs, warn-on-stale, exact-path). Logic: `comm -12` of basenames between `AgentLens/` and `OpenBurnBarMobile/`, **filtered to `.swift` only** — flagging the 60 asset twins (`.png/.svg/.json`) = dead gate. Seed the allowlist with the 63 current twins, each tagged `storage-backend-divergence | platform-ui | transport`. Wire into `fast-feedback.yml` beside `check-no-suppressions`.
- **Key files:** new `scripts/ci/check-twin-basenames.sh`, `docs/LINT_RATIONALE.md`, `.github/workflows/fast-feedback.yml`.
- **Verify:** Exits 0 on current tree (63 allowlisted); inject a synthetic new `.swift` twin → exit 1 + names it; asset twins NOT flagged; stale path warns.

#### 2.2 — #7b Burn down the twin allowlist (incremental) · **L** (multi-PR)
- **Do:** With the 2.1 gate live, consolidate shared logic into `OpenBurnBarCore` one family per PR, starting with the already-half-migrated `BudgetRulesStore` (extract a `RulesStore` protocol + `BudgetRule/Period/Scope` — `BudgetRule.swift` already in Core; keep GRDB impl in AgentLens, Firestore impl in Mobile), then `ComputerUseSecurityCallableClient`. **Mandate a pre-merge twin-diff** for every security/budget family (macOS copy is larger — audit for an unported fix). Only extract clean abstractions; don't force a common `BudgetLedger` protocol where GRDB-tx vs Firestore-eventual-consistency leaks. Target ~63 → ~40 necessary-divergence twins.
- **Key files:** `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/`, the twin pairs, `docs/LINT_RATIONALE.md`, **`OpenBurnBar.xcodeproj/project.pbxproj`**.
- **Risk (highest-probability break):** stale `project.pbxproj` after deleting twin files — update both targets per PR; the file is actively churning, so coordinate.
- **Verify:** Per PR — OpenBurnBarCore `swift build`/`swift test` green; macOS + Mobile/Android targets compile; `AgentLensTests`/`OpenBurnBarCoreTests` confirm unchanged behavior; allowlist count drops; gate stays green.

#### 2.3 — #8a Rollup Cloud Tasks fan-out · **XL**
- **Why:** Fixed `rollupBatchSize=50` (`config.ts:97`) caps rebuilds at ~14.4k dirty users/day → backlog grows past ~5-10k DAU; dashboards silently stale. (Verified: `scheduled.ts:68-85` is `collectionGroup("rollup_jobs").where("dirty",==true).limit(50)` then an inline `for (uid of uniqueUids)` per-user compute loop — cleanly extractable.)
- **Do:** Add `@google-cloud/tasks`. Scheduler stops inline compute: read dirty markers (limit ≫50), dedupe UIDs, **enqueue one Cloud Task per UID** to `rollup-user-rebuilds` with `{uid, dirtiedAt}`. Move the per-UID body into a new queue-target function `rollupUserRebuild` (reuse `beginFullRebuildAttempt` gate + breaker from `rollupJobs.ts`); export from `index.ts`. **Race guard:** compare task `dirtiedAt` vs the job doc's current `dirtiedAt` — a task arriving after a fresh rollup is a no-op. Queue rate limits + DLQ; keep `ROLLUP_BATCH_SIZE` as enqueue page size.
- **New ops surface:** queue creation, IAM invoker SA, DLQ, rate limits, queue-depth alerting.
- **Key files:** `functions/src/scheduled.ts`, `functions/src/rollupJobs.ts`, `functions/src/config.ts`, `functions/src/index.ts`, `functions/package.json`.
- **Verify:** Emulator — seed N>50 dirty markers; scheduler returns <10s + enqueues N tasks (mock client). Unit-test `rollupUserRebuild`: full-rebuild, delta-drain, stale-`dirtiedAt` no-op. Load: 100 tasks/min × proven 540s/512MiB envelope decouples throughput from the 5-min tick (1000-user spike drains ~10 min). DLQ catches poison tasks.

#### 2.4 — #8b Streaming percentiles (t-digest / DDSketch) · **L**
- **Why:** `mediaMonitoring.ts:114-188` pushes one sample/event then sorts the full array — OOM/timeout risk at ~1-5M events/day, silently dropping analytics.
- **Do:** Replace array materialization with a per-(feature,metric) streaming sketch (`add`→`quantile`). Inputs are already bucketed (`bucketRtt/bucketBitsPerSecond`) → cheap+bounded. DDSketch (δ=0.01 ≈ 2%) or a vetted t-digest — decide in review. **Persist** sketch state on `MediaSessionDailyRollupDoc` (opaque fields) for a future live mode; keep `{count,p50,p95,p99}` output shape (schema migration). Ships independently of 8a.
- **Key files:** `functions/src/mediaMonitoring.ts`, `functions/package.json`, `functions/src/index.ts`.
- **Verify:** Parity — old (sort) vs new (sketch) on one fixture; p50/p95/p99 within error bound (≤2%). Memory — 50k events/day → bounded vs linear. Rollup doc validates with new fields.

#### 2.5 — #10 WIRE burnbar-remote (founder chose full wiring) · **XL**
- **Why:** Roadmap decision — make the gen-2 Rust remote engine a first-class transport. (Verified: `openburnbar-iroh` is the exact UniFFI template — `crate-type=[staticlib,cdylib,rlib]`, uniffi 0.28, `build.rs`, `iroh-xcframework.yml` + `build-iroh-android-aar.yml`.)
- **Do (mirror the `openburnbar-iroh` pipeline):**
  1. New `burnbar-remote-uniffi` exposing `burnbar-remote-protocol/host/client` via `#[uniffi::export]` (uniffi 0.28).
  2. Build xcframework (mirror `iroh-xcframework.yml`) + Android AAR (mirror `scripts/build-iroh-android-aar.sh`); generate Swift/Kotlin bindings; add a CI matrix.
  3. Add the crate to a root Cargo workspace; add ≥1 real consumer / smoke FFI call across Swift↔Rust and Kotlin↔Rust so it's no longer a shadow.
  4. **Pin policy:** track migrating both kept crates from `iroh =1.0.0-rc.0` to `iroh 1.0.0` stable.
  5. Separately, `git rm` the dead `docs/archive/legacy-operating-layer/BurnBarOperatingLayer.swift` (4,111 lines).
- **Key files:** new `crates/burnbar-remote/burnbar-remote-uniffi/`, `crates/burnbar-remote/Cargo.toml`, new/updated `.github/workflows/`, `Vendor/`, Swift/Kotlin consumers.
- **Verify:** xcframework + AAR build in CI; a Swift call + a Kotlin call across the FFI boundary return; `cargo build/test`/clippy green; `grep burnbar_remote` in Swift/Kotlin is now non-empty.

---

## Cross-cutting risks & dependencies

- **Sequencing:** #4 ⟵ #1 (runbook + evidence convention). #7b ⟵ #7a (gate first). #8a/#8b independent. #2's code assertions + `verify-github-governance.sh` + CODEOWNERS move in lockstep or the gate self-blocks.
- **`project.pbxproj` drift (#7b):** highest-probability break — every twin deletion updates both targets.
- **macOS↔iOS unported-fix (#7b):** pre-merge twin-diff for every security/budget family.
- **Cloud Tasks is net-new infra (#8a):** queue/IAM/DLQ/rate-limits/alerting; the `dirtiedAt` race is the correctness trap.
- **GCP-side drift (#4):** PITR/backup posture + channel VERIFIED status can change with no code change; fail-closed gate at release + Monday triage are the compensating controls. Evidence artifacts timestamp-validated (≤7d alert; quarterly restore).
- **WIF token lifetime + IAM (#5):** 900s vs sequential builds; missing Cloud Run/Build roles 403 silently — grant first, keep lane to 1 primary service initially.
- **#3 root cause unchanged:** the split fixes *visibility*, not the unreachable targets — fix DAST/redteam under the advisory lane's 30-day budget ratchet (the self-hosted-runner follow-up is the real redteam fix), or the lane gets deleted per policy.
- **iroh rc pin (#10):** shared by both kept crates; a stable-migration follow-up is required.

## End-to-end verification (per launch blocker — falsifiable)

1. **DR restore works:** non-primary machine, PITR-restore into a throwaway DB, schema/index spot-check, within RTO, capture `launch-evidence/firestore-restore-drill-<ts>.json`.
2. **Gate blocks on DR + stale alert proof:** `node scripts/commercial-launch-gate.mjs` → NO_GO with degraded DR or stale alert evidence; GO when both healthy + fresh. Unit harness green.
3. **CI Cloud Run deploy + rollback:** new revision + `/healthz` green; broken image → auto-rollback pins 100% traffic to prior revision; retired relay stays absent.
4. **Review enforcement live:** `verify-github-governance.sh` → `count=1` + code-owner-review + zero bypass; a founder PR un-mergeable until `@emilio3435` approves — no deadlock on routine PRs.
5. **Cheap wins:** relax a firestore.rule → newly-wired V-10 test goes red (proves it bites); green core nightly closes the `lane:nightly-e2e` issue while noise lands only in `lane:nightly-sandbox`.
6. **Regression guard:** `bash scripts/ops/verify-production-ops-plane.sh` + a clean gate from an operator env → GO/READY with `firestoreDisasterRecovery`, `alertDeliverability`, `branchProtection`, `cloudRun` all green simultaneously.

## Effort summary

| Item | Effort | Wave |
|---|---|---|
| #6 wire orphaned tests | S | 0 |
| #9a usage indexes | S | 0 |
| #9b env guard (corrected) | S | 0 |
| #3 nightly re-lane | M | 1 |
| #1 DR runbook+drill | M | 1 |
| #4 gate DR+alerts | L | 1 |
| #5 Cloud Run CI deploy | L | 1 |
| #2 review policy | M | 1 |
| #7a twin gate | M | 2 |
| #7b twin burndown | L (multi-PR) | 2 |
| #8a Cloud Tasks fan-out | XL | 2 |
| #8b streaming percentiles | L | 2 |
| #10 wire burnbar-remote | XL | 2 |

**Wave 0+1 (launch-readiness) ≈ 1.5–2 weeks. Wave 2 (debt/future-proofing, incl. two XL items) ≈ 3–5 weeks, multi-PR.**

## Loophole-hunt ledger (7 caught, all fixed)

| # | Loophole | Fix |
|---|---|---|
| 1 | #5 "5 Cloud Run services" overstated | Only `hosted-mcp` (+`ots-verifier`); `hermes-realtime-relay` gate-asserted retired |
| 2 | #9 `git rm --cached` would break `rollback.sh` | Keep tracked + secret-scan guard |
| 3 | #3 under-counted doomed nightly jobs (2→3) | Move redteam too; control preserved by unit tests + self-hosted follow-up |
| 4 | #2 `require_code_owner_reviews` + sensitive-only CODEOWNERS deadlocks founder PRs | Blanket co-ownership `* @Ajnunezg @emilio3435` |
| 5 | #4 "fire test notification" — no such GCP API | VERIFIED-status + synthetic canary-alert delivery drill |
| 6 | #5 WIF SA lacks Cloud Run/Build IAM roles | Grant `run.admin`/`cloudbuild.builds.editor`/`iam.serviceAccountUser` first |
| 7 | Self-caught `BurnBarRemote` grep false-positive | Precise check confirmed zero wiring |

> Follow-up (optional): update `DILIGENCE_REPORT_2026-06-16.md` with corrections 1–3 so the report and codebase agree.
