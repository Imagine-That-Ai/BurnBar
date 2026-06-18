# Specialist Report: Developer Experience Agent

## Scope covered
- Setup, docs, config for local MCP, Rust static parser, Swift daemon store.
- Tool discoverability, defaults, required env vars, capability gates.
- Error message quality, structured logging, debugging, local overrides, failure recovery.
- Documentation completeness and mental model.

## Files inspected
- `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`
- `docs/architecture/010-project-code-static-parser.md`
- `tools/openburnbar-mcp/README.md`
- `tools/openburnbar-mcp/server.py`
- `tools/openburnbar-mcp/project_code_memory.py`
- `tools/openburnbar-mcp/setup.sh`
- `tools/openburnbar-mcp/requirements.txt`
- `tools/openburnbar-mcp/burnbar_usage_ledger.py`
- `tools/openburnbar-mcp/hermes-skill/SKILL.md`
- `tools/openburnbar-mcp/tests/test_project_code_memory.py`
- `tools/openburnbar-mcp/tests/test_local_mcp_policy.py`
- `crates/project-code-static-parser/Cargo.toml`
- `crates/project-code-static-parser/src/main.rs`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCMemory.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCCode.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonSocketRPCCoverage.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarProjectCodeMemoryContracts.swift`
- `docs/SCHEMA_SQLITE.sql`
- `docs/HOSTED_REMOTE_MCP.md`
- `docs/PENSIEVE.md`
- `docs/REMOTE_MCP_CLIENT_SETUP.md`
- `CHANGELOG.md`
- `scripts/ci/verify-sqlite-schema-doc.mjs`
- `scripts/ci/project-code-memory-load-test.py`

## Commands run
- `pytest tools/openburnbar-mcp/tests/ -x -q` → 86 passed.
- `pytest tools/openburnbar-mcp/tests/test_project_code_memory.py -x -q` → 10 passed.
- `cargo test --quiet` (Rust parser) → 8 passed.
- `node scripts/ci/verify-sqlite-schema-doc.mjs` → passed.
- Adversarial runtime probes: fake daemon accept/reject, missing daemon, missing static parser, malformed paths, empty queries, secret-bearing remember text, scaled-down load test.

## Findings by severity

### Critical
1. **Setup script does not build Rust static parser.** Evidence: `tools/openburnbar-mcp/setup.sh` builds venv but never runs `cargo build`. Most users silently degrade to regex fallback.
2. **README tools table is broken.** Evidence: `README.md:172-178` interrupts Markdown table with paragraph. Discoverability broken.
3. **No runtime logging in Python implementation.** No `logging` import; parser fallback, LSP timeout, staleness downgrade, storage-budget rejection all silent.
4. **`burnbar_search_code` always reports `confidenceTier: lexical_fallback` even when vector-driven.** Evidence: `project_code_memory.py:2149`. Violates master plan §5.6.

### High
5. **Static parser discovery is CWD-relative and fragile.** Evidence: `project_code_memory.py:1382-1391` checks `Path.cwd()` and parent only.
6. **No CLI equivalent of `burnbar_memory_doctor`.** Swift CLI has `healthcheck`/`config` but no `doctor`.
7. **`burnbar_usage_ledger.py` still falls back to direct write when daemon explicitly rejects RPC.** Evidence: `burnbar_usage_ledger.py:404-408`. Inconsistent fail-closed semantics.
8. **Swift store logs too sparse to debug production issues.** Only three `logger.*` calls in 1,993-line file.
9. **LSP configuration documented with JSON env example but no validation/schema/error surface.** Malformed `OPENBURNBAR_CODE_LSP_COMMANDS` silently disables LSP tiers.

### Medium
10. Direct Python helper API raises raw exceptions instead of structured `unavailable` payloads.
11. No guidance on daemon requirement in setup docs.
12. `burnbar_explore` returns `truncated: None` when no query supplied.
13. Dual naming `burnbar_context_pack` / `burnbar_code_context_pack` undocumented.
14. LSP default timeout (1.5s) aggressive for large projects; not surfaced.
15. No validation that `OPENBURNBAR_CODE_LSP_COMMANDS` JSON is well-formed.
16. Hermes skill does not mention Project Code Memory tools.

### Low / Info
17. Load script defaults to 100×1000 = 100k symbols but gate is env-driven.
18. `project_memory_snapshots` reused as durable body store — good privacy choice but not obvious.
19. Master plan lists `config` CLI subcommand but existing CLI `config` is generic.
20. `docs/PENSIEVE.md` mentions Project Code Memory in exactly one sentence.
21. Schema doc accurate and CI check passes — positive finding.

## Recommended UX/DX fixes
1. Make `setup.sh` build Rust helper or warn loudly.
2. Add `doctor` / setup verification command for Project Code Memory.
3. Surface daemon requirement in README Setup section and `setup.sh` output.
4. Fix README tools table.
5. Document `OPENBURNBAR_CODE_LSP_COMMANDS` with schema, examples, timeout.
6. Add dedicated CLI `doctor`/`memory-doctor` command.
7. Make static parser discovery robust (relative to `server.py`/`__file__`).
8. Make Python helper exceptions return structured payloads.
9. Surface LSP/static-parser fallback in tool responses with `tierEvidence`/`fallbackReason`.
10. Stop `burnbar_search_code` from claiming `lexical_fallback` when hybrid produced result.
11. Add structured logging to Python and Swift.
12. Resolve inconsistent fail-closed semantics in usage ledger.
13. Ensure `burnbar_explore` always returns boolean `truncated`.

## Documentation fixes
1. `tools/openburnbar-mcp/README.md`: fix table, move Rust helper build instructions to Setup, add "Before you write" callout, add Troubleshooting, document alias, add code-memory tools to Hermes skill.
2. `tools/openburnbar-mcp/hermes-skill/SKILL.md`: add Project Code Memory tools, correct "only write tool" claim, add decision-tree guidance.
3. `docs/PENSIEVE.md` and `docs/REMOTE_MCP_THREAT_MODEL.md`: add code asset-class section.
4. `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`: update implementation status for delivered items; mark CLI `config` decision.

## Open questions
1. Is fail-open usage ledger intentional?
2. What is canonical static parser path for packaged/editor-launched MCP servers?
3. Should `burnbar_search_code` expose per-hit tier evidence?
4. Why does Hermes skill omit Project Code Memory tools?
5. What is intended CLI `config` surface for memory/code?
6. Are hosted code-memory tools actually deployed now or future-only?
