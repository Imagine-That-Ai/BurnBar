Braces balanced across all four files. 

Let me verify one last thing: the `CLIAgentMissionPrivatePayload` explicit init I added didn't break the call site in `buildSealed` which passes positional/labeled args in the exact memberwise order. It uses labeled args (`title:`, `prompt:`, ..., `synthesisSummary:`), which match my explicit init labels. Confirmed earlier. The `sealGroupPayload` factory also uses labeled args. Both compatible.

All edits complete and self-reviewed. Here is the changelog.

## CHANGELOG

### `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift`
- **`CLIAgentMissionPrivatePayload` (private struct)**: added an explicit memberwise `init` with all-optional defaults so the payload can be constructed with only `liveSummary:` or only `synthesisSummary:`. No field changes (label/order identical to the synthesized init, so existing call sites in `buildSealed`/`sealGroupPayload` are unaffected).
- **`cancelMission(requestID:)`**: now SEALS the cancel summary instead of writing plaintext. Resolves the writable vault key (`MobileCloudVaultKeyAccess.keyForWriting`) and writes the new `cancelMissionUpdate(...)` payload via `setData(merge:true)`. Dropped the top-level plaintext `"liveSummary"`.
- **`cancelMissionUpdate(vaultKey:vaultKeyID:) -> [String:Any]` (new `static`, testable)**: builds the sealed cancel diff with exactly these keys — `status:"cancelled"`, `contentSealed:true`, `sealedStateSchemaVersion:1`, `sealedStateVaultKeyID:<id>`, `sealedStatePayload:<envelope>`, `updatedAt`. The private `liveSummary:"Mission cancelled by user."` lives only inside `sealedStatePayload`. Key set matches the `validMobileMissionCancel()` rule allowlist (owned by stream SD).
- **`mergeMissionGroup(groupID:winnerMissionID:synthesisSummary:)`**: when `synthesisSummary` is present, resolves the writable vault key and seals it into `sealedStatePayload`; dropped the top-level plaintext `"synthesisSummary"`. Keeps `phase`/`winnerMissionID`/`updatedAt` and `merge:true`.
- **`mergeMissionGroupUpdate(winnerMissionID:) -> [String:Any]` and `mergeMissionGroupUpdate(winnerMissionID:synthesisSummary:vaultKey:vaultKeyID:) throws -> [String:Any]` (new `static`, testable)**: the no-synthesis variant writes only non-private `phase`/`winnerMissionID`/`updatedAt`; the sealed variant adds `contentSealed:true` + `sealedStateSchemaVersion:1` + `sealedStateVaultKeyID` + `sealedStatePayload`. The sealed `synthesisSummary` round-trips through the existing `MissionGroupDocument` reader (which already opens `sealedStatePayload` with legacy top-level fallback).
- **`respondToApproval`**: left UNCHANGED (callable-based, no plaintext) per contract §7.
- New sealed field names used: `sealedStatePayload`, `sealedStateSchemaVersion` (=1), `sealedStateVaultKeyID`, `contentSealed`.

### `OpenBurnBarMobile/Services/CLIAgentChatReader.swift`
- **`updateSessionMetadata(id:customTitle:labelColorHex:isPinned:priorityOrder:)`**: now RE-SEALS the whole `CLIAgentSessionRecord` on rename. When `customTitle` is supplied: reads the read vault key, fetches the current doc, decodes via `CLIAgentChatFirestoreSource.decodeDocument` (sealed or legacy), applies the metadata, re-encodes with `CLIAgentSessionCodec.encodeSealed` (so `customTitle` lives only inside `sealedPayload`), and additionally issues `FieldValue.delete()` for any legacy top-level `customTitle`/`title`/`preview`/`messages` so `merge:true` cannot leave a plaintext copy. Stopped writing top-level `customTitle`. When only `labelColorHex`/`isPinned`/`priorityOrder` change, keeps the lightweight top-level `merge:true` write (those remain legal top-level per rules). Safe no-op (with a `logger.warning`) if the record or vault key is unavailable rather than leaking plaintext.
- **`applyMetadata(to:customTitle:labelColorHex:isPinned:priorityOrder:) -> CLIAgentSessionRecord` (new `static`, testable)**: pure helper that applies rename/metadata edits onto an in-memory record; empty `customTitle` clears the override, `"#NONE#"` clears `labelColorHex`.
- Legacy fallback preserved: `decodeDocument` still reads legacy unsealed docs; readers unchanged.

### `OpenBurnBarMobileTests/CLIAgents/CLIAgentMissionDispatcherSealTests.swift` (new file)
- `test_cancelMissionUpdate_sealsSummary_writesNoPlaintextLiveSummary` — asserts the cancel diff has the seal triplet, no plaintext `liveSummary`/`resultPreview`/`errorMessage`, key set ⊆ the `validMobileMissionCancel()` allowlist, and round-trips back to `"Mission cancelled by user."` via `CLIAgentMissionSnapshot`.
- `test_cancelMissionUpdate_summaryUnreadableWithoutKey` — without the vault key the summary stays hidden.
- `test_mergeMissionGroupUpdate_withoutSynthesis_isPlaintextSafe` — no-synthesis merge writes no seal/plaintext private fields.
- `test_mergeMissionGroupUpdate_sealsSynthesis_writesNoPlaintext` — synthesis is sealed into `sealedStatePayload`, no top-level `synthesisSummary`, round-trips via `MissionGroupDocument`.
- `test_mergeMissionGroupUpdate_synthesisUnreadableWithoutKey` — sealed synthesis hidden without the key.
- Helper `baseSealedMissionGroupDocument` builds a realistic sealed group request doc (title/prompt/targetProject inside `sealedPayload`) via `CLIAgentMissionRequestPayloadFactory.sealGroupPayload` so the merge mirrors a real post-`merge:true` document.

### `OpenBurnBarMobileTests/CLIAgents/CLIAgentChatReaderTests.swift`
- Added: `test_applyMetadata_setsCustomTitle_preservesTranscript`, `test_applyMetadata_emptyCustomTitle_clearsOverride`, `test_applyMetadata_sentinelLabelColor_clearsColor`, `test_rename_sealsCustomTitle_noTopLevelPlaintext` (seals `customTitle`, asserts no top-level `customTitle`/`title`/`preview`/`messages`, round-trips via `decodeSealed`), `test_rename_sealedTitleUnreadableWithoutKey` (sealed doc returns nil without key).
- Existing tests unchanged.

### Deviations / notes
- The `validMobileMissionCancel()` rule predicate is owned by stream SD (firestore.rules). I produced the sealed cancel write whose diff key set exactly matches the contract allowlist (`status`,`contentSealed`,`sealedStatePayload`,`sealedStateSchemaVersion`,`sealedStateVaultKeyID`,`updatedAt`); I did not edit firestore.rules.
- The shared codec `OpenBurnBarCore/.../CLIAgentSessionRecord.swift` (`encodeSealed`/`decodeSealed`) already seals `customTitle` inside `sealedPayload` and is owned by stream S1 — no change needed/made.
- `mergeMissionGroup` now resolves the writable vault key (an extra async hop) only when a `synthesisSummary` is present; the no-synthesis merge path stays key-free. The `MissionGroupObserver.applyMerge` caller (another stream's view) is unaffected — same public signature.
- No builds/emulator run per instructions; verified via brace-balance and signature/field cross-checks only. Round-trip tests rely on `CloudVaultCrypto.generateVaultKey()`/`vaultKeyID(for:)` and the existing public readers, so they exercise the real seal/open path without Firestore.