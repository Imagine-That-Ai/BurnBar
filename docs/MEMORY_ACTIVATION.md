# Memory Activation — end-to-end flow, kill levers, and the human GO-LIVE runbook

**Status:** The semantic-memory subsystem is **fully wired and live behind
consent.** Every component named below is built, tested, and merged to `main`.
The go-live flag (G2) was flipped to **true** in `fbce28fce6`
("fix(memory): enable chat memory authority writes (#1156)"), so the feature
activates as soon as the user grants consent (G0) with extraction enabled (G1).
Out of the box it is still dormant **by G0 alone**: consent defaults OFF, so no
transcript is read, no LLM round-trip runs, no durable row is written, and no
derived memory leaves the device until the user accepts the consent sheet. The
residual list in [§7](#7-residual-go-live-decisions-a-human-must-make) records
the decisions that were still open when the flag flipped.

This is the closing doc for the memory-activation build (Waves A–E of
[`2026-06-19-memory-activation-integrated-build-plan.md`](../../.gstack/projects/Ajnunezg-LaHormigaDormida/ceo-plans/2026-06-19-memory-activation-integrated-build-plan.md)).
It records the flow, the three independent kill switches, where each moving part
lives, and what a human still owns before activation.

Related design docs (the "why" and the schema): [`MEMORY_BACKEND_PLAN.md`](MEMORY_BACKEND_PLAN.md),
[`MEMORY_FRONTEND_PLAN.md`](MEMORY_FRONTEND_PLAN.md), [`MEMORY_STRATEGY_AUDIT.md`](MEMORY_STRATEGY_AUDIT.md).

The passive **usage-memory** lane (Safari asks + agent-session rollouts) builds
on this substrate with its own consent lattice (G0-U), a Stage 0–3 funnel, and
a hard v1 invariant — usage memories are local-only and never replicate to any
cloud lane. That delta is documented in
[`USAGE_MEMORY_DESIGN.md`](USAGE_MEMORY_DESIGN.md); the gates described below
are the CHAT lane's.

---

## 1. The three gates (read this first)

Durable memory is gated by **three independent, fail-closed levers**. They are
**AND-ed** at the worker boundary: **no `agent_memories` row is written unless
ALL THREE allow.** Because the outermost gate (G0 — consent) defaults OFF, the
system is dormant out of the box: no transcript is read, no LLM round-trip runs,
and no memory row is written, even before the go-live flag matters.

### Gate 0 (G0) — `consentGranted` (user consent, DEFAULT **OFF** — the outermost AND)

- **What it is:** explicit, persisted, first-run user consent. The outermost gate
  in the AND chain.
- **Where it is stored:** `MemorySettings.consentGranted` (persisted key
  `"memoryConsentGranted"`, **default OFF**). Surfaced via
  `SettingsManager.memoryConsentGranted` passthrough.
- **How it is granted:** the user accepts the first-run `MemoryConsentSheet`.
  Until then the field is `false` and the system never activates.
- **Where it enters the gate:** `MemoryExtractionGate.isEnabled(consentGranted:automaticExtraction:remoteConfigEnabled:)`.
  The full expression is:
  `memoryExtractionEnabled = consentGranted && automaticExtraction && remoteConfigEnabled`.
  Because `consentGranted` defaults `false`, **the entire expression is false by
  default** — no LLM egress, no spend, no writes — regardless of the fleet switch
  or go-live flag state.

### Gate 1 (G1) — `memoryExtractionEnabled` (the instant fleet kill, DEFAULT **FALSE** via G0)

- **What it is:** the combined G4 gate — G0 consent AND the user extraction toggle
  AND the Firebase Remote Config fleet kill switch, all three must allow.
- **Where it is computed:** `SettingsManager.memoryExtractionEnabled`
  (`AgentLens/Services/SettingsManager.swift:724`), which delegates to the pure
  gate `MemoryExtractionGate.isEnabled(consentGranted:automaticExtraction:remoteConfigEnabled:)`
  (`AgentLens/Services/Settings/Stores/MemorySettings.swift:61`).
- **The three inputs (all must be true):**
  - `MemorySettings.consentGranted` (G0 above) — **default OFF**.
  - `MemorySettings.automaticExtraction` — the user extraction toggle, persisted,
    **default ON** (only meaningful once consent is granted).
  - `MemorySettings.remoteConfigCloudModelsEnabled` — the Remote Config
    `memory_cloud_models_enabled` fleet switch for Memory Pro cloud models,
    **default true, not user-settable, not persisted**; ANDed with
    `cloudModelsEnabled` and base consent in `MemoryCloudModelsGate`.
  - `MemorySettings.remoteConfigExtractionEnabled` — the Remote Config
    `memory_extraction_enabled` fleet switch, **default true, not user-settable,
    fail-open on transport error**: a fetch error does NOT flip it false — the
    switch only turns off when a fetched (or previously cached) config value
    says `false` (`SettingsManager.refreshComputerUseRemoteConfigOnce`). The
    fleet kill therefore requires the config to actually reach the client at
    least once.
- **What it gates:** whether the LLM round-trip runs **at all**. It is the
  instant fleet kill: one Remote Config flip to false halts extraction across
  the fleet on the next pump tick.
- **How it reaches the off-main worker:** the `@MainActor` engine mirrors this
  `@MainActor`-computed property into a `Sendable`, `NSLock`-guarded atomic,
  `MemoryExtractionKillSwitch`
  (`AgentLens/Services/Memory/MemoryExtractionPolicy.swift:79`). The MainActor
  pushes the latest value in (`set`); the worker pulls it out (`isAllowed`).
  The gate is therefore **never cached** — every drain tick reads the live value.
  (Reading the `@MainActor` property synchronously from inside the worker actor
  would not compile under strict concurrency; the atomic is the bridge.)
- **Because G1 itself defaults FALSE (consent not granted), this lever is NOT an
  independent dormancy guarantee in isolation.** Dormancy for the full system is
  provided by G0 (outermost) combined with G2.

### Gate 2 (G2) — `chatMemoryAuthorityWritesEnabledByDefault` (the go-live flag, DEFAULT **TRUE** since `fbce28fce6`)

- **What it is:** a static Boolean — the **human-owned go-live switch**. It was
  flipped to `true` in `fbce28fce6` (#1156); since then dormancy rests on G0
  alone. Note this is compile-time state: there is **no runtime kill for durable
  writes** in the chat lane (only extraction has the Remote Config kill) — the
  usage-memory lane adds `memory_usage_authority_writes_enabled` to close that
  gap for its own writes.
- **Where it is defined:** `ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault = true`
  (`AgentLens/Services/DataStore/ControlPlaneStore.swift:10`).
- **What it gates:** the **durable write AND the LLM call**. The worker gates
  `authorityWritesEnabled()` — which is the kill-switch atomic AND the go-live
  flag — **pre-claim, before the extractor/LLM call**:
  `guard authorityWritesEnabled() else { return .idle }` in
  `MemoryExtractionWorker.drainClaimedJob`
  (`AgentLens/Services/DataStore/ControlPlaneStore+Memory.swift:1635`).
  This means **with go-live OFF (the default), the LLM is never called** —
  there is no "extract-but-don't-persist" intermediate state. The gate is also
  re-checked per-record at the persistence boundary
  `ControlPlaneStore.addChatMemoryAuthorityRecord(_:id:now:enabled:)`
  (`+Memory.swift:97`): `guard enabled else { throw ChatMemoryAuthorityError.disabled }`.
- **The full AND:** the engine constructs the worker with
  `authorityWritesEnabled: { killSwitch.isAllowed() && authorityWritesGoLiveEnabled }`
  (`AgentLens/Services/Memory/MemoryExtractionEngine.swift:161`). Both G1 (via
  the kill-switch atomic) and G2 must be true before the LLM is called or any
  write is attempted. G0 is upstream of G1 and blocks G1 from ever being true
  without consent.

### Gate truth table

| G0 `consentGranted` | G1 `memoryExtractionEnabled` | G2 `…AuthorityWritesEnabled` | Result |
|---|---|---|---|
| **false (default)** | (any) | (any) | **Fully dormant** — no LLM egress, zero writes. |
| true | **false** | (any) | No LLM egress, zero writes. |
| true | true | **false** | **LLM never called** — worker returns `.idle` at pre-claim guard; zero writes. |
| true | true | **true (default since `fbce28fce6`)** | Extraction is **live**: LLM runs, clean facts persist as `quarantined`. |

The default ship state is the top row: **dormant by G0** (consent OFF). With G2
now defaulting true, G0 is the load-bearing dormancy gate. The end-to-end test
asserts the gate matrix — extraction ON + authority OFF ⇒ 0 writes — in
`MemoryActivationEndToEndTests`.

### A fourth, independent lever for cloud egress

Cloud replication of approved memory has its **own** off-switch, unrelated to the
three above: `memoryApprovedCloudBackupEnabled`
(`SettingsManager.swift:746` = the user opt-in `MemorySettings.approvedCloudBackupEnabled`,
**default OFF**, ANDed with the Remote Config fleet ceiling). See [§5](#5-optional-cloud-sync-lane-pr-e2).

---

## 2. End-to-end flow

The loop is **trigger → transactional enqueue → engine drain → LLM extract →
G7 gate → quarantined store → review/approve → recall → citation → (optional)
cloud-sync.** Each leg below names the file and the guarantee it provides.

```
 chat terminal-assistant commit
        │  (G3 chokepoint: persistence layer, not UI state)
        ▼
 saveChatMessage  ──── INSIDE the chat-message write txn ────►  extraction_jobs outbox row
   ConversationStore+Chat.swift:96-103                            (atomic; no dual-write window)
        │
        ▼
 MemoryExtractionEngine.launchDrain()  ──►  runDrain() pump (bounded: maxJobsPerPump, deadline)
   MemoryExtractionEngine.swift                               re-reads L1 every tick
        │
        ▼
 MemoryExtractionWorker.drainNext()  ──► pre-claim L1∧L2 gate ──► claimNextMemoryExtractionJob
   +Memory.swift:1614                                              (15-min lease; singleton)
        │
        ▼
 ChatTranscriptExtractor (the @Sendable closure)  ──► local-only LLM round-trip ──► [MemoryAddRequest]
   ChatTranscriptExtractor.swift                       (no DB lock held across the call)
        │
        ▼
 per candidate:  G7 MemorySecretPIIGate.evaluate(.reject)  ──► secret/PII candidate DROPPED
   +Memory.swift:1649                                            (one bad candidate ≠ poisoned batch)
        │
        ▼
 worker recomputeProvenance()  ──► contentHash = SHA-256(SOURCE message), citations rebuilt
   +Memory.swift:1707               model is UNTRUSTED for provenance; unresolved cites dropped
        │
        ▼
 addChatMemoryAuthorityRecord(enabled: L1∧L2)  ──► reviewStatus = .quarantined, ON CONFLICT DO NOTHING
   +Memory.swift:97                                  + a SECOND G7 reject at the persistence boundary
        │
        ▼
 review / approve  (reviewStatus: quarantined → approved)
   +Memory.swift:794-848  (audit-chained)
        │
        ▼
 recallChatMemorySnippets()  ──► returns ONLY reviewStatus == .approved, validTo == nil
   +Memory.swift:652-655
        │
        ▼
 MemoryCitationChipView tap  ──► jumpToMemoryCitation() opens owning thread, scrolls, gold flash
   ChatSessionController+Search.swift:62
        │
        ▼  (independent opt-in lane, default OFF)
 MemoryCloudSyncDomain.sync()  ──► replicates ONLY approved, sealed, scope-matched facts
   MemoryCloudSyncDomain.swift
```

### 2.1 Trigger (G3 — the persistence chokepoint)

The extraction trigger is emitted from `ConversationStore.saveChatMessage`
(`AgentLens/Services/DataStore/ConversationStore+Chat.swift:47`), **not** from UI
streaming state. `makeMemoryExtractionIntent` (`+Chat.swift:120`) returns a job
intent **only** for a terminal, non-empty **assistant** commit, and only when a
memory service is wired. Extraction failure can never fail the chat save.

### 2.2 Transactional enqueue (atomic outbox — no dual-write)

`OpenBurnBarMemoryService` is an `actor` that conforms to
`TransactionalMemoryExtractionServing` via a `nonisolated func
enqueueExtraction(_:in: Database)` (`+Chat.swift:25`). `saveChatMessage` selects
the **transactional branch** (`+Chat.swift:96-103`): the outbox row is inserted
**inside the same `dbQueue.write` transaction** as the `chat_messages` row, so a
crash between the message write and the enqueue cannot lose a job. The async,
post-write fallback (`+Chat.swift:111-117`) exists only for a non-transactional
service; production wires the transactional one (PR-D3 must-fix #2).

The enqueue is idempotent: `MemoryExtraction.idempotencyKey(threadLogicalID:
messageID:promptVersion:)` (`+Chat.swift:34`) is a deterministic HMAC, so a
replayed commit collapses to one outbox event. (This idempotency key is an
**app-wide static key** salted by `promptVersion`; it is **not** an authenticated
cross-device identity and is deliberately *not* reused for provenance — see §2.6.)

### 2.3 Engine drain (the scheduler)

`MemoryExtractionEngine` (`AgentLens/Services/Memory/MemoryExtractionEngine.swift`)
is a `@MainActor @Observable` scheduler that mirrors the established
`AutoSummaryEngine`. It owns the drain loop, the live kill-switch atomic, and the
observable progress state. Its pump (`runDrain`) is bounded by **two** safety
rails (PR-D2 must-fix #6): `MemoryExtractionPolicy.maxJobsPerPump` (8) and
`maxPumpDuration` (4 min). It loops on the worker's **tri-state** `DrainOutcome`
(`drained` / `claimedButFailed` / `idle`), not a `Bool`, so one failing job does
**not** halt the backlog behind it (PR-D2 must-fix #1). Because the worker
swallows extraction errors (it marks the job failed and returns `claimedButFailed`
without re-throwing), the engine learns of failures by reading
`mostRecentFailedMemoryExtractionJob()` after each tick (must-fix #3).

All heavy work lives **off** the MainActor in the worker + extractor; the engine
stays MainActor-isolated so SwiftUI can observe it and the kill switch is updated
synchronously from the UI.

### 2.4 LLM extract (the untrusted producer)

`ChatTranscriptExtractor` (`AgentLens/Services/Memory/ChatTranscriptExtractor.swift`)
is the `@Sendable (MemoryExtractionJob) async throws -> [MemoryAddRequest]`
closure the worker invokes. It reads the transcript from the **same**
`ControlPlaneStore` the worker writes to (`extension ControlPlaneStore:
ChatExtractionTranscriptReading`, `+Memory.swift:1799`), runs a local-only LLM
round-trip via `MemoryExtractionLLMClient`
(`AgentLens/Services/Memory/MemoryExtractionLLMClient.swift`), assembles the
prompt with `MemoryExtractionPromptBuilder`, and parses output with
`MemoryExtractionParser`. The settings it reads each drain are an immutable
`Sendable` `MemoryExtractionSettingsSnapshot` pushed in via the `NSLock`-guarded
`MemoryExtractionSettingsBox` (`MemoryExtractionPolicy.swift:118`).

**Local-only is a HARD default, not a user preference**
(`MemoryExtractionEngine.localFirstProviderOrder`, `MemoryExtractionEngine.swift:339`).
The input transcript (possibly carrying secrets/PII) is sent to the provider
**before** any scan — the G7 gate is **output-only** — so memory extraction drops
cloud providers entirely. A configured cloud-first summary order is overridden for
memory; cloud transcript egress requires a separate, explicit consent/go-live gate
before it can exist.

The failure taxonomy: benign empties (terminal message not found, empty
transcript/output, all candidates dropped, all providers unavailable) return `[]`
so the **job succeeds**; only a genuine transient infra fault throws.

### 2.5 G7 secret/PII gate (the security spine)

`MemorySecretPIIGate`
(`OpenBurnBarCore/Sources/OpenBurnBarCore/Memory/MemorySecretPIIGate.swift`) is
the shared, public, `Sendable`, **fail-closed** pre-persistence gate, promoted
into `OpenBurnBarCore` so the app, the daemon, the tests, and iOS all share **one**
scanner (killing the prior two-scanner drift). Its API:
`evaluate(_:policy:) -> MemoryGateVerdict` with `.allow` / `.redact` / `.reject`
verdicts (`:128`), plus `findings(in:)`, `labels(in:)`, `findingIDs(in:)`.

- **Fail-closed:** a missing or corrupt corpus returns `.reject` with a synthetic
  `secret-scanner-corpus-unavailable` finding (`:98`, `:129`). The gate never
  silently allows.
- **Corpus loader:** `Bundle.module` by **flat filename** (Core resources are
  `.process`'d, which flattens nested folders — there is no `subdirectory:`),
  with an env-override + bounded upward filesystem walk fallback for the daemon
  executable and locally-staged bundles (`:599-639`). Source of truth:
  `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/secret-pattern-corpus.json`
  (mirrored at `tools/project-code-memory/secret-pattern-corpus.json`).
- **Finding-ID contract (the collision resolved in PR-C1):** `MemoryGateFinding`
  carries BOTH a stable dashed `id` (e.g. `openai-api-key`) and a human `label`.
  The daemon shim emits `.map(\.label)` (its historical contract, unchanged);
  the chat path + migration assertions + the worker `failureLabel` use the dashed
  ids. No suite the spec claimed stayed green was silently broken.
- **Data-integrity hardening (PR-C1 must-fix #3):** credit-card matching requires
  a Luhn check, IPv4 octets are bounded 0–255, and phone-vs-card ordering prevents
  a 10-digit phone from also matching as a card — so default-`reject` does not
  silently delete legitimate memories (version strings, order IDs, phones).

The gate runs at **two** points (defense in depth): as a candidate **DROP** filter
in the worker (`+Memory.swift:1649`, `.reject` policy — one secret-bearing
candidate is dropped, not the batch), and again as a hard **reject** at the
persistence boundary inside `addChatMemoryAuthorityRecord` (`+Memory.swift:107`,
which audit-logs `memory.secret_rejected` and throws). A future edit cannot
bypass the gate by calling the store directly.

### 2.6 Worker provenance authority (the model is untrusted)

The **worker** — not the model, not the extractor — is the **sole authority** for
provenance (`MemoryExtractionWorker.recomputeProvenance`, `+Memory.swift:1707`,
PR-D1 must-fix #1/#3). The model's `citation.messageID` is treated as a **lookup
key only**: the worker fetches the real source message
(`fetchChatProvenanceSourceMessage(threadID:messageID:)`) and **drops** any
citation whose message id is not a citable turn on the job's thread — it never
fabricates provenance.

- `contentHash` = SHA-256 of the **cited source message body**
  (`provenanceContentHash`, `:1769`) — the thing the citation points at, **not**
  the extracted memory body — so a later edit/deletion of the source is detectable.
- `crossDeviceHMAC` = a **v1 non-cryptographic, content-derived provenance tag**
  (`provenanceLocalTag`, `:1780`), prefixed `v1-local:`. It is explicitly **not**
  an authenticated HMAC and **not** derived from the idempotency key (that key is
  promptVersion-salted — the wrong envelope) nor any secret key. **This is why
  memory stays local-only:** the tag is the placeholder that gates cloud-sync;
  shipping a `*HMAC` field from an undefined key would be security theater. A real
  key lifecycle (Keychain, cross-device sync, rotation) is the precondition for
  enabling cloud egress (§7.2).

Persistence is idempotent on the deterministic id `memory-<jobID>-<index>`
(`memoryID(for:index:)`, `:1763`) via `ON CONFLICT(id) DO NOTHING`, so a job
re-processed after a reclaim is a no-op, not a duplicate.

### 2.7 Quarantined store

Every extracted fact is persisted with `reviewStatus = .quarantined`
(`+Memory.swift:1673`). Quarantined facts are **useless until approved** — they
are stored, auditable, and forgettable, but excluded from recall.

### 2.8 Review / approve

`reviewStatus` transitions quarantined → approved (or → rejected) through the
audit-chained update path (`+Memory.swift:794-848`), which records a
`memory.approve` / `memory.reject` audit event and adjusts validity windows.
**v1 ships extraction-only: nothing is auto-approved** (see §7.6) — without an
approval surface the feature will *look* dead even when working, which is a real
product risk to raise before activation.

### 2.9 Recall (approved-only, hard gate)

`recallChatMemorySnippets` (`+Memory.swift:652`) returns **only** records with
`reviewStatus == .approved && validTo == nil`, skips any with a tombstoned
source, and respects a token budget + limit. The page/search paths
(`chatMemoryPage` :613, `searchChatMemoryAuthorityRecords` :634) similarly exclude
`.rejected`. This approved-only recall gate is the safety property that holds
across **every** PR in the build: even with both write levers on, a quarantined
fact never surfaces in a prompt until a human approves it.

---

## Review inbox (the human approval surface)

Extracted facts are persisted as `reviewStatus = .quarantined` and are
**quarantined** — stored, auditable, and forgettable, but completely excluded
from recall until a human acts on them. The approval surface is the **Memory
Review inbox**:

- **Dashboard route:** `DashboardMainRoute.memoryReview` — the "Memory"
  destination in the main dashboard.
- **Settings shortcut:** a "Review pending memories" row in the Privacy /
  Indexing settings screen.

Approving a fact calls `store.setChatMemoryReviewStatus`, which transitions
`reviewStatus` to `.approved` via the audit-chained update path
(`+Memory.swift:794-848`) and records a `memory.approve` audit event. This is
the **only** path by which a memory becomes recallable — there is no
auto-approval path in v1. Rejecting a fact records `memory.reject` and excludes
it from both recall and cloud-sync permanently.

Recall stays gated to `.approved` + non-superseded (`validTo == nil`). A
quarantined or rejected fact cannot surface in any prompt regardless of other
gate state.

---

## G7 drop auditing

When `MemorySecretPIIGate` drops a candidate at the worker-level filter
(`+Memory.swift:1649`), a `memory.candidate_dropped` audit event is emitted
carrying only the **stable dashed finding IDs** (e.g. `openai-api-key`,
`credit-card`) — never the candidate text or any secret value. This gives the
corpus-tuning and leak-attempt-detection pipeline a durable, privacy-safe signal:
if a particular finding ID fires repeatedly, the corpus may need adjustment or
an exfil attempt may be underway. The audit event is structurally identical to
the `memory.secret_rejected` event fired at the persistence boundary, so both
gate layers are observable.

---

### 2.10 Citation jump (UX)

A recalled-memory citation chip surfaces on the latest completed assistant turn.
Tapping a device-local source calls
`ChatSessionController.jumpToMemoryCitation(messageID:)`
(`AgentLens/Views/Chat/ChatSessionController+Search.swift:62`). Because recall is
**app-wide** (no thread predicate), the dominant case is **cross-thread**: the
controller resolves the owning thread via
`dataStore.threadID(forChatMessageID:)`
(`AgentLens/Services/DataStore/DataStore+ConversationAccess.swift:180`), opens it
with the existing `openHistoryThreadAsync`, then bumps `memoryJumpRequestToken`
so `ChatMessagesStream.performPendingMemoryJump` (`ChatMessagesStream.swift:110`)
scrolls to the message and plays a gold highlight flash once the messages load.
This is pure local navigation — no decrypt or logging of bodies — and respects
the `.approved` / tombstone gating. Cross-device and corpus-unavailable chips
stay disabled.

### 2.11 Optional cloud-sync

See [§5](#5-optional-cloud-sync-lane-pr-e2).

---

## 3. Where each component lives

| Component | Path | Role |
|---|---|---|
| **Gate 0 — consent** | `AgentLens/Services/Settings/Stores/MemorySettings.swift` (`consentGranted`, key `"memoryConsentGranted"`) + `SettingsManager.memoryConsentGranted` | outermost AND; default OFF; granted via `MemoryConsentSheet` |
| **Gate 1** (combined G4 gate) | `AgentLens/Services/SettingsManager.swift:724` + `Settings/Stores/MemorySettings.swift:61` | `isEnabled(consentGranted:automaticExtraction:remoteConfigEnabled:)` — consent ∧ user toggle ∧ Remote Config fleet switch |
| **Gate 2** (go-live flag) | `AgentLens/Services/DataStore/ControlPlaneStore.swift:10` | static, default **true** since `fbce28fce6`, human-owned |
| Live kill-switch atomic | `AgentLens/Services/Memory/MemoryExtractionPolicy.swift:79` (`MemoryExtractionKillSwitch`) | MainActor→worker bridge for L1 |
| Settings snapshot + box | `MemoryExtractionSettingsSnapshot.swift`, `MemoryExtractionPolicy.swift:118` | off-main per-drain settings |
| Policy / safety rails | `AgentLens/Services/Memory/MemoryExtractionPolicy.swift` | caps, deadlines, daily cap |
| **Trigger** (G3 chokepoint) | `AgentLens/Services/DataStore/ConversationStore+Chat.swift:47,120` | terminal-assistant-commit → intent |
| **Transactional enqueue** | `ConversationStore+Chat.swift:96-103` + `OpenBurnBarMemoryService` | atomic outbox row |
| **Engine** (scheduler) | `AgentLens/Services/Memory/MemoryExtractionEngine.swift` | drain loop, pump, observable state |
| **Extractor** (closure) | `AgentLens/Services/Memory/ChatTranscriptExtractor.swift` | LLM round-trip → `[MemoryAddRequest]` |
| LLM client / prompt / parser | `MemoryExtractionLLMClient.swift`, `MemoryExtractionPromptBuilder.swift`, `MemoryExtractionParser.swift` | provider I/O + parsing |
| API-key resolver | `AgentLens/Services/Memory/MemoryExtractionAPIKeyResolver.swift` | per-provider key lookup |
| **Worker** (drain + provenance) | `AgentLens/Services/DataStore/ControlPlaneStore+Memory.swift:~1560-1799` (`MemoryExtractionWorker`) | claim, gate, recompute provenance, persist |
| **G7 gate** | `OpenBurnBarCore/Sources/OpenBurnBarCore/Memory/MemorySecretPIIGate.swift` | shared fail-closed secret/PII gate |
| G7 corpus | `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/secret-pattern-corpus.json` (+ `tools/project-code-memory/` mirror) | pattern source of truth |
| **Store** (authority CRUD + recall) | `AgentLens/Services/DataStore/ControlPlaneStore+Memory.swift` | `addChatMemoryAuthorityRecord`, recall/page/search |
| Forget / tombstone | `ControlPlaneStore+MemoryForget.swift` | two-phase forget |
| **Citation jump** | `AgentLens/Views/Chat/ChatSessionController+Search.swift:62` + `Views/Chat/Components/ChatMessagesStream.swift:110` | cross-thread open + scroll + flash |
| Thread resolution | `AgentLens/Services/DataStore/DataStore+ConversationAccess.swift:180` | `threadID(forChatMessageID:)` |
| **Cloud-sync domain** | `AgentLens/Services/CloudSync/MemoryCloudSyncDomain.swift` | approved-only sealed replication scheduler |
| Cloud-sync scheduling | `AgentLens/Services/RefreshOrchestrator.swift:186` | `runPostPersistencePhase` cadence |
| **App wiring** | `AgentLens/App/AgentLensApp+MemoryServices.swift` | one shared store, engine, start site |
| **End-to-end test** | `AgentLensTests/Active/MemoryActivationEndToEndTests.swift` | extract→store→recall→cite + gate matrix |
| Engine / extractor tests | `MemoryExtractionEngineTests.swift`, `MemoryExtractionExtractorTests.swift` | pump tri-state, provenance, drop |
| G7 tests | `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/MemorySecretPIIGateTests.swift`, daemon `.available` test | corpus, Luhn, fail-closed |
| CI app-build gate | `.github/workflows/app-pr-gate.yml` | PR-time app compile + test proof |

**App wiring guarantees** (`AgentLensApp+MemoryServices.swift`):

- **One shared `ControlPlaneStore`** built over the live db queue, handed to BOTH
  `OpenBurnBarMemoryService` (enqueue) and `MemoryExtractionEngine` (drain), so the
  worker is the sole provenance authority — no second store (must-fix #1).
- The engine is constructed **before** `ChatSessionController` and injected, so a
  first-session terminal commit can schedule a drain immediately (must-fix #4).
- `startMemoryExtractionIfNeeded` is called from `startLiveServicesIfNeeded`
  (already behind `shouldUseTestStubScene`), and is a no-op when L1 is off.
- The engine API surface has **no** reference to `addChatMemoryAuthorityRecord`,
  so the engine can only ever hand `MemoryAddRequest`s to the worker — the
  worker's preflight/quarantine cannot be bypassed (must-fix #3, asserted by test).

---

## 4. Build provenance (what landed, in order)

| Wave | What | Commit subject |
|---|---|---|
| A | Green baseline + app-target CI gate | `Wave A — green baseline + app-target CI gate` |
| B | Decompose `ControlPlaneStore` (chat-memory cluster → `+Memory.swift`) | `PR-B1 — decompose ControlPlaneStore chat-memory cluster` |
| C | Shared `MemorySecretPIIGate` security spine in Core | `PR-C1 — shared MemorySecretPIIGate security spine in Core` |
| D1 | LLM extractor + worker provenance authority | `PR-D1 — LLM extractor + worker provenance authority` |
| D2 | `MemoryExtractionEngine` scheduler + fixed worker pump | `PR-D2 — MemoryExtractionEngine scheduler + fixed worker pump` |
| D3 | App wiring of the extraction engine + headline E2E | `PR-D3 — app wiring of the extraction engine + headline E2E` |
| D-FIX | AND both dormancy levers in the worker authority gate | `PR-D FIX — AND both dormancy levers in the worker authority gate` |
| E1 | Citation jump (cross-thread) + gold flash | `PR-E1 — citation jump (cross-thread) + gold flash` |
| E2 | Schedule approved-memory cloud sync (DEFAULT OFF) | `PR-E2 — schedule approved-memory cloud sync (DEFAULT OFF)` |

---

## 5. Optional cloud-sync lane (PR-E2)

`MemoryCloudSyncDomain` (`AgentLens/Services/CloudSync/MemoryCloudSyncDomain.swift`)
schedules `MemoryCloudSyncService.syncApprovedMemories` into the existing
post-persistence refresh cadence (`RefreshOrchestrator.runPostPersistencePhase`,
scheduled at `:186`), mirroring `ConversationSyncService` /
`SessionLogSyncService`. **This is scheduling only — it enables no new egress
path.** `sync()` returns **before reading a single candidate or touching a
Firestore handle / vault key** unless **all** of these allow:

- `memoryApprovedCloudBackupEnabled` — the user opt-in (**default OFF**) ANDed
  with the Remote Config fleet ceiling (`remoteConfigExtractionEnabled`), so one
  fleet flip clamps memory egress shut even for an opted-in user.
- `accountManager.isFirebaseAvailable` / `isSignedIn` / `isCloudSyncEnabled` —
  the same account gates every other sync domain honours.

When all gates allow, the wrapped service replicates **exclusively**
`reviewStatus == .approved`, scope-matched, **sealed** facts (the store-level
`cloudSyncEligibleChatMemories` gate) with forget-receipt + tombstone
propagation. The backend `firestore.rules` approved-only sealed-write contract is
already deployed.

**Cloud-sync must NOT be enabled until both** (a) `crossDeviceHMAC` has a real key
lifecycle (replacing the `v1-local:` placeholder, §7.2) **and** (b) the
cloud-replication data-domain gates are in place (registry entry at
`end_to_end`, `scan-chat-cloud-plaintext.mjs` allowlist, `firestore.rules`). This
is the **last** lane to enable and is itself a residual product decision (§7.5).

---

## 6. How to verify it is OFF (sanity checks before and after any change)

1. `MemorySettings.consentGranted` persisted value is `false` (key
   `"memoryConsentGranted"`). G0 — the outermost gate — is OFF by default until
   the user accepts `MemoryConsentSheet`. If this is somehow `true` without a
   user action, investigate before proceeding.
2. `ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault == true`
   (`ControlPlaneStore.swift:10`). G2 — the go-live flag — has shipped `true`
   since `fbce28fce6`; the feature is live once G0 and G1 allow. Dormancy is
   therefore G0's job: check #1 is the load-bearing one.
3. `MemorySettings.approvedCloudBackupEnabled` default `false`
   (`MemorySettings.swift:32`). No cloud egress.
4. The engine's worker closure is the **AND** of the live atomic and the go-live
   flag (`MemoryExtractionEngine.swift:161`). Not the atomic alone.
5. `MemoryActivationEndToEndTests` asserts the gate matrix: extraction ON +
   authority OFF ⇒ **0 durable writes**.

A green run of the suite + these five checks is sufficient to assert the feature
ships dormant.

---

## 7. Residual GO-LIVE decisions a human must make

These are genuine forks (integrated build plan §5). **None should be
auto-decided.** Each carries the plan's recommended frontier-yet-shippable
default. The kill switch should be flipped ON only after **#1 has an owner +
mechanism, #3 / #4 / #6 / #7 are decided, and the end-to-end integration test is
green.** Cloud-sync (#5) additionally requires #2.

1. **Who/what flips `chatMemoryAuthorityWritesEnabledByDefault` (the go-live
   switch), and via what mechanism? — _owner: TBD. BLOCKS ON._**
   This is the actual activation. **Recommendation:** a dedicated Remote Config
   key (e.g. `memory_authority_writes_enabled`) **separate** from
   `memory_extraction_enabled`, so extraction and go-live can be gated
   independently. **Needs a named owner.**

2. **`crossDeviceHMAC` for v1: real key lifecycle, or non-crypto placeholder +
   local-only memory? — _owner: TBD. BLOCKS CLOUD-SYNC (#5), not local
   activation._**
   Today it is the `v1-local:` non-crypto tag (§2.6). **Recommendation:** ship
   **local-only** with the placeholder; build the HMAC key subsystem (Keychain
   storage, cross-device sync, rotation) as the gate for cloud-sync. Do not ship
   a `*HMAC` field computed from an undefined key.

3. **Default secret policy: REJECT vs REDACT? — _owner: TBD._**
   Current code: `.reject` at both gate points. **Recommendation:** keep
   **REJECT** (preserves fail-closed behavior; a secret-bearing fact is
   low-value). Expose REDACT as opt-in once redaction tests are battle-hardened.

4. **PII handling: reject / redact / allow emails & phones? — _owner: TBD._**
   A memory system arguably *wants* "user's email is x@y.com" as a profile fact.
   **Recommendation:** **REJECT all PII** for this activation phase (safest); flag
   profile-scoped PII allowance as a fast-follow. (The Luhn/IPv4 hardening in §2.5
   ensures reject does not eat phones/version strings.)

5. **Cloud backup default: ON vs OFF? — _owner: TBD._**
   Current code: `memoryApprovedCloudBackupEnabled` default OFF.
   **Recommendation:** keep **OFF** (explicit opt-in for cloud egress of derived
   memory, even sealed). Cross-device memory is the headline value, but consent +
   the missing HMAC key (#2) argue for opt-in first.

6. **Approval UX: auto-approve nothing, or auto-approve high-confidence
   user-authored preferences? — _owner: TBD._**
   Extracted memories are quarantined and **useless until approved** (recall gate,
   §2.9). v1 ships extraction-only. **Recommendation:** auto-approve **nothing**;
   the review inbox (`DashboardMainRoute.memoryReview`) is built and unit-tested
   but has **not had visual/UX QA on a running macOS app.** Visual QA of the inbox
   and the first-run `MemoryConsentSheet` is required before activation.
   **Without the inbox being visible and functional, the feature feels dead even
   when working — surface this product risk to Alberto before activation.**

7. **G7 corpus security review before fleet enable. — _owner: TBD._**
   The `secret-pattern-corpus.json` (in `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/`)
   gates what the G7 drop filter catches. A security review of the corpus — coverage
   completeness, false-positive rate for legitimate memories, Luhn/IPv4/phone
   edge cases — is required before enabling the feature at fleet scale. The
   `memory.candidate_dropped` audit trail (carrying stable finding IDs, not secret
   text) provides signal for post-activation corpus tuning.

8. **Cloud transcript egress is a separate go-live decision. — _owner: TBD._**
   Current code is local-only for memory extraction. **Recommendation:** keep it
   that way until there is a separate cloud-transcript consent gate, cumulative
   memory spend ledger, and product copy that names the provider behavior plainly.

9. **Input-side exfil acceptance. — _owner: TBD._**
   Full untrusted transcripts may contain secrets/PII before any output-side G7
   scan. Current local-only extraction avoids cloud transcript exfiltration. If a
   future build adds cloud fallback, gate it explicitly and document the accepted
   residual risk before fleet enable.

---

## 8. Usage memory — the G0-U gate lattice (safety architecture)

Usage memory derives memories from two passive exhausts (Safari asks the member
volunteered, and recorded agent-session rollouts) instead of chat transcripts. It
reuses this document's authority table, secret gate, review lifecycle, and forget
machinery — but it carries **its own consent lattice, its own two fleet kill
switches, and its own worker-facing kill-switch registry**, all defaulting
dormant.

**Scope of this section:** the *safety wiring* — every lever, its default, where
it is stored, and how it reaches an off-main worker. The program's *design*
rationale (why usage kinds ride the one authority table, the Stage 0–3 funnel,
the v61 sidecars, the CoreWeave provider pin, and the hard **v1 local-only
replication invariant**) lives in `docs/USAGE_MEMORY_DESIGN.md`, landing with
[PR #2266](https://github.com/Imagine-That-Ai/BurnBar/pull/2266). Read that for
"why"; read this for "which lever, what default, which file". Do not duplicate
either into the other.

Implementation: [`MemorySettings.swift`](../AgentLens/Services/Settings/Stores/MemorySettings.swift)
(settings + pure gates), [`SettingsManager.swift`](../AgentLens/Services/SettingsManager.swift)
(Remote Config resolution + combined gates),
[`MemoryExtractionPolicy.swift`](../AgentLens/Services/Memory/MemoryExtractionPolicy.swift)
(`UsageMemoryKillSwitchRegistry`). Pinned by
[`UsageMemoryGateTests`](../AgentLensTests/Active/Security/UsageMemoryGateTests.swift).

### 8.1 The lattice

Three pure gate enums compose the lattice. Each is a plain AND — any lever off
means the lane is shut — and each is kept free of Firebase and `SettingsManager`
so the logic is testable in isolation.

| Gate | Expression | Consumers |
|---|---|---|
| `UsageMemoryExtractionGate` | `usageConsentGranted && remoteConfigEnabled && remoteConfigResolved` | `SettingsManager.usageMemoryExtractionEnabled`; registry **extraction** lane |
| `UsageMemoryAuthorityWriteGate` | `remoteConfigEnabled && remoteConfigResolved` | `SettingsManager.usageMemoryAuthorityWritesEnabled`; registry **authority-writes** lane |
| `UsageMemoryCloudGate` | `extractionEnabled && cloudConsentGranted && placementIsCloud` | `SettingsManager.usageMemoryCloudCurationEnabled` |

Note what is **not** in the extraction gate: the two per-source toggles. They
select *which* sources feed the pipeline once it is running; they are not safety
levers and cannot open anything on their own.

The authority-write gate is deliberately **independent of consent** — it is a
fleet quarantine on durable writes, not a user preference — which is why a fleet
flip can halt usage *writes* without disturbing extraction or the chat lane. This
runtime write kill is **new relative to the chat lane**, whose equivalent (G2,
[§1](#gate-2-g2--chatmemoryauthoritywritesenabledbydefault-the-go-live-flag-default-false))
is a compile-time static with no runtime channel.

### 8.2 Every settings key and its default

Persisted through `SettingsPersistenceCoordinator` (the `UserDefaults` key is the
property name in every case):

| Key | Default | What it does |
|---|---|---|
| `usageMemoryConsentGranted` | **false** | **G0-U.** The outermost lever. Until true, no Safari ask or session log is read and no usage memory is derived. Granting implies shown (§8.5). |
| `usageMemoryConsentShown` | **false** | Whether the usage consent prompt has been presented (granted **or** declined), so it is not shown twice. |
| `usageMemoryCloudCurationConsentGranted` | **false** | Separate opt-in for sending usage-derived material to a cloud curation model. Local extraction consent never implies it. |
| `usageMemoryModelPlacement` | **`.local`** | Where the curation model runs (§8.4). |
| `usageMemorySourceSafariAsksEnabled` | **true** | Source selector — inert until consent opens the gate. |
| `usageMemorySourceAgentSessionsEnabled` | **true** | Source selector — inert until consent opens the gate. |

Session-scoped, **never persisted** (a relaunch always re-derives them):

| Field | Default | What it does |
|---|---|---|
| `remoteConfigUsageExtractionEnabled` | true | Mirror of the `memory_usage_extraction_enabled` fleet switch. |
| `remoteConfigUsageAuthorityWritesEnabled` | true | Mirror of the `memory_usage_authority_writes_enabled` fleet switch. |
| `remoteConfigCloudModelsEnabled` | true | Mirror of the `memory_cloud_models_enabled` fleet switch (Memory Pro cloud models; not persisted). |
| `hasResolvedUsageRemoteConfig` | **false** | Whether either mirror has actually been filled from Remote Config (§8.3). |

The two mirrors default to the optimistic `true`, so **they are not themselves a
dormancy guarantee** — `hasResolvedUsageRemoteConfig` is what keeps them inert
until a real fleet value arrives. Out of the box the feature is dormant several
times over: no consent, nothing resolved, no cloud consent, placement `.local`.

### 8.3 The two Remote Config keys and their failure semantics

Both are declared in `SettingsManager.commercialRemoteConfigDefaults` with a
default of `true` (allowed), and both are refreshed by
`refreshComputerUseRemoteConfigOnce()` on the shared 60 s / 5 min / paused
`BackgroundCadenceCoordinator` cadence.

| Remote Config key | Mirrors | Kills |
|---|---|---|
| `memory_usage_extraction_enabled` | `remoteConfigUsageExtractionEnabled` | All usage extraction, fleet-wide, on the next propagation. |
| `memory_usage_authority_writes_enabled` | `remoteConfigUsageAuthorityWritesEnabled` | Durable usage authority writes only; extraction and the chat lane are untouched. |
| `memory_cloud_models_enabled` | `remoteConfigCloudModelsEnabled` | Memory Pro cloud-model egress, fleet-wide: the gate closes and the daemon is handed the policy disabled on the next propagation. Local memory is untouched. |

**Resolution is the load-bearing rule: both usage lanes are held CLOSED until a
Remote Config value has been applied.** The optimistic `true` defaults can never
open a lane on their own. Three paths resolve them, and only these three:

1. **At init**, from Firebase's **active cached** config —
   `SettingsManager.activeUsageMemoryRemoteConfigSnapshot()` is injected into
   `MemorySettings.init(persistence:usageRemoteConfigSeed:)` and applied *before*
   the first `propagateUsageGates()`. This is what makes a **cached fleet kill
   beat persisted consent**: a returning member with
   `usageMemoryConsentGranted == true` never propagates an open lane while a
   cached `false` sits on disk waiting to be read.
2. **Before the network fetch** in `refreshComputerUseRemoteConfigOnce()`, from
   the same active cached config — so a cached kill is not ignored for the
   duration of a round trip, and so the lanes still resolve when Firebase was
   configured *after* the settings manager was built (init seed `nil`).
3. **After a successful `fetchAndActivate`**, from the freshly activated values.

Failure semantics, matching the chat switch's documented posture:

- **Transport error (Firebase unreachable):** whatever the *active cached* config
  says stands, because step 2 already applied it. **Fail-open when nothing cached
  says kill** — an offline member who opted in is not stranded — but **a cached
  `false` remains authoritative**, so a fleet kill survives losing the network.
- **No activated config yet (fresh install):** `configValue` returns the declared
  default (`true`), which resolves the lanes to "allowed". Consent is then the
  only remaining lever, which is the intended posture.
- **Firebase not configured at all** (no `GoogleService-Info.plist`, so
  `FirebaseApp.app() == nil`): the seed returns `nil` and the refresh returns
  early, so **nothing ever resolves and usage memory stays dormant for the whole
  process.** This is deliberate — fail-closed beats guessing when the fleet has
  no channel to this build — but it is a real consequence to know about, and it
  differs from the chat lane, which would run on its local levers alone. Any
  future non-Firebase resolution path must go through the single seam
  `SettingsManager.applyUsageMemoryRemoteConfig(extractionEnabled:authorityWritesEnabled:)`.

Writing `usageMemoryExtractionRemoteConfigEnabled` / …`AuthorityWrites`… directly
sets the mirror but **does not resolve**, so no partial or stray write can
promote a defaulted `true` into an open lane. `applyUsageRemoteConfig` takes both
values together for the same reason: the lanes resolve as a pair, never half.

### 8.4 The placement enum

`UsageMemoryModelPlacement` (`String`-raw, `CaseIterable`) decides where curation
inference runs, and is the third lever of the cloud gate:

| Case | Raw value | `isCloud` | Meaning |
|---|---|---|---|
| `.local` | `local` | **false** | **Default.** On-device model; nothing usage-derived leaves the machine. |
| `.cloudText` | `cloudText` | true | A user-configured cloud text model. |
| `.burnbarCloud` | `burnbarCloud` | true | The BurnBar-hosted curation service. |

`isCloud` is defined as `self != .local`, so a future case is cloud-by-default —
adding one cannot silently create a new egress path that skips the cloud gate.

### 8.5 Consent invariants

**Granting implies shown, one way only.** Granting consent marks the prompt
shown, so a consenting member is never re-prompted; a *shown* prompt never
implies consent (declining leaves `granted == false` and the loop dormant).

Two mechanisms uphold this across a relaunch:

1. `init` loads `…ConsentShown` **before** `…ConsentGranted`, so a live grant is
   never overwritten by a stale persisted `shown`.
2. `normalizeConsentShownInvariants()` runs after every load and repairs a torn
   state (`granted == true` with `shown` false or absent — e.g. a crash between
   the coordinator's separate debounced writes). It covers both the usage and
   chat pairs, and the repair is **persisted**, not just in-memory.

**A macro subtlety worth knowing**, because it is easy to get wrong in review:
Swift does not run property observers for assignments made from inside an
initializer — but `MemorySettings` is `@Observable`, and that macro rewrites each
stored property into a computed property backed by `_property`. An `init`-body
assignment to a property that already has a default value therefore goes through
the **setter**, and `didSet` *does* run (the same class without `@Observable`
behaves the opposite way). So the granted-implies-shown propagation already
worked — but only as a side effect of macro expansion. Step 2 exists to make the
invariant explicit and independent of it, pinned by
`UsageMemoryGateTests.testTornConsentStateIsRepairedOnLoad`. Do not rely on the
implicit behavior when adding a new consent pair.

### 8.6 How the worker-facing registry lanes are populated

Future usage-memory workers run **off the main actor** and cannot read the
`@MainActor` combined gates synchronously, so the same push/pull discipline the
chat lane uses applies here — with two independent lanes instead of one.

`UsageMemoryKillSwitchRegistry` (in `MemoryExtractionPolicy.swift`) holds two
arrays of **weak** boxes over the shared `NSLock`-guarded
`MemoryExtractionKillSwitch`, one per lane:

- **Register (worker side).** A worker builds a `MemoryExtractionKillSwitch`
  (which starts CLOSED) and calls `registerExtraction(_:initiallyAllowed:)` or
  `registerAuthorityWrites(_:initiallyAllowed:)`, seeding it from the live
  MainActor gate. Dead entries are swept on every register and set.
- **Push (settings side).** `MemorySettings.propagateUsageGates()` runs on every
  relevant `didSet` — consent, either RC mirror, the resolution flag — and on
  `init`. It recomputes both gates and pushes into both lanes:
  `setExtraction(UsageMemoryExtractionGate.isEnabled(…))` and
  `setAuthorityWrites(UsageMemoryAuthorityWriteGate.isEnabled(…))`.
- **Pull (worker side).** The worker reads `isAllowed()` per drain tick through a
  `@Sendable () -> Bool` closure. **The gate is never cached** — every tick sees
  the current value, so a fleet kill takes effect on the next tick.

Unlike the chat registry, there is **no drain-launcher lane**: opening a usage
gate pushes the value but does not itself kick a drain.

**Consuming these lanes correctly:** a worker must AND the extraction lane before
reading any source material, and AND the authority-writes lane before any durable
write — reading the registry, never a cached copy of a settings value.

### 8.7 Verifying usage memory is OFF

Sibling of [§6](#6-how-to-verify-it-is-off-sanity-checks-before-and-after-any-change),
for the usage lane:

1. `usageMemoryConsentGranted` persisted value is `false` (G0-U). If it is `true`
   without a member action, investigate before proceeding.
2. `hasResolvedUsageRemoteConfig` starts `false` on every launch — confirm no code
   path sets it outside the three resolution paths in §8.3.
3. `usageMemoryModelPlacement` is `.local` and
   `usageMemoryCloudCurationConsentGranted` is `false` — zero cloud egress.
4. `UsageMemoryGateTests` is green, including the exhaustive fail-closed matrices
   for both gates, the cached-kill-at-init case, and the torn-consent repair.
5. Usage memories reach **no** cloud lane at all in v1 — see the replication
   invariant in `docs/USAGE_MEMORY_DESIGN.md` ([PR #2266](https://github.com/Imagine-That-Ai/BurnBar/pull/2266)).

---

## 9. Keeping this doc honest

When any lever default, gate point, or component path above changes, update this
file in the same PR, and refresh the mem0 / `droid-wiki` mirror on commit (per
[`AGENTS.md`](../AGENTS.md)). The line references are to the `memory/activation`
tree at the time of writing; treat them as starting points, not contracts — the
**names** (`chatMemoryAuthorityWritesEnabledByDefault`, `memoryExtractionEnabled`,
`MemorySecretPIIGate`, `recallChatMemorySnippets`, `UsageMemoryExtractionGate`,
`UsageMemoryAuthorityWriteGate`, `UsageMemoryKillSwitchRegistry`) are the durable
anchors.
