# SUPERSEDED 2026-06-20 by re-audit at tip a0de7b9948 (origin/memory/activation, "Merge main into memory activation").
# Headline blocker below (3 full-suite failures + 4 merge conflicts) is FIXED at this tip: full app suite "App build + test (AgentLens)"
# GREEN in CI (29m51s, unfiltered); branch MERGEABLE. Go-green fixes are LEGIT not theater (nav route-order asserts real new .memoryReview
# order; PromptInjectionHardening +1 line consentGranted=true STRENGTHENS the wrap test). Core gate reproduced locally 26/26 EXIT=0.
# STILL-TRUE confirmed (refute-by-default panels): (Major, go-live-gated) ContextBuilder.swift:806-814 char-prefix truncate severs
# </UNTRUSTED_CONTENT> on recalled memory; recall budgets body-only, never counts ~150-tok wrapUntrusted envelope
# (ControlPlaneStore+Memory.swift:663,1174-1176) = root cause; shipped truncation test is theater (tiny payload/cloud model, never truncates).
# (Major) permanent zombie: running+attempts==max has no reclaim branch + no janitor + enqueue resets only 'failed' (CPS+Memory.swift:363-372,306-325).
# (Major) pure-hex secrets uncatchable: entropy 4.2 > hex ceiling 4.0, no hex pattern. (Minor) dead DELETE FROM project_memory_snapshots
# wrong-table no-op (731,860; update path saved by ON CONFLICT(memory_id) upsert); pending badge never wired (DashboardView.swift:565-571);
# init(context:) drops runtimeContext. (Nit) stale "defaults true" comments after consent G0 made memoryExtractionEnabled default FALSE.
# REFUTED: high-recall x2 "wastes decrypt/IO"; decode-rescan double-encode escape; large-PR review risk.
# --- ORIGINAL (44ee7ca6bd) VERDICT BELOW, retained for history ---
# PR #613 (memory/activation) adversarial audit — verdict 2026-06-19

Audited at worktree /tmp/bb-613-audit (HEAD 44ee7ca6bd). Successor to `mem:memory-activation/wave-D-dormancy-gate-bypass`.

## Prior CRITICAL is FIXED + regression-locked
The Wave-D dormancy bypass (go-live lever never consulted in the engine write path) is genuinely fixed:
- `MemoryExtractionEngine.init` worker closure = `{ killSwitch.isAllowed() && authorityWritesGoLiveEnabled }` (AgentLens/Services/Memory/MemoryExtractionEngine.swift ~161). Go-live default false (`ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault`).
- Worker `drainClaimedJob` guards `authorityWritesEnabled()` PRE-CLAIM, before `extractor(job)` (the LLM call) — ControlPlaneStore+Memory.swift:1674. So go-live OFF ⇒ no claim, no LLM, no write.
- Consent G0 added: `memoryExtractionEnabled = consentGranted(false) && automaticExtraction(true) && remoteConfigExtractionEnabled(true)` (MemorySettings.swift MemoryExtractionGate). Default dormant.
- Recall gated by `memoryExtractionEnabled` (ChatSessionController+Search.swift:240). Cloud sync gated by approvedCloudBackupEnabled (default false) before any Firestore handle.
- Regression test `test_gateMatrix_extractionEnabled_goLiveOff_drainsButWritesNothing` (MemoryActivationEndToEndTests:272) asserts ship-default go-live=false, 0 processed, requestCount==0 (no LLM egress), job stays .pending. Real behavioral assertions.
- G1 sealed body solid (score 9): agent_memories.body_redacted/body_ref both = `memory_body_snapshots:<slug>` reference; plaintext only in memory_body_snapshots.snapshot_json in the SQLCipher (passphrase-mode via DatabaseEncryptionService/prepareDatabase) DB; agent_memories_fts created empty in v50, DROPPED in v51a, never inserted by app code; audit labels carry body_ref/memory_id only.

## THE HEADLINE DEFECT (Blocker): "0 failures / validated / green" is FALSE
I ran the FULL app suite (scripts/test-openburnbar-app.sh): exit 65, 1736 tests, 3 deterministic failures. PR body claims "✅ 0 failures". Implementer ran only a curated 72-subset, deferred full regression to CI — never ran the suite the PR's own new gate (app-pr-gate.yml, full suite, no filter) runs.
- DashboardNavigationModelTests.test_sidebarRouteOrder_agentsMode (:79) + _modelsMode (:89): PR added `.memoryReview` to DashboardNavigationModel routes (:77) but didn't update these order tests.
- PromptInjectionHardeningTests.testRecalledMemorySectionWrapsEverySnippet (:244): consent G0 blast radius — fresh SettingsManager has consentGranted=false ⇒ recallMemorySection returns "" ⇒ security test fails.
- AnalyticsTaxonomyTests mission_console.opened (:44): PRE-EXISTING, not in diff.
Core gate 26/26 PASS; swiftlint 56 files clean — both reproduced true.

## Confirmed Majors (3-skeptic refute-by-default survived)
- Consent UX dead-end: only `confirmMemoryConsent` (one-shot sheet, DashboardView:302) sets consentGranted; Settings "Memory" toggle binds automaticExtraction not consent; decline ⇒ feature permanently unreachable (latent until go-live).
- Recall budget under-counts wrapUntrusted envelope (~185 tok/snippet) ⇒ overflow.
- Arbiter truncates wrapped memory by raw char-prefix (ContextBuilder.swift truncate ~806) ⇒ can sever </UNTRUSTED_CONTENT> seal (G8 invariant break; limited exploit — approved-only, tail-drop).
- G7 false-negatives: pure hex never trips (max 4.0 < minShannonEntropy 4.2; no hex pattern); corpus missing AWS secret key, github_pat_, slack xapp. Mitigated by quarantine+human review.
- 4 real merge conflicts vs origin/main incl ControlPlaneStore.swift (PR body said 5).
- app-pr-gate.yml not yet a REQUIRED status check (repo-settings change; disclosed).
- Running-job "permanent zombie": `<=` reclaim only shifts stuck-running by one (max 4 attempts at maxAttempts=3); no janitor. Bounded, low practical impact.

## Refuted (dropped): claim/lease state machine "untested" (it is tested).
