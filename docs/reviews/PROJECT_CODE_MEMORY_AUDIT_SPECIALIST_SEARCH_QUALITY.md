# Specialist Report: Search Quality Agent

## Scope covered
- Python search implementation and Swift search implementation.
- Exact symbol lookup, fuzzy search, natural-language queries, file/path queries, cross-language queries, ranking, chunk quality, duplicate results, stale index behavior, "where is X implemented?" workflows.

## Files inspected
- `tools/openburnbar-mcp/project_code_memory.py`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Helpers.swift`
- `tools/openburnbar-mcp/tests/test_project_code_memory.py`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarProjectCodeMemoryStoreTests.swift`
- `scripts/ci/project-code-memory-load-test.py`

## Commands run
- `python3 /tmp/burnbar_search_quality_audit.py`
- `python3 -m pytest tools/openburnbar-mcp/tests/test_project_code_memory.py -v`
- `cd OpenBurnBarDaemon && swift test --filter BurnBarProjectCodeMemoryTests`
- `OPENBURNBAR_CODE_MEMORY_LOAD_FILES=20 OPENBURNBAR_CODE_MEMORY_LOAD_SYMBOLS_PER_FILE=100 ... python3 scripts/ci/project-code-memory-load-test.py`
- Deterministic-embedding sanity check for `feline`/`cat`, `payment processing`/`charge customer`, etc.

## Findings by severity

### Critical
1. **Python `search_code` hallucinates results for unrelated queries because vector similarity has no threshold.** Evidence: `project_code_memory.py:2022-2167`. Query `"repo-b-token"` against wrong repo returns 5 repo-a files; `"nonexistent_xyz"` returns 10 results.
2. **The "semantic" embedding is not semantic.** Evidence: `project_code_memory.py:513-530`. Measured: `'feline' <-> 'cat' = -0.1000`; `'nonexistent_xyz' <-> 'def foo' = 0.2048`.
3. **Swift and Python use incompatible project IDs.** Evidence: Python `:171-172`; Swift `:1986-1988`.
4. **Swift lexical fallback falsely claims `shaMatch: true`.** Evidence: `BurnBarProjectCodeMemoryStore+Helpers.swift:339`.

### High
5. **Swift code search lacks vector/RRF entirely.** Evidence: `BurnBarProjectCodeMemoryStore.swift:1758-1805`.
6. **Swift `callGraph` ignores depth and returns only single-hop edges.** Evidence: `BurnBarProjectCodeMemoryStore.swift:743-794` vs. Python depth BFS.
7. **Context pack silently overrides caller’s token budget.** Evidence: `project_code_memory.py:2176` clamps to `[500, 24000]`.
8. **Chunking diverges between runtimes.** Python: 2400-char with 240 overlap; Swift: 4000-char with no overlap.

### Medium
9. Fuzzy `get_symbol` returns noisy substring matches.
10. Ranking is opaque and uninformative; `confidenceTier` always `lexical_fallback`.
11. Memory-recall algorithms diverge (Python FTS pre-filter vs. Swift O(n) scan).
12. Swift FTS5 empty-token behavior differs from Python.
13. Lexical reference detection brittle (`line.contains("\(name)(")`).

### Low / Info
14. Secret scanning and stale-index suppression work well.
15. Existing test suites pass (Python 10/10, Swift 13/13, load test passed).
16. Performance acceptable for moderate corpora.

## Evaluation metrics
| Metric | Observed |
|---|---|
| Exact symbol lookup precision@1 | 100% |
| Exact file/path query top-1 | 80% (4/5) |
| "Where is X implemented?" top-1 | 67% (2/3) |
| Semantic/NL query precision@5 | Low (always returns 5 results) |
| Cross-project false-positive rate@5 | ~100% for unrelated queries |
| Stale-index suppression | 100% effective |
| Indexing throughput | ~10k symbols/s |
| `search_code` latency (50k symbols) | 12–19 ms |

## Recommended fixes
1. Add vector-similarity threshold or remove vector RRF until real embeddings exist.
2. Unify project ID generation.
3. Fix Swift lexical `shaMatch`.
4. Achieve runtime parity for code search.
5. Implement depth-aware BFS in Swift `callGraph`.
6. Remove/document context_pack 500-token floor.
7. Align empty-token behavior.
8. Improve ranking signals (boost definitions, path matches, surface actual tier).
9. Add overlap to Swift chunking.
10. Strengthen reference/call detection.
11. Add adversarial regression tests.

## Open questions
1. What is intended production embedding model?
2. Do Python MCP and Swift daemon share a database?
3. Why does Swift ignore `callGraph` depth parameter?
4. Why is context_pack token budget floored at 500?
5. Are there integration tests comparing Python and Swift results?
6. Should `search_code` always return a full page?
