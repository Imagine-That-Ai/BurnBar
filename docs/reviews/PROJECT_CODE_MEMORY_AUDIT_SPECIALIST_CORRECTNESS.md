# Specialist Report: Correctness Agent

## Scope covered
- Static parser crate, Python MCP helpers, Swift daemon store.
- Edge cases: malformed syntax, huge files, binary files, vendor/generated folders, duplicate symbols, nested scopes, language coverage, symlinks, permissions, renamed/deleted files, partial parses, encoding, LSP fallback/timing, tier-evidence honesty.

## Files inspected
- `crates/project-code-static-parser/src/main.rs`
- `crates/project-code-static-parser/Cargo.toml`
- `tools/openburnbar-mcp/project_code_memory.py`
- `tools/openburnbar-mcp/tests/test_project_code_memory.py`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Helpers.swift`

## Commands run
- `cargo test --quiet` (Rust parser)
- `swift test --filter BurnBarProjectCodeMemoryStoreTests`
- `python3 -m pytest tests/test_project_code_memory.py -q`
- Temporary adversarial scripts in `/tmp`:
  - `/tmp/adversarial_parser_tests.py`
  - `/tmp/adversarial_mcp_tests.py`
  - `/tmp/stale_search_debug.py`
  - `/tmp/test_lsp_tier2.py`

## Findings by severity

### Critical
1. **Python indexer never prunes deleted/renamed files from `code_artifacts` and search index.** Evidence: `project_code_memory.py:1724-1726, 1765` deletes symbol/reference rows but not artifacts/search rows. Repro: rename `Sources/Target.py` → `Sources/Renamed.py`, re-index, `code_artifacts` still contains old file. Fix: delete all project rows at start.
2. **Swift daemon has no timeout when spawning static parser / LSP helper.** Evidence: `BurnBarProjectCodeMemoryStore+Helpers.swift:265-269, 1716-1724` call `process.waitUntilExit()` without timeout. Fix: add timeout and degrade.

### High
3. **Static parser language support too narrow for declared extension set.** Evidence: `main.rs:211-219` only supports Python/Swift/TS/TSX; Rust/Go/Kotlin/Java/C return `unsupported language`. Fix: add grammars or shrink advertised extension set.
4. **Swift lexical fallback falsely claims `shaMatch: true`.** Evidence: `BurnBarProjectCodeMemoryStore+Helpers.swift:333-342`. Fix: set `false`.
5. **Python exact-LSP references evidence always claims `shaMatch: true` without verifying reference files.** Evidence: `project_code_memory.py:1687-1694`. Fix: verify ref blob or mark stale.
6. **Malformed Swift yields zero recovered symbols from tree-sitter.** A single unclosed brace produces `hasParseError: true` and empty symbol list. Fix: ensure lexical fallback covers this.

### Medium
7. Inconsistent binary / invalid-UTF-8 handling between Python and Swift.
8. Python regex fallback loses symbol kinds for TS/JS/Rust/Go.
9. Lexical reference builder scans comments and string literals.
10. `.gitignore` negation patterns are ignored.
11. Secret scanner can over-match legitimate code (credit-card, IPv4, SSN, phone patterns).

### Low / Info
12. No explicit resource cap in static parser itself.
13. Duplicate symbol names produce multiple distinct rows (expected, no explicit test).
14. Nested scopes only recovered by tree-sitter.
15. Swift `identifierTokens` is ASCII-only.

## Evidence table
| Case | Expected | Actual |
|---|---|---|
| Malformed Swift | symbols recovered | `hasParseError=true`, symbols=[]; regex fallback recovers |
| Huge file | completes within budget | 2.4 MB Swift → 200k symbols in ~3.4 s |
| Binary input | no crash | `hasParseError=true`, symbols=[] |
| Unsupported language | `ok=false` | Rust/Go/Kotlin/Java/C all unsupported |
| Vendor folders ignored | not indexed | skipped |
| Symlink escape blocked | outside symlink not indexed | blocked |
| Deleted-file pruning (Python) | old artifact removed | stale artifact remains |
| Storage budget | rejects excess | works |

## Recommended fixes
1. Prune stale project rows in Python indexer.
2. Add process timeout in Swift.
3. Make Swift lexical evidence honest (`shaMatch: false`).
4. Verify reference-file blobs in Python exact-LSP references.
5. Decide on UTF-8/binary policy and apply consistently.
6. Preserve symbol kinds in Python regex fallback.
7. Document or fix gitignore negation and comment/string false-reference limitations.
8. Add language-coverage tests.

## Missing tests
- Static parser: malformed syntax recovery, binary/invalid-UTF-8, huge-file bound, duplicate names, unsupported language, SHA mismatch, LSP timeout.
- Python MCP: vendor/gitignore/symlink/unreadable files, deleted/renamed file pruning, invalid-UTF-8, storage budget, language fallback, exact-LSP staleness.
- Swift store: malformed Swift fallback, non-static languages, binary/unreadable files, parser timeout, duplicate symbols, nested scopes, gitignore negation.

## Open questions
1. Is intended language-extension set the supported tree-sitter set or the larger `indexedExtensions`/`CODE_EXTENSIONS` list?
2. Should exact-LSP references outside project root be filtered?
3. Should broad secret patterns be tightened to reduce false positives?
4. Should `hasParseError` downgrade confidence or trigger stronger fallback?
5. Why does Python indexer not clear stale search rows on re-index?
