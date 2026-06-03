# Pensieve — Personal Knowledge Memory (E2EE)

Pensieve productizes BurnBar's maintainer `droid-wiki → mem0` flow into a
per-paying-member, **end-to-end-encrypted** semantic memory. A Cloud Pro
member's repo docs, hand notes, and chat-derived memories sync — chunked,
embedded, cloaked, and AES-256-GCM-sealed **on device** — into a private,
isolated namespace their coding agents query over the existing hosted MCP. The
provider never sees plaintext.

- Member-facing name: **Pensieve** (pairs with the public "Floo").
- Code / SKU / entitlement id family: **`mnemo`** / `burnbar_ultra`.
- Base tier: included in **$24.99 Cloud Pro** (`burnbar_pro_max`), no price change.
- New tier: **Ultra $59.99/mo · $599/yr** (`burnbar_ultra`) at 10× limits.

## Two hard constraints (from planning)

1. **E2EE** — the provider (BurnBar, any vendor) must never see plaintext. This
   rules out managed mem0 (it reads plaintext to embed).
2. **Cost-neutral inference** — chat-memory extraction + embeddings run on the
   member's own compute/LLM plan, so marginal cost stays in cents.

Result: on-device embeddings + on-device encryption; only ciphertext and
**cloaked** opaque vectors are stored server-side.

---

## Architecture as built

> **Deviation from the source plan (intentional, within the plan's residual
> open decision #1):** the vector store is **Firestore native vector search**
> (`findNearest` + `FieldValue.vector`, 384-dim COSINE), **not** Cloud SQL
> Postgres + pgvector. Firestore reuses the existing owner-only
> `users/{uid}/…` isolation rules, needs no separate instance to provision,
> lets `commitKnowledgeBatch` write a single store, and ships its index
> declaratively via `firestore.indexes.json`. pgvector remains a documented
> future scale lever (swap `knowledge.ts`'s `findNearest` for a pgvector client;
> the `KnowledgeVectorStore` interface in `knowledgeVector.ts` already abstracts
> the contract). This removed the single largest infra dependency.

### Flow 1 — Ingest (docs / notes / extracted memories → queryable)

Runs on the member's device (Mac daemon or mobile app — only the device has the
vault key + embedder):

```
source change → chunkMarkdown (shared verbatim chunker)
  → embed each chunk on-device (bge-small-en-v1.5, 384-dim)
  → CLOAK vector (vault-key Householder-product orthonormal transform)
  → SEAL text + metadata (AES-256-GCM, vault key)
  → commitKnowledgeBatch({sourceSlug, slugHmac, vectors:[{vectorId,
      cloakedVector, sealedCiphertext, sealedMetadata, dedupHash, sourceKind,
      chunkIndex, byteCount}], embeddingModelVersion})
      [dedupHash + slugHmac are VAULT-KEYED HMACs the device computes — no
       cleartext contentHash/sourcePath/sourceSlug leaves the device (B-SEC-2)]
  → server writes users/{uid}/cloud_search_knowledge/{vectorId}
      (embedding = FieldValue.vector, ciphertext stored INLINE) + manifest
  [server sees only ciphertext + cloaked vectors + keyed dedup/slug HMACs
   + sourceKind/byteCount + counts/timestamps]
```

### Flow 2 — Query (agent recall, E2EE)

```
agent → stdio shim (tools/openburnbar-mcp-remote)
  → shim embeds the natural-language query on-device + cloaks it (query text
    never leaves the device)
  → burnbar_search_knowledge {queryVector:number[384], filters?, …}
  → server findNearest COSINE over users/{sub}/cloud_search_knowledge
    → top-K {vectorId, ciphertext, sealedMetadata, score, sourceKind,
             slugHmac, dedupHash}   [keyed, not cleartext — B-SEC-2]
  → shim decrypts ciphertext + metadata (vault key) + applies sealed-only
    filters (sourcePath/section/category) → plaintext memory → agent context
```

The agent sees a `query` (text) field — the shim rewrites the advertised
`tools/list` schema and synthesizes the `queryVector` on device.

### Flow 3 — Chat-derived memory (bring-your-own-inference — the clever core)

```
agent session ends → Claude SessionEnd hook → `openburnbar memory run`
  → run extraction on the USER'S plan: claude -p "<EXTRACT_PROMPT>" --output-format json
  → parse [{title,text,category,confidence}]   [billed to the user, $0 to us]
  → confidence filter + secret redaction
  → dedup (content hash + vector search) → keep net-new
  → embed + cloak + seal → queue for commitKnowledgeBatch (device-authed)
```

### Vault-key vector cloaking (basis hiding + per-user distinct bytes)

Before upload, every embedding (index + query) is multiplied by a per-user
**orthonormal** transform Q derived from the vault key (HKDF seed → a product of
24 Householder reflections). Q is exactly orthonormal, so `<Qx, Qy> = <x, y>`
and `‖Qx‖ = ‖x‖`. That math is the basis of what the cloak does and does **not**
buy us — state only the proven properties:

1. **Hides the public-model (bge) basis.** Stored vectors are no longer expressed
   in the raw bge coordinate frame, so off-the-shelf embedding-inversion models —
   which expect raw bge-space inputs — cannot be applied **directly** to the
   stored vectors. This raises the bar; it is not a proof of non-invertibility.
2. **Per-user distinct stored bytes (partial cross-tenant resistance).** Q is
   per-user, so the same plaintext stored under two members' keys yields
   **different** vectors (relative L2 distance ≈ 0.74), defeating an exact-match
   cross-tenant join. **Caveat — this is NOT full unlinkability:** with only 24
   Householder reflections in 384-dim, cross-tenant **cosine ≈ 0.77**, so a
   curious server can still correlate the same plaintext across tenants by
   *similarity*. Full decorrelation needs ≈ `dim` reflections (a versioned
   re-cloak). See the leakage analysis.
3. **It does NOT hide relative geometry — accepted, documented leakage.** Because
   Q is orthonormal, the **full pairwise cosine matrix**, **k-NN graph**,
   **clusterability**, and **similarity-based dedup** are preserved and
   computable by the server **without the key** — both within a single user's
   vectors and (per the caveat above) across tenants. The cloak is not an
   "inversion-proof", distance-hiding, or full-unlinkability scheme.

For the precise protect-vs-leak accounting, the orthonormality math, the
accepted-leakage rationale, and the trigger that would force a stronger scheme,
see [`docs/pensieve-leakage-analysis.md`](pensieve-leakage-analysis.md).
Implemented in `tools/openburnbar-mcp-remote/src/embed.ts` (`cloakVector`),
mirrored in
`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PensieveVectorCloak.swift`.
Proven by `tools/openburnbar-mcp-remote/src/cloakLeakage.test.ts`.

---

## Security & threat model

**What the server / any vendor can see:** ciphertext, cloaked opaque vectors,
chunk counts, timestamps, `namespace = uid`, the vault-keyed `dedupHash` +
`slugHmac` (HMACs the server cannot reverse or re-derive without the key), and
the two cleartext filter/cap inputs `sourceKind` (one of three coarse buckets) +
`byteCount` (a length). For a connected repo it additionally sees an opaque
server-keyed `repoMatchToken` (used only to route an inbound GitHub webhook) and
a vault-sealed `sealedRepoFullName` it cannot open. **Never** plaintext, raw
query text, a public-bge-space embedding, a confirm-the-guess SHA-256 of the
plaintext (the legacy v0 `contentHash` dedup oracle is GONE end-to-end — commits
require a vault-keyed `dedupHash` and reject a raw `embedding`/`contentHash`, and
as of the dedup-v0 flag-day any pre-existing v0 row — `dedupHashVersion == 0`,
whose doc id was the legacy cleartext SHA-256 — is no longer served and is
purged: `searchKnowledge` floors `dedupHashVersion == 1` and filters the bumped
embedding-model tag `bge-small-en-v1.5-vault-dedup-v1`, the `commitKnowledgeBatch`
idempotent-skip never treats a v0 row as a match, and `purgeLegacyKnowledgeVectors`
deletes v0 rows + rows under the retired model tag, so the cleartext-SHA-256
oracle survives in no served or queryable row),
the real `sourcePath` for an indexed chunk (it is sealed inside `sealedMetadata`),
or the cleartext repo `repoFullName` (now stored only as the opaque match token +
sealed name; the cleartext name is observed transiently server-side only when the
GitHub push webhook arrives, never stored). **Accepted leakage:** because the cloak is
orthonormal, the server can compute the pairwise cosine matrix, k-NN graph,
clusters, and similarity-dedup over the cloaked vectors **without the key** —
relative geometry is preserved, not hidden. At the shipped 24-reflection
parameter this also leaves a cross-tenant "same-item" similarity signal
(cosine ≈ 0.77), so cross-tenant linkage is only *partially* resisted. The repo
`repoMatchToken` is a **global** deterministic HMAC (the same repo yields the same
token for every user), so the server can observe that two members connected the
same repo and — if the single server-side match key ever leaked — could
dictionary-confirm *which* public repo from a candidate list; it is not per-user
salted. The source registry also still stores a reversible cleartext `sourceSlug`
(a slugified source path) on `knowledge_repos` rows and as
`knowledge_sync_manifests` document ids; replacing those with an opaque per-user id
is tracked remaining hardening (privacy-leak-remediation F4/F5). See
[`docs/pensieve-leakage-analysis.md`](pensieve-leakage-analysis.md) and
[`docs/searchable-index-leakage.md`](searchable-index-leakage.md).

| Control | Mechanism |
|---|---|
| **Isolation** | Server queries only `namespace = claims.sub` (Firebase uid from the verified bearer). A client-supplied namespace/uid is never trusted. Firestore data lives under `users/{uid}/…`, enforced by owner-only rules. |
| **Key management** | Vault key device-only (Keychain / `~/.openburnbar/vault-key` 0600). Loss ⇒ unrecoverable memory (documented). |
| **Basis hiding + per-user distinct bytes** | Per-user vault-key orthonormal cloaking on every vector: removes the public bge basis (no *direct* off-the-shelf inversion) and makes the same plaintext stored under two members' keys byte-distinct (defeats exact-match cross-tenant joins). Does **not** hide relative geometry, and at 24 reflections does **not** give full cross-tenant unlinkability (cross-tenant cosine ≈ 0.77) — see [leakage analysis](pensieve-leakage-analysis.md). |
| **Secret hygiene** | `redactSecrets` runs before sealing chat-derived memories; the extraction prompt forbids secrets; per-confidence threshold. |
| **Fail-open** | Missing vault key / lapsed entitlement / unreachable index ⇒ a clear error or empty result, never a crash that blocks a commit, app launch, or agent session. |

### DPA-not-needed note

Because plaintext **never leaves the device** and no third party processes
plaintext, there is **no third-party data processor in the plaintext path** —
so Pensieve requires **no Data Processing Agreement** for the memory content.
This is a privacy win over managed mem0 (which reads plaintext to embed and
would require a DPA). The only data processors touch ciphertext + opaque
vectors (Google Cloud / Firestore, already covered by the existing GCP DPA).

### Adversarial harness — `scripts/test-hosted-mcp-security.sh`

Keeps the 3 base cases and adds 8 Pensieve cases (each skips loudly when its env
is absent; see the script header for the env vars):

1. Cross-tenant: bearer A + forged `namespace=B` → only A's data.
2. Plaintext-at-rest: dump a knowledge doc → only ciphertext + floats.
3. Query-text confidentiality: request body carries only a vector (shim contract; unit-tested in `knowledge.test.ts`).
4. Chunk-cap enforcement: push past the tier cap → `failed-precondition`.
5. Sync-frequency: hammer "Sync now" past the daily bucket → 429.
6. Revoked-client: old token on `burnbar_search_knowledge` → 403.
7. Verbatim integrity: add a chunk, read back → byte-identical after decrypt.
8. Non-entitled gate: free user calls `configureKnowledgeSource` → 403.

---

## Tiers, limits, cost

| Dimension | Pro (`burnbar_pro_max`) | Ultra (`burnbar_ultra`) |
|---|---|---|
| Knowledge sources | 3 | 15 |
| Memory chunks (vectors) | 5,000 | 50,000 |
| Encrypted storage | 25 MB | 250 MB |
| MCP query rate | 60/min (`knowledge:standard`) | 180/min (`search:ultra`) |

Limits live in `functions/src/callables/knowledgeMemory.ts` (`PENSIEVE_LIMITS`),
enforced via Firestore `count()` + `sum(byteCount)` aggregates before any write.
Ultra **mirrors** proMax (inherits every Cloud Pro gate); only the limit lookup
branches on the `burnbar_ultra` doc. Cost (E2EE, on-device/BYO inference): our
spend is just Firestore reads/writes ≈ **$0.02–0.10/member/mo** vs ~$21.24 net.

---

## File map (what was built)

**Shared chunker** — `scripts/lib/verbatim-chunker.mjs` (extracted from
`mem0-sync.mjs`, byte-identical), `scripts/lib/verbatim-chunker.test.mjs`.

**Client shim** (`tools/openburnbar-mcp-remote/src/`, TypeScript — `lib/` is
gitignored build output):
- `embed.ts` — bge-small-en-v1.5 embedder (lazy/opt-in) + vault-key cloaking + cosine helpers.
- `seal.ts` — AES-256-GCM encrypt counterpart to `decrypt.ts`.
- `knowledge.ts` — embed+cloak query, `tools/list` rewrite, decrypt sealed hits + sealed-only post-filter.
- `memoryHook.ts` — BYO-inference: extract → redact → dedup → seal → queue; `installMemoryHook`.
- `index.ts` — CLI `memory install|run|sync`.

**Hosted MCP** (`services/hosted-mcp/src/`):
- `knowledge.ts` — `searchKnowledge` (findNearest) + `readKnowledgeDocument`.
- `knowledgeVector.ts` — store types + cosine + in-memory test/emulator store.
- `toolRegistry.ts` — `burnbar_search_knowledge` + `burnbar_get_knowledge_document`.
- `rateLimits.ts` — `knowledge:standard` (60/min) + `search:ultra` (180/min) buckets.

**Cloud Functions** (`functions/src/`):
- `callables/knowledgeMemory.ts` — `commitKnowledgeBatch`, `configureKnowledgeSource`, `deleteKnowledgeSource`, `purgeKnowledgeMemory`.
- `callables/shared.ts` — `BURNBAR_ULTRA_ENTITLEMENT_ID`, `isActiveBurnBarUltraEntitlement`, `assertActiveBurnBarUltraEntitlement`.
- `appstore/reconciler.ts` — Ultra → mirror(`burnbar_pro_max`) branch.
- `config.ts` / `types/legacy.ts` — Ultra product IDs (Apple + Google Play).
- `remoteMcpGrant.ts` / `callables/remoteMcp.ts` / `remoteMcpOAuth.ts` — `knowledge:read` scope.
- `index.ts` — exports the new callables.

**Firestore** — `firestore.rules` (owner-only `cloud_search_knowledge`,
`knowledge_sync_manifests`, `knowledge_repos`; Ultra SKUs in the premium/media/
computer-use allowlists), `firestore.indexes.json` (4× 384-dim COSINE vector
indexes on `cloud_search_knowledge`). A `knowledge_repos` row stores only an
opaque server-keyed `repoMatchToken` + a vault-sealed `sealedRepoFullName` (no
cleartext `repoFullName`); the webhook recomputes the match token from the
GitHub-signed `full_name` to route, and the rules reject a client-supplied
cleartext `repoFullName`.

**Security/docs** — `scripts/test-hosted-mcp-security.sh` (+8 cases), this file.

---

## Verification

```bash
# Shared chunker parity (byte-identical to the committed manifest)
node --test scripts/lib/verbatim-chunker.test.mjs
node scripts/wiki/mem0-sync.mjs --all --dry-run   # must report "zero writes"

# Client shim (embed/cloak, knowledge path, memory hook, seal): 40 tests
cd tools/openburnbar-mcp-remote && npm test

# Hosted MCP (knowledge search + isolation + vector store): 28 tests
cd services/hosted-mcp && npm test

# Cloud Functions (Pensieve helpers + Ultra reconciler)
cd functions && npx tsc --noEmit && npm run lint
npx vitest run src/__tests__/knowledgeMemory.test.ts
npm run test:appstore   # includes Ultra-mirrors-proMax

# Security harness (base smoke; export PENSIEVE_* env for the 8 adversarial cases)
scripts/test-hosted-mcp-security.sh
```

---

## Deployment checklist (external — not agent-buildable)

- [ ] Deploy `firestore.indexes.json` (the 4 vector indexes) — `findNearest`
      throws `FAILED_PRECONDITION` until they exist.
- [ ] Deploy functions + hosted-mcp.
- [ ] Create Ultra SKUs in App Store Connect + Google Play
      (`com.openburnbar.ultra.monthly` / `.annual`).
- [ ] (Optional, repo connector) Create the GitHub App (contents-read) for the
      `onKnowledgeRepoPush` dirty signal.
- [ ] Members install the on-device embedder once: `npm i -g @huggingface/transformers`.

## Remaining work (documented follow-ups)

- **Native client UX (P7):** Pensieve cards / onboarding / Sync-now on iOS,
  macOS, Android (Swift/Kotlin — written grounded but not compiled in the
  authoring environment; see ledger). `HostedQuotaSubscriptionStore.isActiveUltra`
  on iOS + Android.
- **Ingestion triggers (P5):** macOS `PensieveKnowledgeWatcher` + iOS/macOS
  `KnowledgeSyncService` (device chunk→embed→seal→commit); `onKnowledgeRepoPush`
  webhook + `reconcileKnowledgeMemoryDaily`.
- **`tierCogs.ts` Ultra COGS bucket** + Pensieve unit costs + `schemaVersion`
  bump (analytics only; deferred to avoid blind-breaking the `test:tier-cogs`
  snapshot).
