# Specialist Report: Security & Privacy Agent

## Scope covered
- Local ingestion, search, symbol extraction, agent-memory paths.
- Secret scanning, gitignore handling, path traversal, symlink escape, poisoned repo content, prompt-injection, hosted-sync future risks, multi-user isolation, telemetry, data retention.

## Files inspected
- `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`
- `docs/reviews/SECURITY_PRIVACY_REVIEW.md`
- `docs/REMOTE_MCP_THREAT_MODEL.md`
- `docs/PENSIEVE.md`
- `tools/openburnbar-mcp/project_code_memory.py`
- `tools/openburnbar-mcp/server.py`
- `tools/openburnbar-mcp/tests/test_project_code_memory.py`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Helpers.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCMemory.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCCode.swift`
- `crates/project-code-static-parser/src/main.rs`
- `services/hosted-mcp/src/toolRegistry.ts`
- `services/hosted-mcp/src/knowledge.ts`
- `services/hosted-mcp/src/rateLimits.ts`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/ClientTelemetrySanitizer.swift`

## Commands run
- `python3 -m pytest tests/test_project_code_memory.py -q`
- Adversarial secret probes (base64, spaced, chunked)
- Gitignore edge-case probes
- Symlink / path-traversal probe

## Findings by severity

### Critical
1. **Hosted code-memory query surface deployed before Phase 4 threat-model gate.** Evidence: `services/hosted-mcp/src/toolRegistry.ts:220-264` registers `burnbar_search_code` and `burnbar_get_code_document`. Master plan §5.5 says hosted code sync is Phase 4 and requires threat-model review.

### High
2. **Secret scanner bypassed by trivial encodings and fragmentation.** Evidence: base64, spaced, chunked OpenAI keys indexed (rejected files = 0). `project_code_memory.py:86-111` / `BurnBarProjectCodeMemoryStore+Helpers.swift:55-85`.
3. **`.gitignore` implementation non-compliant.** Drops negation, globstar, anchors, treats `#` as pattern.
4. **Swift static-parser subprocess has no timeout — daemon DB queue can be hung.** Evidence: `BurnBarProjectCodeMemoryStore+Helpers.swift:234-317`.
5. **LSP references path executes arbitrary commands from env var.** Evidence: `main.rs:430-446` reads `OPENBURNBAR_CODE_LSP_COMMANDS` JSON and spawns commands verbatim.
6. **`wrap_untrusted_snippet` is weak prompt-injection mitigation.** Preserves instruction-like comments; no stripping of imperative markers or XML breakouts.
7. **Hidden files blanket skipped; private files rely on extension allowlists.** `.env`, `.pem`, `.key` excluded by extension, but renamed variants can be indexed.

### Medium
8. Python MCP read tools open DB read-write.
9. Python audit hash chain omits sequence number.
10. No local rate limiting on code/memory RPCs.
11. Cloud forget is a label, not cross-tier delete for code.
12. Project partition key path-derived; repo rename splits memory.

### Low / Info
13. Deterministic fake embedding is correctness limitation, not privacy feature.
14. `/var` vs `/private/var` resolution can cause silent zero-file indexes if root not pre-resolved.
15. FTS snippets inject `<b>`/`</b>` inside untrusted wrapper.

## Evidence
- Base64 secret bypass: `main.py` with base64-encoded key indexed.
- Gitignore negation bypass: `!build/keep.txt` still ignored.
- Gitignore globstar bypass: `**/secrets` does not match `sub/secrets/file.txt`.
- Symlink escape resistance: outside symlink skipped.
- Project partition tests pass in Swift and Python.
- Fail-closed write tests pass.
- Label-only audit tests pass.

## Recommended mitigations
1. Secret scanner: add entropy + base64/hex decoding pass; reconstruct multiline strings.
2. Gitignore: replace hand-rolled parser with standards-compliant implementation (`pathspec` Python; real ruleset Swift).
3. Static parser timeout in Swift.
4. LSP command hardening: validate against allowlist or require signatures.
5. Prompt injection: strip/escape common instruction markers; consider guard model.
6. Hosted code surface: disable behind feature flag until threat-model review complete.
7. Python read tools: switch to `_connect_ro`.
8. Include `seq` in Python audit hash.
9. Add local rate limiting for code/memory writes.
10. Define retention policy and user forget path.

## Policy gates to add
1. Pre-merge adversarial test suite for secret bypasses, gitignore edge cases, symlink escapes.
2. No new hosted code tools until threat-model docs updated.
3. Static-parser / LSP subprocess allowlist gate.
4. Telemetry review gate for code-memory log lines.
5. Data-retention gate for code indexes.

## Open questions
1. Is any current client path calling `commitKnowledgeBatch` with `sourceKind: "code"`?
2. Who sets `OPENBURNBAR_CODE_LSP_COMMANDS` — user, app, or installer?
3. For hosted code sync, will chunks be sealed with same vault key and 24-reflection Householder transform as prose?
4. What is retention policy for rejected-file audit events and checkpoints?
5. Are hidden dotfiles intentionally excluded entirely, or should some (e.g., `.github/workflows/*.yml`) be allowed?
