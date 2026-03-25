# Plan 04 — BurnBar daemon semantic / hybrid parity with the Mac app

**Agent assignment:** Close the gap between **`BurnBarIndexedSearchService`** (daemon, **lexical + aggregate only**) and **`SearchService`** (app, **FTS + dense ANN + RRF**). Today the daemon returns **`degradedMessage`**: *“Semantic vector ranking is only available in the BurnBar app…”* (`BurnBarIndexedSearchService.swift` ~78).

---

## 1. Current architecture

### 1.1 Daemon side

| Component | Path | Role |
|-----------|------|------|
| Indexed search | `BurnBarDaemon/Sources/BurnBarDaemon/BurnBarIndexedSearchService.swift` | Read-only SQLite3; `lexicalHits` via FTS; `countOccurrences` on `conversations.fullText`; **no** `chunk_embeddings` reads |
| Server RPC | `BurnBarDaemon/Sources/BurnBarDaemon/BurnBarDaemonServer.swift` case `.searchQuery` (~421–448) | Decodes `BurnBarSearchQueryRequest`, calls `indexedSearch.search`, returns `BurnBarSearchQueryResult` |
| Config | `BurnBarDaemonConfiguration.indexDatabasePath`, env `BURNBAR_INDEX_DATABASE_PATH` (`BurnBarDaemonMain.swift`) | Points at `burnbar.sqlite` |
| Contracts | `BurnBarCore/Sources/BurnBarCore/BurnBarContracts.swift` | `BurnBarRPCMethod.searchQuery`, `BurnBarSearchQueryRequest`, `BurnBarSearchQueryResult`, `BurnBarIndexedSearchHit` |

### 1.2 App side (source of truth for vectors)

| Component | Path | Role |
|-----------|------|------|
| Embeddings | `chunk_embeddings` + `VectorSemanticCandidateProvider` | `SearchService.swift` ~1186+ |
| ANN | `SignpostANNVectorCandidateBackend` / exact rerank | Same file |
| Hybrid fusion | `HybridFusionStrategy`, RRF | `SearchService.retrieve` |

### 1.3 Shared planning

- **`BurnBarSearchPlan.plan(userText:)`** — `BurnBarCore/.../BurnBarSearchPlanner.swift` — used by **both** app (`runBurnBarQuery`) and daemon.

---

## 2. Strategic options (pick one for the agent; document tradeoffs)

### Option A — **Delegate semantic search to the app (IPC)**

- Extension/daemon sends search to **running BurnBar app** via XPC / HTTP localhost / existing socket.
- **Pros:** Zero duplication of embedding code, single ANN index reader.  
- **Cons:** App must be running; failure modes when app quit.

### Option B — **Embed vector retrieval in daemon (Swift)**

- Link **BurnBarDaemon** against shared modules that can read `chunk_embeddings` blobs and run ANN (port `VectorSemanticCandidateProvider` + dependencies to a **non-@MainActor** or daemon-safe variant).
- **Pros:** Works when app closed.  
- **Cons:** Large dependency surface (GRDB vs raw SQLite in daemon today — daemon uses **SQLite3 C API**, app uses **GRDB** in `DataStore`); must avoid duplicating logic.

### C — **Precomputed top-k index files**

- App exports periodic “semantic index” snapshot consumed by daemon read-only mmap.
- **Cons:** Staleness, complexity.

### D — **Hosted semantic search API**

- Daemon calls cloud with query + workspace scope — privacy/cost issues for transcripts.

**Recommended default for BurnBar:** **Option A** short term (fastest parity UX), **Option B** medium term (true offline daemon).

---

## 3. Procedure (Option B expanded — most “codebase-local”)

### Phase 1 — Read path for `chunk_embeddings` in daemon

1. **Schema parity:** confirm `chunk_embeddings` table layout in **`DataStore.swift`** migrations (column names, blob format, `VectorBlobCodec` in `SearchService.swift` ~775+).

2. **Shared library:** extract **embedding decode + cosine similarity** into **`BurnBarCore`** or new **`BurnBarSearchKit`** target (SPM) used by both **AgentLens** and **BurnBarDaemon**:
   - `VectorBlobCodec` (or safe subset)
   - `EmbeddingDistanceMetric`, dimension checks
   - Avoid **@MainActor** `OpenAIEmbeddingProvider` in daemon — daemon uses **query embedding** via:
     - **Option B1:** same OpenAI HTTP client in daemon with API key from **environment variable** (e.g. `BURNBAR_OPENAI_API_KEY`) — security review
     - **Option B2:** only **deterministic** query embedding in daemon (weak parity)
     - **Option B3:** app writes **query vector** into RPC request (extends contract)

3. **Extend `BurnBarSearchQueryRequest`** (`BurnBarContracts.swift`):
   - Optional `queryEmbedding: [Float]?` + `embeddingVersionID: String?` — app/extension computes embedding and calls daemon for ANN-only merge **or** full hybrid.

### Phase 2 — ANN in daemon

1. Port minimal **brute-force** top-k over filtered chunks for **small** DBs first (correctness), behind feature flag.

2. Port **HNSW / ANN** from app’s `SignpostANNVectorCandidateBackend` — locate implementation file via grep — or call into **Accelerate**-backed matrix ops.

3. **Filter alignment:** replicate `RetrievalFilters` constraints as SQL `WHERE` on `search_documents` join (provider, project, date) mirroring `LocalSearchStore.searchLexicalChunks` clauses (~3510–3596).

### Phase 3 — Merge lexical + semantic in daemon

1. In **`BurnBarIndexedSearchService.search`**:
   - Build lexical ranked list (existing `lexicalHits`).
   - Build semantic ranked list (new).
   - Apply **same RRF** formula as **`SearchService.reciprocalRankFusion`** — extract to **BurnBarCore** `HybridRankFusion` static func to **single-source** the math.

2. **`degradedMessage`:** set `nil` when semantic path succeeds; partial degradation when embedding missing.

### Phase 4 — RPC & extension clients

1. Any **VS Code / Cursor extension** using `searchQuery` — grep repo for `daemon.search.query` — update to new request fields if embedding passed from app.

2. **Versioning:** bump **`BurnBarProtocolVersion`** if breaking; or add optional fields only (backward compatible).

### Phase 5 — Tests

1. **`BurnBarDaemonTests/BurnBarDaemonServerTests.swift`** — extend search tests with fixture DB containing small `chunk_embeddings` (copy harness from `AgentLensTests`).

2. **Integration:** two sqlite files — with/without embeddings — assert degraded vs full path.

---

## 4. Procedure (Option A — delegate to app, shorter)

1. Define **BurnBarRPCMethod** e.g. `daemon.search.proxy` or reuse app HTTP server if exists — grep for existing local server in app.

2. **Daemon:** if `indexedSearch` and **semantic** requested, forward to `http://127.0.0.1:<port>/search` with auth token.

3. **App:** lightweight endpoint running only when UI active — **or** always-on helper.

4. **Security:** token in Keychain, localhost only.

---

## 5. Files likely touched (Option B)

| File | Change |
|------|--------|
| `BurnBarCore/Sources/BurnBarCore/BurnBarContracts.swift` | Request/response optional embedding fields |
| `BurnBarDaemon/.../BurnBarIndexedSearchService.swift` | Semantic branch, RRF |
| `BurnBarDaemon/Package.swift` / Xcode | New target dependencies |
| `AgentLens/Services/SearchService.swift` | Shared fusion helper extraction (optional) |
| `BurnBarDaemonTests/...` | Fixture DB tests |
| `docs/BURNBAR_SEARCH_ARCHITECTURE_SPINE.md` | Update diagram (if maintained) |

---

## 6. Risks

- **Dual SQLite access:** app writes DB while daemon reads — WAL mode must be enabled on `burnbar.sqlite` (verify GRDB config).
- **API keys in daemon:** prefer **query vector in RPC** from trusted client over storing OpenAI key in daemon env.
- **Binary size:** ANN + GRDB in daemon increases package.

---

## 7. Definition of done

- [ ] Extension users get **ranked hits** for queries where lexical is empty but semantic would fire in app **OR** clear **single** degraded reason.
- [ ] Contracts backward compatible **or** version negotiated.
- [ ] Automated test covers at least one **semantic** hit in daemon path.
- [ ] No regression: lexical + aggregate behavior unchanged when embeddings absent.

---

## 8. Coordination with other plans

- **Plan 02** (semantic-only in app) — if planner yields empty FTS, app improves; daemon should **mirror** behavior once Plan 04 lands.
- **Plan 03** — new FTS fields require daemon SQL updates in `lexicalHits` query.
