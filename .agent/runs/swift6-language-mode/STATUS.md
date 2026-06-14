# Swift 6 language-mode flip — status

## Done (PR #384, branch swift6/language-mode-flip) — MERGED
- OpenBurnBarCore production → Swift 6 mode (macOS + iOS slices clean; 1578 tests pass).
- OpenBurnBarDaemon production → Swift 6 mode (613 tests pass).
- Generated UniFFI target + all SwiftPM test targets pinned `.v5` (rationale in manifests).

## Done (branch swift6/app-mobile-language-mode) — BUILDS GREEN
- `project.yml` global `SWIFT_VERSION: 6.0`; the 4 XCTest targets pinned `5.10`
  (OpenBurnBarTests, OpenBurnBarDaemonTests, OpenBurnBarMobileTests, OpenBurnBarMobileUITests).
- **AgentLens (macOS)** `xcodebuild build` → ** BUILD SUCCEEDED ** under v6.
- **OpenBurnBarMobile (iOS sim)** `xcodebuild build` → ** BUILD SUCCEEDED ** under v6.
- Ratchet still **0** (all roots); allowlist 34 → 35 (the one new entry = retroactive
  `Firestore: @unchecked Sendable`, `firebase-sdk-handle`). Gate passes.
- swiftlint --strict clean on all 65 changed Swift files.

### Notable fixes (this branch)
- ProviderQuota: `ProviderQuotaService` (@MainActor) ⇄ `QuotaRefreshActor` (actor) decoupled —
  plan readers snapshotted on main into `Sendable ProviderQuotaPlanSnapshot`; codex cache → shared
  `Locked` box; `refreshClaudeBridgeStatus` callback inlined to value-type bridge manager.
- `AsyncPipeLineReader.ReaderState` NSLock → `Locked<BufferState>` (genuinely Sendable).
- `SampleBufferContext` mutable `weak var owner` → `let @MainActor` frame-sink closure.
- Main-queue NotificationCenter observers → `MainActor.assumeIsolated` (panic-halt, rotation lifecycle).
- `FileManager`/`User` crossings → drop stored handle / add `currentUserUID` String accessor.
- `[String: Any]` → Firebase callable: `sending` params + disconnected (array-consume / fresh) values.
- `FirestoreRepository.sanitizeForJSON` → `nonisolated static` (reachable off the @MainActor singleton).
- ~ISO8601 formatters: stored → computed (fresh per call, no shared mutable state).
- Retroactive `extension Firestore: @retroactive @unchecked Sendable` (mirrors AgentLens Foundation shims).

## Delivery
- [done] macOS test suite: 4096 pass / 0 logic regressions (17 env-only: 16 snapshot pixel-diffs
  + 1 keychain-TCC). ProviderQuota + 4 adapter test classes: 181/181 pass.
- [done] iOS test targets COMPILE clean; runtime blocked by pre-existing worktree
  iroh-FFI checksum mismatch (FFI untouched). iOS changes are behaviorally inert.
- [done] committed cf344d54 (74 files); pushed; PR #391 (base main, conflict-free — 0 file
  overlap with the 6 commits main is ahead).
- [done] self-audit: ProviderQuota behavior preserved; Firestore @unchecked justified;
  completeness gap found+closed (OpenBurnBarWidget + OpenBurnBarKeyboard iOS extensions
  built clean under v6; daemon Xcode helpers covered as macOS-app deps). No stray/dead code.
- [doing] CI on PR #391 (no macOS/Xcode Swift lane — local is the Swift gate; "No new
  suppressions" already green). Merge when CI green.
