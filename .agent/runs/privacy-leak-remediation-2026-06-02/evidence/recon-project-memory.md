I have complete information. Let me also quickly verify whether `boundedTrimmedString`/`requireBoundedStringArray` validators surface plaintext through `visualKinds` (those are enum-ish kinds, not private text — safe) and confirm the `vaultKeyID` field is currently NOT persisted server-side in the doc (the writer sends it at line 600 but the server doc at lines 371-388 omits it — relevant for the keyed-id design). I have enough. Producing the design brief.

## RECON COMPLETE — DESIGN BRIEF

### SURFACE: `project_memory_snapshots` plaintext `projectDisplayName` + name-derived doc-id slug

---

### 1. DATA FLOW (writer + every reader)

**Doc path:** `users/{uid}/project_memory_snapshots/{projectSlug}` (Firestore).
**Privacy tier (claimed):** `end_to_end` — `functions/src/callables/dataExport.ts:80-92` and Android `android/app/src/main/java/com/openburnbar/data/domains/DataDomains.kt:51-54` ("project memory … Sealed on-device; the server holds only ciphertext"). **The current code violates this claim.**

**WRITER (Swift Mac only):**
- `AgentLens/Services/CloudSync/SessionLogSyncService.swift:574-607` `uploadProjectMemorySnapshot`. It seals the **entire** `ProjectMemorySnapshot` Codable struct into a `CloudVaultBlobEnvelope`:
  - `:586-587` `let payload = try Self.jsonData(snapshot)` → `let sealedSnapshot = try CloudVaultCrypto.sealBlob(payload, keyData: vaultKey)`
  - then sends a callable payload that **redundantly** includes plaintext `:592 "projectSlug"` and `:593 "projectDisplayName"` **alongside** the sealed blob.
- The sealed body **already contains** `projectDisplayName` and `projectSlug`: `ProjectMemorySnapshot` struct fields `projectSlug` / `projectDisplayName` at `AgentLens/Services/DataStore/DataStoreTypes.swift:979-980`, and `jsonData(snapshot)` (`SessionLogSyncService.swift:866`) serializes the whole struct. **CONFIRMED: the plaintext callable fields are pure denormalization — the values are already inside the ciphertext.**

**SERVER callable writer:** `functions/src/callables/encryptedSearch.ts:321-402` `commitEncryptedProjectMemorySnapshot`
- `:347` `projectSlug = requiredIdentifier(request.data.projectSlug, …)`
- `:348` `projectDisplayName = boundedTrimmedString(request.data.projectDisplayName, …, 240, true)` → **stored as plaintext** in the doc (`:373`)
- `:391` writes to `users/${uid}/project_memory_snapshots/${projectSlug}` — **doc id == the name-derived slug** → server (and anyone with Firestore read, including the data-export path) sees the project name twice: as a plaintext field and as the doc id.

**READERS:**
- **Swift Mac** `SessionLogSyncService.swift:609-638` `fetchCloudProjectMemorySnapshot(projectSlug:)` → callable `getEncryptedProjectMemorySnapshot([ "projectSlug": projectSlug ])` (`:621-623`); it then decodes **only** `sealedSnapshot` (`:628-637`) and **ignores** the plaintext `projectDisplayName`/`projectSlug` echoed back by the server. The plaintext fields it returns (`encryptedSearch.ts:430-431`) are **dead on read**.
- **Server callable readers:** `getEncryptedProjectMemorySnapshot` (`encryptedSearch.ts:404-446`, keyed by `projectSlug` doc id) and `listEncryptedProjectMemorySnapshots` (`:448-492`, returns `projectDisplayName` per doc, `:477`). `list` is **not consumed by any Mac code path** in this surface (the Mac fetches by known slug at `ProjectsView.swift:708`); it exists for parity/portability.
- **Caller chain on Mac:** `AgentLens/Views/Dashboard/ProjectsView.swift:707-713` loops `projectMemoryKeys` and calls `fetchCloudProjectMemorySnapshot(projectSlug: key)`; `projectMemoryKeys` (`:671-682`) derives candidate slugs from `project.slug` + `project.displayName` via `normalizedProjectMemoryKey` (`:661-669`). Display only uses the decrypted body: `snapshot.projectDisplayName` at `ProjectsView.swift:1433, 2934, 2942, 3006, 3021, 3258, 3275` — all post-decryption.
- **Data export** `functions/src/callables/dataExport.ts:208-220` `collectInlineJson` emits each E2E doc verbatim: `{ id: doc.id, ...serializeDoc(doc.data()) }` (`:214`) → **plaintext `projectDisplayName` and the name-derived `doc.id` leak into the export inline JSON**, contradicting the file's own policy comment (`:13-15` "Inline Firestore docs for E2E domains carry only sealed payloads").
- **iOS / Android:** NO consumer of the cloud collection. `OpenBurnBarMobile`'s `MobileProjectMemorySnapshot` (`OpenBurnBarMobile/Services/Tools/MobileToolCatalog.swift:431,474,596,734-745`) is built **locally** from on-device sessions; grep for `EncryptedProjectMemory` callables in `OpenBurnBarMobile/` and `android/app/src/main` returns **nothing**. Android `DataDomains.kt` only declares the privacy **label**, no client.

---

### 2. SERVER-READ REQUIREMENT — definitive: **NO**

The server never needs `projectDisplayName` or the human-readable slug. Proof:
- `commitEncryptedProjectMemorySnapshot` (`encryptedSearch.ts:371-392`) is **pure store-and-forward** — it validates, denormalizes, and `.set()`s. No LLM call, no budget logic keyed on the name, no index built from the name.
- `getEncryptedProjectMemorySnapshot` (`:404-446`) uses `projectSlug` **only as the Firestore doc key** (`:423`) — never inspects its meaning.
- `listEncryptedProjectMemorySnapshots` orders by `updatedAt` (`:469`), not by name; it returns `projectDisplayName` (`:477`) purely as denormalized convenience the Mac doesn't use.
- The only server gate is entitlement (`assertActiveBurnBarProEntitlement(uid)`, `:345/420/464`), which is uid-scoped, name-independent.

**Verdict: seal it (E2E), do not honest-label.** All content can and must be ciphertext; the doc id must become opaque.

---

### 3. VAULT-KEY AVAILABILITY — **YES, trivially**

The only participant that reads/writes this surface is the **same Mac user** who holds the vault key (`writableVaultKey`/`readableVaultKey`, `SessionLogSyncService.swift:71-96`, backed by `CloudVaultKeyStore`). There is no cross-device reader of the cloud doc that lacks the key. E2E sealing — including a **vault-key-derived deterministic doc id** — is fully achievable. (If a future iOS/Android reader is added, it already provisions the same vault key via ECIES device wrapping, so the keyed-id scheme remains valid.)

---

### 4. RECOMMENDED FIX (SOTA, minimal-drift) — reuse existing primitives

**Goal:** (a) stop persisting plaintext `projectDisplayName`; (b) replace the name-derived doc id with an **opaque, deterministic, vault-key-keyed** id so upsert/get still hit the same doc.

**Reuse existing crypto:** the codebase already has the exact pattern — `CloudVaultCrypto.tokenHashes` (`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:241-251`) computes `HMAC<SHA256>` over an HKDF-derived subkey (`searchKey`, `:466-474`) and emits a **lowercase hex** digest. Add **one** sibling helper using the same HKDF→HMAC→hex recipe.

**4a. New crypto helper (CloudVaultCrypto.swift):**
```swift
// new private subkey, same HKDF<SHA256> recipe as searchKey/semanticSearchKey
private static func docIDKey(from data: Data) throws -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: data),
        salt: Data("OpenBurnBar-DocID-Salt-v1".utf8),
        info: Data("OpenBurnBar-ProjectMemory-DocID-v1".utf8), outputByteCount: 32)
}
public static func projectMemoryDocID(forSlug slug: String, keyData: Data) throws -> String {
    let key = try docIDKey(from: keyData)
    let mac = HMAC<SHA256>.authenticationCode(for: Data(slug.utf8), using: key)
    return "pm_" + Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined() // 32 hex chars
}
```
Deterministic ⇒ same slug → same id ⇒ upsert idempotency preserved. Opaque ⇒ server learns nothing. The `pm_` + 32-hex output passes `requiredIdentifier`'s `[a-z0-9_-]` filter **unchanged** (`shared.ts:157-166`) — **zero server-validator change**.

**4b. Writer change (`SessionLogSyncService.swift` `uploadProjectMemorySnapshot`, ~590-602):**
- Compute `let docID = try CloudVaultCrypto.projectMemoryDocID(forSlug: snapshot.projectSlug, keyData: vaultKey)`.
- Change the callable payload: send `"docID": docID` instead of plaintext `"projectSlug"`; **drop `"projectDisplayName"`** entirely. Keep non-sensitive denormalized facets (`contentHash`, counts, `generatedAt`, `freshness`, `visualKinds`, `vaultKeyID`, `sealedSnapshot`). The name/slug stay only inside `sealedSnapshot` (already sealed — confirmed §1).

**4c. Reader change (`SessionLogSyncService.swift` `fetchCloudProjectMemorySnapshot`, ~621-623):**
- Derive `let docID = try CloudVaultCrypto.projectMemoryDocID(forSlug: projectSlug, keyData: vaultKey)` (the function already has `vaultKey` at `:618`) and send `["docID": docID]`. The body decode at `:628-637` is unchanged (still reads `sealedSnapshot`).
- In `ProjectsView.swift:707-713`, the candidate-slug loop is unchanged — each candidate slug is hashed to a docID under the same key, so the first matching doc is found exactly as today.

**4d. Server callable changes (`functions/src/callables/encryptedSearch.ts`):**
- `commitEncryptedProjectMemorySnapshot` (`:321-402`): accept `docID` (validate via `requiredIdentifier(request.data.docID, "docID")`); **remove** `projectDisplayName` read (`:348`) and its doc field (`:373`); **remove** `projectSlug` field from the doc body (`:372`) — write to `users/${uid}/project_memory_snapshots/${docID}` (`:391`). The opaque docID is the only key.
- `getEncryptedProjectMemorySnapshot` (`:404-446`): key by `docID`; stop echoing `projectDisplayName`/`projectSlug` (`:430-431`) — return only `sealedSnapshot` + non-sensitive facets.
- `listEncryptedProjectMemorySnapshots` (`:448-492`): **remove** `projectDisplayName` from the returned projection (`:477`) and don't fall back to `doc.id` as a "slug" (`:476`); the list now carries only opaque id + sealed facets. (The Mac doesn't use the name from list; if a future client needs the name, it opens `sealedSnapshot`.)

**4e. Doc schema (`functions/src/types/legacy.ts:1018-1035` `ProjectMemorySnapshotDoc`):**
- Remove `projectSlug` (`:1019`) and `projectDisplayName` (`:1020`). Optionally add `docID: string` (or rely on the Firestore doc key). Bump `schemaVersion` 1→2 to fence old plaintext docs.

---

### 5. PRODUCT FORK — **none.**
There is no defensible "hosted reading" use of the project name (§2 proves pure store-and-forward, single-party reader, key always present). The fix is unambiguously: **seal + opaque deterministic id.** No product decision is required. (The only minor choice — whether to keep an opaque `docID` field in the doc body or rely solely on the Firestore key — is cosmetic; recommend storing it for export/debuggability since it leaks nothing.)

---

### 6. BLAST RADIUS (lockstep changes)

**Migration (required — old docs are keyed by plaintext slug and carry plaintext name):**
- Old docs at `…/project_memory_snapshots/{plaintext-slug}` become **unreachable** after the reader switches to `docID` lookup. Provide a one-time **client-side re-key** on next `uploadProjectMemorySnapshot`: the Mac re-derives docID, writes the new sealed-only doc, and deletes the old slug doc (it has the slug from the local snapshot). Simplest: on commit, also enqueue delete of the legacy `…/{projectSlug}` doc if `projectSlug != docID`. Do NOT attempt server-side migration (server can't read the vault key).

**Tests:**
- `AgentLensTests/Support/CloudSyncTestSupport.swift:65-68` — fake `commitEncryptedProjectMemorySnapshot`/`getEncryptedProjectMemorySnapshot`; update fake payload shape to assert `docID` present and `projectDisplayName` **absent**.
- `AgentLensTests/Active/ContextPackServiceTests.swift:576-642` and `AgentLensTests/Active/DataStoreTests.swift:245-327` — these exercise the **local** struct (`projectDisplayName`/`projectSlug` remain valid on the in-memory model and local SQLite); keep as-is, but **add** a new test asserting `projectMemoryDocID(forSlug:keyData:)` is deterministic and that the committed cloud payload contains no plaintext name/slug.
- Add a `CloudVaultCrypto` unit test for `projectMemoryDocID` determinism + key-sensitivity (mirror existing token-hash tests).
- Functions: add/adjust a callable test asserting `commit`→`get` round-trips by `docID` and that `list`/`get` no longer return `projectDisplayName`.

**Generated/build artifacts:**
- `functions/lib/**` (compiled TS) regenerates on build — no manual edit.
- Android `android/app/build/**` jacoco/kapt artifacts referencing `ProjectMemory` are **stale build output**, not source — ignore.

**Clients:** none beyond the Mac (iOS/Android don't call these callables — §1).

**Docs (must update to match new reality):**
- `functions/src/callables/dataExport.ts:13-15` policy comment now **becomes true** for this surface (no change needed, but the leak it described is fixed).
- `docs/pricing/gpt-pro-brief/02_CLOUD_BACKEND_AND_INFRASTRUCTURE.md:55,90` — lists the callables/collection; no claim change, but verify any "stores project name" wording is removed.
- Android `DataDomains.kt:52` summary ("project memory … Sealed on-device; the server holds only ciphertext") — **now accurate**; no edit required, but it was previously false advertising — flag in the remediation changelog.

---

## DESIGN BRIEF

1. **Add crypto primitive** in `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`: a private `docIDKey(from:)` (HKDF-SHA256, salt `"OpenBurnBar-DocID-Salt-v1"`, info `"OpenBurnBar-ProjectMemory-DocID-v1"`) + public `projectMemoryDocID(forSlug:keyData:) -> "pm_" + hmacSHA256(slug).prefix16.hex` — reusing the exact pattern of `tokenHashes`/`searchKey` (`:241-251`,`:466-474`). Deterministic, opaque, passes `requiredIdentifier` unchanged.

2. **Writer** `AgentLens/Services/CloudSync/SessionLogSyncService.swift` `uploadProjectMemorySnapshot` (`:590-602`): compute `docID` from `snapshot.projectSlug` + `vaultKey`; send `"docID": docID`; **delete the `"projectSlug"` and `"projectDisplayName"` keys** from the callable payload. Keep `sealedSnapshot` (already contains name+slug — confirmed via `jsonData(snapshot)` + struct `:979-980`).

3. **Reader** `SessionLogSyncService.swift` `fetchCloudProjectMemorySnapshot` (`:621-623`): derive `docID` from the candidate `projectSlug` + the `vaultKey` already loaded at `:618`; send `["docID": docID]`. Body decode (`:628-637`) unchanged.

4. **Server commit** `functions/src/callables/encryptedSearch.ts:321-402`: read `docID = requiredIdentifier(request.data.docID, "docID")`; remove `projectDisplayName` validation (`:348`) and doc field (`:373`); remove `projectSlug` doc field (`:372`); write to `…/project_memory_snapshots/${docID}` (`:391`); bump `schemaVersion: 2` (`:386`).

5. **Server get** `encryptedSearch.ts:404-446`: key by `docID`; drop `projectDisplayName`/`projectSlug` from the returned projection (`:430-431`).

6. **Server list** `encryptedSearch.ts:448-492`: drop `projectDisplayName` (`:477`) and `projectSlug`/`doc.id`-as-slug (`:476`) from the projection.

7. **Doc type** `functions/src/types/legacy.ts:1018-1035`: remove `projectSlug` + `projectDisplayName`; (optional) add `docID: string`; `schemaVersion` semantics → 2.

8. **Migration:** on the next Mac commit, also delete the legacy `…/{plaintext-slug}` doc when `projectSlug != docID` (client-side only; server cannot re-key without the vault key).

9. **Tests:** update `AgentLensTests/Support/CloudSyncTestSupport.swift:65-68` (assert `docID`, no plaintext name); add `CloudVaultCrypto.projectMemoryDocID` determinism/key-sensitivity test; add functions round-trip-by-`docID` test asserting no `projectDisplayName` in `get`/`list`. Leave local-model tests (`ContextPackServiceTests`, `DataStoreTests`) intact — the local struct keeps the fields; only the cloud doc is sealed.

10. **Privacy-tier reconciliation:** this change makes the existing `end_to_end` labels (`dataExport.ts:80-92`, `DataDomains.kt:51-54`) and the export policy (`dataExport.ts:13-15`) **truthful** — `collectInlineJson` (`:214`) will then emit only opaque id + sealed payload for this collection. No label edits needed; note the prior mislabel in the remediation changelog.