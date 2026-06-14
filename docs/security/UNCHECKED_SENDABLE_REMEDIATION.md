# `@unchecked Sendable` → real `Sendable` remediation

Tracks the elimination of `@unchecked Sendable` escape hatches in OpenBurnBar
production Swift, making the Swift 6 concurrency migration real instead of
asserted. Governed by `budgets/unchecked-sendable-baseline.json` (CI fails on
increase via `scripts/debt/check-unchecked-sendable-budget.sh`).

## Status

| Root | Real annotations | Notes |
|---|---|---|
| OpenBurnBarCore/Sources | **7** (was 23) | 16 removed — see below |
| OpenBurnBarDaemon/Sources | **8** (was 11) | 3 removed — see below |
| AgentLens | 101 | classified backlog below |
| OpenBurnBarMobile | 26 | classified backlog below |
| **Total budget** | **142** | target: ≤ 120 (30d) / 0 (90d) |

> The budget counter (`tools/concurrency-debt/count-unchecked-sendable.sh`)
> previously counted `// AUDIT(@unchecked Sendable)` *comment* lines as if they
> were annotations (13 phantom counts repo-wide). It now counts real conformance
> annotations only, so the budget equals the number of live escape hatches and an
> AUDIT justification no longer inflates the debt.

## The constraint that shapes every fix

Deployment target is **macOS 14 / iOS 17**, so `Mutex` from `Synchronization`
(macOS 15+/iOS 18+) is unavailable. The real permanent fixes here are:

1. **Drop `@unchecked` → plain `Sendable`** — the type's stored properties are
   already immutable and `Sendable` (or only an existential needed a `: Sendable`
   refinement). `SWIFT_STRICT_CONCURRENCY: complete` makes this build-verified: if
   the compiler accepts plain `Sendable`, the type is provably race-free.
2. **`@MainActor`-isolate** — UI/observable/controller types only ever touched on
   the main thread.
3. **Box mutable state in `Locked` / `OSAllocatedUnfairLock`** — `OSAllocatedUnfairLock`
   (macOS 13+/iOS 16+) is itself `Sendable`, so a class holding one plus immutable
   `let`s conforms to plain `Sendable` *while keeping a synchronous API* (no actor
   ripple). Use the shared `Locked<T>` box (`OpenBurnBarCore/.../BurnBarLockedState.swift`)
   for `Sendable` state, or `OSAllocatedUnfairLock<State>(uncheckedState:)` +
   `withLockUnchecked` when the guarded state is non-`Sendable`. This is the workhorse.
4. **Convert to `actor`** — mutable state genuinely accessed asynchronously. Forces
   callers to `await`; land per-type with concurrency tests.
5. **Model the smuggled value as a typed `Sendable` struct** — when `@unchecked`
   exists only to carry a non-`Sendable` `[String: Any]` / Firestore value across an
   isolation hop.
6. **Keep `@unchecked` with an `AUDIT(...)` justification** — last resort, only when
   the type wraps an inherently non-`Sendable` handle (FFI object, raw pointer, a
   Foundation type not yet `Sendable`-annotated) whose thread-safety is enforced
   externally (a dedicated `DispatchQueue` or lock).

`Locked<T>` itself was the keystone: it was `@unchecked` on `NSLock` "because macOS
14 precludes `OSAllocatedUnfairLock`" — but that lock has been available since macOS
13. Rebuilding `Locked<T>` on `OSAllocatedUnfairLock` makes it plain `Sendable` and
turns every consumer into a candidate for the same.

## Audited exceptions kept in Core + Daemon (15)

These are correctly `@unchecked` with an in-code `AUDIT(@unchecked Sendable): …`
comment; each is a genuine non-`Sendable`-handle case, not unremediated debt.

| File | Type | Why it stays `@unchecked` |
|---|---|---|
| `OpenBurnBarIrohRelay/OpenBurnBarIrohFFIBridge.swift` | `OpenBurnBarIrohFFIBackend` | UniFFI `IrohEndpointHandle`, serialized on a dedicated `DispatchQueue` (blocking calls rule out an actor) |
| `OpenBurnBarIrohRelay/OpenBurnBarIrohFFIBridge.swift` | `OpenBurnBarIrohFFIStream` | UniFFI `IrohStream`, serialized on send/receive queues |
| `OpenBurnBarIrohRelay/OpenBurnBarIrohBlobFFIBridge.swift` | `OpenBurnBarIrohBlobFFIBackend` | UniFFI `IrohBlobNode`, serialized on a dedicated queue |
| `OpenBurnBarCore/BurnBarPersistentVectorIndex.swift` | `BurnBarMappedWritableIndex` | single-threaded index builder; never shared until `save()` |
| `OpenBurnBarCore/BurnBarHNSWVectorIndex.swift` | `BurnBarHNSWWritableIndex` | single-threaded HNSW graph builder |
| `OpenBurnBarSignalSessionTransport/OBBSignalSessionCipherTransport.swift` | `OBBSignalSessionCipherTransport` | libsignal `OBBSignalProtocolStore`/`ProtocolAddress` (non-Sendable). **Recommended follow-up: actor-isolate** (per-connection ratchet) in a dedicated PR with concurrency tests |
| `OpenBurnBarComputerUseCore/ComputerUseAuditExportSignerProvider.swift` | `ComputerUseKeychainAuditExportSignerProvider` | stores `FileManager` (thread-safe, not yet `Sendable`-annotated) |
| `OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift` | `BurnBarIndexedSearchService` | raw SQLite `OpaquePointer`, serialized on `dbQueue` |
| `OpenBurnBarDaemon/BurnBarResumeService.swift` | `BurnBarResumeService` | raw SQLite `OpaquePointer`, serialized on a dedicated queue |
| `OpenBurnBarDaemon/PTYInteractiveSession.swift` | `PTYInteractiveSession` | non-`Sendable` `Process`; mutable state already in `Locked`, output on a serial queue |
| `OpenBurnBarDaemon/PensieveKnowledgeWatcher.swift` | `PensieveKnowledgeWatcher` | `FileManager` + dispatch-source state mutated only on `workQueue` |
| `OpenBurnBarDaemon/ClaudeInteractiveSessionExecutor.swift` | `ClaudeInteractiveSessionExecutor` | stores `FileManager` |
| `OpenBurnBarDaemon/ClaudeInteractiveHandoffService.swift` | `ClaudeInteractiveHandoffService` | stores `FileManager` |
| `OpenBurnBarDaemon/OpenBurnBarSwitcherShell.swift` | `BurnBarCLIShellShimInstaller` | stores `FileManager` |
| `OpenBurnBarRemoteAccessAgentCore/VirtualHIDKeyboardEngine.swift` | `VirtualHIDKeyboardEngine` | non-`Sendable` CoreHID/IOHID backend, serialized on a queue + lock |

The five `FileManager`-only exceptions can drop `@unchecked` the moment Foundation
annotates `FileManager: Sendable` (already `Sendable` in the Swift 6 SDK roadmap).

## Swift 6 language mode

The per-target `swiftLanguageMode(.v6)` flip is intentionally **not** done here: the
plan flips a target only once it reaches *zero* `@unchecked Sendable`, and Core/Daemon
still hold the audited exceptions above. Flipping early would also surface unrelated
strict-concurrency diagnostics out of this tranche's scope. The genuine-`Sendable`
conversions in this PR are the prerequisite work for that flip.

## AgentLens + OpenBurnBarMobile backlog (next tranches)

Full per-site classification from the 9-agent audit (2026-06-14). Sequenced
security-first, then by ascending risk/ripple.

### Fix-type summary (119 annotations across AgentLens + OpenBurnBarMobile)

| Recommended fix | Count | Caller ripple |
|---|---|---|
| Drop `@unchecked` → plain `Sendable` (all-immutable / already-Sendable members) | 57 | none |
| `@MainActor`-isolate (main-thread-only UI/observable types) | 15 | sync-preserved, none, forces-async |
| Box mutable state in `Locked`/`OSAllocatedUnfairLock` (sync API preserved) | 32 | none, sync-preserved |
| Model the smuggled `[String: Any]`/Firestore value as a typed `Sendable` struct | 9 | none, sync-preserved |
| Convert to `actor` (async-accessed mutable state) | 2 | forces-async |
| Keep `@unchecked` with an AUDIT justification (inherently non-Sendable handle) | 4 | none |

**Sequencing:** security-sensitive sites first (25 flagged: crypto / keychain / capability-token / pairing-key / signing). Then by ascending risk and ripple — `plain-sendable` and `@MainActor` are build-verified no-ops; `actor-isolate` (forces callers to `await`) lands last and per-type with concurrency tests.

### Security-sensitive sites (do first)

| File | Type | Fix |
|---|---|---|
| `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift` | `AgentToolBroker` | keep-audited-lock |
| `AgentLens/Services/CloudSync/RelayEphemeralKeyCache.swift` | `RelayEphemeralKeyCache` | osallocatedunfairlock-box |
| `AgentLens/Services/ComputerUse/ComputerUseCapabilityTokenService.swift` | `ComputerUseCapabilitySigningKeyStore` | plain-sendable |
| `AgentLens/Services/ComputerUse/Mac/RemoteUnlockCapabilitySigningKeyStore.swift` | `RemoteUnlockCapabilitySigningKeyStore` | osallocatedunfairlock-box |
| `AgentLens/Services/ComputerUse/PhoneControlAuthorityProvider.swift` | `FirestorePhoneControlAuthorityProvider` | plain-sendable |
| `AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift` | `PhoneControlAuthorityValidator` | osallocatedunfairlock-box |
| `AgentLens/Services/ComputerUse/PhoneControlConsumedProofStore.swift` | `PhoneControlConsumedProofStore` | plain-sendable |
| `AgentLens/Services/ComputerUse/PhoneControlReceiver.swift` | `PhoneControlReceiver` | osallocatedunfairlock-box |
| `AgentLens/Services/ComputerUse/PhoneControlReplayCounterStore.swift` | `PhoneControlReplayCounterStore` | plain-sendable |
| `AgentLens/Services/CursorConnector/CursorConnectorManager.swift` | `CursorConnectorSecretBroker` | osallocatedunfairlock-box |
| `AgentLens/Services/HermesRelaySenderTrustResolver.swift` | `FirestoreHermesRelaySenderTrustResolver` | plain-sendable |
| `AgentLens/Services/HomeAssistant/HomeAssistantTokenStore.swift` | `InMemoryHomeAssistantTokenStore` | osallocatedunfairlock-box |
| `AgentLens/Services/Insights/MacFirebaseTokenProvider.swift` | `MacFirebaseTokenProvider` | plain-sendable |
| `AgentLens/Services/IrohRelay/IrohPairingKeyStore.swift` | `IrohPairingKeyStore` | plain-sendable |
| `AgentLens/Services/IrohRelay/IrohPairingPublicKeyPublisher.swift` | `IrohPairingPublicKeyPublisher` | plain-sendable |
| `AgentLens/Services/IrohRelay/IrohRelayKeyStore.swift` | `IrohRelayKeyStore` | plain-sendable |
| `AgentLens/Services/Media/IrohBlobKeyStore.swift` | `IrohBlobKeyStore` | plain-sendable |
| `AgentLens/Services/Media/MacMediaCapabilityGate.swift` | `RemoteUnlockCredentialKeyStore` | plain-sendable |
| `OpenBurnBarMobile/Services/ComputerUse/PhoneControlAuthorityPublisher.swift` | `PhoneControlAuthorityPublisher` | plain-sendable |
| `OpenBurnBarMobile/Services/ComputerUse/PhoneControlSender.swift` | `PhoneControlSender` | osallocatedunfairlock-box |
| `OpenBurnBarMobile/Services/ComputerUse/PhoneControlSender.swift` | `PhoneControlSigningKeyStore` | osallocatedunfairlock-box |
| `OpenBurnBarMobile/Services/IrohRelay/FirestoreIrohPairingPublicKeyProvider.swift` | `FirestoreIrohPairingPublicKeyProvider` | plain-sendable |
| `OpenBurnBarMobile/Services/IrohRelay/IrohRelayKeyStore.swift` | `IrohRelayKeyStore` | plain-sendable |
| `OpenBurnBarMobile/Services/Media/IrohBlobKeyStore.swift` | `IrohBlobKeyStore` | plain-sendable |
| `OpenBurnBarMobile/Services/MobileFirebaseTokenProvider.swift` | `MobileFirebaseTokenProvider` | plain-sendable |
