Compatible — I only *added* keys to `__testing__`, the existing destructure still works. 

All changes are complete and self-reviewed. Here is the changelog.

## CHANGELOG

### `functions/src/types/legacy.ts`
- **`ProjectMemorySnapshotDoc`** (§2): removed `projectSlug` + `projectDisplayName`; added optional `docID?: string`. Updated the doc-path comment to `…/project_memory_snapshots/{docID}`. (Caller bumps `schemaVersion` to 2.)
- **`UsageEventDoc`** (§1): added `sealedProjectName?: CloudVaultSealedTextDoc` and `projectKeyHash?: string`. The plaintext `projectName` was never a declared field (undeclared passthrough) — updated clients stop writing it.
- **New `KnowledgeRepoDoc`** (§4): documents the new `knowledge_repos` shape — `repoMatchToken` (server-keyed HMAC), optional `sealedRepoFullName`, `repoId` derived from token, `sourceSlug`, `installId`; no cleartext `repoFullName`.

### `functions/src/callables/shared.ts`
- **`serializeUsageForCallable`** (§1): stopped echoing plaintext `projectName`; now passes through `sealedProjectName` (validated via `isRecord`) and `projectKeyHash` only. (Dead path — no in-repo callers — but no longer leaks if revived.)

### `functions/src/callables/encryptedSearch.ts`
- **`commitEncryptedProjectMemorySnapshot`** (§2): input field `projectSlug`→`docID` (`requiredIdentifier`); dropped `projectDisplayName` validation/storage and `projectSlug` storage; writes to `…/${docID}`; `schemaVersion: 2`; returns `docID` (was `projectSlug`).
- **`getEncryptedProjectMemorySnapshot`**: keys by `docID`; projection drops `projectDisplayName`/`projectSlug`, returns `docID`.
- **`listEncryptedProjectMemorySnapshots`**: projection drops `projectDisplayName`/`projectSlug`, returns `docID` (no `doc.id`-as-slug).
- **New field name sent by clients:** `docID` (Swift S1 derives `CloudVaultCrypto.projectMemoryDocID(forSlug:keyData:)`).

### `functions/src/callables/knowledgeSync.ts`
- Added secret **`KNOWLEDGE_REPO_MATCH_KEY`** (`defineSecret`), helper `normalizeRepoFullName` (trim+lowercase) and `repoMatchTokenFor` (`HMAC_SHA256(secret, normalize(full_name))` hex).
- **`connectKnowledgeRepo`** (§4): bound the secret; accepts `repoFullName` (callable arg, never persisted) + optional `sealedRepoFullName` (`requireSealedText`); stores `repoMatchToken` + `sealedRepoFullName` only; `repoId = safeCloudDocumentID(repoMatchToken)`.
- **`onKnowledgeRepoPush`** (§4): bound the secret; webhook queries `.where("repoMatchToken","==", repoMatchTokenFor(full_name))`; added a 503 guard when the match key is unconfigured.
- Imports added: `stripUndefinedObject`, `requireSealedText`.
- **New stored fields:** `repoMatchToken`, `sealedRepoFullName`. **New client-supplied field:** `sealedRepoFullName` (vault-sealed by the web console).

### `functions/src/callables/knowledgeMemory.ts`
- **Flag-day enforcement** (§3, Option A): `slugHmac` now `requireHexDigest(request.data.slugHmac,…)` (no cleartext-slug fallback); `requireCloakedVector(raw.cloakedVector,…)` (dropped `?? raw.embedding`); `resolveDedupHash` now requires `raw.dedupHash` (dropped the v0 `contentHash` branch, always stamps v1). Idempotent-skip read drops the `?? contentHash` fallback (reads `dedupHash` only). Updated the file/version-const doc comments. Added `DEDUP_HASH_VERSION_LEGACY_CLEARTEXT`, `DEDUP_HASH_VERSION_VAULT_HMAC`, `resolveDedupHash` to `__testing__`.

### `functions/src/callables/knowledgeSearch.ts`
- **§3:** removed `sourceSlug` from the input type, the filter (`.where("sourceSlug"…)`), and the hit shape; hit returns `slugHmac`/`dedupHash` with no `?? sourceSlug`/`?? contentHash` fallbacks. Source filter is `slugHmac`-only.

### `functions/src/callables/dataExport.ts`
- **§5 seal-aware allowlist:** added `OPAQUE_EXPORT_COLUMNS` (the contract's opaque-column set), exported `isSealedEnvelope(value)` (structural AES-256-GCM text/blob detector mirroring `requireSealedText`), `isExportablePrimitive`, and exported `sealAwareSerializeDoc(data) → { out, dropped }` (default-deny for `end_to_end`/`zero_access`). `collectInlineJson` now returns `{ inline, redactedFields }` and applies the seal-aware path for non-`server_readable` tiers; `serializeDoc` (verbatim) kept for `server_readable`. `DomainExport` gained `redactedFields?: string[]`; the `exportUserData` handler emits it. Header comment upgraded from assertion to enforced guarantee.

### `services/hosted-mcp/src/knowledge.ts`
- **§3:** `KnowledgeSearchArgs.sourceSlug`→`slugHmac`; `KnowledgeSearchHit.sourceSlug`→`slugHmac`; `searchKnowledge` filters `.where("slugHmac"…)` (dropped `sourceSlug`); search hits return `slugHmac` only. `readKnowledgeDocument` returns `dedupHash`+`slugHmac` (dropped cleartext `contentHash`+`sourceSlug`). Header updated.

### `tools/openburnbar-mcp-remote/src/memoryHook.ts`
- **§3:** added `vaultKeyedHmac(vaultKey, "content"|"slug", value)` using `HKDF(vaultKey, salt=∅, info="pensieve-dedup:content"|"…:slug") → HMAC_SHA256` — **byte-identical to the Swift helpers and the server test fixture**. `PreparedVector` dropped `contentHash`/`sourcePath`, added `dedupHash`/`slugHmac`; `vectorId` = `dedupHash`. `prepareMemoriesForCommit` dedups on the keyed `dedupHash`, passes it to `isDuplicate`, seals the real path inside `sealedMetadata` only. `RunMemorySyncOptions.isDuplicate` param renamed `dedupHash`. Header pipeline doc updated.

### Tests
- **`functions/src/__tests__/dataExport.test.ts`** (added): `isSealedEnvelope` detection (text+blob, rejects plaintext/partials/arrays/scalars); `sealAwareSerializeDoc` default-deny (drops `repoFullName`/`projectDisplayName`/`sourcePath`/`title`/`inferredTaskTitle` into `dropped`; keeps sealed envelopes, opaque columns, Timestamps/scalars).
- **`functions/src/__tests__/knowledgeMemoryDedupHash.test.ts`** (flipped): legacy v0 case now asserts **rejection** (cleartext `contentHash`/missing keyed fields) with nothing stored; added a raw-`embedding` rejection case (`/cloakedVector/`).
- **`functions/src/__tests__/projectMemoryDocId.test.ts`** (new): commit stores at opaque `docID`, `schemaVersion:2`, no plaintext slug/name on the row; commit rejects missing `docID`; get round-trips by `docID`; list returns only `docID`+sealed facets.
- **`functions/src/__tests__/knowledgeRepoMatchToken.test.ts`** (new): `connectKnowledgeRepo` stores `repoMatchToken`+`sealedRepoFullName`, never the cleartext name; doc id = token; case-insensitive token determinism.
- **`services/hosted-mcp/src/knowledge.test.ts`** (updated): row fixtures use `slugHmac`/`dedupHash` (not `sourceSlug`/`contentHash`); filter test uses `slugHmac`; hit/read assertions verify no `sourceSlug`/`contentHash` leak.
- **`tools/openburnbar-mcp-remote/src/memoryHook.test.ts`** (updated): asserts emitted `dedupHash`==HKDF/HMAC(content), `vectorId`==`dedupHash`, `slugHmac`==HKDF/HMAC(slug), and absence of `contentHash`/`sourcePath`.

### Cross-platform / cross-file flags for the orchestrator
- **Swift S1 dependency (hard):** clients must now send `dedupHash`+`slugHmac` (HKDF labels `pensieve-dedup:content` / `pensieve-dedup:slug`), `cloakedVector`, and (project memory) `docID`. The Node shim derivation here is the canonical reference; Swift `CloudVaultCrypto` must match byte-for-byte. This is a flag-day — un-updated clients are now rejected by `commitKnowledgeBatch`.
- **Swift S2 dependency:** usage/budget writers must write `sealedProjectName` (+ optional `projectKeyHash`) and stop writing plaintext `projectName`; `serializeUsageForCallable` no longer echoes plaintext.
- **`services/hosted-mcp/src/toolRegistry.ts` (NOT owned by me, must coordinate):** the `burnbar_search_knowledge` `inputSchema` (line 142) still declares `sourceSlug` and uses `additionalProperties:false`. My reader now reads `args.slugHmac` (works today only via the nested `filters.slugHmac` path, since `filters` is `additionalProperties:true`). The registry owner should add a top-level `slugHmac` property and drop `sourceSlug` for a clean top-level filter.
- **Ops/deploy:** the new `KNOWLEDGE_REPO_MATCH_KEY` secret must be provisioned (Secret Manager) before deploy; it is bound to `connectKnowledgeRepo` + `onKnowledgeRepoPush`.
- **Migration (owned elsewhere):** `functions/src/callables/privacyBackfill.ts` already gates deletion of legacy `projectDisplayName`/`projectSlug` behind presence of `sealedSnapshot` — consistent with the new sealed-only doc; the legacy plaintext-slug-keyed project_memory docs become unreachable after S1's reader switches to `docID` (S1 deletes the legacy doc on next commit per recon §6).
- **No deviations from CONTRACT.** All edits confined to my OWNED FILES. Did not run builds/emulator (central verification pending).