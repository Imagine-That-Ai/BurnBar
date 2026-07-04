# Memory Activation — end-to-end flow, kill levers, and the human GO-LIVE runbook

**Status:** The semantic-memory subsystem is **fully wired on `main`.** It is **dormant for most users** because Gate 0 (consent) defaults OFF. After consent, extraction and durable writes are live subject to G1 and G2 (see below). Cloud replication remains **opt-in OFF** (§5).

**Canonical activation runbook:** [`MEMORY_MCP_SOTA_PLAN.md`](MEMORY_MCP_SOTA_PLAN.md) §4 (staged rollout, committed §7 decisions). **Architecture:** [`architecture/013-unified-memory-authority-and-mcp-convergence.md`](architecture/013-unified-memory-authority-and-mcp-convergence.md).

Related design docs (the "why" and the schema): [`MEMORY_BACKEND_PLAN.md`](MEMORY_BACKEND_PLAN.md),
[`MEMORY_FRONTEND_PLAN.md`](MEMORY_FRONTEND_PLAN.md), [`MEMORY_STRATEGY_AUDIT.md`](MEMORY_STRATEGY_AUDIT.md).

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
  - `MemorySettings.remoteConfigExtractionEnabled` — the Remote Config
    `memory_extraction_enabled` fleet switch, **default true, not user-settable,
    fail-closed** (a fetch error flips it false).
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

### Gate 2 (G2) — authority writes (compile-time ceiling AND Remote Config go-live)

- **What it is:** the **human-owned fleet go-live switch** for durable writes and LLM
  extraction, ANDed at the worker boundary with G1.
- **Compile-time ceiling:** `ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault = true`
  (`AgentLens/Services/DataStore/ControlPlaneStore.swift:10`). Tests may inject `false`
  to exercise the gate matrix.
- **Fleet lever (preferred):** Firebase Remote Config `memory_authority_writes_enabled`
  (default **true**, fail-closed on fetch error when the active cached value is false).
  Surfaced as `SettingsManager.memoryAuthorityWritesRemoteConfigEnabled`. Owner:
  **Alberto** via Firebase console percentage conditions (see
  `MEMORY_MCP_SOTA_PLAN.md` §4.3).
- **Combined gate:** `memoryAuthorityWritesEnabled` =
  `chatMemoryAuthorityWritesEnabledByDefault && memoryAuthorityWritesRemoteConfigEnabled`.
- **What it gates:** the **durable write AND the LLM call**. The worker gates
  `authorityWritesEnabled()` — kill-switch atomic AND authority gate — **pre-claim,
  before the extractor/LLM call**:
  `guard authorityWritesEnabled() else { return .idle }` in
  `MemoryExtractionWorker.drainClaimedJob`
  (`AgentLens/Services/DataStore/ControlPlaneStore+Memory.swift:1635`).
  Re-checked at persistence:
  `ControlPlaneStore.addChatMemoryAuthorityRecord(_:id:now:enabled:)`
  (`+Memory.swift:97`): `guard enabled else { throw ChatMemoryAuthorityError.disabled }`.
- **Full worker AND:** `killSwitch.isAllowed() && authorityWritesSwitch.isAllowed()`
  (`MemoryExtractionEngine.swift`). G0 is upstream of G1.

### Gate truth table

| G0 `consentGranted` | G1 `memoryExtractionEnabled` | G2 `memoryAuthorityWritesEnabled` | Result |
|---|---|---|---|
| **false (default)** | (any) | (any) | **Fully dormant** — no LLM egress, zero writes. |
| true | **false** | (any) | No LLM egress, zero writes. |
| true | true | **false** | **LLM never called** — worker returns `.idle` at pre-claim guard; zero writes. |
| true | true | true | Extraction is **live**: LLM runs, clean facts persist as `quarantined`. |

The default ship state is the top row: **fully dormant by G0**. The end-to-end
test asserts the gate matrix — extraction ON + authority OFF ⇒ 0 writes — in
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
| **Gate 2** (go-live flag) | `AgentLens/Services/DataStore/ControlPlaneStore.swift:10` | static, default false, human-owned |
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
2. `SettingsManager.memoryAuthorityWritesEnabled == true` (compile-time ceiling AND
   Remote Config `memory_authority_writes_enabled`, both default true). G2 — the go-live
   gate. Fleet rollout stages flip RC to false to halt writes without a client release.
3. `MemorySettings.approvedCloudBackupEnabled` default `false`
   (`MemorySettings.swift:32`). No cloud egress.
4. The engine's worker closure is the **AND** of the live atomic and the go-live
   flag (`MemoryExtractionEngine.swift:161`). Not the atomic alone.
5. `MemoryActivationEndToEndTests` asserts the gate matrix: extraction ON +
   authority OFF ⇒ **0 durable writes**.

A green run of the suite + these five checks is sufficient to assert the feature
ships dormant.

---

## 7. GO-LIVE decisions — committed (2026-07-04)

These were open forks in the integrated build plan. **Committed choices** (full
rationale in `MEMORY_MCP_SOTA_PLAN.md` §4.1):

1. **Go-live mechanism:** Remote Config `memory_authority_writes_enabled`, separate
   from `memory_extraction_enabled`. Owner: **Alberto** (Firebase console staged %).
2. **crossDeviceHMAC:** build real HKDF key lifecycle (task A2); cloud sync blocked
   until complete; `v1-local:` legacy-read only.
3. **Secret policy:** **REJECT** (pinned for v1).
4. **PII:** **REJECT all PII** for activation; profile allowance is fast-follow.
5. **Cloud backup:** **OFF** default, explicit opt-in.
6. **Approval UX:** **auto-approve nothing**; inbox required; visual QA gate (task A3).
7. **G7 corpus review:** required before % fleet (task A4).
8. **Cloud transcript egress:** **prohibited** in v1.
9. **Input-side exfil:** accepted as N/A while extraction stays local-only.

**Pre-GA blockers:** A3 inbox QA sign-off, A4 G7 review, A6 kill-switch drill, staged
rollout per `MEMORY_MCP_SOTA_PLAN.md` §4.3.

---

## 8. Keeping this doc honest

When any lever default, gate point, or component path above changes, update this
file in the same PR, and refresh the mem0 / `droid-wiki` mirror on commit (per
[`AGENTS.md`](../AGENTS.md)). The line references are to the `memory/activation`
tree at the time of writing; treat them as starting points, not contracts — the
**names** (`chatMemoryAuthorityWritesEnabledByDefault`, `memoryExtractionEnabled`,
`MemorySecretPIIGate`, `recallChatMemorySnippets`) are the durable anchors.
