# Memory MCP: from 8/10 to 10/10 — design

Status: approved for implementation 2026-09-02 (Alberto: "push to 10/10, memory MCP is a headlining feature").
Builds on [`docs/superpowers/2026-09-02-memory-mcp-v2-design.md`](../2026-09-02-memory-mcp-v2-design.md) (shipped in PR #2485, audited in PR #2497).

## 1. Why

The post-merge audit scored the memory engine 8 (engineering), 7 (agent-facing UX), 8 (reliability), 6 (extensibility). Three gaps explain every lost point:

1. **Extensibility.** `tools/openburnbar-mcp/memory_engine.py` is one 5,100-line module. Every change fights line anchors, every reviewer reads everything, and no unit can be tested or replaced alone.
2. **The mission.** Memory only happens when an agent decides to call `burnbar_memorize`. The engine's job is "collect important non-confidential information"; today nothing collects unless asked.
3. **Proof.** "SOTA" is a structural claim (mem0 parity). Extraction quality is unmeasured and the secret gate is tested by examples, not adversarially.

## 2. Non-goals

- No change to the MCP tool contracts, recall ranking, gate policies, encryption, audit chain, or daemon mirror.
- No split of `server.py`: the tests pin its module attributes for monkeypatching; splitting trades real coverage for cosmetics.
- No new runtime or dev dependencies (no `hypothesis`, no `pydantic`).
- No edit to the shared `.claude/settings.json`, `.mcp.json`, or `.serena/project.yml`. Automatic collection ships as an opt-in snippet.

## 3. Package split (extensibility)

`memory_engine.py` becomes the package `tools/openburnbar-mcp/memory_engine/` with a facade `__init__.py`. `import memory_engine as me` keeps working for `server.py`, `eval_memory.py`, and every test; every name those consumers reference stays importable from the facade (public and underscore-prefixed alike). Behavior is unchanged: same SQL, same constants, same defaults, same error codes.

| Module | Holds (today's section) | Owns |
|---|---|---|
| `constants.py` | header constants (env names, policies, budgets, RRF weights, `ENGINE_SCHEMA_VERSION`) | one place to tune |
| `_util.py` | "Small utilities" | `now_iso`, `sha`, `_json_dumps`, `_estimate_tokens`, … |
| `text.py` | "Tokenizer + BM25" and the snippet helpers | `tokenize`, `_stem`, `BM`, snippets |
| `crypto.py` | "Encryption" | `KeyRing`, secure file helpers, `store_lock_path` |
| `embeddings.py` | "Embeddings" | providers, vector codec, provider cache |
| `gate.py` | "Secret / PII gate" | `scan_text`, `apply_gate`, `injection_labels`, `GATE_CORPUS_AVAILABLE` |
| `extract.py` | "Entities + relations", "Extraction" | `Fact`, `heuristic_extract`, `parse_llm_facts`, LLM extractors |
| `store.py` | "Store", "Project identity" | schema, `open_store`, `ensure_schema`, migrations, `audit_event`, `verify_audit_chain`, `resolve_project` |
| `filters.py` | "Filters" | validation, SQL compilation, `match_filters` |
| `engine.py` | "Engine" header, `EngineConfig`, `ActiveMemory`, `MemoryEngine` construction/crypto/row loading/salience | the class, composed from three mixins |
| `_write.py` | `MemoryEngine` write path | `memorize`, `remember`, reconciliation |
| `_read.py` | read path and CRUD | `recall`, `pack`, `get`, `list`, `history`, `review`, `forget*` |
| `_admin.py` | maintenance | `doctor`, `export`, `import`, `reindex`, audit trail |

Rules: no module over 1,500 lines (a test enforces it); mutable module flags (`GATE_CORPUS_AVAILABLE`, the provider cache, `OllamaEmbeddingProvider` lookups) are read through their module at call time, never `from .x import FLAG`, so monkeypatching keeps working; the four existing test lines that patch `me.GATE_CORPUS_AVAILABLE` / `me.OllamaEmbeddingProvider` move to `me.gate.` / `me.embeddings.`.

**Versioned migrations.** `store.py` gains `SCHEMA_MIGRATIONS` (ordered `(target_version, statements)` steps, empty today) applied one transaction per step above the stored version, and `SchemaTooNew`: a store stamped with a version newer than `ENGINE_SCHEMA_VERSION` is refused with a message naming both versions. Two engine versions on one machine can no longer corrupt each other's store.

## 4. Automatic collection (the mission)

A Claude Code `SessionEnd` hook memorizes the session transcript through the same gate, encryption, audit, and daemon mirror as the tool path. Facts from the current docs (verified 2026-09-02): the event fires once per session, receives `{session_id, transcript_path, cwd, hook_event_name, reason}` on stdin, cannot block, and has a 30-second ceiling when `timeout` is set. The transcript format is documented as internal, so parsing is lenient by design.

Components:

- `tools/openburnbar-mcp/memorize_transcript.py`: CLI. Reads the JSONL, keeps `user`/`assistant` text (string content or `text` blocks; skips tool use/result, thinking, summaries, malformed lines; strips Claude Code wrapper tags such as `<system-reminder>`), keeps the tail within 400 messages / 200,000 characters, and calls `server.burnbar_memorize(..., source_kind="session", source_ref="claude-code:<session_id>")`. Enforces its own 20-second deadline (macOS has no `timeout(1)`), prints one JSON status line, and exits 0 in every case except a usage error. Kill switch: `OPENBURNBAR_MEMORY_SESSION_HOOK=off`.
- `tools/openburnbar-mcp/hooks/claude-code-session-end.sh`: the hook command. Honors the kill switch, picks `OPENBURNBAR_MEMORY_PYTHON` or the venv interpreter (bootstrapping quietly if missing), runs the CLI with the hook JSON on stdin, always exits 0.
- README section "Automatic collection from Claude Code sessions" with the exact `settings.json` snippet (`timeout: 30`), the privacy statement (local, gated, encrypted, secrets redacted, kill switch, log path), and idempotency (re-running a transcript adds no duplicate memories).

## 5. Measured quality (proof)

- `eval_memory.py --extraction`: a gold set `tools/openburnbar-mcp/eval/extraction_gold.json` of at least 20 developer conversations with expected durable facts (keyword sets) and at least 5 "nothing durable" conversations. Reports recall, precision proxy, false positives on the empty cases, and forbidden-string leaks for the heuristic extractor. A test pins a recall floor and zero leaks so the number can only ratchet up.
- `eval_memory.py --gate`: a detection matrix per secret shape (raw, base64, hex, URL-encoded) so encoded-secret coverage is visible rather than assumed.
- `tests/test_gate_adversarial.py`: seeded, dependency-free. Every secret shape the gate detects standalone is embedded in prose, code fences, key/value lines, tags, entities, metadata values, and source refs; under `redact` the raw token must survive in no surface (result body, tags, entities, metadata, source ref, `get`, `recall` bodies and snippets, `pack`, `export`, `history`, `list`, the audit trail, and the raw bytes of the SQLite file); under `reject` the write is refused; under `retain` the vault decrypts to the verbatim token while the file bytes still do not contain it.

## 6. Acceptance

- All existing tests pass unchanged except the four monkeypatch-target lines; new tests cover migrations, the facade, module sizes, the transcript memorizer, the hook script, the extraction eval floor, and the adversarial gate.
- `ruff check` and `ruff format --check` clean at ruff 0.15.17, line length 120.
- Retrieval eval unchanged (hybrid R@5 0.90 / MRR 0.678 on the local `nomic-embed-text`).
- A real stdio session through `launch-memory.sh` still initializes with the same tool set.
- Docs: README, SKILL.md, and the v2 design doc describe the package layout, the hook, and the measured numbers.
