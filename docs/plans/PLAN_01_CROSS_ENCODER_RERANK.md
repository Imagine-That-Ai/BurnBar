# Plan 01 — Cross-encoder reranking (post-retrieval precision)

**Agent assignment:** Implement optional cross-encoder (or API-based relevance) reranking after hybrid retrieval.  
**Goal:** Improve top-k precision for RAG/chat evidence without replacing existing bi-encoder ANN + FTS pipeline.

---

## 1. Research baseline (SOTA context)

Production hybrid stacks typically: **BM25/FTS → dense ANN → (optional) cross-encoder rerank** on a small candidate set (often 20–100). Cross-encoders score **query + document pairs** jointly, fixing cases where cosine similarity ranks plausible-but-wrong chunks highly.

Options in a macOS Swift app:

| Approach | Pros | Cons |
|----------|------|------|
| **OpenAI / hosted relevance** (e.g. small classifier or ranking API) | No on-device model; consistent with existing `OpenAIEmbeddingProvider` | Latency, cost, privacy |
| **Local Core ML** exported model | Offline | Packaging, size, maintenance |
| **Batch scoring** via existing embeddings (cosine query–chunk only) | Already implemented as bi-encoder | Not true cross-attention |

**Recommendation for this codebase:** Start with a **pluggable `CrossEncoderReranking` protocol** and one implementation using **hosted batch scoring** (structured prompt or a dedicated ranking endpoint) gated by Settings, default off.

---

## 2. Current architecture (where to hook)

### 2.1 Primary integration point

- **`SearchService.retrieve(_:)`** — `AgentLens/Services/SearchService.swift`  
  - After building `scoredResults` and **before** `scoredResults.sort` by `rerankScore` (approximately lines 2228–2258 in current file), or **after** sort but **before** document dedupe — **prefer after hydration** so each candidate has full `chunk.text` / title for the cross-encoder prompt.

### 2.2 Data you already have per candidate

- **`RetrievalResult`** (`SearchService.swift`): `chunkID`, `title`, `snippet`, `sectionPath`, `rerankScore`, `lexicalRank`, `semanticScore`, `conversation`, offsets, etc.
- **`trimmed`** user query string is in scope inside `retrieve`.

### 2.3 Patterns to mirror

- **`OpenAIEmbeddingProvider`** (`SearchService.swift` ~664–773): URLSession, API key from `ProviderAPIKeyStore`, JSON encode/decode, errors.
- **`SettingsManager`**: add toggles similar to `indexEmbeddingProvider` / API keys (see `SettingsView.swift` embedding section).
- **Health / telemetry**: extend **`persistLexicalHealth`** / new subsystem in **`RetrievalHealthRecord`** + `DataStore.upsertRetrievalHealth` if you want `cross_encoder` rows (see `DataStore.swift` `retrieval_health` table ~1367+).

### 2.4 Call sites that inherit behavior

Any code path using `SearchService.retrieve` or `runBurnBarQuery` gets reranking:

- `ChatSessionController.send` → `runBurnBarQuery`
- `DatabaseWorkspaceView` search
- `ArtifactAuthoringService.retrieveContext`
- `SearchService.search` wrapper

Ensure rerank **budget** (max pairs or max tokens) is configurable to avoid blowing latency on chat.

---

## 3. Procedure (implementation phases)

### Phase A — Design API surface

1. Add **`CrossEncoderReranking`** (or `RetrievalReranker`) protocol, e.g.:

   ```swift
   protocol RetrievalRerankProviding: Sendable {
       func rerank(
           query: String,
           candidates: [RetrievalResult],
           limit: Int
       ) async throws -> [RetrievalResult]
   }
   ```

   `@MainActor` vs `Sendable` — align with `SemanticCandidateProviding` (currently `@MainActor`).

2. Add **`NoOpRetrievalReranker`** (identity) for tests and default.

3. Extend **`RetrievalQuery`** with optional fields:
   - `crossEncoderEnabled: Bool` (default `false` or follow global setting)
   - `crossEncoderCandidateLimit: Int` (default 40, cap e.g. 64)

### Phase B — Wire into `SearchService`

1. Add optional **`reranker: RetrievalRerankProviding?`** to **`SearchService`** initializer (parallel to `semanticProvider`).
2. In **`makeConversationSearchService`**, construct reranker when settings + API key allow.
3. Inside **`retrieve`**, after the loop that builds **`scoredResults`**:
   - Take **top N** by current `rerankScore` (N = `min(crossEncoderCandidateLimit, scoredResults.count)`).
   - Call `reranker.rerank(query: trimmed, candidates: slice, limit: slice.count)`.
   - Merge: reranked order replaces scores for those IDs; remaining candidates keep prior order below the slice **or** drop below threshold (document choice).
4. Add **`crossEncoderLatencyMs`** to health JSON (extend **`LexicalRetrievalHealthDetails`** private struct in `SearchService.swift`).

### Phase C — Concrete reranker implementation

1. **`OpenAICrossEncoderReranker`** (new file under `AgentLens/Services/` recommended):
   - Input: query + for each candidate a short pack: `title`, `snippet` or truncated `chunk` text (reuse `BurnBarChatEvidenceFormatting` truncation patterns or cap ~512–1k chars per candidate).
   - Output: ordered `chunkID` list or per-id scores.
   - Implementation options:
     - **Chat Completions** JSON mode: “Return JSON array of `{chunk_id, relevance 0-1}` for these passages.”
     - **Responses API** if project already uses it elsewhere — grep for consistency.
   - **Batching:** single request with numbered passages vs multiple requests — balance context window vs reliability.

2. **Rate limits / errors:** on failure, **fall back** to pre-rerank order and set health `degraded` with `errorCode` e.g. `CROSS_ENCODER_FAILED` (do not return empty results).

### Phase D — Settings & privacy

1. **`SettingsManager`**: `crossEncoderRerankEnabled`, optional `crossEncoderMaxCandidates`.
2. **`SettingsView`**: toggle under Privacy / Search, copy that query text may be sent to provider when enabled.
3. Document in existing user-facing docs only if product policy requires (optional).

### Phase E — Tests

1. **Unit tests** with **`NoOpRetrievalReranker`**: order unchanged.
2. **Mock reranker** reversing order — assert final order matches mock.
3. **`AgentLensTests`** / **`BurnBarSearchIntegrationHarnessTests`**: extend harness with fake reranker injected into `SearchService` (may require test-only initializer or protocol injection).

---

## 4. Files likely touched

| File | Change |
|------|--------|
| `AgentLens/Services/SearchService.swift` | `RetrievalQuery`, `retrieve`, `SearchService.init`, `makeConversationSearchService`, health struct |
| `AgentLens/Services/SettingsManager.swift` | New keys |
| `AgentLens/Views/Settings/SettingsView.swift` | UI |
| New: `AgentLens/Services/CrossEncoderReranker.swift` (name TBD) | Implementation |
| `AgentLens/Services/DataStore.swift` | Only if new `retrieval_health` subsystem enum extended |
| `AgentLensTests/...` | Tests |

---

## 5. Risks

- **Latency:** +200ms–2s per user message if not capped; must default off or cap N aggressively for chat.
- **Cost:** proportional to candidates × prompt size.
- **Stability:** JSON parsing failures — harden with retries or fallback.

---

## 6. Definition of done

- [ ] With reranking **off**, byte-identical behavior vs baseline (integration test).
- [ ] With reranking **on** and mock provider, order changes deterministically.
- [ ] Health row or details JSON records latency and errors without crashing retrieval.
- [ ] Settings persist and gate network calls.

---

## 7. Out of scope (future)

- On-device Core ML cross-encoder.
- Training custom rankers on user click feedback.
