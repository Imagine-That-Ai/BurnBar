Critical finding for the dedup-oracle fix's blast radius: the hosted-MCP `knowledge.ts` (lines 16-17, 38, 164, 169, 194, 238, 242) STILL filters and returns on the **cleartext `sourceSlug`** and returns **cleartext `contentHash`** — it has NOT been updated to the `slugHmac`/`dedupHash` B-SEC-2 model that the callable `knowledgeSearch.ts` already adopted. This is a second live reader that must move in lockstep.

I now have everything needed. Let me write the design brief.

## RECON COMPLETE — DESIGN BRIEF

### SURFACE 1 — `exportUserData` (functions/src/callables/dataExport.ts)

**1. DATA FLOW**
- **Writer:** `exportUserData` onCall handler, `dataExport.ts:291-342`. It enumerates collections from the server-authoritative `DATA_DOMAIN_PATHS` map (`dataExport.ts:53-192`), one entry per data-domain, drift-guarded against `packages/data-domains/registry.json` by `functions/src/__tests__/dataExport.test.ts:22-55`.
- **Enumeration:** `collectInlineJson(uid, paths)` (`dataExport.ts:208-220`) loops `paths.firestoreCollections`, does `db.collection(\`users/${uid}/${collection}\`).limit(1000).get()`, and maps **every doc to `{ id, ...serializeDoc(doc.data()) }`**.
- **Serialization:** `serializeDoc` (`dataExport.ts:223-251`) walks every field recursively; the ONLY transform is Firestore `Timestamp → ISO`. **There is no allowlist, no per-tier field filter, no redaction.** Every field of every doc is dumped verbatim.
- **Readers of the export output:** web console `apps/console/lib/api.ts` + `apps/console/components/inventory/DomainRow.tsx`; iOS/Mac `AgentLens/Services/DataControlCenterViewModel.swift`; Android `android/.../ui/control/ControlCenterFunctions.kt` + `ControlCenterStore.kt`. All treat `domains[].inlineJson` as opaque-display + `sealedRefs[]` as download URLs.

**2. SERVER-READ REQUIREMENT** — None. `exportUserData` is **pure store-and-forward**: it reads the user's own docs and returns them to that same user. The server has no functional need for plaintext; it is just relaying. The doc header (`dataExport.ts:9-16`) *asserts* "E2E inline docs carry only sealed envelopes / opaque hashes" — but `collectInlineJson` does NOT enforce that. It is an unchecked assumption. Any plaintext private field that exists on an `end_to_end` (or `zero_access`) collection doc is dumped verbatim. Confirmed offenders reachable through this path:
  - `pensieve` domain (`dataExport.ts:93-97`, tier `end_to_end`) dumps `knowledge_repos` → cleartext **`repoFullName`** + **`sourceSlug`** (Surface 2), and legacy `cloud_search_knowledge` rows → cleartext **`contentHash`** / **`sourceSlug`** / (pre-B-SEC-2) **`sourcePath`** (Surface 3).
  - `conversations_chat` (`dataExport.ts:68-79`, `end_to_end`) dumps `conversations`, `mobile_assistant_chats`, `cli_sessions`, `cli_agent_mission_requests`, `text_snippets` verbatim — any denormalized title/snippet/project/path field on those docs leaks.

**3. VAULT-KEY AVAILABILITY** — The reader IS the authenticated owner, who holds the vault key. So sealed envelopes are fully acceptable in the export; the user decrypts locally. We never need to emit plaintext for the user's benefit.

**4. RECOMMENDED FIX (minimal-drift, seal-aware allowlist export)** — Make `collectInlineJson` tier-aware and field-safe rather than a verbatim dump:
   - Add a `SEALED_ENVELOPE_KEYS`/opaque-field allowlist policy keyed by `encryptionTier`. For `server_readable` domains keep verbatim dump (server can already read them, by definition). For `end_to_end` and `zero_access` domains, pass each doc through a **field allowlist** that keeps only: doc `id`; known sealed-envelope fields (anything matching the `requireSealedText` shape — `{algorithm, keyVersion, nonce, ciphertext, tag}` — detected structurally, reused from `shared.ts:338`); opaque cryptographic columns (`slugHmac`, `dedupHash`, `vectorId`, `embedding` vector, `embeddingModelVersion`, `sourceKind`, `byteCount`, `chunkIndex`, `schemaVersion`, timestamps, `uid`); and DROP every other string/scalar (which is where cleartext titles/paths/names live).
   - Implement as a new helper `sealAwareSerializeDoc(data, tier)` called from `collectInlineJson` (`dataExport.ts:214`). For E2E/zero-access, default-deny: emit a field only if it is (a) a detected sealed envelope, (b) on the opaque-allowlist, or (c) a Timestamp/number/bool. Any other top-level string is omitted and replaced with a marker (e.g. add the key to a `redactedFields: string[]` so the export is honest about what was withheld).
   - This satisfies (a) never emits a plaintext private field the rules would reject, and (b) still gives the user their data — the sealed envelopes are emitted and the user decrypts locally; large E2E bodies already flow as `sealedRefs` (`collectSealedRefs`, `dataExport.ts:258-282`), unchanged.

**Exact change points:**
   - `dataExport.ts:208-220` `collectInlineJson` — pass `paths.encryptionTier` into the serializer.
   - `dataExport.ts:223-251` — add `sealAwareSerializeDoc` (and a structural `isSealedEnvelope(value)` predicate mirroring `requireSealedText`); keep `serializeValue` for `server_readable`.
   - Add a small per-domain field allowlist constant near `DATA_DOMAIN_PATHS` (the union of opaque columns the E2E/zero-access collections legitimately need to round-trip).

**5. PRODUCT FORK** — None. The export reader is always the owner (vault-key holder); sealed-only export for E2E domains is unambiguously correct. No hosted reader consumes the export.

**6. BLAST RADIUS** — `functions/src/__tests__/dataExport.test.ts` (drift guard unaffected, but add a new test asserting that an E2E doc containing a cleartext `repoFullName`/`title`/`sourcePath` is NOT present in `inlineJson`); `dataExportFailClosed.test.ts` (uses empty Firestore — unaffected). Web/iOS/Android export consumers already treat `inlineJson` as opaque, so no client change required. Update `dataExport.ts` header comment (lines 9-16) from an *assertion* to a *guarantee* and reference the enforcing helper.

---

### SURFACE 2 — `knowledge_repos` `repoFullName` / `sourceSlug` cleartext (functions/src/callables/knowledgeSync.ts)

**1. DATA FLOW**
- **Writer:** `connectKnowledgeRepo` (`knowledgeSync.ts:89-113`) stores `{ uid, repoId, repoFullName, sourceSlug, installId, ... }` at `users/{uid}/knowledge_repos/{repoId}` — `repoFullName` written cleartext (`knowledgeSync.ts:107`). Device-side caller is the web console only (`apps/console/components/pensieve/PensieveDashboard.tsx:46,128,160` → `connectRepo: "connectKnowledgeRepo"` in `apps/console/lib/domains.generated.ts:211`); no Swift/Kotlin caller exists yet. Rules allow owner self-write (`firestore.rules:1651-1655`, `ownerWritableNonSecret`).
- **Readers:**
   1. **`onKnowledgeRepoPush`** GitHub webhook (`knowledgeSync.ts:65-83`): reads `req.body.repository.full_name` from GitHub's HMAC-signed payload, then `db.collectionGroup("knowledge_repos").where("repoFullName", "==", repoFullName).get()` (`knowledgeSync.ts:73`) to map repo→owner(s), and reads `sourceSlug` (`:77`) to flag the manifest.
   2. **`exportUserData`** (verbatim dump, Surface 1).
- The hosted-MCP `services/hosted-mcp/src/knowledge.ts` and the `searchKnowledge` callable do **NOT** read `knowledge_repos` or `repoFullName` (confirmed).

**2. SERVER-READ REQUIREMENT** — The webhook needs to *match* the incoming GitHub `full_name` against stored rows, but it does **NOT need the cleartext value back** — it only needs equality (`repoFullName == repoFullName`). The server receives the plaintext repo name from GitHub regardless (out-of-band, signed payload), so it can compute a **keyed match token** on the fly *only if* it holds the matching key — which it does not (zero-knowledge). Therefore the match must be done over a value the server can derive from the GitHub-supplied plaintext WITHOUT the vault key, OR a value the server can compare without learning identity. This forces the design.

**3. VAULT-KEY AVAILABILITY** — The webhook is a server with no vault key (and no user auth context). It only has the GitHub-signed `full_name` plaintext. The device (which holds the vault key) is NOT in the webhook loop. So a **vault-keyed HMAC of repoFullName is impossible to match server-side** (server can't recompute it). This is the key constraint distinguishing this surface from `sourceSlug`/`dedupHash`.

**4. RECOMMENDED FIX (keyed-hash, NOT vault-sealing)** — Replace cleartext `repoFullName` with a **server-keyed (NOT vault-keyed) HMAC**: `repoMatchToken = HMAC_SHA256(serverWebhookKey, normalize(full_name))`, where `serverWebhookKey` is a Cloud Functions secret the *server* holds (reuse the `defineSecret` pattern already present at `knowledgeSync.ts:29`, `KNOWLEDGE_GITHUB_WEBHOOK_SECRET`, or a sibling `KNOWLEDGE_REPO_MATCH_KEY`). Rationale: the webhook receives the plaintext `full_name` from GitHub and can recompute the same token to query `where("repoMatchToken","==",token)`; a Firestore-only adversary sees an opaque token, not the repo identity. The `connectKnowledgeRepo` callable computes the same token server-side (it receives `repoFullName` over an authed HTTPS callable anyway, then stores only the token). `sourceSlug` stays as-is server-side **only as the manifest doc-id**; do not duplicate it cleartext on the repo row beyond what's needed to flag the manifest — instead store `slugHmac` if a future device wants to correlate, but the webhook→manifest hop is server-internal and uses the doc-id slug. Since the slug is the user's own source registry doc-id (same accepted-leakage rationale as `knowledge_sync_manifests`, `knowledgeMemory.ts:330-331`), keeping it server-side for the webhook flag is consistent with the existing model; the leak to seal is specifically the **project-identity `repoFullName`**.

   - **Note the alternative (vault-seal) is NOT viable here** because the webhook has no vault key and no user context to decrypt; only a server-keyed token enables the equality match. This is the correct minimal change.

**Exact field/schema changes:**
   - `knowledgeSync.ts:99-109` (`connectKnowledgeRepo`): stop storing `repoFullName`; compute and store `repoMatchToken = HMAC(secret, normalizedFullName)`. Keep `repoId` (already a sanitized derivative — note `repoId` at `:102` is `repoFullName.replace(/[^A-Za-z0-9_.-]/g,"_")` which **also leaks the name** and must change to `safeCloudDocumentID(repoMatchToken)` or a random id).
   - `knowledgeSync.ts:73` (`onKnowledgeRepoPush`): query `.where("repoMatchToken","==", HMAC(secret, normalize(req.body.repository.full_name)))`.
   - Add `KNOWLEDGE_REPO_MATCH_KEY` secret via `defineSecret` and bind it to both functions' `secrets:[]` (`knowledgeSync.ts:48,90`).

**5. PRODUCT FORK** — Minor: if product wants the repo name to remain **user-visible in the web dashboard**, the cleartext can't live server-side; either (Option A) store ONLY the token server-side and keep the display name on-device / in a sealed envelope the web app decrypts (consistent with E2E), or (Option B) accept `repoFullName` as a server-readable convenience field (GitHub repo names are arguably low-sensitivity public identifiers for public repos, but PRIVATE repo names are project-identity leakage). **Recommended: Option A** (token server-side + sealed display name) to honor the privacy contract; the brief's adversarial finding explicitly classifies project/repo names as PRIVATE TEXT.

**6. BLAST RADIUS** — `connectKnowledgeRepo`/`onKnowledgeRepoPush` (functions), the new secret, `firestore.rules:1651-1655` (the `ownerWritableNonSecret` field set — if web writes the token it must be allowed; if server computes it the create rule may need `repoFullName` excluded from owner-writable to avoid a client-supplied cleartext), `apps/console/components/pensieve/PensieveDashboard.tsx` (display name source), `apps/console/lib/domains.generated.ts` (if shape changes), and the Surface-1 export allowlist (which then no longer needs special-casing once the cleartext is gone). No tests currently cover `knowledgeSync.ts` repo-match — add one.

---

### SURFACE 3 — Pensieve cloaking enforcement + dedup oracle (functions/src/callables/knowledgeMemory.ts)

**1. DATA FLOW**
- **Writer:** `commitKnowledgeBatch` (`knowledgeMemory.ts:197-353`). Per vector it accepts:
   - `requireCloakedVector(raw.cloakedVector ?? raw.embedding, ...)` (`knowledgeMemory.ts:247`) — **accepts a raw `embedding` field as a fallback** (`?? raw.embedding`). `requireCloakedVector` (`:125-134`) validates ONLY dimensionality (384) + finiteness; it does NOT verify the vector is cloaked. So an un-cloaked plaintext embedding passes.
   - `resolveDedupHash` (`:174-190`): if `raw.dedupHash` present → v1 keyed; else falls back to `raw.contentHash` (cleartext SHA-256 of plaintext) stamped v0 (`:186-189`). The v0 path is the **dedup oracle**: a server can confirm a guessed plaintext by `SHA-256(guess) == stored.dedupHash`.
- **Device writers (production):**
   - Swift `OpenBurnBarCore/.../PensieveKnowledgeChunker.swift:177` sets `contentHash = sha256Hex(trimmed)` (keyless), `vectorId = contentHash` (`:210`), and `KnowledgeSyncService.encode` (`AgentLens/Services/CloudSync/KnowledgeSyncService.swift:287-298`) sends `cloakedVector`, `contentHash`, `sourcePath` (**cleartext path!**, `:295`) and sends **NO `dedupHash`, NO `slugHmac`**. → every live Mac-written row is **v0 legacy** with a cleartext SHA-256 dedup oracle and a cleartext `sourcePath`.
   - TS shim `tools/openburnbar-mcp-remote/src/memoryHook.ts:180,198,202` identically emits keyless `contentHash` as `vectorId`, no `dedupHash`/`slugHmac`.
- **Readers:**
   1. **`searchKnowledge`** callable (`functions/src/callables/knowledgeSearch.ts`): already B-SEC-2-aware — filters on `slugHmac` with `sourceSlug` fallback (`:97-98`), returns `dedupHash ?? contentHash` (`:123`).
   2. **Hosted-MCP `services/hosted-mcp/src/knowledge.ts`**: **NOT updated** — filters on cleartext `sourceSlug` (`:169`), returns cleartext `sourceSlug` (`:194`) and cleartext `contentHash` (`:238`). This is a live second reader still on the leaky model.
   3. **`exportUserData`** (Surface 1, verbatim).
- Idempotent-skip reads `prior.dedupHash ?? prior.contentHash` (`knowledgeMemory.ts:280`); delete sweeps `slugHmac` then legacy `sourceSlug` (`:437-439`).

**2. SERVER-READ REQUIREMENT** — None for plaintext. The server's ONLY functional needs are: (a) run `findNearest` over the **cloaked** `embedding` (it never needs the true embedding), (b) idempotency by an opaque dedup key (equality only — does not need plaintext), (c) coarse filters `sourceKind`/`embeddingModelVersion`/`slugHmac` (no content). So neither the raw embedding nor the cleartext SHA-256 is ever functionally required. The `?? raw.embedding` and `?? raw.contentHash` are pure backward-compat fallbacks for not-yet-updated clients — store-and-forward, no server read of plaintext.

**3. VAULT-KEY AVAILABILITY** — The device holds the vault key and can compute both the cloaked vector and the vault-keyed `dedupHash`/`slugHmac` (the test `knowledgeMemoryDedupHash.test.ts:110-114` spells out the exact derivation: `HKDF(vaultKey, salt=∅, info="pensieve-dedup:content"/"…:slug") → HMAC_SHA256(plaintext/slug)`). The CryptoKit primitives already exist in `CloudVaultCrypto.swift` (`HMAC<SHA256>` at `:246`, `HKDF<SHA256>.deriveKey` at `:400,468`). So full E2E is achievable for every reader (all readers are the owner or the owner's cloaked-query path).

**4. RECOMMENDED FIX**
   - **Enforce cloaking — reject raw embeddings:** in `commitKnowledgeBatch`, drop the `?? raw.embedding` fallback (`knowledgeMemory.ts:247`) → require `raw.cloakedVector`. Strengthen `requireCloakedVector` (`:125-134`) to reject the legacy field name (only accept `cloakedVector`). Mirror in `searchKnowledge` (`requireCloakedQueryVector` already only reads `queryVector`, OK) and in hosted-MCP `knowledge.ts` (its query vector is already cloaked per its header `:7`).
   - **Remove / key the legacy dedup oracle:** remove the `raw.contentHash` v0 fallback in `resolveDedupHash` (`:174-190`) → require `raw.dedupHash` (vault-keyed HMAC). Stop reading/writing `contentHash` on the idempotent-skip (`:280`) and the search return (`knowledgeSearch.ts:123`, `knowledge.ts:238`). Keep `dedupHashVersion` stamping at v1 only.
   - **Ship the device derivation FIRST (hard dependency):** update `PensieveKnowledgeChunker.prepareBatch` (`PensieveKnowledgeChunker.swift:157-228`) and `KnowledgeSyncService.encode` (`KnowledgeSyncService.swift:287-298`) AND the TS shim `memoryHook.ts:180-202` to compute and send `dedupHash`/`slugHmac` (HKDF labels `pensieve-dedup:content` / `pensieve-dedup:slug`, per the test) and to **stop sending `contentHash` and `sourcePath`** (the path already lives inside `sealedMetadata`, `PensieveKnowledgeChunker.swift:189-206`). Add a `PensieveDedupKey` helper to `CloudVaultCrypto`/a sibling reusing `HKDF<SHA256>.deriveKey` + `HMAC<SHA256>` (mirrors `searchKey`/`semanticSearchKey` at `CloudVaultCrypto.swift:466-478`).

**5. PRODUCT FORK — BACKWARD-COMPAT (the real decision)** — Hard-rejecting raw embeddings + cleartext `contentHash` **breaks every not-yet-updated client immediately** and **strands existing v0 rows** (which still carry cleartext SHA-256 + the Mac client even stores cleartext `sourcePath`). Two options:

   - **Option A — Flag-day enforce (recommended for the privacy fix):** Ship the device derivation (Swift + TS) and the hosted-MCP reader update in the SAME release, THEN flip `commitKnowledgeBatch`/`searchKnowledge`/`knowledge.ts` to reject raw embedding + require `dedupHash`. Existing v0 rows remain readable but carry a live oracle until the device **re-ingests** each source (which rewrites them at v1 — there is no server backfill; the server lacks the vault key, per `knowledgeMemory.ts:76-81`). To eliminate the stranded oracle, trigger a forced re-ingest by bumping `embeddingModelVersion`/`dedupHashVersion` so the watcher (`OpenBurnBarDaemon/.../PensieveKnowledgeWatcher.swift`) re-syncs. Consequence: a transient window where old rows still leak until re-ingest completes; clean end state.
   - **Option B — Soft-deprecate:** keep accepting v0 but emit a server warning + force re-ingest, and only reject after a deadline. Consequence: oracle persists longer; simpler rollout. **Reject** — leaves the confirmed leak live.

   The decision the code cannot make for you: **do we accept the transient v0-row leak during the re-ingest window, or do we PURGE all v0 rows on upgrade** (call `purgeKnowledgeMemory`, `knowledgeMemory.ts:457-466`, then full re-ingest) for a hard cut. Purge = zero residual oracle, costs the user a re-embed of all sources.

**6. BLAST RADIUS**
   - Functions: `knowledgeMemory.ts:125-134,174-190,247,280` (enforce/remove fallbacks); `knowledgeSearch.ts:89-98,122-123` (drop `sourceSlug`/`contentHash` fallbacks once clients are v1).
   - **Second live reader (must move in lockstep):** `services/hosted-mcp/src/knowledge.ts:16-17,38,164,169,194,238,242` — migrate filter to `slugHmac`, stop returning cleartext `sourceSlug`/`contentHash`.
   - Device: `OpenBurnBarCore/.../PensieveKnowledgeChunker.swift` (struct `PensieveKnowledgeVector` fields `:17-49` — drop `contentHash`/`sourcePath`, add `dedupHash`/`slugHmac`), `AgentLens/Services/CloudSync/KnowledgeSyncService.swift:287-298` (encoder), `tools/openburnbar-mcp-remote/src/memoryHook.ts:61-202`, plus a new `CloudVaultCrypto` dedup-key helper.
   - Tests: `functions/src/__tests__/knowledgeMemoryDedupHash.test.ts` (its "legacy v0" case at `:210-226` must flip to expect a **rejection** once the fallback is removed); `OpenBurnBarCore/Tests/.../PensieveKnowledgeChunkerTests.swift`, `PensieveCloakTSParityTests.swift`, `PensieveVectorCloakTests.swift` (assert `dedupHash`/`slugHmac` present, `contentHash`/`sourcePath` absent).
   - Rules: `firestore.rules:1631-1646` unchanged (server-only writer), but the export allowlist (Surface 1) covers the residual v0 rows until purge.
   - Docs: `docs/PENSIEVE.md`, `docs/pensieve-leakage-analysis.md` (referenced at `knowledgeMemory.ts:36`).

---

## DESIGN BRIEF

1. **dataExport — kill the verbatim dump.** In `functions/src/callables/dataExport.ts:208-220`, pass `paths.encryptionTier` into serialization. Add `sealAwareSerializeDoc(data, tier)` beside `serializeDoc` (`:223`): for `server_readable` keep current `serializeValue` behavior; for `end_to_end`/`zero_access` **default-deny** every field except (a) detected AES-256-GCM sealed envelopes (add `isSealedEnvelope(v)` mirroring `requireSealedText`, `shared.ts:338`), (b) an opaque-column allowlist (`id, uid, vectorId, embedding, embeddingModelVersion, slugHmac, dedupHash, dedupHashVersion, sourceKind, byteCount, chunkIndex, schemaVersion, repoMatchToken`, all Timestamps/numbers/bools), and record dropped keys in a `redactedFields: string[]`. Emit `inlineJson` + `redactedFields` per domain.

2. **dataExport test.** Add a case to `functions/src/__tests__/dataExport.test.ts` (or a new `dataExportSealAware.test.ts`): seed an E2E collection doc with cleartext `repoFullName`/`title`/`sourcePath`, run the export, assert those strings are absent from `inlineJson` and listed in `redactedFields`; assert a sealed envelope IS present.

3. **dataExport header.** Update `dataExport.ts:9-16` from assertion to enforced guarantee; reference `sealAwareSerializeDoc`.

4. **knowledge_repos — server-keyed match token.** In `functions/src/callables/knowledgeSync.ts`: add `KNOWLEDGE_REPO_MATCH_KEY` via `defineSecret`; in `connectKnowledgeRepo` (`:99-109`) replace stored `repoFullName` with `repoMatchToken = HMAC_SHA256(secret, normalize(repoFullName))`, and replace `repoId` derivation (`:102`, which also leaks the name) with `safeCloudDocumentID(repoMatchToken)`; in `onKnowledgeRepoPush` (`:73`) query `.where("repoMatchToken","==", HMAC(secret, normalize(req.body.repository.full_name)))`; bind the secret to both functions (`:48,90`).

5. **knowledge_repos — display name.** If the web dashboard must show the repo name (`apps/console/components/pensieve/PensieveDashboard.tsx`), source it from on-device/sealed state, not the server row. Update `firestore.rules:1651-1655` so a client-supplied cleartext `repoFullName` is no longer accepted (token-only).

6. **Pensieve — enforce cloaking.** In `functions/src/callables/knowledgeMemory.ts:247` drop `?? raw.embedding`; in `requireCloakedVector` (`:125-134`) accept only `cloakedVector`.

7. **Pensieve — remove the dedup oracle.** In `resolveDedupHash` (`:174-190`) drop the `raw.contentHash` v0 branch → require vault-keyed `raw.dedupHash` (v1 only); remove `contentHash` reads at `:280`, `knowledgeSearch.ts:123`, `services/hosted-mcp/src/knowledge.ts:238`; remove `sourceSlug` filter/return fallbacks at `knowledgeSearch.ts:89-98,122` and `knowledge.ts:164,169,194,242` once clients are v1.

8. **Pensieve — ship device derivation FIRST (hard dependency for 6–7).** Add a `CloudVaultCrypto` dedup-key helper (`HKDF<SHA256>` info `pensieve-dedup:content`/`pensieve-dedup:slug` → `HMAC<SHA256>`, reusing the pattern at `CloudVaultCrypto.swift:466-478`). Update `PensieveKnowledgeChunker.swift:17-49,157-228` and `KnowledgeSyncService.swift:287-298` to send `dedupHash`/`slugHmac` and STOP sending `contentHash`/`sourcePath`; mirror in `tools/openburnbar-mcp-remote/src/memoryHook.ts:180-202`.

9. **Pensieve — second reader in lockstep.** Migrate `services/hosted-mcp/src/knowledge.ts:16-17,38,164,169,194,238,242` to `slugHmac` filter + sealed-only returns (it is a live reader still on the leaky model).

10. **Pensieve — v0 migration decision (PRODUCT FORK).** Choose: (A) flag-day enforce + forced device re-ingest via `embeddingModelVersion`/`dedupHashVersion` bump (transient v0-row leak until re-ingest), or (B) hard cut: `purgeKnowledgeMemory` on upgrade + full re-ingest (zero residual oracle, costs a re-embed). Recommend A unless zero-residual is required, then B.

11. **Pensieve tests.** Flip `knowledgeMemoryDedupHash.test.ts:210-226` (legacy v0) from "stamped v0" to "rejected"; update Swift `PensieveKnowledgeChunkerTests` / `PensieveCloakTSParityTests` / `PensieveVectorCloakTests` to assert `dedupHash`/`slugHmac` present and `contentHash`/`sourcePath` absent; update `docs/PENSIEVE.md` + `docs/pensieve-leakage-analysis.md`.

Relevant files (absolute):
- /Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/dataExport.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/knowledgeSync.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/knowledgeMemory.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/knowledgeSearch.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/shared.ts (requireSealedText:338)
- /Users/albertonunez/Documents/Windsurf/BurnBar/services/hosted-mcp/src/knowledge.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PensieveKnowledgeChunker.swift
- /Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift (HKDF/HMAC:246,400,466-478)
- /Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/CloudSync/KnowledgeSyncService.swift (encoder:287-298)
- /Users/albertonunez/Documents/Windsurf/BurnBar/tools/openburnbar-mcp-remote/src/memoryHook.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/__tests__/dataExport.test.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/__tests__/knowledgeMemoryDedupHash.test.ts
- /Users/albertonunez/Documents/Windsurf/BurnBar/firestore.rules (knowledge blocks:1631-1655)
- /Users/albertonunez/Documents/Windsurf/BurnBar/packages/data-domains/registry.json