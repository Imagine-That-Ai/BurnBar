# Project Code Memory Adversarial Audit

**Date:** 2026-06-17  
**Scope:** BurnBar Project Code Memory & Agent Memory feature — shipped static tree-sitter tier, local MCP/daemon surface, and future LSP/hosted-sync opt-ins.  
**Method:** Live repo analysis + 9 specialist agents + June 2026 web research.  
**Status:** READ-ONLY audit; no code changes.  
**Remediation owner:** `docs/reviews/PROJECT_CODE_MEMORY_MASTER_REMEDIATION_PLAN_2026-06-17.md`.

**Remediation progress (2026-06-17):** the P0 trust fixes are partially landed:
untrusted wrappers, explicit stale degradation, no fake project-code semantic
ranking, read-only Python code reads, default-off hosted code tools, shared
Swift/Python secret-scanner corpus with decode/entropy tests, Git
exclude-standard ignore behavior, manifest-backed delta indexing with removed
file pruning, Git fingerprint-backed Project ID v2 with path-alias tests, and
depth-aware Swift call graph traversal. Production readiness remains false until
the remaining SQLCipher, parser/LSP, retrieval, and hosted-code threat-model
gates are complete.

---

## Executive Verdict

**State: HARDEN before ship.**

BurnBar’s Project Code Memory is a well-architected, privacy-first foundation with strong trust primitives: project partitioning, fail-closed daemon writes, label-only audit chains, secret scanning, and honest confidence tiers in the design. However, the *current implementation* has critical gaps in correctness, runtime parity, security hardening, and performance that would make it unreliable or misleading in production. The feature should not be marketed as fully shipped until the "Fix now" backlog is cleared.

The single most important decision to preserve: **local-only default for code**. That is correct and should not change.

The single biggest implementation risk: **two parallel implementations (Python MCP helpers and Swift daemon store) that already diverge** in project IDs, search ranking, chunking, tier evidence, and freshness semantics.

---

## What Exists Today

### Plain English

BurnBar can index a local git repo, extract symbols and references, chunk source files, store them in a local SQLite database, and answer agent queries like "search code," "get symbol," "find references," "call graph," and "explore." Agent memory can also be stored, recalled, forgotten, and audited per project. All code indexing defaults to local-only; hosted sync is deferred.

### Technical Terms

| Layer | Component | Responsibility |
|---|---|---|
| Static parser | `crates/project-code-static-parser` | Stateless Rust binary (stdin/stdout JSONL). Tree-sitter symbol extraction for Swift, TypeScript/TSX, Python; optional LSP `documentSymbol`/`references` bridge. |
| Python helpers | `tools/openburnbar-mcp/project_code_memory.py` | Compatibility schema bootstrap, dev/test indexing harness, lexical code search, symbol/reference/call-graph queries, memory CRUD, audit. Deterministic vectors are fingerprints only and must not rank project-code search. |
| MCP server | `tools/openburnbar-mcp/server.py` | FastMCP tool wrappers; write tools route through daemon RPC (`_local_memory_write_authority`); read tools hit SQLite directly. |
| Swift daemon store | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift` | GRDB-less raw-SQLite store with indexing, watching, search (FTS5 only), memory, audit. |
| RPC handlers | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCCode.swift` | 11 `daemon.code.*` methods and 5 `daemon.memory.*` methods. |
| Capability gating | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift` | `memoryRead`/`memoryWrite`, `codeRead`/`codeWrite` capability groups. |
| Tests | Python (`test_project_code_memory.py`), Rust (`main.rs` unit tests), Swift (`BurnBarProjectCodeMemoryStoreTests.swift`, `BurnBarDaemonSocketRPCCoverageTests.swift`, `BurnBarRPCCapabilityTests.swift`) | 10 + 8 + 13 + 2 + 6 = 39 core tests. |

### Data Flow

```
repo files
  → enumerateIndexableFiles / iter_project_files (gitignore-aware)
  → secret scan (regex patterns)
  → static parser OR regex fallback → symbols
  → chunk(text) → search_documents + search_chunks + search_chunks_fts + chunk_embeddings
  → buildReferences / build_references → code_references + code_call_edges
  → SQLite (local)
  → agent queries via MCP tools or daemon RPC
```

### Boundary: Shipped vs. Future Opt-ins

**Shipped (Phase 0–3 / current code):**
- Local-only code indexing and search.
- Static tree-sitter symbol extraction for Swift, TS/TSX, Python.
- Regex-based lexical fallback for other languages.
- Agent memory (`remember`/`recall`/`forget`), audit trail, analytics.
- Daemon RPC with capability gating.
- Fail-closed writes (daemon required).
- Project partitioning by path-derived ID.
- Blob-SHA staleness suppression.

**Future opt-ins (Phase 4 / not yet safe to claim):**
- `exact_lsp` persistent language-server integration (currently per-request shell-out).
- Hosted code sync (server-side tools exist but local upload path is unclear and threat-model gate is not complete).
- SCIP/LSIF ingestion.
- Real learned semantic embeddings.
- Cross-project workspace context.

---

## SOTA Comparison

### What June 2026 frontier systems do

| Capability | SOTA practice (June 2026) | Source |
|---|---|---|
| **Hybrid retrieval** | BM25 + dense embeddings fused with RRF `k=60`, optionally cross-encoder rerank. | [arXiv BM25→CRAG benchmark](https://arxiv.org/html/2604.01733v1), [CrossCheck 2026 retrieval stack](https://crosscheck.cloud/blogs/what-are-embeddings-in-llms) |
| **Embeddings** | Learned code-aware models (OpenAI `text-embedding-3-small/large`, Voyage-3, BGE-M3, custom) 384–3072 dims. | [CrossCheck](https://crosscheck.cloud/blogs/what-are-embeddings-in-llms), [Cursor/ZenML case study](https://www.zenml.io/llmops-database/enhancing-ai-coding-agent-performance-with-custom-semantic-search) |
| **AST chunking** | Function/class-boundary chunks; CAST structure-aware chunking outperforms fixed-size. | [arXiv CAST](https://arxiv.org/html/2506.15655v1), [Firecrawl chunking 2026](https://www.firecrawl.dev/blog/best-chunking-strategies-rag) |
| **Incremental indexing** | Merkle/file-hash change detection + OS-native file watchers (FSEvents/inotify). | [Cursor codebase indexing](https://towardsdatascience.com/how-cursor-actually-indexes-your-codebase/), [Roo Code docs](https://roocodeinc.github.io/Roo-Code/features/codebase-indexing/) |
| **Symbol extraction** | Tree-sitter for 25+ languages or persistent LSP; LSP-over-MCP (Serena supports 40+ languages). | [Ry Walker code intelligence tools map](https://rywalker.com/research/code-intelligence-tools), [Roo Code docs](https://roocodeinc.github.io/Roo-Code/features/codebase-indexing/) |
| **Precise references** | SCIP/LSIF indexes or persistent LSP sessions; lexical token-matching is a fallback. | [Sourcegraph SCIP announcement](https://sourcegraph.com/blog/announcing-scip), [Crader RFC on tree-sitter incremental indexing](https://github.com/orgs/sheeptechnologies/discussions/4) |
| **Repo map** | PageRank/structure-aware graph navigation (Aider, Cursor `@codebase`). | [Aider repo-map deep dive](https://www.digitalapplied.com/blog/aider-deep-dive-cli-agentic-coding-tutorial-2026), [Hermes Agent PageRank issue](https://github.com/NousResearch/hermes-agent/issues/535) |
| **Diagnostics loop** | LSP `textDocument/diagnostic`, `codeAction`, `rename` fed back to agent for self-correction. | [Claude Code LSP operations](https://code.claude.com/docs/en/changelog), [Anthropic issue #40282](https://github.com/anthropics/claude-code/issues/40282) |
| **Privacy model** | Local-first default, optional cloud with client-side keys (Cursor Privacy Mode, CodeGraph local SQLite). | [Cursor secure codebase indexing](https://cursor.com/blog/secure-codebase-indexing), [Zylos codebase intelligence 2026](https://zylos.ai/research/2026-04-19-codebase-intelligence-repository-understanding-ai-agents) |

### Where BurnBar stands

| Capability | BurnBar | vs. SOTA |
|---|---|---|
| Local-first default | ✅ Strong | Matches best practice |
| Project partitioning | ✅ Strong | Matches best practice |
| Fail-closed writes | ✅ Strong | Matches best practice |
| Hybrid retrieval | ⚠️ Python has RRF; Swift does not | Behind on daemon path |
| Embeddings | ❌ Deterministic 96-dim hash | Not semantic; major gap |
| AST chunking | ❌ Fixed char chunks | Behind |
| Incremental indexing | ❌ Full reindex every time | Behind |
| Language coverage | ❌ 4 tree-sitter + regex | Behind |
| Precise references | ❌ Per-request LSP shell-out or lexical | Behind |
| Repo map | ❌ None | Major gap |
| Diagnostics loop | ❌ Passive cache reader | Major gap |
| File watching | ⚠️ Polling timer | Behind |

---

## Critical Findings

### 1. Two implementations diverge on the same database contract
**Severity: Critical**  
**Evidence:** `project_code_memory.py:171-172` uses `sha256_hex(str(root))[:32]`; `BurnBarProjectCodeMemoryStore.swift:1986-1988` uses `"proj_" + sha256Hex(root.path).prefix(16)`. Python search uses FTS5+vector+RRF (`project_code_memory.py:2021-2167`); Swift search uses FTS5 only (`BurnBarProjectCodeMemoryStore.swift:1758-1805`). Python chunks 2400 chars with 240-char overlap; Swift chunks 4000 chars with no overlap.  
**Risk:** If Python and Swift ever share a database, the same repo gets duplicated, searches return different results, and maintenance cost doubles.  
**Fix:** Pick one runtime as the source of truth for production queries; make Python a thin RPC client. Unify project ID, chunking, ranking, and tier evidence.

### 2. Swift search omits the vector/RRF leg entirely
**Severity: Critical**  
**Evidence:** `BurnBarProjectCodeMemoryStore.swift:1758-1805` queries only `search_chunks_fts` with `bm25(...)` and falls back to `LIKE`. No join to `chunk_embeddings`, no cosine, no RRF.  
**Risk:** Daemon-backed agents get materially worse code search than Python-backed agents for the same repo.  
**Fix:** Implement the same RRF fusion in Swift, or remove the vector leg from Python until both can share one authoritative implementation.

### 3. Deterministic embeddings are not semantic
**Severity: Critical**  
**Evidence:** `project_code_memory.py:23` declares `EMBEDDING_MODEL = "deterministic-fake-embedding"`; `deterministic_embedding` at `:513-530` hashes tokens with SHA-256. Measured similarity: `'feline' <-> 'cat' = -0.1000`; `'nonexistent_xyz' <-> 'def foo' = 0.2048`.  
**Risk:** The "semantic" search leg returns noise, and unrelated queries hallucinate results.  
**Fix:** Replace with a local learned embedding model (ONNX-based, code-aware) or remove semantic search until one ships.

### 4. Indexing is full-project, not incremental
**Severity: Critical**  
**Evidence:** Swift deletes every `code_*` row before reinsert (`BurnBarProjectCodeMemoryStore.swift:407-423`); Python deletes `code_call_edges`/`code_references`/`code_symbols` per project (`project_code_memory.py:1723-1726`). `watchProject` re-runs full `indexProject`. Performance Agent measured a one-file change in a 500-file repo costs ~89 s.  
**Risk:** Large repos become unusable; watch-mode repeatedly burns CPU/SSD.  
**Fix:** Use blob-SHA/mtime per file; re-parse only changed/new/deleted files.

### 5. Hosted code-memory surface is deployed before the threat-model gate
**Severity: Critical**  
**Evidence:** `services/hosted-mcp/src/toolRegistry.ts:220-264` registers `burnbar_search_code` and `burnbar_get_code_document` with `code:read` scope and rate-limit buckets. The master plan §5.5 says hosted code sync is Phase 4 and requires `REMOTE_MCP_THREAT_MODEL.md` + `PENSIEVE.md` updates first.  
**Risk:** Code could be uploaded/sealed before the asset-class threat model is reviewed; Pensieve cloak geometry leakage for prose (≈0.77 same-item signal) is likely unacceptable for source code.  
**Fix:** Gate hosted code tools behind an explicit feature flag; complete the threat-model review before enabling uploads.

### 6. Secret scanner is bypassed by trivial encodings
**Severity: Critical**  
**Evidence:** Security Agent probes showed base64-encoded, spaced-out, and string-concatenated OpenAI keys are indexed (rejected files = 0). Patterns at `project_code_memory.py:86-111` / `BurnBarProjectCodeMemoryStore+Helpers.swift:55-85` are regex-only.  
**Risk:** Live secrets in comments or obfuscated strings are indexed and retrievable.  
**Fix:** Add entropy + decoding pass for high-entropy base64/hex blobs and multiline string reconstruction.

### 7. Python indexer does not prune deleted/renamed files
**Severity: Critical**  
**Evidence:** `index_project` deletes symbol/reference rows but not `code_artifacts`, `search_documents`, `search_chunks`, or `search_chunks_fts` rows for missing files (`project_code_memory.py:1723-1726`). Correctness Agent reproduced stale `Sources/Target.py` remaining after rename.  
**Risk:** Stale files and chunks persist across reindexes; agents see ghost results.  
**Fix:** Delete all project code rows at reindex start (mirror Swift), then reinsert.

### 8. `.gitignore` implementation is non-compliant
**Severity: Critical**  
**Evidence:** Both Python and Swift drop negation patterns (`!`), globstar (`**`), anchored paths (`/`), and treat `#` as a pattern (`project_code_memory.py:1265-1299`; `BurnBarProjectCodeMemoryStore+Helpers.swift:458-496`).  
**Risk:** Private files the user explicitly excluded are indexed; files they explicitly un-ignored are skipped.  
**Fix:** Use a standards-compliant parser (`pathspec` on Python; a real Git ignore ruleset on Swift).

### 9. Swift lexical fallback falsely claims `shaMatch: true`
**Severity: Critical**  
**Evidence:** `BurnBarProjectCodeMemoryStore+Helpers.swift:333-343` sets `shaMatch: true` for regex-extracted symbols; Python correctly sets `shaMatch: false` with rationale (`project_code_memory.py:1408-1421`).  
**Risk:** Violates master plan §5.6 (tiers earned at query time, never decorative); agents trust incorrect evidence.  
**Fix:** Set Swift lexical evidence `shaMatch: false`; add contract tests.

### 10. LSP references execute arbitrary commands from an env var
**Severity: Critical**  
**Evidence:** `crates/project-code-static-parser/src/main.rs:430-437` reads `OPENBURNBAR_CODE_LSP_COMMANDS` JSON and spawns commands verbatim; `BurnBarProjectCodeMemoryStore+Helpers.swift:319-330` reads `OPENBURNBAR_CODE_STATIC_PARSER_PATH`.  
**Risk:** Any process that can set the daemon’s env can run arbitrary code under the exact_lsp path.  
**Fix:** Move LSP configuration into a validated daemon config file with allowlist/signature checks.

### 11. Schema authority is split between raw SQLite and GRDB
**Severity: Critical**  
**Evidence:** `BurnBarProjectCodeMemoryStore.swift:1018-1251` bootstraps code-memory tables via raw `sqlite3_*` C calls, while the same `openburnbar.sqlite` is owned by `OpenBurnBarDatabase.swift` GRDB migrations. The master plan says "migrations v49+" but the code does not use GRDB.  
**Risk:** Two schema authorities on one file; future migrations can conflict; recovery/encryption bookkeeping is bypassed.  
**Fix:** Move schema ownership to GRDB migrations; make the daemon store a consumer only.

### 12. Swift static-parser/LSP subprocess has no timeout
**Severity: High**  
**Evidence:** `BurnBarProjectCodeMemoryStore+Helpers.swift:234-317` and `:1716-1724` call `process.waitUntilExit()` without timeout. The Rust helper has no internal parse timeout.  
**Risk:** A pathological file or hanging LSP can block the serial SQLite queue indefinitely.  
**Fix:** Add a timeout (match Python’s 5 s cap) and degrade to lexical fallback.

### 13. Python MCP read tools open the database read-write
**Severity: High**  
**Evidence:** `server.py:1567`, `:1602`, `:1611` use `_connect_rw` for `burnbar_recall`, `burnbar_audit_trail`, `burnbar_memory_analytics`. `_connect_rw` is documented for budget mutations.  
**Risk:** Unnecessary write lock; future maintainers may accidentally mutate under read tools.  
**Fix:** Switch read tools to `_connect_ro`.

### 14. Python audit hash chain omits `seq`
**Severity: High**  
**Evidence:** `project_code_memory.py:581-614` hashes `{ts, actor, action, domain, project_id, subject_id, labels, prevHash}` but not `seq`. Swift includes `seq` (`BurnBarProjectCodeMemoryStore.swift:1500-1536`).  
**Risk:** Hash-chain integrity depends on sequence ordering, but the hash does not bind the sequence number.  
**Fix:** Include `seq` in the Python audit hash payload.

### 15. No runtime logging in Python implementation
**Severity: High**  
**Evidence:** `project_code_memory.py` has no `logging` import; parser fallback, LSP timeout, staleness downgrade, and storage-budget rejection are silent.  
**Risk:** Production failures are undebuggable.  
**Fix:** Add structured logging without secret/file-content leakage.

### 16. `search_code` always reports `lexical_fallback` even when vector-driven
**Severity: High**  
**Evidence:** `project_code_memory.py:2149` hard-codes `"confidenceTier": "lexical_fallback"` for every hit.  
**Risk:** Violates master plan §5.6; agents cannot tell how a result was produced.  
**Fix:** Emit accurate tier evidence (`fts_only`, `vector_only`, `hybrid_rrf`) per hit.

### 17. Setup script does not build the Rust static parser
**Severity: High**  
**Evidence:** `tools/openburnbar-mcp/setup.sh` builds the Python venv but never runs `cargo build` in `crates/project-code-static-parser`.  
**Risk:** Most users silently degrade to regex `lexical_fallback`.  
**Fix:** Build the helper in setup or warn loudly with exact command.

### 18. README tools table is broken
**Severity: Medium**  
**Evidence:** `tools/openburnbar-mcp/README.md:172-178` interrupts the Markdown table with a paragraph about the Rust helper.  
**Risk:** Discoverability of resume/Castle/Ministry tools is broken; doc looks untrustworthy.  
**Fix:** Move the paragraph out of the table.

### 19. Diagnostics cache has no producer
**Severity: Medium**  
**Evidence:** `code_diagnostics_cache` is read by `diagnostics()` but never populated by any built-in producer (`BurnBarProjectCodeMemoryStore.swift:796-818`; `project_code_memory.py:2377-2410`).  
**Risk:** Tool returns empty by default; dead surface area confuses agents.  
**Fix:** Wire to build-tool output capture or remove/hide the tool.

### 20. SQLite bloat and ineffective vacuum
**Severity: High**  
**Evidence:** Performance Agent measured DB size 16–17× source size. `PRAGMA incremental_vacuum(256)` frees essentially no pages because deletes and inserts happen in the same transaction.  
**Risk:** Conversation-search substrate is threatened by multi-GB code indexes.  
**Fix:** Incremental indexing + periodic `VACUUM` + consider separate file-backed vector store.

---

## Improvement Backlog

### Fix now (block ship)

1. **Unify Python and Swift on one authoritative runtime.** Make the Swift daemon the source of truth; make Python MCP a thin RPC client. Keep Python helpers only for tests/load harness.
2. **Fix deleted/renamed-file pruning in Python indexer.** Delete all project `code_artifacts`/`search_documents`/`search_chunks`/`search_chunks_fts` rows at reindex start.
3. **Fix Swift lexical-fallback `shaMatch: false`.** Match Python’s honest tier evidence.
4. **Fix `.gitignore` parsing** to support negation, globstar, anchors, comments. Use `pathspec` (Python) and a real ignore ruleset (Swift).
5. **Harden secret scanner** against base64/spaced/chunked secrets; add entropy + decoding pass.
6. **Gate hosted code-memory tools** behind an explicit feature flag until Phase 4 threat-model review is complete.
7. **Add process timeout to Swift static-parser/LSP subprocess.** Degrade to lexical fallback on timeout.
8. **Move LSP command config out of env var** into validated daemon config with allowlist.
9. **Switch Python MCP read tools to `_connect_ro`.**
10. **Include `seq` in Python audit hash.**
11. **Move code-memory schema ownership to GRDB migrations.**
12. **Fix README tools table.**

### Next hardening pass

13. **Implement file-incremental indexing** using blob SHA/mtime; only reindex changed/new/deleted files.
14. **Add OS-native file watching** (`FSEventStream` on macOS) replacing polling.
15. **Add a real local embedding model** for code (ONNX-based) or remove semantic search.
16. **Add AST-aware chunking** aligned to function/class boundaries.
17. **Consolidate search ranking:** same RRF vector+FTS in Swift and Python; add cross-encoder reranker on top 50.
18. **Expand tree-sitter language coverage** to Rust, Go, Kotlin, Java, C/C++.
19. **Add structured logging** to Python and more logging to Swift.
20. **Add storage-budget/retention policy** and periodic `VACUUM`.
21. **Wire diagnostics cache** to actual build-tool output or remove the tool.
22. **Unify project ID generation** across Python and Swift.

### Strategic upgrades

23. **Repo-map / PageRank context tool** over the symbol-reference graph.
24. **Live LSP diagnostic/code-action loop** for agent self-correction.
25. **Test discovery and test-aware context** for "did I break anything?" loops.
26. **Natural-language codebase Q&A** with citations.
27. **Semantic diff / patch context** for agent-driven review.
28. **Persistent LSP session pool** instead of per-request shell-outs.
29. **SCIP ingestion** for compiler-accurate cross-file references.

### Future opt-ins: LSP and hosted sync

30. **exact_lsp tier:** persistent pooled LSP sessions, timeout-gated, only emitted when a live language server responds for the current buffer within timeout.
31. **Hosted code sync:** complete `REMOTE_MCP_THREAT_MODEL.md` + `PENSIEVE.md` updates for code as a new asset class; evaluate Householder reflection count; implement device-driven sealed backfill; hard-delete callable.

---

## Test Plan

### Tests to add

1. **End-to-end daemon RPC integration tests** for all 11 `daemon.code.*` methods over a real UNIX socket.
2. **Python ↔ Swift parity tests** using shared golden repos; assert equal project IDs, symbol counts, search top-k, recall results.
3. **Schema parity test** comparing `project_code_memory.py::ensure_schema`, `BurnBarProjectCodeMemoryStore.bootstrapSchema`, and `docs/SCHEMA_SQLITE.sql` columns/indexes/constraints.
4. **Static parser negative-path tests:** missing binary, non-zero exit, SHA/filePath mismatch, malformed JSON, LSP timeout.
5. **Secret scanner adversarial tests:** base64, spaced, chunked, false positives, label-only audit.
6. **gitignore adversarial tests:** negation, globstar, anchors, `.git/info/exclude`, symlink loops.
7. **Incremental indexing tests:** mutate one file; assert reindex time is O(changed files), not O(corpus).
8. **Concurrency tests:** simultaneous `indexProject` + `watchProject`, search during reindex.
9. **Storage budget boundary tests:** zero budget, exact-size budget, budget changes across reindexes.
10. **FTS5 query sanitization tests:** special chars, quotes, long queries, injection attempts.
11. **Watch stability test** without `Thread.sleep` polling.
12. **`codeDiagnostics` read-path tests** or removal test.
13. **Load test in CI** (bounded 100×1000 run).

### CI additions

1. Add the load test to a nightly or pre-release workflow.
2. Strengthen `verify-sqlite-schema-doc.mjs` to compare columns, indexes, FTS5 virtual-table columns, and constraints.
3. Add a Python/Swift schema parity job.
4. Ensure `cargo build` of the static parser runs before Swift tests in CI.
5. Verify `agent-tools-ci.yml` continues to run `pytest tests/` for the MCP surface on relevant changes.

---

## Research Appendix

| Source | URL | What it informed |
|---|---|---|
| Sourcegraph — Context Engineering for AI Agents (2026) | https://sourcegraph.com/blog/context-engineering | SCIP-backed lookups, Cody 13-tool pipeline, code graph → rerank → LLM. |
| Sourcegraph — Announcing SCIP | https://sourcegraph.com/blog/announcing-scip | SCIP replaces LSIF; 8× smaller / 3× faster; incremental indexing benefit. |
| TechBytes — Graph-Based IDEs [Deep Dive] 2026 | https://techbytes.app/posts/graph-based-ides-visual-code-maps-2026/ | Repo maps, graph-native retrieval gains. |
| Crader RFC — Tree-sitter Based File-Incremental Indexing | https://github.com/orgs/sheeptechnologies/discussions/4 | Industry trend away from full-project SCIP rebuilds. |
| Cursor / ZenML — Custom Semantic Search | https://www.zenml.io/llmops-database/enhancing-ai-coding-agent-performance-with-custom-semantic-search | Cursor trains custom embeddings; hybrid + grep. |
| Cursor indexing deep dive | https://techjacksolutions.com/ai/ai-development/cursor-ide-what-it-is/ | Merkle tree → semantic chunking → vector embeddings → RAG. |
| arXiv — BM25 to Corrective RAG | https://arxiv.org/html/2604.01733v1 | RRF k=60 default; hybrid+rerank Recall@5 = 0.816 vs 0.587 dense-only. |
| CrossCheck — What Are Embeddings in LLMs? 2026 | https://crosscheck.cloud/blogs/what-are-embeddings-in-llms | 2026 default stack: recursive 500-token chunks + text-embedding-3-small/voyage-3 + HNSW + hybrid RRF + rerank. |
| arXiv — CAST structural chunking | https://arxiv.org/html/2506.15655v1 | AST-aware chunking outperforms fixed-size for code RAG. |
| Firecrawl — Best Chunking Strategies for RAG 2026 | https://www.firecrawl.dev/blog/best-chunking-strategies-rag | Recursive 400-512 token splits; code benefits from function/class separators. |
| Ry Walker — Code Intelligence Tools for AI Agents Compared | https://rywalker.com/research/code-intelligence-tools | June 2026 market map; Serena LSP-over-MCP 40+ languages; real-time incremental table stakes. |
| Roo Code — Codebase Indexing | https://roocodeinc.github.io/Roo-Code/features/codebase-indexing/ | Tree-sitter first, 100–1000 char blocks, file watching + hash caching + branch-aware updates. |
| Kilo AI — Codebase Indexing | https://kilo.ai/docs/customize/context/codebase-indexing | Tree-sitter AST parsing for 25+ languages; ignore `.gitignore`/`.kilocodeignore`; incremental file watching. |
| GitHub Copilot — Indexing repositories | https://docs.github.com/copilot/concepts/indexing-repositories-for-copilot-chat | Copilot indexes repos for semantic code search; updates within seconds. |
| GitHub Copilot 2026 guide | https://www.nxcode.io/resources/news/github-copilot-complete-guide-2026-features-pricing-agents | Pre-indexing/caching, custom instructions. |
| Tree-sitter releases | https://github.com/tree-sitter/tree-sitter/releases | tree-sitter 0.26.9 is current. |
| Cursor — Securely indexing large codebases | https://cursor.com/blog/secure-codebase-indexing | Local-first indexing privacy stance, Merkle-tree change detection. |
| Towards Data Science — How Cursor indexes codebases | https://towardsdatascience.com/how-cursor-actually-indexes-your-codebase/ | AST chunking, Turbopuffer vector storage, masked metadata retrieval. |
| Zylos — Codebase Intelligence 2026 | https://zylos.ai/research/2026-04-19-codebase-intelligence-repository-understanding-ai-agents | Comparative architectures, repo-map/PageRank value. |
| Aider deep dive 2026 | https://www.digitalapplied.com/blog/aider-deep-dive-cli-agentic-coding-tutorial-2026 | PageRank-style repo-map, tree-sitter tag extraction, token budget. |
| Hermes Agent — PageRank Repo Map | https://github.com/NousResearch/hermes-agent/issues/535 | Detailed Aider repo-map reproduction. |
| Claude Code changelog/docs | https://code.claude.com/docs/en/changelog | LSP operations, subagent delegation. |
| Karan Bansal — Claude Code LSP upgrade | https://karanbansal.in/blog/claude-code-lsp/ | Passive self-correcting edit loop via LSP diagnostics. |
| Anthropic issue #40282 — LSP surface | https://github.com/anthropics/claude-code/issues/40282 | Requested LSP diagnostics/codeAction/rename. |
| Devon/DeepWiki knowledge graphs | https://www.zenml.io/llmops-database/building-an-autonomous-ai-software-engineer-with-advanced-codebase-understanding-and-specialized-model-training-6bnir | Continuous knowledge graph, multi-agent fleet. |

---

## Code Appendix

### Core implementation files

| File | Why it matters |
|---|---|
| `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md` | Strategy, parity matrix, cross-cutting invariants, phased work. |
| `docs/architecture/010-project-code-static-parser.md` | ADR defining stateless Rust helper boundary. |
| `crates/project-code-static-parser/src/main.rs` | Stateless parser; tree-sitter + LSP bridge; SHA-1 blob checks. |
| `crates/project-code-static-parser/Cargo.toml` | Dependency versions (tree-sitter 0.26.9, grammar crates). |
| `tools/openburnbar-mcp/project_code_memory.py` | Python MCP helpers: schema, indexing, search, memory, audit. |
| `tools/openburnbar-mcp/server.py` | FastMCP tool wrappers; write authority routing. |
| `tools/openburnbar-mcp/tests/test_project_code_memory.py` | Python correctness tests. |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift` | Swift daemon store: raw SQLite, indexing, search, memory, audit. |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Helpers.swift` | Swift static helpers: parser invocation, secret scanning, FTS query, chunking. |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCCode.swift` | 11 `daemon.code.*` RPC handlers. |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCMemory.swift` | 5 `daemon.memory.*` RPC handlers. |
| `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift` | RPC method enumeration and envelope types. |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift` | Capability groups for read/write/code/memory. |

### Configuration / docs / CI

| File | Why it matters |
|---|---|
| `docs/SCHEMA_SQLITE.sql` | Schema reference; CI-checked for table-name coverage. |
| `scripts/ci/verify-sqlite-schema-doc.mjs` | Schema drift gate (currently table-name-only). |
| `scripts/ci/project-code-memory-load-test.py` | Synthetic 100k-symbol load proof; not in CI. |
| `.github/workflows/agent-tools-ci.yml` | Runs `pytest tests/` for MCP surface on path-filtered PRs. |
| `.github/workflows/fast-feedback.yml` | Lint/typecheck/unit-test fast path. |
| `docs/PENSIEVE.md` | Sealed/cloud memory threat model; needs code asset-class update. |
| `docs/REMOTE_MCP_THREAT_MODEL.md` | Hosted MCP threat model; needs code asset-class update. |
| `services/hosted-mcp/src/toolRegistry.ts` | Hosted `burnbar_search_code` / `burnbar_get_code_document` tools. |

### Key line references

- Project ID mismatch: `project_code_memory.py:171-172` vs. `BurnBarProjectCodeMemoryStore.swift:1986-1988`
- Swift FTS-only search: `BurnBarProjectCodeMemoryStore.swift:1758-1805`
- Python RRF search: `project_code_memory.py:2021-2167`
- Deterministic embedding: `project_code_memory.py:513-530`
- Full reindex (Swift): `BurnBarProjectCodeMemoryStore.swift:407-423`
- Full reindex (Python): `project_code_memory.py:1723-1726`
- Swift lexical `shaMatch: true`: `BurnBarProjectCodeMemoryStore+Helpers.swift:339`
- Python lexical `shaMatch: false`: `project_code_memory.py:1417`
- Secret patterns: `project_code_memory.py:86-111`
- gitignore parser: `project_code_memory.py:1265-1299`
- LSP env command: `crates/project-code-static-parser/src/main.rs:430-437`
- Hosted code tools: `services/hosted-mcp/src/toolRegistry.ts:220-264`

---

## Top 10 Highest-Leverage Improvements

1. **Make the Swift daemon the single source of truth** and turn Python MCP into a thin RPC client. Eliminates the dual-implementation divergence.
2. **Ship file-incremental indexing** (blob-SHA/mtime diff). Transforms watch-mode from unusable to practical.
3. **Replace deterministic fake embeddings** with a local learned model, or remove semantic search until then.
4. **Harden the secret scanner** against base64/spaced/chunked secrets with entropy + decoding.
5. **Use standards-compliant `.gitignore` parsing** in both runtimes.
6. **Gate hosted code-memory tools** behind a feature flag until the Phase 4 threat-model gate is complete.
7. **Move schema ownership to GRDB migrations** so the daemon store is a consumer, not a second authority.
8. **Add AST-aware chunking** at function/class boundaries.
9. **Implement OS-native file watching** (`FSEventStream`) replacing polling.
10. **Add a repo-map / PageRank context tool** to turn the existing symbol graph into agent-navigable structure.

---

## Top 5 Risks if Left Unchanged

1. **Silent data corruption / ghost indexes:** Python does not prune deleted/renamed files; stale chunks persist.
2. **Inconsistent agent behavior:** Python and Swift return different search rankings, chunk boundaries, and project IDs.
3. **Secrets leakage:** Obfuscated secrets bypass the scanner and are indexed.
4. **Hosted code sync before review:** Code could be uploaded/sealed before the asset-class threat model is validated.
5. **Performance collapse:** Full reindexes and linear semantic scans make large repos unusable and bloat the shared SQLite.

---

## Recommended Implementation Sequence

1. **Week 1 — Correctness & safety hardening**
   - Fix deleted-file pruning in Python.
   - Fix `.gitignore` parsing.
   - Fix Swift lexical `shaMatch`.
   - Harden secret scanner.
   - Gate hosted code tools.
   - Add process timeout to Swift parser/LSP.
   - Move LSP config to validated daemon config.

2. **Week 2 — Runtime unification**
   - Make Python MCP a thin RPC client.
   - Unify project ID, chunking, ranking, tier evidence.
   - Move schema to GRDB migrations.
   - Switch Python read tools to `_connect_ro`.
   - Fix Python audit hash to include `seq`.

3. **Week 3 — Performance & incremental indexing**
   - File-level incremental indexing.
   - OS-native file watching.
   - Batch inserts + WAL in Python.
   - Storage budget / retention policy.

4. **Week 4 — Quality upgrades**
   - Real local embeddings or semantic-search removal.
   - AST-aware chunking.
   - Cross-encoder reranker.
   - Expanded tree-sitter language coverage.

5. **Month 2+ — Strategic product upgrades**
   - Repo-map / PageRank context tool.
   - Persistent LSP session pool.
   - Live diagnostics / code-action loop.
   - Test discovery integration.
   - Natural-language codebase Q&A.
   - Hosted code sync threat-model review and implementation.

---

## Specialist Reports Cross-Reference

| Specialist | Agent ID | Status | Key critical finding | Report file |
|---|---|---|---|---|
| SOTA Research | agent-0 | ✅ completed | Daemon search lacks vector/RRF; deterministic embeddings not semantic; no incremental indexing. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_SOTA.md` |
| Architecture | agent-1 | ✅ completed | Raw SQLite daemon store bypasses GRDB; Python duplicates Swift logic; god module. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_ARCHITECTURE.md` |
| Correctness | agent-2 | ✅ completed | Python does not prune deleted files; Swift lexical `shaMatch: true`; secret bypasses. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_CORRECTNESS.md` |
| Search Quality | agent-3 | ✅ completed | Vector hallucinates results; Python/Swift project IDs differ; Swift no depth BFS. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_SEARCH_QUALITY.md` |
| Performance | agent-4 | ✅ completed | Full reindex on every call; 16–17× DB bloat; linear semantic scan. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_PERFORMANCE.md` |
| Security & Privacy | agent-5 | ✅ completed | Hosted code surface deployed early; secret scanner bypassed; gitignore non-compliant. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_SECURITY_PRIVACY.md` |
| Testing & CI | agent-6 | ✅ completed | Load test not in CI; schema verifier table-name-only; no end-to-end RPC tests. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_TESTING_CI.md` |
| Developer Experience | agent-7 | ✅ completed | Setup doesn't build helper; README table broken; no Python logging. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_DEVELOPER_EXPERIENCE.md` |
| Product Strategy | agent-8 | ✅ completed | No repo-map, AST chunking, real embeddings, LSP diagnostics, or test integration. | `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_PRODUCT_STRATEGY.md` |

*Note: The Testing & CI agent initially stated Python tests were not in CI; subsequent inspection of `.github/workflows/agent-tools-ci.yml` (added as part of the 2026-06-11 tech-debt audit remediation) shows they are path-filtered and blocking. The load test remains unwired.*

---

*End of audit.*
