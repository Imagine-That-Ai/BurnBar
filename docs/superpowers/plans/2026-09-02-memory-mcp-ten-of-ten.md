# Memory MCP 10/10 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three gaps that keep the memory engine below 10/10: split the 5,100-line engine into a package, collect memories automatically at the end of every Claude Code session, and measure extraction quality and gate robustness instead of asserting them.

**Architecture:** `memory_engine.py` becomes a package with a facade so consumers and tests are untouched; a transcript memorizer CLI plus a `SessionEnd` hook script reuse the server's `burnbar_memorize` wrapper so gating, encryption, audit, and daemon mirroring stay identical; the eval script grows extraction and gate modes with a checked-in gold set, and an adversarial gate suite pins the secret guarantees.

**Tech Stack:** Python 3.12 (the venv `bootstrap-memory.sh` creates), stdlib `sqlite3`, `pytest>=8`, ruff 0.15.17, bash. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-02-memory-mcp-ten-of-ten-design.md`

## Global Constraints

- Working directory for every command: `tools/openburnbar-mcp` inside your worktree, unless a step says otherwise.
- Environment setup once per worktree: `./bootstrap-memory.sh` then `uv pip install --quiet --python .venv/bin/python -r requirements-dev.txt`.
- Test command: `.venv/bin/python -m pytest tests -q --no-header -p no:cacheprovider --ignore=tests/test_domain_core_cloudvault.py` (the ignored file needs a cargo-built package; it is environmental and untouched). Baseline on the base commit: 312 passed, 1 skipped, 0 failed.
- Lint/format, run from the repo root: `uvx ruff@0.15.17 check scripts tools/openburnbar-mcp` and `uvx ruff@0.15.17 format scripts tools/openburnbar-mcp` (line length 120; `ruff.toml` at the repo root is the config). Both must be clean before every commit.
- No new runtime or dev dependencies. `requirements.txt` and `requirements-dev.txt` are not modified.
- `import memory_engine as me` keeps working; every name referenced as `me.<name>` in `server.py`, `eval_memory.py`, or any file under `tests/` stays importable from the facade.
- Never modify `.serena/project.yml`, `.claude/settings.json`, `.mcp.json`, `server.py` (Task 1, Task 3), or another task's files. Task 2 may not modify `memory_engine.py`; Task 3 may not modify `memory_engine.py`.
- Never touch the real memory store: every test and every manual check points `OPENBURNBAR_MEMORY_DB_PATH` and `BURNBAR_DB_PATH` at a temporary directory, sets `OPENBURNBAR_MEMORY_EMBEDDING_PROVIDER=none`, `OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT=true`, and `OPENBURNBAR_DAEMON_SOCKET_PATH=<tmp>/missing.sock` (copy the block in `tests/test_mcp_stdio_smoke.py`).
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never push. Never force-push. Never run `git stash`.
- Every test asserts behavior; no test may pass trivially, and test output must be pristine (no warnings).

---

### Task 1: Split `memory_engine.py` into a package with a facade, plus versioned migrations

**Files:**
- Delete: `tools/openburnbar-mcp/memory_engine.py`
- Create: `tools/openburnbar-mcp/memory_engine/__init__.py`, `constants.py`, `_util.py`, `text.py`, `crypto.py`, `embeddings.py`, `gate.py`, `extract.py`, `store.py`, `filters.py`, `engine.py`, `_write.py`, `_read.py`, `_admin.py`
- Modify: `tools/openburnbar-mcp/tests/test_memory_engine_hardening.py:245` and `:778`, `tools/openburnbar-mcp/tests/test_memory_engine_hardening_round5.py:204` and `:218` (monkeypatch targets only)
- Modify: `docs/superpowers/2026-09-02-memory-mcp-v2-design.md` (§ "Data model"/"Module map": replace the single-file description with the table from the spec §3), `tools/openburnbar-mcp/README.md` (the sentence that names `memory_engine.py` now names the package)
- Test: `tools/openburnbar-mcp/tests/test_memory_engine_layout.py` (new), `tools/openburnbar-mcp/tests/test_store_migrations.py` (new)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the package `memory_engine` with facade names identical to today's module; `memory_engine.store.SCHEMA_MIGRATIONS`, `memory_engine.SchemaTooNew`, `memory_engine.gate.GATE_CORPUS_AVAILABLE`, `memory_engine.embeddings.OllamaEmbeddingProvider`.

Section map of the current file (line numbers at the base commit; use them to cut, then verify by reading):

| Lines | Section | Destination |
|---|---|---|
| 1–285 | imports, env names, policies, budgets, RRF weights, `ENGINE_SCHEMA_VERSION` | `constants.py` (imports go to the modules that need them) |
| 286–373 | Small utilities | `_util.py` |
| 374–488 | Tokenizer + BM25 | `text.py` |
| 489–685 | Encryption | `crypto.py` |
| 686–894 | Embeddings | `embeddings.py` |
| 895–1258 | Secret / PII gate | `gate.py` |
| 1259–1633 | Entities + relations, Extraction | `extract.py` |
| 1634–1937 | Store, Project identity | `store.py` |
| 1938–2366 | Engine header, `EngineConfig`, persisted decision keys, `class MemoryEngine` through the salience helpers | `engine.py` |
| 2367–3422 | `MemoryEngine` write path | `_write.py` as `class _WritePath` |
| 3423–4399 | read path and CRUD | `_read.py` as `class _ReadPath` |
| 4400–4882 | maintenance | `_admin.py` as `class _Maintenance` |
| 4883–5181 | Filters + snippets | `filters.py` (filters) and `text.py` (snippet helpers) |

- [ ] **Step 1: Write the layout and facade tests (they fail because the package does not exist)**

`tests/test_memory_engine_layout.py`:

```python
"""The engine is a package of focused modules, and its facade hides the split from consumers."""

from __future__ import annotations

import importlib
import re
from pathlib import Path

MCP_DIR = Path(__file__).resolve().parents[1]
PACKAGE_DIR = MCP_DIR / "memory_engine"
MAX_MODULE_LINES = 1500
CONSUMERS = [MCP_DIR / "server.py", MCP_DIR / "eval_memory.py", *sorted((MCP_DIR / "tests").glob("test_*.py"))]
REFERENCE = re.compile(r"\bme\.([A-Za-z_][A-Za-z0-9_]*)")


def test_memory_engine_is_a_package_of_bounded_modules():
    assert (PACKAGE_DIR / "__init__.py").is_file()
    assert not (MCP_DIR / "memory_engine.py").exists()
    oversized = {
        path.name: sum(1 for _ in path.open(encoding="utf-8"))
        for path in PACKAGE_DIR.glob("*.py")
        if sum(1 for _ in path.open(encoding="utf-8")) > MAX_MODULE_LINES
    }
    assert oversized == {}, f"modules over {MAX_MODULE_LINES} lines: {oversized}"


def test_facade_exposes_every_name_consumers_reference():
    me = importlib.import_module("memory_engine")
    missing: dict[str, list[str]] = {}
    for consumer in CONSUMERS:
        names = sorted(set(REFERENCE.findall(consumer.read_text(encoding="utf-8"))))
        absent = [name for name in names if not hasattr(me, name)]
        if absent:
            missing[consumer.name] = absent
    assert missing == {}, f"facade is missing names used by consumers: {missing}"


def test_mutable_flags_are_read_through_their_module():
    """`from .gate import GATE_CORPUS_AVAILABLE` would freeze the flag and break monkeypatching."""
    offenders = []
    for path in PACKAGE_DIR.glob("*.py"):
        source = path.read_text(encoding="utf-8")
        for flag in ("GATE_CORPUS_AVAILABLE", "OllamaEmbeddingProvider"):
            if re.search(rf"^from \.\w+ import [^\n]*\b{flag}\b", source, re.MULTILINE) and path.name != "__init__.py":
                offenders.append(f"{path.name}:{flag}")
    assert offenders == [], offenders
```

The `test_facade_exposes_every_name_consumers_reference` test must list the four monkeypatch sites' new targets too, so it stays green after Step 5; `me.gate` and `me.embeddings` are attributes of the package once the submodules are imported by `__init__.py`.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `.venv/bin/python -m pytest tests/test_memory_engine_layout.py -q`
Expected: 3 failures (`__init__.py` missing).

- [ ] **Step 3: Cut the module into the package**

Mechanics that keep behavior identical:
- Move code verbatim; do not rename functions, constants, SQL, or error codes. Formatting changes are limited to what `ruff format` requires.
- Each module imports only what it uses. Circular imports: `engine.py` imports the leaf modules; the three mixin modules import from the leaf modules and, under `if TYPE_CHECKING:`, from `.engine`; leaf modules never import `engine`.
- `class MemoryEngine(_WritePath, _ReadPath, _Maintenance)` in `engine.py`; the mixin classes carry only the methods from their line ranges and no `__init__`.
- Mutable module state is read at call time through its module: inside the package write `gate.GATE_CORPUS_AVAILABLE`, `embeddings.OllamaEmbeddingProvider`, never `from .gate import GATE_CORPUS_AVAILABLE`.
- `__init__.py` re-exports every public name of every module and, explicitly, the underscore-prefixed names consumers use (`_estimate_tokens`, `_stem`, and any other `me._name` the facade test reports). Import the submodules so `me.gate`, `me.embeddings`, `me.store` resolve. Define `__all__`.
- Delete `memory_engine.py` in the same commit as the package appears.

- [ ] **Step 4: Run the whole suite; it must be 312 passed, 1 skipped, 0 failed except the four monkeypatch sites**

Run: `.venv/bin/python -m pytest tests -q --no-header -p no:cacheprovider --ignore=tests/test_domain_core_cloudvault.py`
Expected: the only failures are the tests that patch `me.GATE_CORPUS_AVAILABLE` or `me.OllamaEmbeddingProvider`.

- [ ] **Step 5: Repoint the four monkeypatch sites**

`tests/test_memory_engine_hardening.py:245` and `tests/test_memory_engine_hardening_round5.py:204,218`: `monkeypatch.setattr(me.gate, "GATE_CORPUS_AVAILABLE", ...)`. `tests/test_memory_engine_hardening.py:778`: `monkeypatch.setattr(me.embeddings, "OllamaEmbeddingProvider", RecoveringOllama)`.

Run the suite again. Expected: 312 passed + 3 new layout tests, 1 skipped, 0 failed.

- [ ] **Step 6: Write the migration tests (they fail: `SchemaTooNew` and `SCHEMA_MIGRATIONS` do not exist)**

`tests/test_store_migrations.py`:

```python
"""Stores carry a schema version; the engine upgrades older stores and refuses newer ones."""

from __future__ import annotations

import sqlite3

import pytest

import memory_engine as me


def _stamp(db_path, version: str) -> None:
    with sqlite3.connect(db_path) as conn:
        conn.execute("UPDATE engine_meta SET value = ? WHERE key = 'schema_version'", (version,))


def _stored_version(db_path) -> str:
    with sqlite3.connect(db_path) as conn:
        return conn.execute("SELECT value FROM engine_meta WHERE key = 'schema_version'").fetchone()[0]


def test_open_refuses_a_store_written_by_a_newer_engine(tmp_path, monkeypatch):
    monkeypatch.setenv(me.MEMORY_KEY_ENV, "0" * 64)
    db_path = tmp_path / "memory.sqlite"
    me.MemoryEngine.open(db_path=db_path).close()
    _stamp(db_path, "999")
    with pytest.raises(me.SchemaTooNew) as excinfo:
        me.MemoryEngine.open(db_path=db_path)
    assert "999" in str(excinfo.value)
    assert str(me.ENGINE_SCHEMA_VERSION) in str(excinfo.value)
    assert _stored_version(db_path) == "999", "a refused store must not be rewritten"


def test_pending_migrations_run_in_order_and_stamp_the_version(tmp_path, monkeypatch):
    monkeypatch.setenv(me.MEMORY_KEY_ENV, "0" * 64)
    db_path = tmp_path / "memory.sqlite"
    me.MemoryEngine.open(db_path=db_path).close()
    _stamp(db_path, "0")
    applied: list[int] = []
    monkeypatch.setattr(
        me.store,
        "SCHEMA_MIGRATIONS",
        (
            (1, ("CREATE TABLE migration_probe_a(x INTEGER)",)),
        ),
    )
    engine = me.MemoryEngine.open(db_path=db_path)
    try:
        tables = {row[0] for row in engine.conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    finally:
        engine.close()
    assert "migration_probe_a" in tables
    assert _stored_version(db_path) == str(me.ENGINE_SCHEMA_VERSION)
    assert applied == []  # the list exists only to make the intent explicit: migrations are data, not callbacks


def test_current_stores_open_without_running_migrations(tmp_path, monkeypatch):
    monkeypatch.setenv(me.MEMORY_KEY_ENV, "0" * 64)
    db_path = tmp_path / "memory.sqlite"
    me.MemoryEngine.open(db_path=db_path).close()
    monkeypatch.setattr(me.store, "SCHEMA_MIGRATIONS", ((1, ("CREATE TABLE must_not_exist(x INTEGER)",)),))
    engine = me.MemoryEngine.open(db_path=db_path)
    try:
        tables = {row[0] for row in engine.conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    finally:
        engine.close()
    assert "must_not_exist" not in tables
```

If `MemoryEngine.open` needs different keyword names or the engine exposes its connection under another attribute than `conn`, adapt the test to the real names and say so in your report; do not change the engine's API.

- [ ] **Step 7: Implement migrations in `store.py`**

```python
class SchemaTooNew(RuntimeError):
    """The store was written by a newer engine; refuse to touch it."""


# Ordered (target_version, statements). Append a step and bump ENGINE_SCHEMA_VERSION
# to the last target when the schema changes. Empty today: v1 is the first version.
SCHEMA_MIGRATIONS: tuple[tuple[int, tuple[str, ...]], ...] = ()


def _stored_schema_version(conn: sqlite3.Connection) -> int | None:
    row = conn.execute("SELECT value FROM engine_meta WHERE key = 'schema_version'").fetchone()
    return int(row[0]) if row else None


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA_SQL)  # the existing idempotent DDL, unchanged
    current = _stored_schema_version(conn)
    if current is None:
        conn.execute(
            "INSERT OR IGNORE INTO engine_meta(key, value) VALUES ('schema_version', ?)",
            (str(ENGINE_SCHEMA_VERSION),),
        )
        conn.commit()
        return
    if current > ENGINE_SCHEMA_VERSION:
        raise SchemaTooNew(
            f"memory store schema version {current} is newer than this engine's {ENGINE_SCHEMA_VERSION}; "
            "upgrade OpenBurnBar or point OPENBURNBAR_MEMORY_DB_PATH at a different store"
        )
    for target, statements in SCHEMA_MIGRATIONS:
        if target <= current:
            continue
        with conn:
            for statement in statements:
                conn.execute(statement)
            conn.execute("UPDATE engine_meta SET value = ? WHERE key = 'schema_version'", (str(target),))
        current = target
```

`open_store` retries `ensure_schema` on "locked" errors; `SchemaTooNew` must propagate untouched (it is not a lock error). Export `SchemaTooNew` from the facade.

- [ ] **Step 8: Run the migration tests and the full suite**

Run: `.venv/bin/python -m pytest tests/test_store_migrations.py -q` then the full suite command.
Expected: 3/3, then 318 passed, 1 skipped, 0 failed.

- [ ] **Step 9: Lint, format, docs, commit**

Run from the repo root: `uvx ruff@0.15.17 format scripts tools/openburnbar-mcp && uvx ruff@0.15.17 check scripts tools/openburnbar-mcp`. Update the design doc module map and the README sentence. Commit:

```bash
git add -A tools/openburnbar-mcp/memory_engine tools/openburnbar-mcp/memory_engine.py tools/openburnbar-mcp/tests docs/superpowers/2026-09-02-memory-mcp-v2-design.md tools/openburnbar-mcp/README.md
git commit -m "refactor(memory-mcp): split memory_engine into a package with a facade; versioned store migrations

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Automatic collection from Claude Code sessions

**Files:**
- Create: `tools/openburnbar-mcp/memorize_transcript.py`, `tools/openburnbar-mcp/hooks/claude-code-session-end.sh` (executable), `tools/openburnbar-mcp/tests/fixtures/claude_code_transcript.jsonl`
- Modify: `tools/openburnbar-mcp/README.md` (new section "Automatic collection from Claude Code sessions", placed after the setup sections), `tools/openburnbar-mcp/SKILL.md` (one row/line pointing at the hook), `docs/superpowers/2026-09-02-memory-mcp-v2-design.md` (new § "Automatic collection")
- Test: `tools/openburnbar-mcp/tests/test_memorize_transcript.py`

**Interfaces:**
- Consumes: `server.burnbar_memorize(messages=..., project_path=..., source_kind=..., source_ref=..., metadata=...) -> str` (JSON string; read its docstring in `server.py` for the response shape), `server` module loading as done by `_load_server()` in `tests/test_local_mcp_policy.py`, the env block in `tests/test_mcp_stdio_smoke.py`.
- Produces: `memorize_transcript.load_transcript(path) -> list[dict[str, str]]`, `memorize_transcript.memorize(*, transcript_path, project_path, session_id, reason, budget_seconds, env) -> dict`, `memorize_transcript.main(argv) -> int`, the hook script contract below.

Facts about the hook (current Claude Code docs): `SessionEnd` fires once per session; stdin JSON is `{"session_id", "transcript_path", "cwd", "hook_event_name": "SessionEnd", "reason"}` with `reason` in `clear|resume|logout|prompt_input_exit|other`; the hook cannot block; a `timeout` of up to 60 seconds may be set per hook; the transcript format is internal and changes between versions, so parsing must be lenient and must never raise.

Transcript lines to keep: objects with `type` in `{"user", "assistant"}` and a `message` object whose `role` is `user` or `assistant`; `message.content` is either a string or a list of blocks, of which only `{"type": "text", "text": "..."}` blocks count. Everything else (tool_use, tool_result, thinking, `type: summary`, `isMeta` lines, malformed JSON, non-object lines) is skipped. Strip wrapper tags `<system-reminder>…</system-reminder>`, `<command-name>…</command-name>`, `<command-message>…</command-message>`, `<command-args>…</command-args>`, `<local-command-stdout>…</local-command-stdout>`, `<local-command-stderr>…</local-command-stderr>` (DOTALL) and drop messages that become empty. Keep the tail: at most 400 messages and 200,000 characters.

- [ ] **Step 1: Write the fixture**

`tests/fixtures/claude_code_transcript.jsonl` (one JSON object per line; include exactly these shapes):
1. `{"type":"summary","summary":"old session","leafUuid":"x"}`
2. user string content: `We decided to use SQLCipher for the local store because the daemon already links it.`
3. assistant blocks: one `text` block `Agreed. I'll keep the AES-256-GCM row encryption and use SQLCipher only for the daemon mirror.` and one `tool_use` block.
4. user with a `tool_result` block only (must be skipped).
5. user string content wrapped in `<system-reminder>…</system-reminder>` around the text `ignore this reminder` (must be dropped entirely).
6. assistant text containing a GitHub token shape `ghp_` followed by 36 alphanumerics, plus the sentence `Prefer ruff over black for formatting in this repo.`
7. a malformed line: `{not json`
8. an assistant line with `isMeta: true` and text `meta noise` (must be skipped).

- [ ] **Step 2: Write the failing tests**

`tests/test_memorize_transcript.py`:

```python
"""The SessionEnd memorizer turns a Claude Code transcript into gated, deduplicated memories and never blocks."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

MCP_DIR = Path(__file__).resolve().parents[1]
FIXTURE = MCP_DIR / "tests" / "fixtures" / "claude_code_transcript.jsonl"
HOOK = MCP_DIR / "hooks" / "claude-code-session-end.sh"
sys.path.insert(0, str(MCP_DIR))

import memorize_transcript as mt  # noqa: E402


def _isolated_env(tmp_path: Path) -> dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "BURNBAR_MCP_TOOLSET": "memory",
            "OPENBURNBAR_MEMORY_DB_PATH": str(tmp_path / "memory.sqlite"),
            "BURNBAR_DB_PATH": str(tmp_path / "app.sqlite"),
            "OPENBURNBAR_MEMORY_EMBEDDING_PROVIDER": "none",
            "OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT": "true",
            "OPENBURNBAR_DAEMON_SOCKET_PATH": str(tmp_path / "missing.sock"),
            "OPENBURNBAR_MEMORY_PYTHON": sys.executable,
        }
    )
    env.pop("OPENBURNBAR_MEMORY_SESSION_HOOK", None)
    return env


def test_load_transcript_keeps_only_user_and_assistant_text():
    messages = mt.load_transcript(FIXTURE)
    roles = [m["role"] for m in messages]
    assert roles == ["user", "assistant", "assistant"]
    joined = "\n".join(m["content"] for m in messages)
    assert "SQLCipher" in joined
    assert "ignore this reminder" not in joined
    assert "meta noise" not in joined
    assert "tool_result" not in joined


def test_trim_keeps_the_tail():
    messages = [{"role": "user", "content": f"m{i}"} for i in range(10)]
    assert [m["content"] for m in mt.trim_messages(messages, max_messages=3, max_chars=10_000)] == ["m7", "m8", "m9"]
    assert mt.trim_messages(messages, max_messages=10, max_chars=5)[-1]["content"] == "m9"


def _run_cli(tmp_path: Path, payload: dict, env: dict[str, str]) -> dict:
    result = subprocess.run(
        [sys.executable, str(MCP_DIR / "memorize_transcript.py"), "--hook-stdin"],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        cwd=str(tmp_path),
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


def _memory_bodies(env: dict[str, str]) -> list[str]:
    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        listing = engine.list(project_path=None, scope=None)  # adapt to the real signature; every memory, every scope
    finally:
        engine.close()
    return [item["body"] for item in listing["memories"]]


def test_hook_payload_memorizes_gated_facts_once(tmp_path):
    env = _isolated_env(tmp_path)
    project = tmp_path / "project"
    project.mkdir()
    payload = {
        "session_id": "sess-1",
        "transcript_path": str(FIXTURE),
        "cwd": str(project),
        "hook_event_name": "SessionEnd",
        "reason": "other",
    }
    first = _run_cli(tmp_path, payload, env)
    assert first["status"] == "memorized"
    bodies = _memory_bodies(env)
    assert any("SQLCipher" in body for body in bodies)
    assert not any("ghp_" in body for body in bodies)
    second = _run_cli(tmp_path, payload, env)
    assert second["status"] in {"memorized", "already_ingested"}
    assert len(_memory_bodies(env)) == len(bodies)


def test_kill_switch_writes_nothing(tmp_path):
    env = _isolated_env(tmp_path)
    env["OPENBURNBAR_MEMORY_SESSION_HOOK"] = "off"
    payload = {"session_id": "s", "transcript_path": str(FIXTURE), "cwd": str(tmp_path), "reason": "clear"}
    assert _run_cli(tmp_path, payload, env)["status"] == "skipped_disabled"
    assert not Path(env["OPENBURNBAR_MEMORY_DB_PATH"]).exists()


def test_missing_transcript_is_reported_not_raised(tmp_path):
    env = _isolated_env(tmp_path)
    payload = {"session_id": "s", "transcript_path": str(tmp_path / "nope.jsonl"), "cwd": str(tmp_path), "reason": "clear"}
    assert _run_cli(tmp_path, payload, env)["status"] == "skipped_missing_transcript"


def test_deadline_turns_a_slow_memorize_into_a_timeout_status(tmp_path, monkeypatch):
    import time

    monkeypatch.setattr(mt, "_memorize_messages", lambda **_: time.sleep(5))
    result = mt.memorize(
        transcript_path=FIXTURE, project_path=str(tmp_path), session_id="s", reason="clear", budget_seconds=1, env=_isolated_env(tmp_path)
    )
    assert result["status"] == "timeout"


@pytest.mark.skipif(sys.platform == "win32", reason="bash hook")
def test_hook_script_runs_the_memorizer_and_exits_zero(tmp_path):
    env = _isolated_env(tmp_path)
    payload = {"session_id": "sess-2", "transcript_path": str(FIXTURE), "cwd": str(tmp_path), "reason": "logout"}
    result = subprocess.run(["bash", str(HOOK)], input=json.dumps(payload), capture_output=True, text=True, env=env, timeout=120, check=False)
    assert result.returncode == 0, result.stderr
    assert any("SQLCipher" in body for body in _memory_bodies(env))
```

Adapt `_memory_bodies` to the engine's real `list` signature and response keys (read `MemoryEngine.list` in the engine); the assertion stays "every memory body across scopes".

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `.venv/bin/python -m pytest tests/test_memorize_transcript.py -q`
Expected: import error (`memorize_transcript` missing).

- [ ] **Step 4: Implement `memorize_transcript.py`**

```python
#!/usr/bin/env python3
"""Memorize a Claude Code session transcript into the local OpenBurnBar memory store.

Runs from the SessionEnd hook (`hooks/claude-code-session-end.sh`) or by hand. It reuses the
server's `burnbar_memorize` wrapper so the secret/PII gate, encryption, audit chain, and daemon
mirror behave exactly as they do for the MCP tool. It never blocks session end: every outcome is
one JSON line on stdout and exit code 0 (2 only for a usage error).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
from pathlib import Path
from typing import Any

HOOK_ENV = "OPENBURNBAR_MEMORY_SESSION_HOOK"
MAX_MESSAGES = 400
MAX_TRANSCRIPT_CHARS = 200_000
DEFAULT_BUDGET_SECONDS = 20
WRAPPER_TAGS = ("system-reminder", "command-name", "command-message", "command-args", "local-command-stdout", "local-command-stderr")
_WRAPPER_RE = re.compile("|".join(rf"<{tag}>.*?</{tag}>" for tag in WRAPPER_TAGS), re.DOTALL)
_DISABLED = {"0", "off", "false", "no", "disabled"}


class _Deadline(TimeoutError):
    pass


def hook_disabled(env: dict[str, str]) -> bool:
    return env.get(HOOK_ENV, "").strip().lower() in _DISABLED


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"]
        return "\n".join(part for part in parts if isinstance(part, str))
    return ""


def load_transcript(path: Path) -> list[dict[str, str]]:
    messages: list[dict[str, str]] = []
    with Path(path).open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("type") not in {"user", "assistant"} or entry.get("isMeta"):
                continue
            message = entry.get("message")
            if not isinstance(message, dict) or message.get("role") not in {"user", "assistant"}:
                continue
            text = _WRAPPER_RE.sub("", _text_of(message.get("content"))).strip()
            if text:
                messages.append({"role": message["role"], "content": text})
    return messages


def trim_messages(messages: list[dict[str, str]], *, max_messages: int = MAX_MESSAGES, max_chars: int = MAX_TRANSCRIPT_CHARS) -> list[dict[str, str]]:
    kept = list(messages[-max_messages:])
    total = sum(len(m["content"]) for m in kept)
    while kept and total > max_chars:
        total -= len(kept.pop(0)["content"])
    return kept


def _memorize_messages(*, messages, project_path, session_id, reason, env) -> dict[str, Any]:
    os.environ.update({k: v for k, v in env.items() if k.startswith(("OPENBURNBAR_", "BURNBAR_"))})
    os.environ.setdefault("BURNBAR_MCP_TOOLSET", "memory")
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import server  # noqa: PLC0415 — deferred: loading FastMCP is only worth it once we know there is work

    raw = server.burnbar_memorize(
        messages=messages,
        project_path=project_path,
        source_kind="session",
        source_ref=f"claude-code:{session_id}",
        metadata={"hook": "SessionEnd", "reason": reason, "sessionId": session_id},
    )
    return json.loads(raw)


def memorize(*, transcript_path, project_path, session_id, reason, budget_seconds=DEFAULT_BUDGET_SECONDS, env=None) -> dict[str, Any]:
    env = dict(os.environ if env is None else env)
    if hook_disabled(env):
        return {"status": "skipped_disabled"}
    path = Path(transcript_path)
    if not path.is_file():
        return {"status": "skipped_missing_transcript", "transcriptPath": str(path)}
    messages = trim_messages(load_transcript(path))
    if not messages:
        return {"status": "skipped_empty"}

    def _alarm(_signum, _frame):
        raise _Deadline()

    previous = signal.signal(signal.SIGALRM, _alarm)
    signal.setitimer(signal.ITIMER_REAL, budget_seconds)
    try:
        result = _memorize_messages(messages=messages, project_path=project_path, session_id=session_id, reason=reason, env=env)
    except _Deadline:
        return {"status": "timeout", "budgetSeconds": budget_seconds, "messages": len(messages)}
    except Exception as exc:  # noqa: BLE001 — a hook must never fail the session; report and exit 0
        return {"status": "error", "error": f"{type(exc).__name__}: {exc}"}
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    status = "memorized" if result.get("status") in {"ok", "memorized"} else result.get("status", "memorized")
    return {"status": status, "messages": len(messages), "result": result}
```

Then `main(argv)`: `--hook-stdin` reads the JSON payload from stdin (`session_id`, `transcript_path`, `cwd`, `reason`), otherwise `--transcript`, `--project`, `--session-id`, `--reason` flags; `--budget-seconds` (default 20). Prints `json.dumps(result)` as one line and returns 0; usage errors return 2. Map the server's real response status to `memorized` / `already_ingested` after reading the `burnbar_memorize` docstring (the test accepts either for the second run and requires `memorized` for the first).

- [ ] **Step 5: Implement the hook script**

`hooks/claude-code-session-end.sh`:

```bash
#!/usr/bin/env bash
# Claude Code SessionEnd hook: memorize the session transcript into the local OpenBurnBar memory store.
# Reads the hook JSON on stdin. Never blocks session end: always exits 0.
set -u
case "${OPENBURNBAR_MEMORY_SESSION_HOOK:-on}" in 0|off|false|no|disabled) exit 0 ;; esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$(cd "$HERE/.." && pwd)"
PY="${OPENBURNBAR_MEMORY_PYTHON:-$MCP_DIR/.venv/bin/python}"
if [ ! -x "$PY" ]; then
  "$MCP_DIR/bootstrap-memory.sh" >/dev/null 2>&1 || exit 0
  PY="$MCP_DIR/.venv/bin/python"
fi
[ -x "$PY" ] || exit 0
LOG="${OPENBURNBAR_MEMORY_SESSION_HOOK_LOG:-/dev/null}"
"$PY" "$MCP_DIR/memorize_transcript.py" --hook-stdin >>"$LOG" 2>&1 || true
exit 0
```

`chmod +x hooks/claude-code-session-end.sh`.

- [ ] **Step 6: Run the tests**

Run: `.venv/bin/python -m pytest tests/test_memorize_transcript.py -q`
Expected: 7 passed, no warnings.

- [ ] **Step 7: Docs**

README section "Automatic collection from Claude Code sessions": what it does, the exact snippet below, the privacy paragraph (local only; same gate; secrets redacted; encrypted at rest; audit event per run; `OPENBURNBAR_MEMORY_SESSION_HOOK=off` disables; `OPENBURNBAR_MEMORY_SESSION_HOOK_LOG=<file>` keeps a log), and idempotency. SKILL.md: one line. Design doc: § "Automatic collection" (summarize the contract).

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR/tools/openburnbar-mcp/hooks/claude-code-session-end.sh\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 8: Full suite, lint, commit**

Run the full suite (expected: baseline + 7, 0 failed), then `uvx ruff@0.15.17 format` and `check` from the repo root. Commit:

```bash
git add tools/openburnbar-mcp/memorize_transcript.py tools/openburnbar-mcp/hooks tools/openburnbar-mcp/tests/fixtures tools/openburnbar-mcp/tests/test_memorize_transcript.py tools/openburnbar-mcp/README.md tools/openburnbar-mcp/SKILL.md docs/superpowers/2026-09-02-memory-mcp-v2-design.md
git commit -m "feat(memory-mcp): memorize Claude Code sessions automatically from a SessionEnd hook

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Measured extraction quality and an adversarial gate suite

**Files:**
- Create: `tools/openburnbar-mcp/eval/extraction_gold.json`, `tools/openburnbar-mcp/tests/test_gate_adversarial.py`, `tools/openburnbar-mcp/tests/test_eval_extraction.py`
- Modify: `tools/openburnbar-mcp/eval_memory.py` (add `--extraction` and `--gate` modes; keep the retrieval mode and its flags unchanged), `tools/openburnbar-mcp/README.md` (the "Quality" bullets gain the extraction recall and the gate matrix pointer), `docs/superpowers/2026-09-02-memory-mcp-v2-design.md` (§ "Evaluation": the measured numbers)
- Test: the two new test files

**Interfaces:**
- Consumes: `me.scan_text(text, pii_policy="keep") -> GateFindings` (read its fields in the engine), `me.heuristic_extract` (read its signature in the engine), `me.MemoryEngine.open(db_path=...)`, `me.EngineConfig(secret_policy=..., pii_policy=..., retain_allowed=...)`, the engine's `remember`, `get`, `recall`, `pack`, `export`, `history`, `list`, audit-trail and vault methods (read their names in `server.py`'s tool wrappers).
- Produces: `eval_memory.run_extraction(gold_path) -> dict` with keys `cases`, `expected`, `hits`, `recall`, `precision`, `emptyCaseFacts`, `leaks`; `eval_memory.run_gate_matrix() -> list[dict]` with keys `shape`, `raw`, `base64`, `hex`, `urlencoded` (booleans).

Gold set format (`eval/extraction_gold.json`):

```json
{
  "cases": [
    {
      "id": "sqlcipher-decision",
      "messages": [
        {"role": "user", "content": "Should the daemon mirror use SQLCipher or plain SQLite?"},
        {"role": "assistant", "content": "We decided to use SQLCipher for the daemon mirror because the daemon already links it."}
      ],
      "expected": [{"keywords": ["SQLCipher", "daemon mirror"]}],
      "forbidden": []
    },
    {
      "id": "chit-chat",
      "messages": [{"role": "user", "content": "thanks, that's all for today"}, {"role": "assistant", "content": "You're welcome. Have a good evening."}],
      "expected": [],
      "forbidden": []
    }
  ]
}
```

At least 20 cases with expected facts across decisions, preferences, architecture facts, procedures, constraints, ownership, and bug root causes, written as realistic developer conversations (2–6 messages each), and at least 5 cases with `expected: []` (chat, transient debugging noise, tool output). At least 3 cases carry a secret shape in `messages` and list its prefix in `forbidden`.

Scoring: an expected fact is a hit when one extracted fact body contains every keyword (case-insensitive). `recall = hits / expected`. `precision = facts matching some expected / facts extracted over cases with expected facts`. `emptyCaseFacts = facts extracted over empty cases`. `leaks = forbidden strings found in any extracted fact`.

- [ ] **Step 1: Write the failing eval test**

`tests/test_eval_extraction.py`:

```python
"""The heuristic extractor's quality is a measured, ratcheting number."""

from __future__ import annotations

import sys
from pathlib import Path

MCP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MCP_DIR))

import eval_memory  # noqa: E402

GOLD = MCP_DIR / "eval" / "extraction_gold.json"
RECALL_FLOOR = 0.70  # set to the measured value rounded down to 0.05 in Step 4; never lower it


def test_gold_set_is_large_enough_to_mean_something():
    report = eval_memory.run_extraction(GOLD)
    assert report["cases"] >= 25
    assert report["expected"] >= 20


def test_heuristic_extraction_meets_the_floor_and_leaks_nothing():
    report = eval_memory.run_extraction(GOLD)
    assert report["recall"] >= RECALL_FLOOR, report
    assert report["leaks"] == 0, report
    assert report["emptyCaseFacts"] <= 2, report


def test_gate_matrix_detects_every_raw_shape():
    matrix = eval_memory.run_gate_matrix()
    assert len(matrix) >= 12
    assert all(row["raw"] for row in matrix), [row["shape"] for row in matrix if not row["raw"]]
```

- [ ] **Step 2: Write the failing adversarial gate test**

`tests/test_gate_adversarial.py`. Structure (write the real code; this is the contract):

- `SHAPES`: at least 16 candidate secret generators (seeded `random.Random(20260902)`): GitHub `ghp_`/`github_pat_` tokens, AWS access key id `AKIA…` with a secret, Slack `xoxb-`, OpenAI `sk-…`, Anthropic `sk-ant-…`, Stripe `sk_live_…`, Google `AIza…`, a JWT, a PEM private key block, a `postgres://user:pass@host/db` URL, a `Bearer` header, a `.npmrc` `_authToken`, a SendGrid `SG.` key, a Twilio `SK…` key, a generic `password=…` assignment, an SSH private key header.
- `detected_shapes()`: keep only shapes where `me.scan_text(shape_text).labels` (or the real field) is non-empty; the module-level `assert len(detected) >= 12` is a test (`test_the_corpus_detects_enough_shapes_for_this_suite_to_have_teeth`).
- `CONTEXTS`: prose middle, prose end, `key: <token>` line, inside a fenced code block, as a tag value, as an entity, as a metadata value, as `source_ref`.
- `test_redact_policy_leaves_no_surface_with_the_raw_token(tmp_path)`: for every detected shape × context, `remember` under `EngineConfig(secret_policy="redact")`, then assert the token is absent from: the write result, `get`, `list`, `recall(query=<a word from the prose>)` bodies and snippets, `pack`, `export`, `history`, the audit trail, and `Path(db).read_bytes()` (also check the `-wal` file if present). Use `pytest.mark.parametrize` over contexts so failures name the surface.
- `test_reject_policy_refuses_every_detected_shape(tmp_path)`: `EngineConfig(secret_policy="reject")` → status `rejected` (read the real status/code names in the engine) and no row written.
- `test_retain_policy_keeps_the_verbatim_token_only_in_the_vault(tmp_path)`: `EngineConfig(secret_policy="retain", retain_allowed=True)` → the vault read returns the verbatim token, the memory body does not contain it, and the DB file bytes do not contain it.
- No network, no Ollama: `OPENBURNBAR_MEMORY_EMBEDDING_PROVIDER=none` via `monkeypatch.setenv`, `MEMORY_KEY_ENV` set to a fixed hex key.

- [ ] **Step 3: Run both test files to confirm they fail**

Run: `.venv/bin/python -m pytest tests/test_eval_extraction.py tests/test_gate_adversarial.py -q`
Expected: failures (`run_extraction` missing; gold set missing).

- [ ] **Step 4: Implement the gold set and the eval modes**

In `eval_memory.py` add `run_extraction(gold_path: Path) -> dict` and `run_gate_matrix() -> list[dict]` (base64 via `base64.b64encode`, hex via `.hex()`, URL-encoding via `urllib.parse.quote`), and the flags `--extraction [--gold PATH]` and `--gate`, printing a table (and JSON with the existing `--json`). Run `.venv/bin/python eval_memory.py --extraction --provider none` and record the measured recall; set `RECALL_FLOOR` to that value rounded down to a multiple of 0.05 (for example 0.78 → 0.75). Put the measured number and the floor in your report. If recall is below 0.60, stop and report DONE_WITH_CONCERNS with the misses listed: the gold set may be too hard or the extractor may need work, and that is a decision for the controller, not a reason to soften the gold set.

- [ ] **Step 5: Run the tests**

Run: `.venv/bin/python -m pytest tests/test_eval_extraction.py tests/test_gate_adversarial.py -q`
Expected: all passed, no warnings, under 60 seconds total.

- [ ] **Step 6: Docs, full suite, lint, commit**

README "Quality" bullets: extraction recall (the number), the floor, `eval_memory.py --extraction` and `--gate` usage. Design doc § "Evaluation": the same numbers. Full suite: baseline + new tests, 0 failed. Ruff format and check from the repo root. Commit:

```bash
git add tools/openburnbar-mcp/eval tools/openburnbar-mcp/eval_memory.py tools/openburnbar-mcp/tests/test_gate_adversarial.py tools/openburnbar-mcp/tests/test_eval_extraction.py tools/openburnbar-mcp/README.md docs/superpowers/2026-09-02-memory-mcp-v2-design.md
git commit -m "test(memory-mcp): measured extraction quality and an adversarial secret-gate suite

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Integration (controller)

Merge order: Task 1, then Task 2, then Task 3 onto `chore/memory-mcp-ten-of-ten`. Expected conflicts: `README.md` and the v2 design doc (three tasks add sections; keep all three). After merging: full suite, ruff, `bash bootstrap-memory.test.sh`, `tests/test_mcp_stdio_smoke.py`, the retrieval eval (`eval_memory.py --provider auto`, expected hybrid R@5 0.90 / MRR 0.678), all `scripts/debt/check-*-budget.sh`, then the final whole-branch review.
