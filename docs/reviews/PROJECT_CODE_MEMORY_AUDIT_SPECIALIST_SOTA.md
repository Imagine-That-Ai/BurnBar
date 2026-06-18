# Specialist Report: SOTA Research Agent

## Scope covered
- June 2026 industry and research best practices for: tree-sitter / LSP / SCIP / LSIF / code graphs / semantic & lexical retrieval / embeddings / BM25+hybrid RRF / AST chunking / repo maps / call graphs / incremental indexing / file watching / privacy-preserving local indexing.
- BurnBar’s implementation of Project Code Memory: static parser crate, Python MCP implementation, Swift daemon store, RPC handlers, master plan.

## Files inspected
- `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`
- `crates/project-code-static-parser/Cargo.toml`
- `crates/project-code-static-parser/src/main.rs`
- `tools/openburnbar-mcp/project_code_memory.py`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCCode.swift`

## Commands run
```bash
cd /Users/albertonunez/Documents/Developer/BurnBar/crates/project-code-static-parser
cargo test 2>&1 | tail -n 40
# Result: 8 passed; 0 failed
```

## Internet sources used
| Source | URL |
|---|---|
| Sourcegraph — Context Engineering for AI Agents (2026) | https://sourcegraph.com/blog/context-engineering |
| Sourcegraph — Announcing SCIP | https://sourcegraph.com/blog/announcing-scip |
| TechBytes — Graph-Based IDEs [Deep Dive] 2026 | https://techbytes.app/posts/graph-based-ides-visual-code-maps-2026/ |
| Crader RFC — Tree-sitter Based File-Incremental Indexing | https://github.com/orgs/sheeptechnologies/discussions/4 |
| Cursor / ZenML — Custom Semantic Search | https://www.zenml.io/llmops-database/enhancing-ai-coding-agent-performance-with-custom-semantic-search |
| Cursor indexing deep dive | https://techjacksolutions.com/ai/ai-development/cursor-ide-what-it-is/ |
| arXiv — BM25 to Corrective RAG | https://arxiv.org/html/2604.01733v1 |
| CrossCheck — What Are Embeddings in LLMs? 2026 | https://crosscheck.cloud/blogs/what-are-embeddings-in-llms |
| arXiv — CAST structural chunking | https://arxiv.org/html/2506.15655v1 |
| Firecrawl — Best Chunking Strategies for RAG 2026 | https://www.firecrawl.dev/blog/best-chunking-strategies-rag |
| Ry Walker — Code Intelligence Tools for AI Agents Compared | https://rywalker.com/research/code-intelligence-tools |
| Roo Code — Codebase Indexing | https://roocodeinc.github.io/Roo-Code/features/codebase-indexing/ |
| Kilo AI — Codebase Indexing | https://kilo.ai/docs/customize/context/codebase-indexing |
| GitHub Copilot — Indexing repositories | https://docs.github.com/copilot/concepts/indexing-repositories-for-copilot-chat |
| GitHub Copilot 2026 guide | https://www.nxcode.io/resources/news/github-copilot-complete-guide-2026-features-pricing-agents |
| Tree-sitter releases | https://github.com/tree-sitter/tree-sitter/releases |
| deps.rs — tree-sitter 0.26.9 | https://deps.rs/crate/tree-sitter/0.26.9 |

## Findings by severity

### Critical
1. **Swift `searchCode` is not hybrid** — omits vector leg. Evidence: `BurnBarProjectCodeMemoryStore.swift:1758-1805` queries only FTS5. SOTA: hybrid sparse+dense with RRF k=60. Fix: add dense retrieval + RRF in daemon.
2. **Embeddings are deterministic hashes, not learned semantic embeddings.** Evidence: `project_code_memory.py:23` and `:513-530`. Fix: local learned embedding model or remove semantic leg.
3. **Indexing is full-project, not file-incremental.** Evidence: Swift `:407-423`; Python `:1723-1726`. Fix: Merkle/blob-SHA per-file diff.
4. **Tree-sitter parser never uses incremental parsing.** Evidence: `main.rs:170` calls `parser.parse(..., None)`. Fix: cache trees and apply `Tree::edit`.

### High
5. **Language coverage far behind SOTA** — only Python/Swift/TS/TSX. Evidence: `main.rs:211-219`.
6. **Call graph is lexical token-matching, not type-aware.** Evidence: `project_code_memory.py:1938-1987`; Swift `:1627-1657`.
7. **LSP references spawned per-request with no persistent server pool.** Evidence: `main.rs:333-365`.
8. **Chunking is line-based, not AST-aware.** Evidence: `project_code_memory.py:563-578`; Swift `:481`.

### Medium
9. File watching is polling-based, not event-driven. Evidence: Swift `:554-628`.
10. No cross-encoder reranker on code retrieval. Evidence: Python `:2021-2167`.
11. Missing SCIP/LSIF consumption. Evidence: master plan §3 excludes it.
12. Regex secret scanner incomplete vs. SOTA. Evidence: `project_code_memory.py:86-111`.

### Low / Info
13. Tree-sitter core is current (0.26.9); grammar versions should be tracked.
14. Diagnostics tool is passive cache reader.
15. `context_pack` token budget uses coarse char÷4 heuristic.
16. Privacy posture is correctly local-first by default.
17. Project scoping and staleness checks are sound.
18. Audit hash-chain and fail-closed writes are present.

## Recommended fixes (prioritized)
1. Unify Swift `searchCode` with Python hybrid RRF path.
2. Replace deterministic embeddings with local learned model.
3. Make indexing file-incremental.
4. Use Tree-sitter incrementally.
5. Expand language coverage.
6. Improve call-graph accuracy with LSP-derived edges.
7. Pool persistent LSP sessions or adopt SCIP.
8. Adopt AST-aware chunking.
9. Replace polling watcher with OS-native events.
10. Add local cross-encoder reranker.
11. Complete and validate secret scanner pattern set.
12. Wire diagnostics or remove tool.
13. Use tokenizer-accurate budgets in context_pack.

## Open questions
1. Which local code-aware embedding model should BurnBar ship?
2. SCIP adoption boundary: CI-generated indexes or strictly Tree-sitter + optional LSP?
3. LSP lifecycle: daemon-owned persistent pool or helper session pool?
4. Cross-language references for Swift/TS/Python RPC contracts?
5. Vector storage scaling: shared SQLite chunk_embeddings or separate file-backed store?
6. Where should parsed Tree-sitter trees live?
7. Which local reranker fits <500 ms retrieval budget?
