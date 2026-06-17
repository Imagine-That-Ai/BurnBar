# Specialist Report: Performance Agent

## Scope covered
- Python indexing/search substrate, Swift daemon store.
- Cold index, warm reindex, incremental "update", memory usage, large repo behavior, cache invalidation, parallelism, lock contention, CI/runtime cost.

## Files inspected
- `tools/openburnbar-mcp/project_code_memory.py`
- `tools/openburnbar-mcp/tests/test_project_code_memory.py`
- `scripts/ci/project-code-memory-load-test.py`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Helpers.swift`
- `.github/workflows/fast-feedback.yml`

## Commands run

### Default load test
```bash
python3 scripts/ci/project-code-memory-load-test.py
# Result: passed, 100 files, 100k symbols, index 18.477s, query 0.0278s, DB 6.3MB source
```

### Single-scenario benchmark
Script `/tmp/pcm_bench_one.py`:
- 100×1000: cold 15.01s, warm 14.80s, incremental 15.20s, RSS +226MB, DB 103.8MB for 6.3MB source (~17×)
- 500×1000: cold 80.1s, warm 91.4s, incremental 89.4s, RSS +1.10GB, DB 519MB for 31.5MB source (~16×)
- 1000×200: cold 45.3s, RSS +437MB, DB 211MB for 12.6MB source (~17×)

### Query latency
| Repo | get_symbol | search_code | find_references | call_graph |
|---|---|---|---|---|
| Small chain | 0.24ms | 0.46ms | 6.92ms | 0.38ms |
| 500×1000 (500k symbols) | 30.6ms | 119.6ms | 0.18ms* | 0.15ms* |

*Fast because synthetic repo has no cross-file edges.

### Vacuum / bloat
- After 100×1000: 23,196 pages, 94.9MB
- After deleting all code rows + `incremental_vacuum(10000)`: 23,195 pages, 95.0MB (no shrink)
- After `VACUUM`: 80.5MB

### Profiling (100×1000)
Top hotspots:
- `index_project` 19.77s
- `build_references` 6.09s
- `deterministic_embedding` 5.93s (3,000 calls)
- `extract_symbols` 5.63s
- `static_tree_sitter_symbols` 5.62s (subprocess per file)
- `line_col` 5.26s
- subprocess overhead 2.57s
- sqlite3 execute 1.03s

### Concurrency
Two processes indexing different projects into same DB: serialized at SQLite lock; each took ~1s but started simultaneously.

## Findings by severity

### Critical
1. **Incremental updates do not exist — every update is full reindex.** One-file change in 500-file repo costs ~89s.
2. **SQLite DB bloat unbounded; incremental vacuum ineffective.** 16–17× source size; `incremental_vacuum(256)` frees no pages.
3. **Storage budget ignores FTS/index overhead.** 512MB source budget → ~8GB DB possible.
4. **Python path lacks WAL and busy timeout; concurrent writers collide.** `ensure_schema` sets auto_vacuum but not journal_mode=WAL or busy_timeout.

### High
5. Static parser subprocess per file dominates indexing cost.
6. `search_code` semantic path is full linear scan of all chunk embeddings.
7. Every query re-reads files to validate blob SHA.
8. Single-threaded architecture on both paths.

### Medium
9. `deterministic_embedding` CPU-heavy per chunk.
10. `build_references` near-quadratic cost in dense code.
11. Symbol extraction via regex still runs even when static parser present as fallback.
12. Swift store opens SQLite with `SQLITE_OPEN_FULLMUTEX` and serializes through `dbQueue`.

### Low / Info
13. Unit tests are fast and do not stress scale.
14. Load test not CI-gated.

## Bottlenecks
| # | Bottleneck | Why it hurts |
|---|---|---|
| 1 | Full-project reindex | No file-level change detection |
| 2 | Per-file parser subprocess | Process spawn per file |
| 3 | Deterministic embedding in Python | SHA-256 per token per position |
| 4 | Cross-reference construction | Scans every token in every file |
| 5 | Linear semantic search | Reads every chunk embedding |
| 6 | Disk-based freshness checks per result | Re-hashes files for every candidate |
| 7 | Serial DB access / no WAL in Python | Collisions and no concurrent reads |
| 8 | No insert batching | One execute per row |
| 9 | Ineffective vacuum | Same-transaction delete/insert leaves no freelist |

## Recommended optimizations
1. File-incremental indexing by blob SHA/mtime.
2. Batch inserts; commit per changed-file group.
3. Long-lived parser daemon or batch RPC.
4. Cache embeddings by contentHash.
5. Approximate vector index or drop semantic search.
6. Use mtime+size for freshness; verify SHA only on mtime change.
7. Enable WAL and busy timeout in Python path.
8. Run `VACUUM` periodically, not `incremental_vacuum(256)`.
9. Parallelize file parsing outside DB transaction.
10. Add load test to CI.

## Open questions
1. Is production Mac daemon always used for indexing, or can Python MCP still call `index_project` directly?
2. What is target repo size for BurnBar itself? 500k symbols already takes ~80s and 1.1GB RAM.
3. Are cross-file references common in real codebase?
4. Is deterministic embedding required for code search, or can system rely on FTS alone?
5. What is operational limit for shared SQLite file?
6. Has Swift store been profiled with same large synthetic repos?
