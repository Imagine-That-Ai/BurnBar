# Wave D (PR-D1/D2/D3) adversarial review — CRITICAL dormancy gate bypass

Branch: `memory/activation` (reviewed at /private/tmp/bb-activation), commits
74ba42bf5e (D1), 2ed6038188 (D2), c18a0335e7 (D3).

## The headline must-fix (gate bypass — feature ships ON, not OFF)

The design narrative (all 3 commit messages + comments in
`MemoryExtractionEngine.swift`, `AgentLensApp+MemoryServices.swift`,
`MemoryExtractionPolicy.swift`, `OpenBurnBarStartupRecovery.swift`) claims TWO
independent fail-closed levers keep chat-memory extraction dormant:
1. `settingsManager.memoryExtractionEnabled` (combined G4: user toggle AND RC kill switch)
2. `ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault` (static `false`, human-owned go-live)

Reality: lever 2 is NEVER consulted in the engine-driven extraction write path.
- `MemoryExtractionEngine.init` constructs the worker with
  `authorityWritesEnabled: { killSwitch.isAllowed() }` where killSwitch mirrors
  lever 1. The worker (`MemoryExtractionWorker.drainClaimedJob` in
  `ControlPlaneStore+Memory.swift` ~line 1631) uses `authorityWritesEnabled()` for
  BOTH the pre-claim guard AND `addChatMemoryAuthorityRecord(..., enabled:)`. So the
  durable write happens whenever lever 1 is true; lever 2 is dead code here.
- Contrast `OpenBurnBarMemoryService.init` (the direct `add()` path) which DOES
  default `authorityWritesEnabled` to `chatMemoryAuthorityWritesEnabledByDefault`
  (false). Two write paths, inconsistent gating; the extraction worker (the real
  chat-memory write path) is the unguarded one.

Lever 1 DEFAULTS OPEN:
- `MemorySettings.automaticExtraction = true`, `remoteConfigExtractionEnabled = true`
  (AgentLens/Services/Settings/Stores/MemorySettings.swift:15,27).
- RC default `"memory_extraction_enabled": NSNumber(value: true)` (SettingsManager.swift:252).
- RC only closes the gate on a *fetch error* (SettingsManager.swift:289) or an
  explicit server `false`. If Firebase absent (`FirebaseApp.app()==nil`), refresh
  returns early and RC stays default true.

Live wiring is real (not test-only):
`startLiveServicesIfNeeded` (AgentLensApp.swift:1375, behind shouldUseTestStubScene)
-> `startMemoryExtractionIfNeeded` -> `engine.launchDrain()`; plus
`ChatSessionController.scheduleMemoryDrainAfterCommit()` after every terminal commit.

NET: on any normal fleet, terminal assistant commits enqueue + drain + DURABLY WRITE
chat memories with no human go-live, bypassing the flag the whole design rests on.
The e2e `MemoryActivationEndToEndTests` "proves" this bug-as-feature: it only sets
`memoryExtractionEnabled=true` (never the authority flag) yet asserts a memory IS
written. No test asserts {extraction on + authority off => no write} because the
engine makes that combination unrepresentable.

FIX: worker authority gate must be `killSwitch.isAllowed() && chatMemoryAuthorityWritesEnabledByDefault`
(AND of both levers), and add a regression test for the on/off-authority matrix.

## What is genuinely solid (do NOT re-flag)
- Pump tri-state DrainOutcome (drained/claimedButFailed/idle) — does NOT halt on one
  failing job; proven by `test_pump_drainsPastFailingJob`.
- Worker is sole provenance authority: `recomputeProvenance` re-derives contentHash =
  SHA256(source body), xdevice_hmac = `v1-local:` content-derived tag (NOT the
  idempotency key, NOT a secret). `test_worker_recomputesProvenanceFromSourceMessageIgnoringModelSuppliedHashes`
  feeds MODEL-FORGED-* and asserts they're ignored. Citations are lookup-only,
  thread-scoped + role-restricted (user/assistant) via `fetchChatProvenanceSourceMessage`.
- G7 gate is fail-closed (corpus-unavailable => reject); run as per-candidate DROP in
  BOTH extractor and worker. Transactional atomic-outbox enqueue is real.
- Concurrency boxes (MemoryExtractionKillSwitch/SettingsBox: NSLock + nonisolated(unsafe))
  match shipping repo patterns; resolver mirrors SummaryAPIKeyResolver.

## Secondary holes
- Worker-side G7 gate is UNTESTED under a secret (extractor always filters first), so
  the defense-in-depth backstop is unproven.
- Cloud daily cap reads `summarySpendToday` but memory NEVER records its own cloud
  spend (MemoryExtractionLLMClient writes no usage row) -> memory cloud spend is
  unmetered against its own cap; cap only trips on summary spend.
- Idempotency id `memory-{job.id}-{index}` is POSITION-based over non-deterministic LLM
  output; a retry with reordered candidates can mis-key under ON CONFLICT DO NOTHING.
- App target was NOT compiled ("deferred to human heavy lane"); only Core builds.
  MainActor/Sendable boundaries mirror shipping patterns so risk is low, but unproven.
