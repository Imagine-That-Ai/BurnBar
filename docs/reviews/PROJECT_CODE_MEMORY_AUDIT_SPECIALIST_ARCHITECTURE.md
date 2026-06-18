# Specialist Report: Architecture Agent

## Scope covered
- End-to-end data flow for agent memory and project code memory.
- Module boundaries: Rust static parser, Python MCP helper library, Swift daemon store, MCP server, RPC handlers, capability gating.
- Coupling, config propagation, extension seams, storage contracts, maintainability.

## Files inspected
- `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`
- `docs/architecture/010-project-code-static-parser.md`
- `crates/project-code-static-parser/src/main.rs`
- `crates/project-code-static-parser/Cargo.toml`
- `tools/openburnbar-mcp/project_code_memory.py`
- `tools/openburnbar-mcp/server.py`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Helpers.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCCode.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCMemory.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarProjectCodeMemoryContracts.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarProjectCodeMemoryStoreTests.swift`
- `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift`
- `docs/SCHEMA_SQLITE.sql`

## Commands run
- `cargo check --quiet` in `crates/project-code-static-parser` — passed.
- `python3 -m py_compile tools/openburnbar-mcp/project_code_memory.py tools/openburnbar-mcp/server.py` — passed.

## Findings by severity

### Critical
1. **Raw-SQLite daemon store bypasses canonical GRDB migrator.** Evidence: `BurnBarProjectCodeMemoryStore.swift:1018-1251` bootstraps tables via raw `sqlite3_*`; GRDB side lacks code-memory migrations. Risk: two schema authorities. Fix: move schema to `OpenBurnBarDatabase.swift` migrations.
2. **Python MCP read tools open DB read-write and duplicate indexing logic.** Evidence: `server.py:178` `_connect_rw` used by reads; `project_code_memory.py` reimplements `index_project`, `search_code`, `get_symbol`. Fix: make Python a thin RPC client; keep helpers as test/load harness.
3. **Fail-closed write path has bypass risk.** Evidence: read tools use `_connect_rw`; future maintainers could add writes there. Fix: introduce `_connect_ro` for reads; CI check banning `_connect_rw` in read tools.

### High
4. **Duplicate secret-scanner corpus in Swift and Python.** Evidence: `BurnBarProjectCodeMemoryStore+Helpers.swift:55-84` vs. `project_code_memory.py:86-111`. Fix: shared JSON/YAML corpus + parity test.
5. **Tier evidence claims inconsistent SHA semantics.** Evidence: Python lexical sets `shaMatch: false` (`:1417`); Swift lexical sets `shaMatch: true` (`BurnBarProjectCodeMemoryStore+Helpers.swift:339`). Fix: centralize schema; Swift lexical = false.
6. **`codeWatchProject` poll-based watcher lacks FSEvents/debounce.** Evidence: `BurnBarProjectCodeMemoryStore.swift:554-628`. Fix: use `FSEventStream`.
7. **Call-graph edges from naive lexical heuristics.** Evidence: Swift `:1647`; Python `:1978`. Fix: document limitation; use LSP callHierarchy when available.
8. **`chunk_embeddings` recomputed from scratch; no incremental diff.** Evidence: Swift `:407-423`; Python `:1723-1732`. Fix: use contentHash to skip unchanged chunks.

### Medium
9. Exact LSP config via JSON env var with no schema validation. Evidence: `main.rs:430-437`.
10. Diagnostics tool reads from always-empty cache. Evidence: `BurnBarProjectCodeMemoryStore.swift:796-818`; `project_code_memory.py:438-448`.
11. Swift `codeSearchHits` lacks vector/RRF. Evidence: `BurnBarProjectCodeMemoryStore.swift:1758-1805` vs. Python RRF.
12. Project ID generation differs between Swift and Python.
13. `BurnBarProjectCodeMemoryStore.swift` is a 1,993-line god module.

### Low
- `insertSearchDocument` hardcodes `sourceVersionID` to empty string.
- `ftsQuery` lacks token cap and shared builder.
- Swift deletion leaves orphan `chunk_embeddings`.
- `memoryAnalytics` fetches global last audit hash, not project-scoped.

## Recommended refactors (prioritized)
1. Unify schema ownership in GRDB.
2. Make Python MCP a thin RPC client.
3. Single shared secret-scanner corpus.
4. Consolidate search ranking.
5. Fix tier-evidence truth.
6. Replace polling watcher.
7. Incremental indexing by blob SHA.
8. Split god store into focused modules.
9. Validate/populate `sourceVersionID` with blob SHA.
10. Decide on diagnostics: implement or remove.

## Open questions
1. Is daemon raw-SQLite bootstrap temporary or permanent?
2. Is `project_code_memory.py` used by non-MCP clients?
3. Are any current paths uploading code-memory rows to the cloud?
4. Where do new Swift CLI arms live?
5. Should code search be served by existing `BurnBarIndexedSearchService`?
