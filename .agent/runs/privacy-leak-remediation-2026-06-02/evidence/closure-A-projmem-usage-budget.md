All paths verified. The privacy backfill **deletes** the gated plaintext fields once the sealed copy is present (it does not re-seal — deletion is the scrub). The `requiredIdentifier` normalizes the docID; the device sends an opaque vault-key-derived hex docID (`projectMemoryDocID(forSlug:)`), which survives normalization unchanged.

I have full confirmation across all surfaces. Here are my verdicts.

---

## Adversarial verification summary

**(1) project_memory_snapshots** — CLOSED. The device derives an opaque `docID = CloudVaultCrypto.projectMemoryDocID(forSlug:keyData:)` (SessionLogSyncService.swift:595) and drops the plaintext slug/name; it only sets `legacyDocID` (the old slug) to request deletion of the stranded legacy doc (:612-614). The callable `commitEncryptedProjectMemorySnapshot` reads only `docID`+`legacyDocID`, builds the persisted `doc` from a fixed allowlist with NO `projectDisplayName`/`projectSlug` (encryptedSearch.ts:375-393), and deletes the legacy doc (:407-414). `get`/`list` project only opaque `docID` + sealed snapshot + content-free facets (:453-466, :501-511). The `getEncryptedProjectMemorySnapshot` legacy retry sends `projectSlug` (SessionLogSyncService.swift:654) but the callable IGNORES it (reads only `docID`, :447) — so no name-keyed server read occurs. Rules reject `projectDisplayName`/`projectSlug` and require schemaVersion≥2 + `validCloudSealedBlob` (firestore.rules:1727-1735), tested at T11 (test-firestore-rules.mjs:3045-3077). Backfill deletes stranded plaintext (privacyBackfill.ts:110-116).

**(2) usage + budgetRules** — CLOSED on all platforms.
- Mac usage: `encodeUsage` seals `sealedProjectName` + `projectKeyHash`, never writes plaintext `projectName` (UsageSyncService.swift:151-157).
- Mac budget: `encodeRule` seals `sealedProjectName`/`sealedLabel` + `projectKeyHash` (CloudBudgetService.swift:165-178); decoder opens sealed with legacy fallback (:219-225).
- iOS budget: same seal-on-write (BudgetRulesStore.swift:220-233), sealed-first decode (:296-302).
- Android budget: `BudgetRule.toMap` seals + `FieldValue.delete()` on legacy `projectName`/`label` when key present (FirestoreRepository.kt:576-585); `toBudgetRule` sealed-first decode (:609-614); Android usage is read-only, decodes sealed-first (:424-426).
- iOS mobile usage: read-only; opens sealed in-memory for the decoder only — never writes plaintext back (FirestoreRepository.swift:154-159, in-memory `enriched` dict).
- Peer-download open paths confirmed: Mac DownloadSyncService.swift:348 opens `sealedProjectName`; android FirestoreBudgetRepository.kt:51-54 resolves read key and opens via `toBudgetRule`.
- Rules: `rejectsPlaintextWhenSealed` rejects plaintext `projectName`/`label` once sealed present, requires `validCloudSealedText` (firestore.rules:1018-1038), tested at T12 (test-firestore-rules.mjs:3080-3133). Server guard `requireSealedText` mandates AES-256-GCM envelope (shared.ts:338-355). Backfill deletes stranded plaintext (privacyBackfill.ts:74-80).

No residual server-readable project text found on any of these surfaces.

## VERDICTS
- [CLOSED][high] project_memory_snapshots (opaque docID + sealed snapshot, no name/slug persisted or returned) | evidence: functions/src/callables/encryptedSearch.ts:352,375-393,447,453-466,501-511 + AgentLens/Services/CloudSync/SessionLogSyncService.swift:595,612-614 + firestore.rules:1707-1736 | note: legacy `projectSlug` retry is silently ignored by the docID-only callable; legacyDocID delete + privacyBackfill.ts:110-116 scrub stranded legacy rows; tested test-firestore-rules.mjs:3045-3077
- [CLOSED][high] usage projectName seal (Mac write + Mac/iOS/Android peer-download open) | evidence: AgentLens/Services/CloudSync/UsageSyncService.swift:151-157 + AgentLens/Services/CloudSync/DownloadSyncService.swift:348 + android/.../FirestoreRepository.kt:424-426 + OpenBurnBarMobile/Services/FirestoreRepository.swift:154-159 | note: rule firestore.rules:1018-1024 rejects plaintext when sealed; server guard shared.ts:338-355; tested T12 test-firestore-rules.mjs:3092-3106
- [CLOSED][high] budgetRules projectName/label seal (Mac+iOS+Android write & open) | evidence: AgentLens/Services/CloudBudgetService.swift:165-178,219-225 + OpenBurnBarMobile/Models/BudgetRulesStore.swift:220-233,296-302 + android/.../FirestoreRepository.kt:576-585,609-614 + android/.../FirestoreBudgetRepository.kt:51-54 | note: rule firestore.rules:1030-1038 rejects plaintext projectName/label when sealed; tested T12 test-firestore-rules.mjs:3110-3132
- [CLOSED][med] firestore.rules plaintext-when-sealed enforcement + backfill backstop | evidence: firestore.rules:1013-1038,1707-1736 + functions/src/callables/privacyBackfill.ts:74-116 | note: `rejectsPlaintextWhenSealed` + project_memory hasOnly allowlist; backfill deletes (not re-seals) stranded plaintext