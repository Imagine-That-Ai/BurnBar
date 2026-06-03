All changes are persisted. Let me do a final logical review of one edge: in `CloudBudgetService.downloadRemoteBudgetRules`, when a peer's rule is sealed but this device has no read key, `decodeRule` returns a `BudgetRule` with `projectName=nil`/`label=nil` (since `openSealedProjectName` returns nil for sealed-but-unreadable). The rule is still upserted (with nil project/label) — that's a transient until the key arrives. This matches the migration-tolerant intent. Acceptable.

All implementation complete. Let me provide the changelog.

## CHANGELOG

### `AgentLens/Services/CloudSync/UsageSyncService.swift` (Mac, usage writer)
- Added `import OpenBurnBarCore`.
- `init` now takes an injectable `vaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider()` (reuses the existing protocol/provider already used by `ConversationSyncService`, and the existing `TestConversationVaultKeyProvider` for tests).
- `sync()`: resolves the write key once via `vaultKeyProvider.keyForWriting(uid:deviceId:)` and threads it into `encodeUsage`.
- `encodeUsage(_:deviceId:vaultKey:)` (now `throws`): **removed plaintext `projectName`**; writes **`sealedProjectName`** (`CloudVaultCrypto.sealText` → `CloudVaultCrypto.dictionary` envelope) and **`projectKeyHash`** (opaque group-by trapdoor, omitted for blank names).
- Added `enum CloudVaultProjectSealError { case encodingFailed }` and an internal **`extension CloudVaultCrypto`** (Mac target) with: `dictionary(_:)`, `projectKeyHash(for:keyData:)` (single 32-hex HMAC trapdoor via existing `tokenHashes`, no new crypto), `openSealedProjectName(from:sealedField:legacyField:keyData:)` (legacy plaintext fallback; never leaks legacy when sealed-but-unreadable), `decodeSealedText(from:)` (JSON round-trip, matching the adjacent sync services).

### `AgentLens/Services/CloudBudgetService.swift` (Mac, budgetRules writer+reader)
- `init` now takes injectable `vaultKeyProvider` (same default/protocol).
- `uploadPendingBudgetRules()`: resolves the write key (skips the cycle if unavailable) and passes it to `encodeRule`.
- `downloadRemoteBudgetRules()`: best-effort read key passed to `decodeRule`.
- `encodeRule(_:vaultKey:)` (now `throws`): **removed plaintext `projectName` + `label`**; writes **`sealedProjectName`**, **`sealedLabel`** (sealText), and **`projectKeyHash`** (for the project name).
- `decodeRule(from:id:vaultKey:)`: opens `sealedProjectName`/`sealedLabel` via `CloudVaultCrypto.openSealedProjectName(...)` with legacy plaintext fallback.

### `OpenBurnBarMobile/Models/BudgetRulesStore.swift` (iOS, budgetRules writer+reader)
- `encodeRule(_:vaultKey:)` (now `throws`): same seal as Mac — **`sealedProjectName`**, **`sealedLabel`**, **`projectKeyHash`**, no plaintext.
- `decodeRule(from:id:vaultKey:)`: opens sealed fields with legacy fallback.
- Call sites updated: `upsertRule` (resolves write key after DEBUG mock early-return), `fetchAllRules`/`fetchRule` (read key), `startListening` snapshot closure (uses synchronous `cachedVaultKey()`).
- Added private helpers `writableVaultKey()`/`readableVaultKey()` (via `MobileCloudVaultKeyAccess.keyForWriting/keyForReading(uid:)`) and `cachedVaultKey()` (synchronous `CloudVaultKeyStore().loadKey`).

### `OpenBurnBarMobile/Services/FirestoreRepository.swift` (iOS, usage/budget decode)
- `decodeWithDocID` `TokenUsage` branch: opens `sealedProjectName` (legacy fallback) via `CloudVaultCrypto.openSealedProjectName(from:keyData: Self.cachedVaultKey())`, injects the opened value into `enriched["projectName"]` for the existing `Decodable`, and drops the sealed envelope. (Critical: `TokenUsage.init(from:)` requires `projectName`, so injection guarantees the key is present for sealed-only docs.)
- Lines ~699/~776 (`fetchHermesCloudLibrarySessions`, `streamManifest` — `session_logs` reads named in the contract reader list): now read project name via `openSealedProjectName` (sealed-aware + legacy fallback).
- Added nonisolated `static func cachedVaultKey()` (synchronous local-keychain key load for the signed-in uid).
- Added iOS-target `enum CloudVaultProjectSealError` + `extension CloudVaultCrypto` (same four helpers as the Mac extension; per-target to avoid cross-module duplication).

### `AgentLensTests/Active/UsageSyncRoundTripTests.swift`
- Injected `TestConversationVaultKeyProvider` into `usageSync` (required — `keyForWriting` otherwise hits real Firestore).
- Added `test_usageUpload_sealsProjectName_andWritesNoPlaintext`: asserts the raw cloud doc has **no** `projectName`, a well-formed AES-256-GCM `sealedProjectName` envelope, a 32-hex `projectKeyHash`, the serialized doc never contains the cleartext, and seal→open recovers the exact name; stable hash assertion.
- Added `test_usageUpload_emptyProjectName_omitsProjectKeyHash`: empty name still seals but omits the opaque hash.

### `AgentLensTests/Active/BudgetRuleSealingRoundTripTests.swift` (NEW)
- Budget-rule sealing round-trip (no Firestore needed; exercises the exact `CloudVaultCrypto` primitives the encoder/decoder use): seal→open round trip for `sealedProjectName`+`sealedLabel`, raw doc carries no plaintext, stable 32-hex `projectKeyHash`, legacy plaintext fallback decodes, sealed-but-no-key never leaks a stale plaintext value, empty name → no hash.

### New field names introduced (cross-platform, byte-identical envelope)
- `sealedProjectName` — `CloudVaultSealedText` dict `{algorithm,keyVersion,nonce,ciphertext,tag}` (usage + budgetRules).
- `sealedLabel` — same shape (budgetRules).
- `projectKeyHash` — 32-hex HMAC trapdoor of the normalized project name (usage + budgetRules; optional, omitted for blank names).

### DEVIATIONS / BLOCKERS / TODO (for the orchestrator)
- **`projectKeyHash` derivation**: the contract names `CloudVaultCrypto.tokenHashes` as the trapdoor but S1 owns `CloudVaultCrypto.swift`, so I could not add a dedicated single-term helper there. I implemented `projectKeyHash(for:keyData:)` in a per-target `extension CloudVaultCrypto` that **reuses only the existing public `tokenHashes`** (collapses the name to one canonical alphanumeric term, then HMACs it, taking the single 32-hex result). No new AES/HKDF/HMAC. If S1 later adds a canonical helper, these per-target shims should collapse onto it.
- **`extension CloudVaultCrypto` is defined twice** (once in the Mac `OpenBurnBar` target via `UsageSyncService.swift`, once in the iOS `OpenBurnBarMobile` target via `FirestoreRepository.swift`) because the two app targets are separate modules and `CloudVaultCrypto.swift` (S1-owned, in `OpenBurnBarCore`) was off-limits. Identical implementations; no in-target duplication. If the orchestrator prefers, fold both into one shared `OpenBurnBarCore` helper (S1).
- **`AgentLens/Services/CloudSync/DownloadSyncService.swift:344` reads plaintext `data["projectName"]` for the Mac peer-download of `usage`** and is NOT in my owned-file list, so I did not edit it. The legacy fallback keeps existing behavior/tests green, but **once writers seal, sealed usage rows downloaded peer→peer on Mac will lose the project name** until that line is switched to `CloudVaultCrypto.openSealedProjectName(from: data, keyData: <read key>)`. Flagging for the owning stream/orchestrator. (Line 452 reads `privatePayload.projectName` from an already-sealed conversation payload — unaffected.)
- **Migration transient**: a sealed budget rule/usage row read on a device that has not yet unwrapped the vault key decodes with `projectName=nil`/`""` (sealed-but-unreadable never leaks legacy plaintext). This is the intended migration window per CONTRACT §1; resolves once escrow delivers the key.
- Server-type (`legacy.ts` `UsageEventDoc`/`serializeUsageForCallable`), `firestore.rules` backstop, registry, and Android are owned by SA/SD/SE/SC — untouched here as required.