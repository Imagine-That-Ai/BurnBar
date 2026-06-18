# Specialist Report: Testing & CI Agent

## Scope covered
- Project Code Memory local implementation across Rust parser, Python helpers/MCP server, Swift daemon store, RPC handlers.
- Schema documentation and drift gates.
- CI workflows executing relevant tests.
- Coverage gaps, flaky areas, regression risks.

## Files inspected
- `tools/openburnbar-mcp/project_code_memory.py`
- `tools/openburnbar-mcp/server.py`
- `tools/openburnbar-mcp/tests/test_project_code_memory.py`
- `tools/openburnbar-mcp/tests/test_mcp_untrusted_snippet_wrapper.py`
- `tools/openburnbar-mcp/tests/test_semantic_search.py`
- `crates/project-code-static-parser/src/main.rs`
- `crates/project-code-static-parser/Cargo.toml`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Helpers.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+SQLiteRow.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCCode.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonSocketRPCCoverage.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarProjectCodeMemoryStoreTests.swift`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarDaemonSocketRPCCoverageTests.swift`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarRPCCapabilityTests.swift`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarCLITests.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarProjectCodeMemoryContracts.swift`
- `docs/SCHEMA_SQLITE.sql`
- `scripts/ci/verify-sqlite-schema-doc.mjs`
- `scripts/ci/project-code-memory-load-test.py`
- `scripts/test-openburnbar-swift.sh`
- `.github/workflows/fast-feedback.yml`
- `.github/workflows/daemon-pr-gate.yml`
- `.github/workflows/openburnbar-pr-harness.yml`
- `.github/workflows/agent-tools-ci.yml`

## Commands run (exact results)
- `tools/openburnbar-mcp/.venv/bin/python -m pytest tools/openburnbar-mcp/tests/test_project_code_memory.py -v --tb=short` → 10 passed in 0.29s.
- `cargo test --manifest-path crates/project-code-static-parser/Cargo.toml` → 8 passed; 0 failed.
- `cd OpenBurnBarDaemon && swift test --filter BurnBarProjectCodeMemoryStoreTests` → 13 tests, 0 failures (2.124s).
- `swift test --filter BurnBarDaemonSocketRPCCoverageTests` → 2 passed.
- `swift test --filter BurnBarRPCCapabilityTests` → 6 passed.
- Load test (10 files × 100 symbols) → passed.
- `node scripts/ci/verify-sqlite-schema-doc.mjs` → SQLite schema doc covers 16 migration/source tables.
- `tools/openburnbar-mcp/.venv/bin/python -m pytest tools/openburnbar-mcp/tests/ -v --tb=short` → 86 passed in 3.14s.

## Findings by severity

### Critical
1. **Synthetic load test is not in CI.** Evidence: `grep -R project-code-memory-load-test .github` only matches `CHANGELOG.md`. Risk: performance regressions not caught.
2. **No end-to-end daemon RPC integration test for Project Code Memory.** `BurnBarDaemonSocketRPCCoverageTests` proves handler mapping, but no test exercises full socket path with live store.

### High
3. **Schema drift gate is table-name-only.** `verify-sqlite-schema-doc.mjs` does not verify columns, types, FTS5 virtual-table columns, indexes, foreign keys, constraints.
4. **Schema doc provenance is misleading.** Header claims generation from migration files that do not exist; actual schema is lazily created by Python/Swift.
5. **No Python ↔ Swift parity tests.** Same feature in two languages with no shared golden fixtures.
6. **`watchProject` Swift test is timing-dependent.** Uses `Thread.sleep` and 4.0s deadline; flaky on slow CI.

### Medium
7. No negative-path tests for static parser integration.
8. No concurrency/race tests.
9. gitignore / traversal coverage shallow.
10. Secret scanner lacks adversarial regression tests.
11. No storage-budget boundary tests.
12. No regression tests tied to specific incidents/bug IDs.

### Low
13. Trace propagation not asserted.
14. `codeDiagnostics` untested.
15. CLI formatting test stub-driven.

### Info
- Existing tests pass.
- Rust parser tests and Swift store tests are already gated by `daemon-pr-gate.yml`.
- Python tests are run by `agent-tools-ci.yml` on path-filtered PRs.

## Missing tests list
1. End-to-end daemon socket tests for all 11 `code.*` RPC methods.
2. Negative-path static parser tests.
3. Python ↔ Swift parity tests with shared golden repos.
4. Schema column/index/constraints parity test.
5. Schema verifier unit tests proving failure on removal.
6. Concurrent operation tests.
7. gitignore adversarial tests.
8. Storage budget boundary tests.
9. Secret scanner adversarial tests.
10. Memory recall ranking/snippet edge cases.
11. FTS5 query sanitization tests.
12. `codeDiagnostics` read path tests.
13. `project_memory_snapshots` content-hash integrity tests.
14. Load/performance regression test in CI.
15. Regression tests named/commented against incident IDs.
16. Watch-polling stability test without `Thread.sleep`.

## Recommended CI additions
1. Wire load test into nightly or pre-release workflow.
2. Add daemon RPC integration test target `BurnBarProjectCodeMemoryRPCTests.swift`.
3. Strengthen schema drift gate to compare columns/indexes/constraints.
4. Add Python/Swift schema parity job.
5. Pin static parser binary build before Swift tests in CI.
6. Add debt-budget ratchet requiring tests for new RPC methods.
7. Replace polling sleeps with deterministic synchronization.

## Open questions
1. Is `docs/SCHEMA_SQLITE.sql` intended to remain hand-maintained or be generated?
2. Why were Python tests historically excluded from CI, and is `agent-tools-ci.yml` sufficient?
3. What is canonical schema truth — Python, Swift, or doc?
4. Are there production incident IDs to encode as regression tests?
5. Is `codeDiagnostics` cache populated by future LSP integration or dead code?
6. Should Python and Swift guarantee identical behavior or approximate parity?

*Note: Subsequent direct inspection of `.github/workflows/agent-tools-ci.yml` confirmed it runs `pytest tests/` for the MCP surface on path-filtered PRs, with a blocking summary gate. The original finding that Python tests were "not in CI" is therefore too strong; they are gated but path-filtered.*
