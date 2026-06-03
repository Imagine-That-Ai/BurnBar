No stale callers. All call sites pass `vaultKey`. Implementation complete and self-consistent.

## CHANGELOG

### `OpenBurnBarMobile/Services/RollbackService.swift` (owned source)
- **`encodeRequest(_:vaultKey:)`** — now `static` + `throws`, takes `vaultKey: Data`. Seals the scope JSON → **`sealedScope`** (`CloudVaultCrypto.sealText` → canonical `CloudVaultSealedText` envelope `{algorithm,keyVersion,nonce,ciphertext,tag}`); **DROPPED plaintext `scopeJSON`**. Phone never writes `errorMessage` (Mac claim path will write `sealedErrorMessage`).
- **`decodeRequest(data:documentID:vaultKey:)`** — now `static`, takes `vaultKey: Data?`. Opens **`sealedScope`** via `openText` with **legacy fallback to `scopeJSON`**; opens **`sealedErrorMessage`** with **legacy fallback to `errorMessage`**.
- **`decodeSnapshot(data:documentID:sessionID:vaultKey:)`** — now `static`, takes `vaultKey: Data?`. Opens **`sealedActionLabel`** (fallback `actionLabel`), **`sealedTouchedFiles`** (sealed as one JSON `[String]` array; fallback `touchedFiles`), **`sealedMacSnapshotPath`** (fallback `macSnapshotPath`). Snapshot writer is unbuilt (Mac), so this is the prepared reader.
- **`submit(...)`** resolves the vault key via `MobileCloudVaultKeyAccess.keyForWriting`; both listener closures (`startObservingSession`, `startObservingRequests`) resolve via `keyForReading` once per fire (nil-tolerant → legacy decode).
- Added local `private static` helpers `dictionary(_:)`, `sealedText(from:)`, `openSealedString(...)`, `openSealedStringArray(...)` mirroring `TextExpansionSyncService`. Reused existing `CloudVaultCrypto.sealText`/`openText` only (no `sealBlob`).
- **New field names:** `sealedScope`, `sealedErrorMessage`, `sealedActionLabel`, `sealedTouchedFiles`, `sealedMacSnapshotPath`.

### `OpenBurnBarMobile/Views/Hermes/Square/AgentBrandZoneView.swift` (owned source)
- **`encodeTopic(_:vaultKey:)`** (`AgentSubscriptionTopicStore`) — now `static` + `throws`, takes `vaultKey: Data`. Seals `displayName` → **`sealedDisplayName`**, `description` → **`sealedDescription`** (`sealText`); **DROPPED plaintext `displayName`/`description`**. Kept `agentURI`/`topicID`/`cadence`/`consentGivenAt`/`isMuted`/`deliveryMode`/`minimumEventImportance`/`deliveryCountThisMonth`/`lastDeliveredAt` plaintext (routing/doc-ID/metadata).
- **`decodeTopic(documentID:data:vaultKey:)`** — now `static`, takes `vaultKey: Data?`. Opens `sealedDisplayName`/`sealedDescription` with **legacy fallback** to plaintext `displayName`/`description`; **preserved** the existing `displayName.isEmpty ? documentID` fallback.
- **`upsert`** resolves key via `keyForWriting`; **`refresh`** + **`restartRealtimeListener`** resolve via `keyForReading` (nil-tolerant). Added same local seal helpers (`openSealedString`, `dictionary`, `sealedText(from:)`).
- **New field names:** `sealedDisplayName`, `sealedDescription`.

### `OpenBurnBarMobileTests/RollbackServiceSealTests.swift` (new, owned test)
- Round-trips: `encodeRequest` seals `scopeJSON`→`sealedScope` and writes no plaintext; `encodeRequest`→`decodeRequest` recovers the `singleFile` path scope; legacy plaintext `scopeJSON` still decodes; sealed scope unreadable without key drops the row; `sealedErrorMessage` opens + legacy `errorMessage` fallback; snapshot `sealedActionLabel`/`sealedTouchedFiles`/`sealedMacSnapshotPath` open, legacy plaintext snapshot decodes, and sealed-only snapshot drops without key.

### `OpenBurnBarMobileTests/AgentSubscriptionTopicSealTests.swift` (new, owned test)
- Round-trips: `encodeTopic` seals display text and writes no plaintext (asserts canonical envelope shape, plaintext routing IDs retained); `encodeTopic`→`decodeTopic` recovers text; legacy plaintext row decodes; sealed-only row without key falls back to documentID for `displayName` (no leak) and still decodes.

### Deviations / notes
- **Helper sourcing:** Per contract stream-ownership (S1 owns `CloudVaultCrypto.swift`), I did NOT add shared helpers to core. `BudgetRulesStore.swift` references a `CloudVaultCrypto.dictionary(...)` extension that is not present on this branch (S2-owned, unmerged); to stay self-contained I defined file-local `private static` `dictionary`/`sealedText(from:)` mirroring the established `TextExpansionSyncService` pattern. No cross-stream file edited.
- **Out-of-scope blocker (flagged, untouched):** `RollbackRequest.Status` (`RollbackContracts.swift:104-109`) lacks a `cancelled` case and serializes `inFlight` as camelCase, while `firestore.rules`/Android expect `in_flight`/`cancelled`. Sealing does not touch `status`; this pre-existing mismatch is left for a separate fix (rules + status enum live in other streams' ownership).
- **Not in my scope (other streams per CONTRACT §STREAM OWNERSHIP):** `firestore.rules` `validRollbackRequest`/`validRollbackSnapshot`/`subscription_topics` updates (SD), `registry.json` honesty edits + codegen (SE), `legacy.ts` `SubscriptionTopicDoc` typing (SA), Android `RollbackService.kt`/`AgentSubscriptionTopicStore.kt` (SC). My iOS readers/writers and tests are consistent with the field names those streams will gate.
- Did not run builds (central verify follows). No JS streams in this assignment.