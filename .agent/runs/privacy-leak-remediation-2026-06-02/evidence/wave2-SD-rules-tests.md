All correct. My implementation is complete. Let me write the final changelog.

## CHANGELOG

### `firestore.rules`

**§6.1 — session_logs MANIFEST → strict `hasOnly`** (`ownerWritableSessionLogManifest`)
- Added top-level helper `validSessionLogManifestKeys()` with a 39-key `hasOnly([...])` allowlist (the create + facet-refresh merge UNION, from recon §2.A). Wired it into `ownerWritableSessionLogManifest`, kept the 10-key `!hasAny`-style denials + `validSessionLogFacets()`, and added bounded checks: `inferredTaskTitle` (string ≤64), `sealedTitle`/`sealedBodyPreview` via `validCloudSealedText`, `encryption` is map, `vaultKeyID` via `validVaultKeyID`.

**§6.2 — session_logs CHUNK → strict `hasOnly`** (`ownerWritableSessionLogChunk`)
- Added `validSessionLogChunkKeys()` with the 19-key allowlist (§2.B). Wired into `ownerWritableSessionLogChunk`, kept the legacy denials, and added: `sealedSnippet` via `validCloudSealedText`, `tokenHashes`/`semanticHashes` via `validCloudSearchHashes`, `superseded` is bool.

**§6.3 — chat_threads → strict `hasOnly`** (`validChatThreadSealedContent`)
- Added `validChatThreadKeys()` with the 10-key allowlist (§2.C). Wired into `validChatThreadSealedContent` alongside the existing `chatThreadHasPlaintextContent()` denial and `validSealedPayloadForUser` gate. The deleted-via-`FieldValue.delete()` keys (`title`/`preview`/`messages`) stay absent and denied.

**§6.4 — media_session_events → strict `hasOnly`**
- Added match-scoped `validMediaSessionEventKeys()` (16-key set §2.D). Added bucketed-enum constraints (`p95RoundTripMillisBucket`, `p95BitsPerSecondBucket`, `durationBucket`), `peerDeviceIdHash` bound (≤128), kept the `body/payloadCiphertext/ciphertext/filename` denials. `update/delete: if false` unchanged.

**§6.5 — media_attachment_manifests → `hasOnly` + Fork F=SEAL (`sealedFilename`)**
- Added match-scoped `validMediaAttachmentManifestKeys()` (allowlist incl. both `sealedFilename` and legacy `filename`). New logic: requires at least one of `sealedFilename`/`filename`; when `sealedFilename` is present it must pass `validCloudSealedText` AND no plaintext `filename` may co-exist; legacy `filename` retained only as a bounded (≤256) migration fallback. Removed the unconditional `filename is string` requirement.

**§6 — `validMobileMissionCancel()` added to cli_agent_mission_requests**
- New match-scoped function: `status=="cancelled"` + `diff().affectedKeys().hasOnly(["status","contentSealed","sealedStatePayload","sealedStateSchemaVersion","sealedStateVaultKeyID","updatedAt"])`. Wired into `allow update` as a 4th predicate (alongside host/approval/refusal). Plaintext `liveSummary` stays denied by the request-level `!hasAny` denylist.

**§2/§6 — project_memory_snapshots rule block added** (new `match /users/{userId}/project_memory_snapshots/{docID}`)
- New `validProjectMemorySnapshotKeys()` (11-key allowlist keyed to the SA-updated `ProjectMemorySnapshotDoc`: `docID, contentHash, sourceSessionCount, sourceConversationCount, generatedAt, freshness, visualKinds, sealedSnapshot, encryption, schemaVersion, updatedAt`). Rejects `projectDisplayName`/`projectSlug`, pins `docID==docID`, enforces `freshness` enum, `validCloudSealedBlob(sealedSnapshot)`, and `schemaVersion>=2` (fences legacy plaintext-keyed v1 rows). Gated by `hasActiveHostedQuotaEntitlement`.

**§1/§6 — usage + budgetRules sealed-aware plaintext rejection**
- New top-level helper `rejectsPlaintextWhenSealed(plaintextField, sealedField)` (same dynamic-key pattern as the existing `validSessionLogFacetCount`). `usage`: rejects `projectName` when `sealedProjectName` present + validates `sealedProjectName`. `budgetRules`: same for `projectName`/`sealedProjectName` and `label`/`sealedLabel`. Migration-safe (legacy rows with no sealed field still pass).

**New shared validator**
- `validCloudSealedBlob(value)` — `CloudVaultBlobEnvelopeDoc` shape (`schemaVersion/algorithm/keyVersion/plaintextSHA256/sealedBoxBase64/createdAt`), reusing the existing crypto envelope, for `project_memory_snapshots.sealedSnapshot`.

**New exact field/key names introduced in rules:** `sealedFilename` (media manifest), `sealedProjectName`/`sealedLabel`/`projectKeyHash` (usage/budgetRules, recognized via the migration gate), `docID` (project_memory_snapshots).

### `functions/scripts/test-firestore-rules.mjs`
- Added module-level fixture factories `sealedText()` (canonical `validCloudSealedText` envelope, base64 strings) and `sealedBlob()` (canonical `validCloudSealedBlob` envelope).
- Fixed a pre-existing malformed `sealedSnippet` fixture in the "conversation and session-log backup" test (was `{schemaVersion,…}` missing `keyVersion` → would fail the new `validCloudSealedText(sealedSnippet)` chunk check); now uses `sealedText()` and normalized tab→space indentation.
- Added tests **T1–T12**: T1 hermes_relay request+chunk create+merge-update stays sealed (plaintext body/text/sessionId denied); T2 mobile_assistant_chats plaintext + unlisted-key denial; T3 session_logs manifest arbitrary-unlisted-key + plaintext denial; T4 session_logs chunk unlisted/plaintext denial; T5 conversations merge-update plaintext denial; T6 cli_sessions merge-update plaintext denial; T7 session_logs manifest merge-update plaintext/unlisted denial (merge-semantics guard); T8 media_session_events unlisted-key denial; T9 media_attachment_manifests `sealedFilename` accepted + co-emitted plaintext/unlisted denied + legacy `filename` fallback accepted; T10 mobile mission sealed cancel accepted + plaintext `liveSummary` cancel denied; T11 project_memory_snapshots opaque docID+sealed snapshot accepted + `projectDisplayName`/`projectSlug`/v1 denied; T12 usage+budgetRules sealed name/label accepted + co-emitted plaintext denied + legacy plaintext-only fallback accepted.
- `node --check functions/scripts/test-firestore-rules.mjs` → passes.

### Validation performed (no builds/emulator, per rules)
- Rules brace/paren/bracket balance = 0; 95 functions, zero duplicate function names; all referenced helpers (`validCloudSealedText`, `validVaultKeyID`, `validCloudSearchHashes`, `validCloudSealedBlob`, `validSealedPayloadForUser`, `hasActiveHostedQuotaEntitlement`, `hasActiveHostedMediaEntitlement`) defined exactly once. Dynamic-key indexing in `rejectsPlaintextWhenSealed` mirrors the established `validSessionLogFacetCount(data, field)` pattern. Test syntax OK.

### Deviations / blockers / TODO (flag for orchestrator)
1. **Fork F=SEAL — partial (writer/type owned by other streams).** The contract says replace plaintext `filename` with `sealedFilename`. I own neither the Swift media writer (recon §5: its real Firestore write path is unlocated) nor `functions/src/types/legacy.ts` (stream SA owns it). I implemented the **rule** to accept `sealedFilename` (preferred, `validCloudSealedText`) AND keep a bounded legacy `filename` fallback that is **rejected once a sealed copy is present** — satisfying the LEGACY-FALLBACK hard rule and the SEAL intent. **TODO for SA:** add `sealedFilename?: CloudVaultSealedTextDoc` to `MediaAttachmentManifestDoc` and mark `filename` legacy-optional. **TODO for the media owner:** seal `filename` into `sealedFilename` at the write path; once shipped, the rule already enforces sealed-only.
2. **project_memory_snapshots rule is intent/future-proofing.** These rows are written server-side via the Admin SDK (`commitEncryptedProjectMemorySnapshot`), which bypasses Firestore rules. The new block documents the hardened contract and fences any future direct client write; it does not change current server behavior. It assumes SA's already-applied `ProjectMemorySnapshotDoc` (`docID`-keyed, `schemaVersion:2`) — confirmed present in `legacy.ts`.
3. **usage/budgetRules sealed field names** (`sealedProjectName`, `sealedLabel`, `projectKeyHash`) are taken verbatim from CONTRACT §1; the actual Swift/Kotlin writers that emit them are owned by streams S2/SC. The rule is migration-safe regardless of writer landing order.
4. **Git/HEAD snapshot note (not a code issue):** `git diff HEAD firestore.rules` shows only an unrelated 34-line delta (entitlement product-id `com.openburnbar.ultra.annual.v2`, pre-existing branch work I did not author and did not touch). All my SD edits are physically present on disk (verified by grep: 7/7 deliverables + 12 named tests) — the harness advanced HEAD to include prior applied edits, which makes `git diff` understate my changes. No action needed; the on-disk file is correct.