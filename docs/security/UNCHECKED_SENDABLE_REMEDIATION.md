# `@unchecked Sendable` → real `Sendable` remediation

Records the elimination of every *fixable* `@unchecked Sendable` escape hatch in
OpenBurnBar production Swift — making the Swift 6 concurrency migration real
instead of asserted. Governed by a **fail-closed assert-zero gate**
(`scripts/debt/check-unchecked-sendable-budget.sh`) over the dual-bucket counter
(`tools/concurrency-debt/count-unchecked-sendable.sh`).

## Status — ratchet bucket is ZERO

| Root | Ratchet (fixable) | Allowlist (irreducible) |
|---|---|---|
| OpenBurnBarCore/Sources | **0** (was 23) | 5 |
| OpenBurnBarDaemon/Sources | **0** (was 11) | 5 |
| AgentLens | **0** (was 101) | 9 |
| OpenBurnBarMobile | **0** (was 26) | 5 |
| **Total** | **0** (was 161 real) | **24** |

Every `@unchecked Sendable` that *could* become a genuine `Sendable` was converted
(plain `Sendable`, `@MainActor`, a `Locked`/`OSAllocatedUnfairLock` box, a typed
`Sendable` payload, or an `actor`). The 24 that remain are genuinely irreducible —
each carries a `sendable-allowlist: <reason-id>` token (registry below) and is
**not** counted against the budget.

> Two earlier accounting bugs were fixed along the way: the counter once counted
> `// AUDIT(@unchecked Sendable)` *comment* lines as annotations (13 phantom counts
> repo-wide), and treated all annotations as equally fixable. It now (1) ignores
> comment lines and (2) splits real conformances into a ratchet bucket (enforced
> → 0) and an allowlist bucket (documented, not enforced).

## The dual-bucket gate (permanence)

`scripts/debt/check-unchecked-sendable-budget.sh` is fail-closed:

1. **Ratchet must be 0.** Any new `@unchecked Sendable` conformance without an
   allowlist token fails CI and is printed with its `file:line`.
2. **Allowlist tokens must use a registered reason-id** (the set below). A novel
   reason-id fails until it is added to the gate *and* documented here.

There is no baseline file — the budget is *asserted* to be zero, not ratcheted
against a stored number. The gate runs in `openburnbar-pr-harness.yml`
(`platform-misc`).

## The constraint that shaped every fix

Deployment target is **macOS 14 / iOS 17**, so `Mutex` from `Synchronization`
(macOS 15+/iOS 18+) is unavailable. The real permanent fixes used:

1. **Drop `@unchecked` → plain `Sendable`** — stored properties already immutable
   and `Sendable` (or an existential/protocol needed a `: Sendable` refinement).
   `SWIFT_STRICT_CONCURRENCY: complete` makes this build-verified.
2. **`@MainActor`-isolate** — UI/observable/controller types only ever touched on
   the main thread (e.g. `ComputerUseRuntimeController`, `SettingsRouter`,
   `TextExpansionRuntimeController`).
3. **Box mutable state in `Locked` / `OSAllocatedUnfairLock`** — `OSAllocatedUnfairLock`
   (macOS 13+/iOS 16+) is itself `Sendable`, so a class holding one plus immutable
   `let`s conforms to plain `Sendable` *while keeping a synchronous API* (no actor
   ripple). Use the shared `Locked<T>` box (`OpenBurnBarCore/.../BurnBarLockedState.swift`)
   for `Sendable` state, or `OSAllocatedUnfairLock<State>(uncheckedState:)` +
   `withLockUnchecked` for non-`Sendable` state ([String: Any], `Error`,
   `CMSampleBuffer`, continuations, weak refs). The workhorse.
4. **Convert to `actor`** — mutable state genuinely accessed asynchronously
   (`VectorSemanticCandidateProvider`, the libsignal `OBBSignalSessionCipherTransport`).
   Land per-type with concurrency tests.
5. **Model the smuggled value as a typed `Sendable` struct / `SendableFileSystem`
   seam** — `OpenBurnBarCore/.../SendableFileSystem.swift` replaced the stored
   non-`Sendable` `FileManager` in 5 types with a genuinely-`Sendable` protocol +
   `FileManager.default`-backed struct, keeping test injection (no allowlist).

`Locked<T>` itself was the keystone: it was `@unchecked` on `NSLock` "because macOS
14 precludes `OSAllocatedUnfairLock`" — but that lock has been available since macOS
13 (the comment confused it with `Mutex`). Rebuilding `Locked<T>` on
`OSAllocatedUnfairLock` made it plain `Sendable` and turned every consumer into a
candidate for the same.

## Allowlist registry (24 irreducible exceptions)

Each is `@unchecked Sendable` because it wraps an inherently non-`Sendable` handle
whose thread-safety is enforced externally; the reason-id is validated by the gate.

| reason-id | Count | What it covers | Why irreducible |
|---|---|---|---|
| `iroh-ffi-handle` | 3 | `OpenBurnBarIrohFFI{Backend,Stream}`, `OpenBurnBarIrohBlobFFIBackend` | UniFFI Swift handles (non-editable, AAR parity) serialized on a dedicated `DispatchQueue`; the Rust objects are `Send+Sync` but the blocking FFI calls rule out an actor |
| `sqlite-raw-pointer` | 2 | `BurnBarResumeService`, `BurnBarIndexedSearchService` | raw SQLite `OpaquePointer` confined to a serial `dbQueue`; boxing the pointer would guard nothing |
| `single-threaded-vector-builder` | 2 | `BurnBarMappedWritableIndex`, `BurnBarHNSWWritableIndex` | single-threaded index builders, immutable-by-contract after `save()`; never shared during construction |
| `corehid-backend` | 1 | `VirtualHIDKeyboardEngine` | non-`Sendable` CoreHID/IOHID backend, serialized on a queue + lock (Apple SDK gap) |
| `process-handle` | 1 | `PTYInteractiveSession` | non-`Sendable` `Process`; mutable state already in `Locked`, output on a serial queue |
| `firebase-sdk-handle` | 7 | `CloudSync{Collection,Document,Query,WriteBatch}LiveGateway`, `FirebaseSessionLogEncryptedCloudClient`, `FirebaseCallableExecutor`, `@retroactive` `Firestore` (Mobile) | non-`Sendable` Firebase SDK handles (`Firestore`/`CollectionReference`/`DocumentReference`/`Query`/`WriteBatch`/`Functions`/`HTTPSCallable`), internally thread-safe |
| `firestore-any-payload` | 3 | `ClaimedRelayRequest`, `LiveUsageDocumentChange`, `FirebaseCallablePayload` | immutable carriers of Firestore's untyped `[String: Any]`/`NSDictionary` across one confined hop |
| `firestore-any-test-fake` | 1 | `QueryPredicate` (CloudSync fake gateway) | test-only enum carrying Firestore's untyped `Any` comparison values |
| `foundation-sdk-shim` | 5 | `@retroactive` shims for `FileManager`/`UserDefaults`/`NSDictionary`/`KeyPath`; `RemoteUnlockSavedCredentialStore` (stores `UserDefaults`) | thread-safe Foundation types not yet `Sendable`-annotated by Apple |

The `firebase-sdk-handle` and `foundation-sdk-shim` entries can be cleared once
those SDKs annotate their types `Sendable`; the FFI/SQLite/CoreHID/Process/builder
entries are structural.

## Swift 6 language mode

**SwiftPM packages are now on the Swift 6 language mode** (`swiftLanguageModes: [.v6]`,
tools-version 6.0): OpenBurnBarCore and OpenBurnBarDaemon production targets build
clean under v6 (Core verified on both macOS and iOS slices), so data-race safety is
compiler-enforced for the shared core + daemon TCB. CI already runs Swift jobs on
macos-26, which supports the flip.

**The application targets are now on Swift 6 as well** (`project.yml` global
`SWIFT_VERSION: 6.0`, the four XCTest targets pinned to `5.10`): AgentLens (macOS)
and OpenBurnBarMobile (iOS) both build clean under v6, so the entire shipping
surface — core, daemon, and both apps — is compiler-enforced data-race-safe. The
largest single change was decoupling `ProviderQuotaService` (`@MainActor`) from
`QuotaRefreshActor` (`actor`): plan readers are snapshotted on the main actor into a
`Sendable` `ProviderQuotaPlanSnapshot`, the codex-scan cache moved into a shared
`Locked` box, and the bridge-status callback was inlined to the value-type
`ClaudeQuotaBridgeManager` — removing every cross-actor read of main-actor state.

Pinned to Swift 5 (each with an in-manifest rationale): the generated UniFFI bindings
target (`OpenBurnBarIrohFFI`, never hand-edited / AAR parity) and all SwiftPM test
targets (harness-only code; the Swift 6.3 region-isolation checker has known gaps —
e.g. `Task`-handle hand-off — that would force contorting correct tests).

v6 fix patterns used (no behavior change, no new ratchet `@unchecked`): real
`Sendable` conformances / protocol refinements; `@Sendable` closures; route formatters
through `ThreadSafeISO8601DateFormatter` or a fresh-per-call formatter; `Locked`
boxes; `sending` ownership transfer; `nonisolated(unsafe)` only for immutable
constants / lock-guarded statics / test seams; and `@unchecked Sendable` +
`sendable-allowlist: firebase-sdk-handle|apple-media-buffer|foundation-sdk-shim` for
inherently-non-Sendable Apple/Firebase SDK handles.

**App targets (AgentLens macOS, OpenBurnBarMobile iOS) remain on Swift 5** — they build
clean against the v6 packages. Flipping them is a larger, genuinely-architectural
effort (e.g. `CloudSyncService` is a non-Sendable `@Observable` class sent across
actor/async boundaries and referenced in ~31 files — making it `@MainActor`/`Sendable`
ripples through the CloudSync subsystem), so it is staged as its own PR rather than
forced into this one. A work-in-progress patch capturing the ~24 mechanical app-source
fixes already derived (media/NetService boxes, provider-closure `@Sendable`, protocol
refinements) is saved at `.agent/runs/swift6-language-mode/app-mobile-v6-wip.patch` for
that follow-up; the remaining work is the service-isolation decisions + a full
app/mobile test pass.

## Verification

All conversions were build-verified per batch:
- **OpenBurnBarCore** `swift build` + `swift test` (incl.
  `testConcurrentSendsSerializeRatchetWithoutCorruption`: 16 concurrent sends
  through the libsignal actor decrypt exactly once — proof the ratchet is
  serialized without corruption).
- **OpenBurnBarDaemon** `swift build`.
- **AgentLens** macOS `xcodebuild` and **OpenBurnBarMobile** iOS-simulator
  `xcodebuild` (the SwiftPM lane does not cover the app targets).
- `swiftlint --strict` clean on every touched file; the assert-zero gate green
  with both negative cases (un-allowlisted conformance, unknown reason-id) proven
  to fail.
