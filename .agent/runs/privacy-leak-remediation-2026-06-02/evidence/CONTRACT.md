# LOCKED FIELD & CRYPTO CONTRACT — privacy-leak-remediation-2026-06-02

This is the single source of truth for field names, sealed shapes, and crypto labels.
Every implementation stream MUST follow this verbatim so parallel edits don't drift.
Reuse EXISTING `CloudVaultCrypto` primitives only (byte-identical envelopes across Swift/Kotlin/TS/web/Node — see `evidence/recon-crypto-primitives.md`). Never invent crypto.

Canonical sealed-text envelope (all platforms):
`{ "algorithm":"AES-256-GCM", "keyVersion":1, "nonce":<b64 12B>, "ciphertext":<b64>, "tag":<b64 16B> }`
Server validator: `requireSealedText(raw, field)` (functions/src/callables/shared.ts:338).

Decoders everywhere MUST keep a LEGACY FALLBACK: if the new sealed field is absent, read the
old plaintext field (so in-flight/legacy docs still render during migration).

---

## 1. usage / budget project text  → SEAL (Alberto ratified)
- `users/{uid}/usage/{id}`: REMOVE plaintext `projectName`. ADD:
  - `sealedProjectName`: CloudVaultSealedText dict (sealText of `usage.projectName`)
  - `projectKeyHash`: 32-hex `CloudVaultCrypto.tokenHashes`/HMAC trapdoor of the normalized project name (for client group-by without decrypt). Optional but include it.
- `users/{uid}/budgetRules/{id}`: REMOVE plaintext `projectName` + `label`. ADD `sealedProjectName`, `sealedLabel` (sealText), and `projectKeyHash` for the project name.
- Writers: Mac `UsageSyncService.swift:114`, `CloudBudgetService.swift:133-134`; iOS `BudgetRulesStore.swift:205`; Android `FirestoreRepository.kt:512`.
- Readers (open with legacy fallback): iOS `FirestoreRepository.swift:699,776`, `BudgetRulesStore.swift:284`; Android `FirestoreRepository.kt:402,539`; Mac `CloudBudgetService decodeRule`.
- Server type: add `sealedProjectName?: CloudVaultSealedTextDoc` to `UsageEventDoc` (legacy.ts:1200); fix dead `serializeUsageForCallable` (shared.ts:519) to NOT echo plaintext projectName.
- Rules: usage (867-871) + budgetRules (875-879) create/update must REJECT a plaintext `projectName`/`label` key (gate behind presence of sealed field to allow migration).
- Registry: `usage_spend` — drop `"project"` from serverSees, add `"opaque project hashes"`; add `"project names"`,`"budget labels"` to deviceOnly.

## 2. project_memory_snapshots  → SEAL + OPAQUE DOC ID (no fork)
- New Swift primitive in `CloudVaultCrypto.swift` (mirror searchKey pattern :466-474):
  - `projectMemoryDocID(forSlug:keyData:) -> "pm_" + HMAC_SHA256(docIDKey, slug).prefix(16).hex` (32 hex)
  - `docIDKey`: `HKDF<SHA256>` salt `"OpenBurnBar-DocID-Salt-v1"`, info `"OpenBurnBar-ProjectMemory-DocID-v1"`, 32B.
- Writer `SessionLogSyncService.swift uploadProjectMemorySnapshot` (~591-602): send `"docID": projectMemoryDocID(...)`; DROP `"projectSlug"` and `"projectDisplayName"` (name is already inside `sealedSnapshot`). On commit, also delete legacy `…/{projectSlug}` doc if `projectSlug != docID` (client-side migration).
- Reader `fetchCloudProjectMemorySnapshot` (~621): derive docID from candidate slug + vaultKey; send `["docID": docID]`. Body decode unchanged.
- Server `encryptedSearch.ts`: `commitEncryptedProjectMemorySnapshot` read `docID = requiredIdentifier(data.docID)`; remove `projectDisplayName` (:348,:373) and `projectSlug` (:372) doc fields; write to `…/${docID}`; bump `schemaVersion:2`. `getEncryptedProjectMemorySnapshot` key by docID, drop name echo (:430-431). `listEncrypted…` drop `projectDisplayName`/slug (:476-477).
- Type `legacy.ts:1018-1035` ProjectMemorySnapshotDoc: remove `projectSlug`+`projectDisplayName`; optional `docID`.
- Rules: ADD `match /users/{uid}/project_memory_snapshots/{docID}` hasOnly allowlist rejecting `projectDisplayName`/`projectSlug` (server-written today; documents intent + future client writes).

## 3. Pensieve dedup + cloaking  → ENFORCE + VAULT-KEYED (flag-day, Option A re-ingest)
- New Swift `CloudVaultCrypto` helper `pensieveDedupHash(_ plaintext:keyData:)` and `pensieveSlugHmac(_ slug:keyData:)`:
  - `HKDF<SHA256>` over vault key, salt `∅`, info `"pensieve-dedup:content"` (content) / `"pensieve-dedup:slug"` (slug) → 32B key → `HMAC_SHA256(plaintext/slug)` hex. (Exact derivation per `functions/src/__tests__/knowledgeMemoryDedupHash.test.ts:110-114`.)
- Device writers send `dedupHash`+`slugHmac`, STOP sending `contentHash`+`sourcePath`: `PensieveKnowledgeChunker.swift:17-49,157-228`, `KnowledgeSyncService.swift:287-298`, Node shim `tools/openburnbar-mcp-remote/src/memoryHook.ts:180-202`.
- Server `knowledgeMemory.ts`: drop `?? raw.embedding` (:247) — require `cloakedVector`; `requireCloakedVector` reject legacy field. `resolveDedupHash` (:174-190) drop `raw.contentHash` v0 branch — require `dedupHash`. Remove contentHash reads (:280, knowledgeSearch.ts:123, hosted-mcp/knowledge.ts:238). Drop sourceSlug fallbacks once v1 (knowledgeSearch.ts:89-98,122; hosted-mcp/knowledge.ts:164,169,194,242 → slugHmac).
- Migration: flag-day enforce + forced re-ingest by bumping `dedupHashVersion`/`embeddingModelVersion` watermark; legacy v0 rows readable until re-ingest (transient). Flip `knowledgeMemoryDedupHash.test.ts:210-226` to expect rejection.

## 4. knowledge_repos  → SERVER-KEYED MATCH TOKEN + SEALED DISPLAY NAME
- `connectKnowledgeRepo` (knowledgeSync.ts:99-109): DROP plaintext `repoFullName`; store `repoMatchToken = HMAC_SHA256(KNOWLEDGE_REPO_MATCH_KEY, normalize(repoFullName))` (server secret via defineSecret) + `sealedRepoFullName` (vault-sealed, supplied by the authed web client for its own later display). Replace name-derived `repoId` (:102) with `safeCloudDocumentID(repoMatchToken)`.
- `onKnowledgeRepoPush` (:73): query `.where("repoMatchToken","==", HMAC(secret, normalize(github full_name)))`.
- Rules (1651-1655): no client-supplied cleartext `repoFullName`.
- Console (`apps/console/components/pensieve/PensieveDashboard.tsx`): display name from `sealedRepoFullName` decrypted client-side (console holds vault key via escrow.ts), not the server row.
- Registry `pensieve`: note `knowledge_repos` stores only an opaque match token + sealed name; repo names are observed transiently server-side ONLY for GitHub webhook routing (not stored).

## 5. dataExport  → SEAL-AWARE ALLOWLIST (no fork)
- `dataExport.ts collectInlineJson` (:208-220): pass `paths.encryptionTier`. Add `sealAwareSerializeDoc(data, tier)` + `isSealedEnvelope(v)` (mirror requireSealedText). For `server_readable`: verbatim. For `end_to_end`/`zero_access`: DEFAULT-DENY — emit only `id`, detected sealed envelopes, and the opaque-column allowlist `[uid, vectorId, embedding, embeddingModelVersion, slugHmac, dedupHash, dedupHashVersion, sourceKind, byteCount, chunkIndex, schemaVersion, repoMatchToken, docID, projectKeyHash, bodyHash, storagePath, tokenHashes, semanticHashes, contentHash(only if already hashed)]` + Timestamps/numbers/bools; record dropped keys in `redactedFields:[]`.
- Header (:9-16) becomes an enforced guarantee.

## 6. firestore.rules denylist → hasOnly (merge-union sets from recon-rules-and-tests.md §2)
- session_logs MANIFEST (294-307): add hasOnly(39-key set §2.A), keep 10 denials + validSessionLogFacets.
- session_logs CHUNK (334-346): add hasOnly(19-key set §2.B), keep denials.
- chat_threads (483-498): add hasOnly(10-key set §2.C), keep chatThreadHasPlaintextContent denial.
- media_session_events (2096-2111): hasOnly(16-key §2.D).
- media_attachment_manifests (2447-2462): hasOnly(§2.E) with `sealedFilename` (validCloudSealedText) REPLACING plaintext `filename` (Fork F = SEAL). If the media writer can't be cleanly updated this pass, bound `filename is string && size()<=256` + flag [incomplete] honest-label.
- ADD `validMobileMissionCancel()` to cli_agent_mission_requests allow-update (per recon-client-regressions §Fork B): diff hasOnly(["status","contentSealed","sealedStatePayload","sealedStateSchemaVersion","sealedStateVaultKeyID","updatedAt"]) with status=="cancelled".
- CRITICAL merge semantics: writers use merge:true → hasOnly must cover the UNION of every write path's post-merge keys; FieldValue.delete() keys must NOT be in the allowlist (they're absent).

## 7. Client regressions (recon-client-regressions.md) — SEAL, mirror the already-correct platform
- iOS cancelMission (CLIAgentMissionDispatcher.swift:526-541): seal `CLIAgentMissionPrivatePayload(liveSummary:"Mission cancelled by user.")` → `sealedStatePayload`+`sealedStateSchemaVersion:1`+`sealedStateVaultKeyID`+`contentSealed:true`+`status:"cancelled"`. Drop raw liveSummary.
- iOS mergeMissionGroup (:484-501): seal `synthesisSummary` → `sealedStatePayload`(+triplet); keep phase/winnerMissionID; merge:true.
- iOS updateSessionMetadata (CLIAgentChatReader.swift:144-174) + Android ThreadInboxStore.updateSessionMetadata: re-seal WHOLE record (customTitle inside sealedPayload via CLIAgentSessionCodec.encodeSealed). Stop top-level customTitle. Keep labelColorHex/isPinned/priorityOrder top-level.
- Android parseCLISession (ThreadInboxStore.kt:195-224): ADD sealed-read branch (AndroidCloudVaultKeyAccess.keyForReading + CloudVaultCrypto.openPayload + @Serializable mirror of CLIAgentSessionRecord). Keep plaintext path for legacy.
- Leave iOS respondToApproval unchanged (callable, no plaintext).

## 8. Honesty (registry/website/docs) + tooling
- Gateway (Alberto chose E2E re-architecture = CHAINED GOAL): in THIS pass fix registry.json:116 `deviceOnly` line so it stops claiming gateway payloads are sealed — distinguish relay (sealed) from gateway chat (currently server-readable, E2E migration committed). Scrub any website "never sees plaintext" wording that overreaches to the gateway. Do NOT change gateway code/schema this pass.
- After registry.json edits: `node packages/data-domains/codegen.mjs` then `cd android && ./gradlew :app:syncGeneratedSources`. Never hand-edit gen/* or website/src/data/trust.generated.ts or android DataDomains.kt.
- Scanner (scan-chat-cloud-plaintext.mjs): add coverage for project_memory_snapshots, hermes_gateway_*, knowledge_repos, media_*; add a SEMANTIC `hasOnly([` presence check per sensitive rule helper (not just hasAny denylist).
- Scrubber (scrub-chat-cloud-plaintext.mjs): add hermes_gateway_messages/events/attachments, hermes_relay/pi_agent_relay legacy chunks, text_snippets legacy, project_memory_snapshots projectDisplayName.
- Migration: ship an idempotent backfill (callable/scheduled) that deletes legacy plaintext fields ONLY when a sealed copy exists, and bumps a reseal watermark for client re-seal. Document it (not a manual dry-run).

## STREAM OWNERSHIP (disjoint files — no two streams edit the same file)
- S1 Swift-vault: `CloudVaultCrypto.swift` (3 new helpers), `SessionLogSyncService.swift` (project_memory), `KnowledgeSyncService.swift`, `PensieveKnowledgeChunker.swift`.
- S2 Swift-usagebudget: `UsageSyncService.swift`, `CloudBudgetService.swift`, `BudgetRulesStore.swift`, `OpenBurnBarMobile/Services/FirestoreRepository.swift`.
- S3 Swift-regressions: `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift`, `CLIAgentChatReader.swift`.
- SA Node/TS: `functions/src/callables/{encryptedSearch,dataExport,knowledgeSync,knowledgeMemory,knowledgeSearch,shared}.ts`, `functions/src/types/legacy.ts`, `services/hosted-mcp/src/knowledge.ts`, `tools/openburnbar-mcp-remote/src/memoryHook.ts`.
- SC Kotlin: `android/.../square/ThreadInboxStore.kt`, `android/.../firebase/FirestoreRepository.kt`, budget mapper. (NOT DataDomains.kt.)
- SD Rules+tests: `firestore.rules`, `functions/scripts/test-firestore-rules.mjs`.
- SE Honesty: `packages/data-domains/registry.json` + regen, `apps/console/**` (repo display), `website/**`, `docs/**`, `scripts/privacy/**`.
- Tests are owned by the same stream as the code they cover.
- All builds/tests run CENTRALLY in integration (agents EDIT + self-review only; no builds inside agents).
