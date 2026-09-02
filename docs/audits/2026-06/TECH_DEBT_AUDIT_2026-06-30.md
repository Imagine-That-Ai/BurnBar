# OpenBurnBar Tech Debt Audit & Reduction Strategy — 2026-06-30

> **Status: UNTRACKED — do not commit** (same handling as `TECH_DEBT_AUDIT_2026-06-11.md` and the `DILIGENCE_REPORT_2026-06-1*.md` series; contains live security findings). Relocate to `docs/` only after redacting the privileged-input specifics.
> **Target:** `origin/main` @ `d3f17761d6` (verified in a clean detached worktree, not the local feature branch).
> Produced by a 6-lens diagnosis swarm (orchestrator + 6 specialized sub-agents, Opus 4.8, `/effort max`). Every finding was **verified against today's code by symbol/path**, not by the (now-stale) line numbers in the prior audit. The swarm's explicit mandate was **verify-and-update**: credit what the 2026-06-11 remediation actually closed, apply skepticism to green gates, and isolate the *current* balance of debt.
> **Headline:** the 2026-06-11 audit's Phase 0 ("stop the bleeding") was **substantially executed and the fixes are real**. There are **no standing Criticals**. The current balance is a subtler, second-order class of debt created *by the speed of the remediation itself*, plus the structural work the audit correctly deferred.

---

## 1. Executive Summary

**The biggest truth about this codebase today: the remediation worked — and in working, it moved the problem up one level. The 2026-06-11 problem was "controls are theater and cannot fail." The 2026-06-30 problem is "controls are honest but measure shape instead of health, at the wrong scope or the wrong point — while the real structural debt sits just outside their frame."**

Nineteen days ago a swarm found 11 Criticals: no Firestore backup/PITR, a fake Firebase key killing production sign-in, NXDOMAIN alerting, a wedged deploy, phantom OAuth on the paid CLI, a squattable password-typing socket, an 11.5 GB SQLite FTS leak, dead mobile crash reporting, presence-based coverage gates. **We re-verified every one. They are closed — not renamed, not papered over, but genuinely fixed with fail-closed controls and, in the best cases, invariant tests:**

- **Data safety:** `verify-firestore-disaster-recovery.sh` fails the build unless live PITR + delete-protection + ≥7d retention + a backup schedule exist; the FTS leak is fixed with `ON CONFLICT` + a real repair migration (`v48`) + an active invariant test asserting "5 upserts × 8 conversations → 8 FTS rows, not 40"; TTLs now cover `pop_nonces` and 8 more collections with a live-state gate.
- **Detection:** alert contact repointed to `support@burnbar.ai` with a gate that verifies channel handshake + rejects black-hole emails; the copy-pasted 4-workflow issue-dedupe replaced by one shared label-keyed composite action; Sentry-for-functions is deploy-blocking and health-gated; **iOS and Android crash reporting are both live** (prior C11 refuted).
- **Deploy/security:** submodule wedge fixed; rollback rejects calver betas and re-applies runtime config; Cloud Run gets CI deploy with auto-rollback; website ships a real (public, non-secret) web key; hosted-MCP OAuth refresh is fully implemented with timing-safe hash verification and sealed delivery; the privileged socket moved to a root-owned dir with **real client-side code-signature server authentication** and a fixed peer token; Dependabot spans 13 ecosystems; the source-less `.pyc` runtime is now a provenance-pinned manifest.

**The team demonstrably knows how to close debt when it's framed as a project. The question this plan answers is: what is the remaining balance, and in what order should it be paid?**

Three structural facts define that balance:

1. **The new control plane measures the shrinking surface, not the growing one.** The size gate counts per *file* — so god-*types* split across `Type+Extension.swift` clusters (HermesTabView 4,059 lines across 5 files; ChatSessionController 3,297 across 4; ControlPlaneStore 2,811 across 3) report green with coupling unchanged. The singleton gate is scoped to `AgentLens/` (56) while `OpenBurnBarMobile` alone holds 65 ungated. The duplication gate is token-based and blind to clone-and-rename (the 2,943-line QuickSwitch fork passes). The metrics doc reports `types.ts` = 8 lines while the honest baseline shows 2,682. **The dashboards say "done" over debt that is merely relocated.**

2. **Honest gates run at the wrong point.** `diff-coverage.sh` was genuinely rewritten to real line-level, fail-closed measurement — then wired into the **post-merge** `push:main` harness, not PR checks (`app-pr-gate.yml` runs with coverage OFF). A PR can still introduce uncovered production Swift/Kotlin and merge green; the honest gate only trips *after* the code lands. TS diff-coverage only runs its own self-test; the Android jacoco floor is dead config; detekt runs post-merge only.

3. **The structural debt the audit deferred is now the top of the stack.** The privileged and daemon binaries still link the **97k-LOC** (grew from 79k) SwiftUI/AppKit/crypto `OpenBurnBarCore` kitchen-sink. A full trust/approval/execution engine lives inside the GUI app's Firestore listener, parallel to the daemon's. Android has **no DI/composition root** — `HermesService` is `remember{}`'d per screen. None of this was touched by a sprint focused (correctly) on stopping the bleeding.

**Root cause in one sentence:** the remediation was executed at the same AI-fleet velocity that created the original debt, so it optimized for the metric turning green rather than the property becoming true — building controls scoped to what already passed, wiring them where they wouldn't slow PRs, and deferring the structural work that a metric can't capture.

**The good news, again evidence-based:** the remaining dangerous items are cheap and asymmetric. The single safety-critical residual (a privileged-input kill-switch that silently fails app-side) is an S/M fix. Making crash reports usable (dSYM/mapping upload) is S/M. Re-arming the coverage gate at the PR boundary and fixing the size gate to count per-type are configuration/tooling changes, not refactors. The structural work (Core kernel extraction, split-brain collapse, Android DI) is real L/XL effort — but it now lands on a control plane that, once the Phase-1 gate fixes are in, can actually prove the progress.

---

## 2. Top Debt Themes

**T1 — Measurement & enforcement theater 2.0 (the meta-theme).** *Systemic.* Independently surfaced by 4 of 6 lanes. The controls are honest *mechanisms* but scoped/placed so the real debt escapes them: per-file (not per-type) size counting; singleton gate scoped to the Mac app only; jscpd blind to renamed clones; the CloudSync metric measuring a 228-line shim beside a 17,016-line sibling directory; the datastore-isolation gate excluding the largest DB file; `TECH_DEBT_METRICS.md` reporting barrels; and — most consequential — **the honest coverage/lint gates running post-merge instead of on PRs.** Everything downstream depends on fixing T1 first: refactoring "to green" under gates that measure shape just relocates debt again.

**T2 — Structural debt deferred by design, now overdue (rewrite-risk).** *Systemic.* The privileged/daemon TCB binaries transitively link the 97k-LOC UI+crypto Core (entitlements are now minimal — real mitigation — but the link/rebuild surface is not); split-brain mission execution duplicates trust/approval/backend-resolution across a GUI-app listener and the daemon; Android has no composition root and constructs services per-composable; god-*types* remain tightly coupled behind the cosmetic file splits; the iOS↔Firebase boundary is 461 `[String: Any]` sites (up from 454) with no ratchet.

**T3 — "Mechanism built, migration skipped" — recurred one level up.** *Systemic.* The audit named this the single most-repeated pattern; the remediation reproduced it. TypeSpec now genuinely compiles and drift-checks (real progress) — but 10 of 14 generated domains have **zero** runtime consumers and the hand-maintained legacy types remain the de-facto contract. `parser_checkpoints` (v29) is a wired store + table with zero callers. `BurnBarRemoteEngine` is a CI-built xcframework + SPM product that nothing on Apple platforms links.

**T4 — Unfinished tails of the remediation.** *Cross-cutting.* Sentry is "on" but ships **unsymbolicated** on all three clients (no dSYM/mapping upload anywhere) — crash capture with address-soup output. The FTS fix stopped the leak but deferred the `VACUUM`, so already-bloated files stay large. Primary tables (`token_usage`, `conversations`) still have no retention. The reconcile path still calls `fetchAllUsage()` (whole-table materialization). The privileged-input **panic kill-switch silently fails** when the non-root app writes it. DR/alerting correctness depends on operator-only GCP provisioning CI can't confirm, and the ops-plane verifier itself files no alert when it fails.

**T5 — Compounding cost/scale.** *Cross-cutting.* `session_logs` carries a 36-composite-index cartesian matrix (next collection: 14); ~half combine a facet no query filters on. The daemon MissionControl journal grows unbounded with a full-file read. And a pure-waste CI item: 4 PR-gated macOS jobs recompile libsignal with **zero** cargo cache while a mis-pathed SPM "cache" (`.spm-cache` vs the `.spm-cache-new` the scripts actually use) restores nothing — ~60–100 wasted runner-minutes per PR.

**T6 — Test/correctness residuals.** *Cross-cutting.* `Task.sleep` timing races **worsened** (≈140 → ≈175 across 44 files, 10–80 ms margins against Combine/debounce timers, plus multi-second real-clock waits). Five test god-files (6,127 / 5,859 / 5,802 / 5,545 / 4,089 lines) remain permanent merge-collision zones. Two parallel functions test harnesses (32 bare-assert `.mjs` + vitest). The live privileged-socket redteam is nightly and non-blocking.

**T7 — Same-language duplication (cheap, still open).** *Cross-cutting.* The QuickSwitch Popover/Dashboard fork (2,943 lines, now drifting on data-loading); the provider-executor family (~8,285 lines, per-provider paste-adaptation) inside the privileged daemon; partial socket-scaffold consolidation + keychain-CRUD copied across 6 daemon stores; the iOS `BudgetEnforcement` twin still hardcoding model pricing; 92 prose "mirrors the iOS" comments (up from 54) as un-CI'd contracts.

---

## 3. Ranked Debt Register

Ranking axis: **gate integrity at the enforcement point → observability/safety delivery → rewrite-prevention → compounding cost → leverage cleanups → long tail.** Every row was verified today. Verdict key: STANDING (open, prior), PARTIAL (prior item partly closed), NEW (introduced/revealed since 06-11). Lane key: CQ=code-quality, AR=architecture, TE=testing, OP=reliability/ops, SE=security, PF=performance.

| # | Title | Sev | Scope | Verdict | Effort | Disp | Lane |
|---|---|---|---|---|---|---|---|
| 1 | Honest coverage/lint gates run **post-merge, not on PRs** — uncovered code merges green | High | Systemic | PARTIAL | M | fix-now | TE |
| 2 | Size gate counts per-**file** → extension-cluster god-types grow green (coupling unchanged) | High | Systemic | NEW | M gate / XL decomp | fix-now (gate) | CQ/AR |
| 3 | Sentry ships **unsymbolicated** on iOS/macOS/Android — crash triage impossible | High | Systemic | PARTIAL | M | fix-now | OP |
| 4 | Privileged/daemon binaries link the **97k-LOC** SwiftUI/AppKit/crypto Core | High | Systemic | STANDING | XL | schedule-soon | AR |
| 5 | **Split-brain mission execution** — dual trust/approval/exec (GUI listener ∥ daemon) | High | Systemic | STANDING | L | schedule-soon | AR |
| 6 | Android has **no DI/composition root**; `HermesService` per-composable | High | Systemic | STANDING | L | schedule-soon | AR |
| 7 | Privileged-input **panic kill-switch silently fails** app-side (writes root-owned `/var/run`, swallows error) | Med (safety) | Cross | PARTIAL | S-M | fix-now | SE |
| 8 | Unbounded primary data (`token_usage`/`conversations`) + `fetchAllUsage()` whole-table on reconcile | High | Systemic | STANDING | M-L | schedule-soon | PF |
| 9 | Singleton gate scoped to `AgentLens/` only; Mobile's 65 + Core/Daemon ungated (131 repo-wide) | Med-High | Systemic | PARTIAL | M | fix-now (gate) | AR/CQ |
| 10 | `Task.sleep` flakiness **worsened** (~175 across 44 test files) | High | Systemic | STANDING | M-L | schedule-soon | TE |
| 11 | `[String: Any]` iOS↔Firebase boundary grew (461/2,789), no ratchet | High | Systemic | STANDING | L | schedule-soon | CQ |
| 12 | FTS repair **VACUUM deferred** — already-bloated DB files stay ~14 GB | High | Local | PARTIAL | S-M | schedule-soon | PF |
| 13 | TypeSpec strangler stalled — 10/14 generated domains have **zero** consumers; legacy is real contract | Med-High | Systemic | PARTIAL | L | schedule-soon | AR |
| 14 | CI: 4 macOS jobs recompile libsignal with **no** rust-cache; SPM cache path dead | Med (cost) | Cross | STANDING | S | fix-now | PF |
| 15 | `ops-plane-verify.yml` (the live DR/alert verifier) files **no alert when it fails** | Med-High | Local | NEW | S | fix-now | OP |
| 16 | DR/alerting correctness depends on **operator-only GCP provisioning** CI can't confirm | Med-High | Systemic | PARTIAL | M-L | schedule-soon | OP |
| 17 | `session_logs` **36-composite-index** cartesian bloat (~half on an unqueried facet) | Med | Cross | PARTIAL | M | schedule-soon | PF/OP |
| 18 | Kotlin has **no size gate**; `SwarmBackground.kt` 2,987 + `*Sections.kt` sprawl | Med-High | Systemic | STANDING | M gate / L decomp | schedule-soon | CQ |
| 19 | jscpd blind to clone-and-rename; QuickSwitch fork (2,943) drifting | Med | Systemic | STANDING | M | schedule-soon | CQ |
| 20 | Provider-executor family (~8,285 lines) paste-adapted inside privileged daemon | Med | Cross | STANDING | L | schedule-soon | CQ |
| 21 | Test god-files (6,127 / 5,859 / 5,802 / 5,545 / 4,089) — merge-collision zones | Med | Systemic | STANDING | M-L | opportunistic | CQ/TE |
| 22 | Daemon MissionControl journal unbounded on disk + one full-file O(n) read | Med | Local | PARTIAL | M | schedule-soon | PF |
| 23 | Mach fallback sends credentials without client-side server code-sig check | Low-Med | Local | STANDING | S | schedule-soon | SE |
| 24 | TS diff-coverage script exists but only self-tests; jacoco floor dead; detekt post-merge only | Med | Cross | PARTIAL | S | schedule-soon | TE |
| 25 | Dead scaffolds: `parser_checkpoints` (v29) + `BurnBarRemoteEngine` Swift product — zero consumers | Med-Low | Cross | STANDING | S remove / M wire | opportunistic | PF/AR |
| 26 | iOS `BudgetEnforcement` twin hardcodes model pricing ($15/M) | Med | Local | STANDING | M | schedule-soon | CQ |
| 27 | Cloud Functions deploy detects unhealthy but does **not** auto-rollback (asymmetry vs Cloud Run) | Low-Med | Local | NEW | M | schedule-soon | OP |
| 28 | File-size **ratchet-hugging**: 13 files parked at 1,800–1,999; `AppDelegate` at exactly 2,000 | Med | Systemic | NEW | S (tooling) | opportunistic | AR/CQ |
| 29 | 92 prose "mirrors the iOS" contracts (up from 54), unenforced | Med | Systemic | STANDING | M | opportunistic | CQ |
| 30 | Diff-coverage allowlist waives the **entire** `OpenBurnBarMobile/` prefix | Low-Med | Local | STANDING | M | schedule-soon | TE |
| 31 | `@unchecked Sendable` (32) frozen behind an honest allowlist, not retired | Med | Systemic | PARTIAL | M | opportunistic | AR |
| 32 | Legacy plaintext shared-artifact backfill incomplete (new writes sealed) | Low | Cross | PARTIAL | M | schedule-soon | SE |
| 33 | Vendored hermes-agent has provenance but **no scannable dependency manifest** | Low | Local | NEW | S-M | schedule-soon | SE |
| 34 | Swift CodeQL is push/nightly only, not PR-gated | Low | Systemic | STANDING | M | opportunistic | SE |
| 35 | `firestore.rules` grew to 4,796 lines (single file; hand-maintained allowlists) | Med | Cross | STANDING | M | schedule-soon | AR/SE |
| 36 | Two parallel functions test harnesses (32 bare-assert `.mjs` + vitest) | Low-Med | Local | STANDING | M | opportunistic | TE |

### Detailed entries — the top 8 (full field set)

**#1 — Honest coverage/lint gates enforce post-merge, not on PRs**
Category: gate honesty / release confidence · Severity **High** · Scope Systemic · Verdict PARTIAL (C6 morph) · Lane TE
Evidence: `scripts/diff-coverage.sh` was genuinely rewritten to real line-level, fail-closed measurement (`:32-33`, `:616-619`) — but it runs only in `openburnbar-pr-harness.yml` which is `push:main + schedule` and self-documents "intentionally **not** a pull_request or merge_group gate" (`:3-4`); `app-pr-gate.yml:80` runs `OPENBURNBAR_ENABLE_COVERAGE=NO`; `pr-native-fast.yml` "coverage is left off here"; no caller passes `enable_diff_coverage=true`. Android jacoco `minimumInstructionCoverage=0.17` is defined (`build.gradle.kts:360`) but `jacocoTestCoverageVerification` is never invoked. `diff-coverage-ts.sh` appears only as its own self-test (`workflow-lint.yml:246`).
Why it matters: the entire "we now have honest gates" investment does not bind the moment code enters `main`. A PR can add uncovered production Swift/Kotlin/TS and merge green; the gate only trips afterward (opening an issue, blocking nothing). This is the linchpin — it protects every other refactor in this plan.
Business/eng impact: coverage erodes PR-by-PR while the narrative says "gated"; regressions land and are noticed post-hoc, raising MTTR and re-review cost.
Risk 3–12mo: silent coverage decay; the multi-agent factory merges undertested changes at velocity.
Remediation: run `diff-coverage.sh` / `diff-coverage-android.sh` (scope-partitioned) as **required PR checks** with coverage ON in `app-pr-gate`/`daemon-pr-gate`/`pr-native-fast`; wire `diff-coverage-ts.sh <base>` into `fast-feedback.yml`; either enforce a ratcheting jacoco floor on a PR lane or delete the dead task. Effort **M** · Owner CI/native · Deps: PR lanes must emit xcresult/profdata.
Disposition **fix-now**.

**#2 — Per-file size gate is blind to extension-cluster god-types**
Category: gamed control / tight coupling · Severity **High** · Scope Systemic · Verdict NEW · Lane CQ/AR
Evidence: 144 `Type+Feature.swift` files in production Swift. Single logical types split across files, each <2,000 so the gate is silent, total size preserved/grown: `HermesTabView` 4,059 across 5 files; `ChatSessionController` 3,297 across 4 (base `:30` `final class`, `+Search`/`+Retrieval`/`+Attachments` all `extension ChatSessionController`); `ControlPlaneStore` 2,811 across 3 (`+Memory.swift` alone 1,936); `OpenBurnBarProviderExecutor` 3,372; `ProjectsView` 3,372. `check-swift-file-size-budget.sh` + `count-swift-file-size.py:8` count `lines > target` per *file path*, exclude `Tests/`, threshold 2,000 exclusive — `AppDelegate.swift` sits at exactly 2,000, unbaselined. Extensions share the type's stored properties and actor isolation, so coupling and the concurrent-editor collision hazard are unchanged.
Why it matters: the audit's headline win ("god-files gone") is substantially cosmetic, and the ratchet meant to *prove* progress is the thing being gamed. Refactoring "to green" under this gate keeps relocating debt.
Risk 3–12mo: the "de facto rewrite required before 5+ engineers parallelize" (prior diligence) stays unaddressed while dashboards claim progress.
Remediation: aggregate size per *symbol* (base + all same-type extensions) in `count-swift-file-size.py`; set a real per-type target (~800–1,200) with a shrink-only baseline; extend the counter to Kotlin (jscpd already knows `.kt`). Real decomposition then extracts collaborators, not more same-type extensions. Effort **M** (gate) / **XL** (decomposition) · Owner architecture+platform.
Disposition **fix-now** (gate) / schedule-soon (decomposition).

**#3 — Sentry is "on" but ships unsymbolicated on all three clients**
Category: observability delivery · Severity **High** · Scope Systemic · Verdict PARTIAL · Lane OP
Evidence: repo-wide search for `upload-dif|upload-dsym|debug-files|difutil` is **empty** (no dSYM/mapping upload in `project.yml` build phases or any workflow). Android `build.gradle.kts:172` `isMinifyEnabled=true`; mapping upload gated on `SENTRY_AUTH_TOKEN` which `release.yml` never passes to the Android build (`:410-421`). iOS/macOS: `release.yml:1463-1466` runs `sentry-cli releases new/finalize` only — no debug-file upload for optimized Swift.
Why it matters: crash *capture* works (the C11 fix was real), but the release stack traces are R8-obfuscated / unsymbolicated. The one moment Sentry earns its keep — a production crash spike — yields address soup.
Risk 3–12mo: recurring "can't triage this crash" incidents; paying for observability with no actionable output.
Remediation: pass `SENTRY_AUTH_TOKEN` to `:app:bundleRelease` (Android R8 mapping); add a `sentry-cli debug-files upload` phase/step for iOS+macOS dSYMs. Effort **M** · Owner release+mobile · Deps: token scoping.
Disposition **fix-now**.

**#4 — Privileged & daemon binaries link the 97k-LOC UI+crypto Core**
Category: layering/boundary · Severity **High** · Scope Systemic · Verdict STANDING (worse: 79k→97k) · Lane AR
Evidence: `OpenBurnBarDaemon/Package.swift:54` (daemon → `OpenBurnBarCore`), `:78` (`RemoteAccessAgentCore` → `ComputerUseCore`); `OpenBurnBarCore/Package.swift:273-274` (`ComputerUseCore` → `OpenBurnBarCore`). Main module = 359 files / 97,053 LOC containing 110 `import SwiftUI`, 14 `import AppKit` (incl. `SwitcherCLILaunchService.swift` 1,781, `BrowserLaunchAdapter`, `ChromeProfileDiscovery`) and 18 CryptoKit importers. So `OpenBurnBarPrivilegedInputExecution` (HID-only entitlement) transitively links the full SwiftUI/AppKit/crypto module.
Why it matters: entitlements are now minimal (real runtime-privilege containment), but the *build graph and link surface* of the most sensitive binaries still include the entire UI monolith; the "pure Swift, no AppKit" ComputerUseCore contract is leaky at the package-dependency level.
Risk 3–12mo: every UI change rebuilds privileged binaries; an App Store / security review eventually forces a hard split under deadline → rewrite pressure on Core.
Remediation (strangler): extract a leaf `OpenBurnBarKernel` (models + crypto, zero SwiftUI/AppKit); repoint `ComputerUseCore` and the daemon at it; leave SwiftUI in an `OpenBurnBarUI` product only app targets link. Effort **XL** · Owner platform/Core · Deps: #2 gate first (so decomposition is measurable).
Disposition **schedule-soon**.

**#5 — Split-brain mission execution**
Category: duplicated responsibility / security-sensitive divergence · Severity **High** · Scope Systemic · Verdict STANDING · Lane AR
Evidence: GUI app `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift` (1,952) + `+Planner` (596) + `+Mirrors` (612) + `+WandRouting` (223) + `+Models` (185) ≈ 3,568 LOC performing trust validation (`prepareAndValidateTrustedExecutor` `:448`), approval gating (`:934-1006`), backend resolution (`:1102`), and direct CLI execution (`:1168`). Daemon side: `MissionControlService.swift` (1,360) + cluster ≈ 5,515 LOC does the same.
Why it matters: two independent implementations of trust/approval/backend-resolution on the remote-mission path (one embedded in a menubar SwiftUI app). Every provider/approval/trust change is dual-maintenance and can silently diverge on a security-sensitive surface.
Risk 3–12mo: divergent authorization behavior between engines; shotgun surgery per backend change.
Remediation: designate the daemon MissionControl as the single execution authority; reduce the GUI listener to a transport/relay forwarding to the daemon RPC. Effort **L** · Owner platform.
Disposition **schedule-soon**.

**#6 — Android has no DI/composition root**
Category: object lifetime / shared state · Severity **High** · Scope Systemic (Android) · Verdict STANDING · Lane AR
Evidence: zero Hilt/Dagger/Koin/`@Inject` in `android/app/src`. `HermesService` constructed via `remember { HermesService() }` in ≥6 screens (`ui/hermes/HermesView.kt:16`, `ui/square/HermesSquareScreenSections.kt:219`, `ui/pulse/PulseViewSections.kt:196`, `ui/navigation/BurnBarNavHostSections.kt:652`, `ui/hermes/AssistantsScreen.kt:33`, `ui/computeruse/ComputerUseAgentWatchScreen.kt:60`); `BurnBarApplication` owns none of it.
Why it matters: each screen spins up its own service (own relay connection/state); no shared session, no teardown. The first second-entry-point feature (widget deep link, foreground media service, process-death restore) forces emergency untangling.
Risk 3–12mo: connection duplication, state divergence, a de-facto Android rewrite before feature-scaling.
Remediation: introduce Hilt (or a manual `AppContainer` on `BurnBarApplication`); make `HermesService` an app-singleton injected into ViewModels. Effort **L** · Owner Android.
Disposition **schedule-soon**.

**#7 — Privileged-input panic kill-switch silently fails app-side**
Category: safety-control integrity · Severity **Medium** (safety-critical) · Scope Cross-cutting · Verdict PARTIAL · Lane SE
Evidence: `PrivilegedInputKillSwitch.activate()` (`:23-30`) writes `/var/run/openburnbar-privileged-input-kill` and **swallows any error** (`fputs` to stderr only). `/var/run` is root-owned `0755`; the only non-daemon callers are the non-root GUI app (`ComputerUseSessionCoordinator+Approvals.swift`, on hardCap/deny). The root watchdog that *can* write the flag binds a `0600` root-only socket (`PrivilegedInputKillSwitchWatchdogMain.swift:64`) with **zero in-app clients**. Installers only `chown` binaries; nothing pre-provisions a user-writable flag path.
Why it matters: on the highest-scrutiny surface (synthetic HID incl. typing the macOS login password), the documented local panic stop does not run app-side in production and fails without telemetry. The Remote Config fleet kill-switch still works and the leaf input policy is fail-closed to certified actions — so this is defense-in-depth loss, not total loss — but a claimed safety control is inert.
Risk 3–12mo: a real "stop now" event where the operator believes the kill-switch armed but it didn't → safety/reputational incident on the most sensitive feature.
Remediation: give the app an authenticated path to the root watchdog (group-permission its socket to a first-party group + add the in-app client that already has the code-signature story), or have the root bridge own flag writes; make `activate()` **return failure** so callers can surface it. Effort **S-M** · Owner privileged-input/daemon.
Disposition **fix-now** (small, asymmetric, safety-critical).

**#8 — Unbounded primary data + whole-table reconcile**
Category: data lifecycle / slow path · Severity **High** · Scope Systemic · Verdict STANDING · Lane PF
Evidence: `RefreshOrchestrator.swift:74-79` — "No user-facing retention window is configured yet"; `runRetentionPurgeIfNeeded()` reaps only terminal `projection_jobs`. `token_usage` and `conversations` (the two fastest-growing tables) are never bounded. `UsageStore.swift:373-375` `fetchAllUsage() = fetchRecentUsage(limit: Int.max)`, called as the billing baseline every reconcile (`RefreshOrchestrator.swift:130`) and on every supplemental persist/delete reload; the aggregator holds the whole set in memory and replaces it each refresh (`UsageAggregator.swift:157,196-198`). Dashboard reads are correctly windowed — the reconcile path is the outlier.
Why it matters: O(entire-history) load + full re-materialization per cycle; at 10× history that's 10× memory + 10× load latency every reconcile tick, compounding with #12 (deferred VACUUM).
Risk 3–12mo: slow refresh, memory pressure, ballooning backups on heavy users.
Remediation: add a retention-window setting bounding usage/conversation history in the existing purge hook; reconcile against a bounded/incremental watermark instead of the full table; stop holding the entire usage set in memory. Effort **M-L** · Owner DataStore/UsageAggregation.
Disposition **schedule-soon**.

*(Full evidence for #9–#36 is captured in the per-lane appendices below.)*

---

## 4. What Is Hurting Velocity Most

1. **CI recompiles libsignal cold, 4× per PR, with a dead SPM cache (#14).** `app-pr-gate.yml`, `daemon-pr-gate.yml`, `pr-native-fast.yml`, `computer-use-loopback-test.yml` have zero `Swatinem/rust-cache` steps (the xcframework lanes *do* cache); `app-pr-gate.yml:52` caches `.spm-cache` while `scripts/test-openburnbar-app.sh:33,280` uses `.spm-cache-new`. ≈60–100 wasted runner-minutes per PR. **The single cheapest high-value win in the plan.**
2. **God-type collision tax (#2, #4).** The highest-churn logical types are 2,800–4,100 lines behind cosmetic file splits; two agents/engineers cannot touch streaming/connection/chat without colliding, and every edit re-reviews the whole cluster.
3. **PR gates that don't gate (#1).** Because coverage/lint fire post-merge, breakage is discovered on `main` and fixed in follow-up PRs — the exact re-work loop the factory was meant to remove.
4. **`Task.sleep` flakiness (#10).** ~175 real-timer races normalize "just re-run CI," which is how a real regression gets waved through and how PR cycle time inflates.
5. **Test god-files (#21) + two functions harnesses (#36).** Single 5–6k-line suites serialize edits and defeat test sharding; two runners mean two failure models and easy silent no-runs.

## 5. What Is Riskiest for Production

In strict order: **(1) Safety:** #7 — the privileged-input kill-switch is inert app-side on the password-typing surface (defense-in-depth degraded). **(2) Blind observability:** #3 (crash reports unsymbolicated) + #15 (the ops verifier files no alert on its own failure) + #16 (DR/alerting depend on operator-only GCP state) — capture exists but delivery/triage is compromised. **(3) Data growth:** #8 + #12 — unbounded primary tables and a deferred VACUUM keep large user DBs large. **(4) Rollback asymmetry:** #27 — a bad Cloud Functions deploy that passes deploy but fails health stays live until a human runs rollback (Cloud Run auto-rolls back; functions don't). **(5) Coverage erosion (#1)** as a slow multiplier on all of the above. Note: the acute prior risks (data recovery, dead sign-in, phantom OAuth, credential-capture socket) are **closed**.

## 6. What Could Force a Rewrite Later

1. **`OpenBurnBarCore` mega-target (#4)** — 97k LOC, 110 SwiftUI imports, AppKit launchers + E2EE crypto in one module linked wholesale by the privileged daemon. Interface-first extraction now ≈ weeks; a forced split under App Store / security-review deadline ≈ months.
2. **Split-brain mission execution (#5)** — two authorization engines on the remote-mission path; the longer they coexist, the harder convergence becomes and the higher the chance of a divergent-authorization incident.
3. **Android composition (#6)** — the first second-entry-point feature forces untangling services constructed inside composables.
4. **The contract layer (#13)** — TypeSpec compiles but 10/14 domains are unconsumed while legacy hand-types remain canonical; each quarter of legacy↔generated drift turns "regenerate from one canon" from a migration into a rewrite of sync surfaces.
5. **God-type coupling (#2)** — until the gate measures per-type and decomposition extracts real collaborators, the coupling that motivates a rewrite keeps growing behind green metrics.

---

## 7. Debt Reduction Strategy

**Philosophy: re-arm the control plane at the PR boundary and make it measure health, not shape — *then* pay down the structural balance the metrics can finally see. Never refactor "to green" under a gate that measures the wrong thing.**

This inverts nothing from the 06-11 strategy; it advances it. That plan said "restore control integrity → collapse copies → decompose structure." The team executed "restore *existence* of controls." The gap now is **integrity of the controls that exist** (scope + enforcement point), which is Phase 1 here, followed by the deferred structural decomposition (Phase 3).

Prioritization framework (axes, in order):

| Rank | Criterion | Rationale | Items |
|---|---|---|---|
| 1 | Gate integrity **at the PR boundary** | Green must mean something *before* merge, or every later refactor is unverifiable | #1, #2, #9, #24 |
| 2 | Observability/safety **delivery** | Capture without usable output or a working stop is zero | #3, #7, #15 |
| 3 | Rewrite-prevention structure | Compounding, expensive-later, metric-invisible | #4, #5, #6, #11, #13 |
| 4 | Compounding cost/data | Hurts at 10×, cheap now | #8, #12, #14, #17, #22 |
| 5 | Leverage cleanups | One fix kills a recurring tax | #19, #20, #25, #26, #29 |
| 6 | Long tail | Naming, test size, flakiness polish | #10, #21, #28, #36 |

**Explicit tradeoffs:**
- Structural decomposition (#4/#5/#6) is deliberately **behind** the Phase-1 gate fixes. Decomposing 3–4k-line god-types while the size gate counts per-file just produces more extension clusters.
- The cross-language re-implementation tax (Swift/Kotlin/TS) is **architecture to manage, not debt to erase** — native apps were a deliberate choice. What gets fixed is *unprotected drift* (per-type gates, twin-drift diffs, fixture parity), not the existence of three implementations.
- **Accepted intentionally (record, don't fix):** XcodeGen-generated pbxproj; generated uniffi bindings; single-file `firestore.rules` (Firestore constraint — fix internal duplication via generation instead, #35); English-only v1 (write the ADR + cut the string-catalog seam *during* god-type decomposition, near-zero cost); Swift CodeQL push/nightly (#34, accept with a triage SLA given 60–90 min analysis); the `@unchecked Sendable` allowlist as a *managed* register (#31, shrink opportunistically).

---

## 8. Phased Roadmap

### Phase 0 — Cheap, asymmetric, safety & observability (Week 1; all S/M; no refactors)
**Goal:** close the items where a tiny change removes an outsized risk, and re-arm the linchpin gate.
**Workstreams:**
- **Safety:** fix the privileged-input kill-switch (#7) — authenticated app→watchdog path or daemon-owned flag write; `activate()` returns failure.
- **Observability:** dSYM/mapping upload on iOS/macOS/Android (#3); add `open/close-failure-issue` to `ops-plane-verify.yml` (#15).
- **Velocity/cost:** add `rust-cache` to the 4 macOS jobs + fix the SPM cache path (#14).
- **Gate integrity (start):** turn `diff-coverage` into a **required PR check** with coverage ON for `app-pr-gate`/`daemon-pr-gate`/`pr-native-fast`; wire `diff-coverage-ts.sh`; decide the jacoco floor (enforce-or-delete) (#1, #24).
**Why now:** highest asymmetry per hour; restores "green-on-PR means something" before more code lands.
**Benefits:** working safety control; triage-able crashes; ~60–100 runner-min/PR reclaimed; coverage binds at the boundary.
**Risks:** turning coverage ON on PR lanes may surface a backlog of uncovered diffs — mitigate with a short, dated allowlist that expires (not a permanent carve-out).
**Success criteria:** kill-switch integration test passes; a symbolicated crash appears in Sentry from a release build; a PR with an uncovered new function fails a required check; PR wall-clock drops measurably.

### Phase 1 — Make the control plane measure health, not shape (Weeks 2–4)
**Goal:** every ratchet measures the *whole* surface at the *right* point, so subsequent refactors are provably progress.
**Workstreams:**
- Per-**type** size aggregation (base + same-type extensions) + extend the counter to Kotlin (#2, #18, #28).
- Repo-wide singleton gate incl. `OpenBurnBarMobile`/Core/Daemon (#9).
- Add a `[String: Any]`-at-call-site ratchet (#11); make `TECH_DEBT_METRICS.md` measure directories, not barrels.
- Add a detekt PR lane (mirror `android-ktlint.yml`); retire the diff-coverage `OpenBurnBarMobile/` prefix waiver by wiring the iOS xcresult (#24, #30).
- Complement jscpd with structural/AST similarity or a twin-drift diff on the allowlist; stop skipping `scripts/**` (#19).
**Why now:** the Phase-3 structural work is only measurable once these gates see the real surface.
**Benefits:** ~6 hidden god-types re-exposed; Mobile debt becomes visible; drift/coupling become CI-observable.
**Risks:** re-scoped gates go red on day one — treat the first red as the honest baseline, ratchet down from there.
**Success criteria:** the size gate reports the true count of >1,200-line *types*; the singleton gate counts 131, not 56; a renamed clone fails duplication.

### Phase 2 — Compounding cost/data + leverage cleanups (Weeks 4–8)
**Goal:** curb the debt that grows with usage; collapse the cheapest duplication.
**Workstreams:**
- Retention windows + guarded VACUUM (free-disk check) + bounded/incremental reconcile (#8, #12).
- Prune `session_logs` unused-facet indexes + add an index-vs-query drift check (#17); daemon journal rotation (#22).
- Convert DR/alert provisioning to IaC/Terraform so it's declarative not tribal (#16); schedule the alert-delivery drill.
- TypeSpec per-domain **migrate-or-delete** (#13); decide `parser_checkpoints` and `BurnBarRemoteEngine` (adopt or remove) (#25).
- Dedup: QuickSwitch → `SwitcherFlowController` (#19); provider-executor protocol + shared translation (#20); route remaining daemon executables through the shared socket server + one `KeychainItemStore` (#20-adjacent); hoist `BudgetEnforcement` math into Core (#26).
**Why now:** detection now exists to see these start to hurt; the leverage fixes each kill a recurring tax.
**Success criteria:** DB p95 file size trending down; `session_logs` index count halved with zero query regressions; no domain both compiled and unconsumed.

### Phase 3 — Structural / rewrite-prevention (Weeks 8–16)
**Goal:** shrink the rewrite-risk surface under gates that now measure it.
**Workstreams:**
- Extract leaf `OpenBurnBarKernel` (models + crypto, zero SwiftUI) and repoint the daemon + `ComputerUseCore` (#4) — strangler, interface-first.
- Collapse split-brain: daemon = single mission authority, GUI listener = relay (#5).
- Android DI (Hilt/`AppContainer`), `HermesService` app-singleton (#6).
- Decompose god-types by responsibility (extract interactor/view-model from `ChatSessionController`; split `HermesTabView` into child views with owned state) behind the per-type gate (#2).
**Why now:** decomposition is only durable once it's measurable and the control plane can't be gamed by re-splitting.
**Success criteria:** privileged binaries no longer link SwiftUI/AppKit; one authorization engine; Android services owned by the app container.

### Phase 4 — Long tail (ongoing / opportunistic)
`Task.sleep` → injected clocks/`XCTestExpectation` (#10); split test god-files + add a test-size ratchet (#21); consolidate the two functions harnesses (#36); retire `@unchecked Sendable` conformances (#31); Swift CodeQL PR fast-path for privileged dirs (#34); generate `firestore.rules` from per-domain fragments (#35); finish the shared-artifact backfill + add a `contentSealed != true` counter (#32); pin + scan the vendored hermes-agent dependency manifest (#33).

---

## 9. Quick Wins (highest ROI, days — do these first)

- **#7** privileged-input kill-switch (safety, S-M)
- **#3** dSYM/mapping upload (observability, M)
- **#15** ops-plane-verify failure alert (S)
- **#14** rust-cache + SPM cache path (velocity/cost, S) — reclaims runner-hours immediately
- **#1** diff-coverage as required PR check (M)
- **#9** repo-wide singleton gate (M)
- **#2 (gate half)** per-type + Kotlin size aggregation (M)
- **#25** delete dead scaffolds (`parser_checkpoints`, `BurnBarRemoteEngine`) if not adopted (S)
- **#24** decide jacoco floor; wire TS diff-coverage (S)

## 10. Longer-Horizon Refactors (deep surgery — sequence behind the gate fixes)

- **#4** `OpenBurnBarKernel` extraction (XL, strangler)
- **#5** split-brain collapse to one authority (L)
- **#6** Android DI (L)
- **#2 (decomp half)** god-type decomposition by responsibility (XL)
- **#8/#11** typed Firebase DTOs + bounded reconcile (L)
- **#13** TypeSpec strangler completion (L)

**Refactor strategy per area:** Core split → *strangler* (leaf kernel first, repoint incrementally). God-types → *interface-first* (extract interactor/view-model, then move logic). Split-brain → *test-first* (characterize both engines' authorization behavior, then route GUI → daemon). Data lifecycle → *test-first* (the C10 invariant-test pattern is proven — reuse it for retention/VACUUM). Duplication → *incremental* (one shared type at a time behind the twin-drift gate). Nothing here warrants a from-scratch rewrite.

## 11. Metrics and Governance

**Track monthly (extend `docs/TECH_DEBT_METRICS.md`, and fix it to measure directories not barrels):**
- **PR-gate coverage:** % of production directories behind a *PR-blocking* coverage/size/lint gate (target 100% of product surfaces). This is the headline metric — it measures T1 directly.
- **Max LOC per *type*** (not per file); repo-wide singleton count; `[String: Any]` call-site count; extension-cluster count.
- **Symbolicated-crash rate:** % of release crashes with resolved frames (proxy: dSYM/mapping upload present in the release pipeline).
- **Provisioning-as-code:** DR/alert config declared in IaC vs applied manually (target: 100% IaC).
- **Post-merge gate red rate** — should *fall* as PR gates catch first (a rising post-merge red count means PR gates are still bypassed).
- **Flaky re-run rate; `Task.sleep` count; DB file-size p95; index-to-query drift count.**

**Governance change that prevents T1 from recurring — a "gate honesty" review:** every ratchet must declare its **scope** in-file, and a recurring review must audit each gate for scope-narrowing, enforcement-point (PR vs post-merge), and clustering-at-threshold. Treat scope-narrowing a gate, or trimming a file to sit one line under a threshold, as a **finding** — the same way a new lint suppression is. Fold this into the existing `scripts/ci/check-no-suppressions.sh` philosophy: a gate that measures the shrinking surface is a suppression by another name.

## 12. Final Recommendation

**Do first (this week):** the nine Quick Wins in §9 — they are all S/M, they remove the only safety-critical residual (#7), they make crashes triage-able (#3), they reclaim CI hours (#14), and they re-arm the coverage gate at the PR boundary (#1). None is a refactor; all are high-asymmetry.

**Do next (weeks 2–4):** Phase 1 — make every ratchet measure the whole surface at the right point (#2 gate, #9, #11, #24). This is the precondition for trustworthy structural work and the durable fix for the pattern that produced this whole report.

**Can wait (weeks 4–16):** the compounding-cost cleanups (Phase 2) and the structural decompositions (Phase 3) — important, expensive-later, but safe to sequence behind honest gates.

**Accept intentionally (record, don't fix):** XcodeGen pbxproj; generated uniffi bindings; single-file `firestore.rules`; English-only v1; Swift CodeQL push/nightly (with a triage SLA); the cross-language native re-implementation tax; the `@unchecked Sendable` managed allowlist.

**The one-sentence mandate:** *the last sprint proved this team can close dangerous debt fast; the next one should prove it can make its own gates honest — because a control that measures shape instead of health is how all of this quietly comes back.*

---

## Appendix A — Credit: what the 2026-06-11 remediation genuinely closed (verified 2026-06-30)

**Data & performance:** FTS orphan leak (C10) — `ON CONFLICT` upsert + `v48` repair migration + active invariant test; `projection_jobs` retention (`reapTerminalProjectionJobs`); Firestore TTLs on `pop_nonces` +8 with a live-state gate; rollup fan-out coalesced + paginated; refresh loop lifecycle-gated (`BackgroundCadenceCoordinator`); Android monolithic chat-history JSON → per-thread incremental files.

**Reliability/ops:** Firestore DR gate (PITR/delete-protection/retention/backup, fail-closed) + restore runbook + drill; alerting repointed to `support@burnbar.ai` with a delivery-aware gate; shared label-keyed dedupe action across 6 lanes; deploy-production submodule fix (C8); Sentry-for-functions deploy-blocking + health-gated (H13); **iOS + Android crash reporting live** (C11 refuted); rollback calver/config fix (H14); beta-never-latest (H15); Cloud Run CI deploy + auto-rollback (H17); scheduled-lane structural-red fix (H18).

**Security/supply-chain:** website real (public) web key (C2); hosted-MCP OAuth refresh fully implemented, timing-safe, sealed delivery (C5); privileged socket → root-owned dir + real client-side code-signature server-auth + fixed peer token 0x006 + tightened designated requirement (C9); `cloud_vault_key_wrappers` client delete denied; V-10 sealed-at-rest + healing intact; Dependabot 13 ecosystems, `renovate.json` removed (H24); hermes-agent `.pyc` → provenance manifest, zero `.pyc` (H25); `qa.yml` gated to dispatch, 5 secrets, honest-conclusion step (H26); Android creds hardware-backed + biometric; Stripe webhook HMAC verified; gitleaks runs against the *base* config (can't be weakened in the same PR).

**Testing/contracts/architecture:** diff-coverage rewritten to real line-level fail-closed (C6); peer-auth tests invoke a real socket + run the real validator (C7); orphaned suites wired (services, quota-runner, mcp, mcp-remote, firestore-rules); ktlint honest (baseline removed, anti-vacuous guard); detekt exists; honesty-copy PR-blocking (H7); DAST can fail; TypeSpec canon compiles + bidirectional drift-check; iOS composition root (`OpenBurnBarRuntimeContext`); `crates/burnbar-remote` now CI-covered; CloudSyncService 228-line facade; `@unchecked Sendable` honest assert-zero gate; privileged-input entitlements split to least-privilege.

## Appendix B — Per-lane health verdicts

| Lane | Verdict | One-line |
|---|---|---|
| Code quality | **Real but uneven** | Clean decompositions (HTTPGatewayServer, ScreenShareViewer, FunctionsRepository) coexist with systemic gate-gaming (`Type+Extension` / `*Sections.kt`) and 3 scope-narrowed controls. |
| Architecture | **Foundations laid, structure deferred** | Composition root + compiled canon + CI-covered crate landed; Core kitchen-sink, split-brain, Android DI, and stalled strangler remain. |
| Testing | **~70% de-theatered** | Flagrant theater dead; residual is enforcement-point (post-merge, not PR), dead jacoco floor, missing TS/detekt PR lanes, worsened `Task.sleep`. |
| Reliability/ops | **Largest credit story** | Most C-level ops hypotheses closed with fail-closed gates; residual is verify-but-can't-provision + unsymbolicated crashes + one non-alerting verifier. |
| Security | **Strong; gates unusually honest** | Nearly every prior Critical closed; only residual is the silent kill-switch + a Mach-fallback code-sig gap + low-severity supply-chain nuance. |
| Performance/data | **Big-ticket fixed, tails open** | C10/TTL/retention/refresh closed; deferred VACUUM, unbounded primary tables, whole-table reconcile, and a cheap CI cache win remain. |

*Generated by a 6-lens verify-and-update swarm. Every claim was verified against `origin/main@d3f17761d6`. Advisory retrieval (mem0/prior audits) was treated as hypothesis, not fact.*
