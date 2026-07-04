# Memory MCP SOTA — security review receipt (G1)

- **Date:** 2026-07-04
- **Reviewer lane:** principal audit pass (implementation + adversarial self-review)
- **Status:** **Nearly done** for the scoped branch work. Independent Codex factory review remains the merge gate per `AGENTS.md`.

## Checklist (§8)

| # | Invariant | Evidence | Honest status |
|---|---|---|---|
| 1 | E2EE / sealed-reference | `cloudSyncEligibleChatMemories` fail-closed on `v1-local:`; G7 corpus v5; `scripts/ci/check-memory-store-invariants.sh` | **Proven in code + CI script** |
| 2 | Prompt-injection defense | `LLMSafeContent.wrapUntrusted` on macOS recall; iOS F1 (inlined into `PensieveMemorySearchView.swift`); Android F1 (`LLMSafeContent.kt` byte-shape tests) | **Proven for wrap shape; mobile recall still silent-empty on failure** |
| 3 | Quarantine-by-default | `recallChatMemorySnippets` gates approved + `validTo==nil`; hybrid RRF | **Proven on macOS authority path** |
| 4 | Embedding-version floor | Write throw + read floor; PCM version column; Ollama provider **opt-in** via `OPENBURNBAR_OLLAMA_EMBED_URL` | **Honest OFF by default** (NL fallback) |
| 5 | Two-phase audited forget | v53 outbox; B6 `burnbar_forget_all` fail-closed | **Mac-owned writes; MCP does not implement forget_all** |
| 6 | Cost-neutral extraction | Local-only LLM order; kill-switch runbook | **Proven by existing kill-switch tests when suite compiles** |
| 7 | Windows byte-compat | `memoryCitationHmac` KAT + C#/Swift pin tests | **Proven** |
| 8 | Kill switches | `MemoryExtractionPolicy` + runbook | **Proven by policy code** |
| 9 | MCP trust | Hosted fail-closed rate buckets; D6 livez/readyz/trace_id; B6 **Python read path** (not daemon RPC); D8 parity matrix | **B6 is read-only Python over main DB — not daemon RPC** |
| 10 | No 4th store / suppressions | `check-memory-store-invariants.sh` | **Proven** |

## What this branch does **not** claim

- **B6 daemon RPC** (`daemon.memory.get/list/update/forget_all/list_entities`) is **not** implemented. Python tools read `agent_memories(source_kind='chat')` from `BURNBAR_DB_PATH` and fail closed on writes.
- **Windows memory pane** is a **read-only empty mirror** until B1 cloud sync delivers approved facts. No demo/sample facts are shown.
- **Mobile F1** injects Pensieve `searchKnowledge` hits (deterministic `hashing-bow-v1` embed+cloak), not local chat-memory authority rows. Failures degrade to empty injection (no user-visible error — intentional fail-closed for prompt assembly).
- **ADR-012 dense tier** is opt-in Ollama only; default remains OS NaturalLanguage / honest `semanticAvailable` when fingerprint-only.

## Residual risks (named)

1. Full macOS `OpenBurnBarTests` may still fail on unrelated compile issues in the test target; memory-specific suites must be green before GA.
2. Android/iOS recall only matches knowledge indexed under `hashing-bow-v1` unless a device bge runtime is wired later.
3. Windows Firestore REST hydration of synced facts is follow-on once B1 is fleet-enabled.

## Sign-off checklist for factory reviewer

- [ ] `bash scripts/ci/check-memory-store-invariants.sh`
- [ ] `cd tools/openburnbar-mcp && .venv/bin/python -m pytest tests/test_chat_memory_authority.py tests/test_tool_parity.py`
- [ ] `cd services/hosted-mcp && npm test`
- [ ] `cd windows/tests/cloudsync && dotnet test --filter MemoryCitationHmac`
- [ ] `cd windows/tests/presentation && dotnet test --filter MemoryStore`
- [ ] Swift `CloudVaultCryptoTests.test_memoryCitationHMAC_matchesWindowsKATVector`
- [ ] Android `:app:testDebugUnitTest` for `LLMSafeContentTest` / `PensieveVectorCloakTest`
