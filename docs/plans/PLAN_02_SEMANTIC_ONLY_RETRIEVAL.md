# Plan 02 — Semantic-only retrieval path (empty FTS query)

**Agent assignment:** Allow `SearchService.retrieve` to return **dense-vector results** when the lexical branch produces an **empty FTS string** or **zero FTS matches**, instead of returning no evidence.

---

## 1. Problem statement

### 1.1 Current behavior

In **`SearchService.retrieve`** (`AgentLens/Services/SearchService.swift`):

1. **`lexicalFTSInput`** is built from `query.lexicalFTSQuery` or `BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)` (~1869–1874).
2. **`guard lexicalFTSInput.isEmpty == false else { return [] }`** (~1875) — **hard exit** with no semantic path.
3. Separately, **`BurnBarIndexedSearchService`** (`BurnBarDaemon/.../BurnBarIndexedSearchService.swift` ~64–76): if `plan.lexicalFTSQuery` is empty after trim, **`hits = []`** with no vector fallback.

### 1.2 When this triggers

- User query is **only stopwords** filtered by **`BurnBarFTSQueryBuilder.naturalLanguage`** (`BurnBarCore/.../BurnBarSearchPlanner.swift` + `BurnBarFTSQueryBuilder.englishStopwords`).
- **`runBurnBarQuery`** passes **`plan.semanticText`** as `RetrievalQuery.text` but may pass **empty** `lexicalFTSQuery` when planner leaves lexical empty (edge cases in `BurnBarSearchPlan.plan`).
- Very short affirmations / pronouns if ever used as **sole** retrieval text without merging prior message (mitigated in chat by `retrievalQueryText`, but other surfaces may not).

### 1.3 SOTA rationale

Dense retrieval is designed for **semantic** overlap when **keywords fail**. Refusing to run semantic when FTS is empty leaves recall at zero.

---

## 2. Target behavior

| Condition | Lexical | Semantic | Result |
|-----------|---------|----------|--------|
| FTS non-empty | run FTS | run as today | hybrid as today |
| FTS empty, `semanticLimit > 0`, provider present | skip (or no-op) | run **`semanticCandidates(for: trimmed, ...)`** | hydrate chunks from semantic IDs only |
| FTS empty, no provider | — | — | `[]` (or optional degraded message) |

**Important:** Use the **same** `trimmed` query string that would have been embedded for hybrid mode (`RetrievalQuery.text`), i.e. **`plan.semanticText`** from `runBurnBarQuery` when applicable.

---

## 3. Code touchpoints

### 3.1 `SearchService.retrieve` (main work)

**File:** `AgentLens/Services/SearchService.swift`

**Refactor outline:**

1. **Remove or branch** the early `guard lexicalFTSInput.isEmpty == false else { return [] }`.

2. **Split** into:
   - `lexicalMatches: [SearchChunkLexicalMatch]`  
     - If `lexicalFTSInput.isEmpty` → `[]`  
     - Else existing `dataStore.searchLexicalChunks(...)`  
   - If lexical throws → keep current error path **only** when lexical was required; if semantic-only mode, consider whether to catch and continue (product decision: prefer **fail lexical, still try semantic** for robustness).

3. **Build `candidates` / `lexicalChunkMap`** from lexical matches as today; may be empty.

4. **Semantic block** (`semanticLimit > 0, let semanticProvider`):  
   - **Unchanged** when `trimmed` non-empty — already runs after lexical.  
   - Ensure **`semanticRankByChunkID`** is populated from provider order (already added for RRF).

5. **Guard before rerank:** replace `guard candidates.isEmpty == false` with logic:
   - If empty → return `[]` **only if** semantic also failed or was skipped.
   - If semantic populated candidates → proceed.

6. **RRF / legacy preliminary score:** when **only semantic** ranks exist, `lexicalRankByChunkID` empty — existing **`reciprocalRankFusion`** already handles single-list (semantic rank only). Verify **legacyWeighted** preliminary still works (semantic-only → `preliminaryScore` uses semantic component only).

7. **Hydration:** today **`missingChunkIDs`** fetches chunks not in `lexicalChunkMap`; semantic-only candidates will **all** be “missing” from lexical map — **`fetchSearchChunks(ids:)`** must run for all bounded IDs. Confirm this path works when `lexicalChunkMap` is empty.

8. **`persistQueryHealth`:** when lexical skipped due to empty FTS, `lexicalCandidateCount == 0` is correct; add **`errorCode`** distinction optional: `LEXICAL_SKIPPED_EMPTY_QUERY` vs real failure (avoid conflating with `LEXICAL_QUERY_FAILED`).

### 3.2 `runBurnBarQuery`

**File:** same

- When **`lexicalTrimmed.isEmpty`**, today subquery sets `lexicalFTSQuery: nil` and FTS builder uses NL from `semanticText` — often non-empty.  
- If still empty, **semantic-only path** in `retrieve` must activate. No change strictly required if `retrieve` handles empty FTS input.

### 3.3 Planner (optional hardening)

**File:** `BurnBarCore/Sources/BurnBarCore/BurnBarSearchPlanner.swift`

- Optionally set **`note`** when `lexicalFTSQuery.isEmpty && !semanticText.isEmpty` e.g. `semantic_only_eligible` for UI/debug.
- Do **not** force non-empty FTS with garbage tokens — prefer clean semantic-only path.

### 3.4 Daemon parity (see Plan 04)

**File:** `BurnBarDaemon/.../BurnBarIndexedSearchService.swift`

- Today: `fts.isEmpty` → `hits = []`.  
- Semantic-only in daemon is **out of scope for Plan 02** unless you embed ANN in daemon — at minimum, return **`degradedMessage`** clarifying “no lexical query; open app for semantic search” or delegate RPC to app.

---

## 4. Testing strategy

1. **Unit / integration:** `RetrievalQuery` with `text: "the a an"` (all stopwords) → NL builder may yield empty → assert semantic returns chunks when harness has embeddings (`BurnBarSearchIntegrationHarness`, `AgentLensTests`).
2. **Query with empty `lexicalFTSQuery`** explicitly and non-empty `text` — assert non-empty results.
3. **Regression:** normal queries unchanged (FTS + semantic).
4. **Daemon:** if unchanged, add test that empty FTS still returns empty hits **and** stable `degradedMessage` (existing behavior documented).

---

## 5. Files likely touched

| File | Change |
|------|--------|
| `AgentLens/Services/SearchService.swift` | `retrieve` control flow, health codes |
| `BurnBarCore/Tests/.../BurnBarSearchPlannerTests.swift` | Optional note / edge tests |
| `AgentLensTests/...` | New retrieve tests |

---

## 6. Risks

- **Stopword-only queries** may retrieve **noisy** broad semantic results — mitigate with **low resultLimit** or **minimum semantic score** threshold (VectorSemanticCandidateProvider already returns scores; filter sub-threshold in `retrieve` if needed).
- **Performance:** semantic path always runs when FTS empty — acceptable; cap `semanticCandidateLimit`.

---

## 7. Definition of done

- [ ] Empty `lexicalFTSInput` no longer causes immediate `[]` when semantic provider available and `semanticLimit > 0`.
- [ ] `lexicalFTSInput` empty + no semantic provider → `[]` (clear health / no crash).
- [ ] Existing hybrid queries covered by regression tests.
- [ ] Chat and workspace search both benefit (shared `SearchService`).
