"""The SessionEnd memorizer turns a Claude Code transcript into gated, deduplicated memories and never blocks."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from memorize_transcript import _KNOWN_CODES, _KNOWN_EXTRACTORS, _KNOWN_STATUSES  # noqa: E402

MCP_DIR = Path(__file__).resolve().parents[1]
FIXTURE = MCP_DIR / "tests" / "fixtures" / "claude_code_transcript.jsonl"
HOOK = MCP_DIR / "hooks" / "claude-code-session-end.sh"
PLACEHOLDER = "{{secret:github_pat}}"
if str(MCP_DIR) not in sys.path:
    sys.path.insert(0, str(MCP_DIR))

import eval_memory  # noqa: E402
import memorize_transcript as mt  # noqa: E402


def _expanded_fixture(tmp_path: Path) -> tuple[Path, str]:
    """A runnable copy of the fixture, plus the credential it now carries.

    The committed fixture holds `{{secret:github_pat}}` rather than a token: a
    credential-shaped literal in the repo trips the repo's own secret scanners.
    The expansion uses `eval_memory.SECRET_SHAPES`, the same seeded generator the
    extraction gold set uses, so the gate still sees a real GitHub token shape.
    """
    raw = FIXTURE.read_text(encoding="utf-8")
    assert PLACEHOLDER in raw, "the fixture must carry the placeholder, not a literal token"
    token = eval_memory.SECRET_SHAPES["github_pat"]
    target = tmp_path / "claude_code_transcript.jsonl"
    target.write_text(eval_memory._expand_secrets(raw), encoding="utf-8")
    assert token in target.read_text(encoding="utf-8")
    return target, token


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
    for name in list(env):
        if name.startswith("OPENBURNBAR_LOCAL_MCP_ENABLE_") or name == "OPENBURNBAR_LOCAL_MCP_PROFILE":
            env.pop(name)
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
        bodies: list[str] = []
        page = 1
        while True:
            listing = engine.list(
                project_path=None,
                scope="all",
                include_cross_project=True,
                page=page,
                page_size=200,
            )
            bodies.extend(str(item["body"]) for item in listing["results"])
            if len(bodies) >= int(listing["total"]) or not listing["results"]:
                return bodies
            page += 1
    finally:
        engine.close()


def test_hook_payload_memorizes_gated_facts_once(tmp_path):
    env = _isolated_env(tmp_path)
    transcript, token = _expanded_fixture(tmp_path)
    project = tmp_path / "project"
    project.mkdir()
    payload = {
        "session_id": "sess-1",
        "transcript_path": str(transcript),
        "cwd": str(project),
        "hook_event_name": "SessionEnd",
        "reason": "other",
    }
    first = _run_cli(tmp_path, payload, env)
    assert first["status"] == "memorized"
    bodies = _memory_bodies(env)
    assert any("SQLCipher" in body for body in bodies)
    # The token reached the gate and came back redacted, not merely absent.
    assert not any(token in body for body in bodies)
    assert not any("ghp_" in body for body in bodies)
    assert any("[REDACTED:GitHub token detected]" in body for body in bodies), bodies
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
    payload = {
        "session_id": "s",
        "transcript_path": str(tmp_path / "nope.jsonl"),
        "cwd": str(tmp_path),
        "reason": "clear",
    }
    assert _run_cli(tmp_path, payload, env)["status"] == "skipped_missing_transcript"


def test_memorize_messages_leaves_the_process_environment_as_it_found_it(tmp_path, monkeypatch):
    """The CLI runs as its own process, but `_memorize_messages` is importable: an
    in-process caller owns its `os.environ` and must get it back unchanged."""
    env = _isolated_env(tmp_path)
    monkeypatch.setenv("OPENBURNBAR_MEMORY_DB_PATH", str(tmp_path / "outer.sqlite"))
    monkeypatch.delenv("OPENBURNBAR_MEMORY_SESSION_HOOK", raising=False)
    monkeypatch.delenv("OPENBURNBAR_DAEMON_SOCKET_PATH", raising=False)
    before = dict(os.environ)

    result = mt._memorize_messages(
        messages=[{"role": "user", "content": "We decided to keep the memory store local-only."}],
        project_path=str(tmp_path),
        session_id="sess-env",
        reason="clear",
        env=env,
    )

    assert result.get("status") == "ok", result
    assert dict(os.environ) == before
    # The write went to the env that was passed in, not to the caller's.
    assert Path(env["OPENBURNBAR_MEMORY_DB_PATH"]).exists()
    assert not (tmp_path / "outer.sqlite").exists()


def test_deadline_turns_a_slow_memorize_into_a_timeout_status(tmp_path, monkeypatch):
    import time

    monkeypatch.setattr(mt, "_memorize_messages", lambda **_: time.sleep(5))
    result = mt.memorize(
        transcript_path=FIXTURE,
        project_path=str(tmp_path),
        session_id="s",
        reason="clear",
        budget_seconds=1,
        env=_isolated_env(tmp_path),
    )
    assert result["status"] == "timeout"


@pytest.mark.skipif(sys.platform == "win32", reason="bash hook")
def test_hook_script_runs_the_memorizer_and_exits_zero(tmp_path):
    env = _isolated_env(tmp_path)
    transcript, token = _expanded_fixture(tmp_path)
    payload = {"session_id": "sess-2", "transcript_path": str(transcript), "cwd": str(tmp_path), "reason": "logout"}
    result = subprocess.run(
        ["bash", str(HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    bodies = _memory_bodies(env)
    assert any("SQLCipher" in body for body in bodies)
    assert not any(token in body for body in bodies)


def _synthetic_transcript(path: Path, turns: int) -> Path:
    """A transcript far larger than the tail the memorizer keeps."""
    with path.open("w", encoding="utf-8") as handle:
        for index in range(turns):
            entry = {
                "type": "user" if index % 2 == 0 else "assistant",
                "message": {
                    "role": "user" if index % 2 == 0 else "assistant",
                    "content": f"turn-{index} " + ("filler " * 40),
                },
            }
            handle.write(json.dumps(entry) + "\n")
    return path


def test_load_transcript_keeps_only_a_bounded_tail(tmp_path):
    """A multi-gigabyte transcript must not be materialized in full before the
    tail is taken: the reader keeps only what `trim_messages` could ever use."""
    transcript = _synthetic_transcript(tmp_path / "big.jsonl", turns=mt.MAX_MESSAGES * 3)
    messages = mt.load_transcript(transcript)
    assert len(messages) == mt.MAX_MESSAGES
    assert messages[-1]["content"].startswith(f"turn-{mt.MAX_MESSAGES * 3 - 1} ")
    assert messages[0]["content"].startswith(f"turn-{mt.MAX_MESSAGES * 2} ")
    # The char budget is still `trim_messages`'s to enforce, unchanged.
    trimmed = mt.trim_messages(messages, max_messages=mt.MAX_MESSAGES, max_chars=1_000)
    assert 0 < sum(len(m["content"]) for m in trimmed) <= 1_000


def test_the_deadline_covers_reading_the_transcript(tmp_path, monkeypatch):
    """The budget was armed after `load_transcript`, so a pathological transcript
    could hold session end open for as long as it took to read."""
    import time

    def _slow_load(_path, **_kwargs):
        time.sleep(5)
        return [{"role": "user", "content": "never reached"}]

    monkeypatch.setattr(mt, "load_transcript", _slow_load)
    started = time.monotonic()
    result = mt.memorize(
        transcript_path=FIXTURE,
        project_path=str(tmp_path),
        session_id="s",
        reason="clear",
        budget_seconds=1,
        env=_isolated_env(tmp_path),
    )
    assert result["status"] == "timeout", result
    assert time.monotonic() - started < 4, "the deadline must fire during the read, not after it"


@pytest.mark.parametrize(
    ("result", "expected"),
    [
        ({"status": "ok", "code": "ALREADY_INGESTED", "decisions": []}, "already_ingested"),
        ({"status": "ok", "factsConsidered": 0, "summary": {}, "decisions": []}, "skipped_no_facts"),
        (
            {
                "status": "ok",
                "factsConsidered": 2,
                "summary": {"ADD": 0, "UPDATE": 0, "NONE": 0, "DELETE": 0, "REJECT": 2},
                "decisions": [{"event": "REJECT", "code": "SECRET_DETECTED"}, {"event": "REJECT"}],
                "receiptStored": False,
            },
            "rejected",
        ),
        (
            {
                "status": "ok",
                "factsConsidered": 1,
                "summary": {"ADD": 1, "UPDATE": 0, "NONE": 0, "DELETE": 0, "REJECT": 0},
                "decisions": [{"event": "ADD", "memoryID": "m1"}],
                "receiptStored": True,
            },
            "memorized",
        ),
        (
            # A reinforcement reports NONE and still touched the row.
            {
                "status": "ok",
                "factsConsidered": 1,
                "summary": {"ADD": 0, "UPDATE": 0, "NONE": 1, "DELETE": 0, "REJECT": 0},
                "decisions": [{"event": "NONE", "memoryID": "m1", "reason": "duplicate"}],
                "receiptStored": True,
            },
            "memorized",
        ),
        (
            # A NONE that wrote nothing: the duplicate was blocked in review.
            {
                "status": "ok",
                "factsConsidered": 1,
                "summary": {"ADD": 0, "UPDATE": 0, "NONE": 1, "DELETE": 0, "REJECT": 0},
                "decisions": [{"event": "NONE", "code": "PREVIOUSLY_REJECTED", "memoryID": "m1"}],
                "receiptStored": True,
            },
            "rejected",
        ),
        ({"status": "rejected", "code": "AUX_TOO_LARGE", "decisions": []}, "rejected"),
        ({"status": "skipped_empty"}, "skipped_empty"),
    ],
)
def test_cli_status_reports_what_actually_landed(result, expected):
    """`memorized` used to be reported for a run that extracted nothing and for one
    whose every fact the gate refused."""
    assert mt._cli_status(result) == expected


def _keys(value, found=None):
    out = [] if found is None else found
    if isinstance(value, dict):
        for key, item in value.items():
            out.append(key)
            _keys(item, out)
    elif isinstance(value, list):
        for item in value:
            _keys(item, out)
    return out


def _leaves(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from _leaves(item)
    elif isinstance(value, list):
        for item in value:
            yield from _leaves(item)
    else:
        yield value


def test_the_printed_line_carries_no_memory_text(tmp_path):
    """The hook appends stdout to a log file, so the line must be a receipt, not
    a copy of what was memorized (CodeQL: clear-text logging of sensitive info)."""
    env = _isolated_env(tmp_path)
    transcript, token = _expanded_fixture(tmp_path)
    project = tmp_path / "project"
    project.mkdir()
    payload = {
        "session_id": "sess-redact",
        "transcript_path": str(transcript),
        "cwd": str(project),
        "reason": "other",
    }
    printed = _run_cli(tmp_path, payload, env)
    assert printed["status"] == "memorized", printed
    blob = json.dumps(printed)
    assert token not in blob
    assert "SQLCipher" not in blob, printed
    assert "REDACTED" not in blob, printed
    assert not {"text", "body", "messagesContent"} & set(_keys(printed)), _keys(printed)
    # The receipt still says enough to be useful.
    assert printed["result"]["factsConsidered"] >= 1, printed
    assert printed["result"]["summary"]["ADD"] >= 1, printed
    assert printed["result"]["sourceHashPresent"] is True, printed
    assert printed["result"]["decisions"]["ADD"] >= 1, printed
    # Every printed leaf is a count, a flag, or a vocabulary constant — never a copied string.
    for value in _leaves(printed):
        assert (
            isinstance(value, bool | int | float)
            or value is None
            or value in (*_KNOWN_STATUSES, *_KNOWN_CODES, *_KNOWN_EXTRACTORS, "other", "none")
        ), value


FIXTURE_CURSOR = MCP_DIR / "tests" / "fixtures" / "cursor_transcript.jsonl"
FIXTURE_CODEX = MCP_DIR / "tests" / "fixtures" / "codex_transcript.jsonl"
FIXTURE_HERMES = MCP_DIR / "tests" / "fixtures" / "hermes_transcript.json"
FIXTURE_GROK = MCP_DIR / "tests" / "fixtures" / "grok_transcript.jsonl"


def _quarantined_memories(env: dict[str, str], project_path: str) -> list[dict]:
    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        listing = engine.list(
            project_path=project_path,
            scope="all",
            include_quarantined=True,
            include_cross_project=True,
            page_size=200,
        )
        return listing["results"]
    finally:
        engine.close()


def test_cursor_transcript_maps_fields_and_lands_quarantined_with_provenance(tmp_path):
    env = _isolated_env(tmp_path)
    project = tmp_path / "cursor_proj"
    project.mkdir()
    session_id = "cursor-sess-001"

    result = mt.memorize(
        transcript_path=FIXTURE_CURSOR,
        project_path=str(project),
        session_id=session_id,
        reason="clear",
        client="cursor",
        env=env,
    )
    assert result["status"] == "memorized", result

    decisions = result["result"]["decisions"]
    assert decisions, "expected decisions from cursor transcript"
    for d in decisions:
        assert d.get("reviewStatus") == "quarantined", d
        assert f"cursor:{session_id}#" in d.get("sourceRef", ""), d

    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        # Default approved listing excludes quarantined memories
        default_list = engine.list(project_path=str(project), scope="all", review_status="approved")
        assert len(default_list["results"]) == 0

        # Quarantined list contains all extracted rows
        quarantined = engine.list(project_path=str(project), scope="all", review_status="quarantined")
        assert len(quarantined["results"]) >= 1
        bodies = [m["body"] for m in quarantined["results"]]
        for row in quarantined["results"]:
            assert row["reviewStatus"] == "quarantined"
            assert row["sourceRef"].startswith(f"cursor:{session_id}#")
            assert row["metadata"].get("client") == "cursor"
            assert row["metadata"].get("source_tool") == "memorize_transcript"
            assert row["metadata"].get("sessionId") == session_id

        # Field mapping assertions: prose extracted, system and tool noise ignored
        assert any("daemon socket" in b for b in bodies), bodies
        assert not any("coding assistant" in b for b in bodies)
        assert not any("grep_search" in b for b in bodies)
        assert not any("Found daemon socket" in b for b in bodies)
    finally:
        engine.close()


def test_codex_transcript_maps_fields_and_lands_quarantined_with_provenance(tmp_path):
    env = _isolated_env(tmp_path)
    project = tmp_path / "codex_proj"
    project.mkdir()
    session_id = "codex-sess-002"

    result = mt.memorize(
        transcript_path=FIXTURE_CODEX,
        project_path=str(project),
        session_id=session_id,
        reason="clear",
        client="codex",
        env=env,
    )
    assert result["status"] == "memorized", result

    decisions = result["result"]["decisions"]
    assert decisions, "expected decisions from codex transcript"
    for d in decisions:
        assert d.get("reviewStatus") == "quarantined", d
        assert f"codex:{session_id}#" in d.get("sourceRef", ""), d

    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        default_list = engine.list(project_path=str(project), scope="all", review_status="approved")
        assert len(default_list["results"]) == 0

        quarantined = engine.list(project_path=str(project), scope="all", review_status="quarantined")
        assert len(quarantined["results"]) >= 1
        bodies = [m["body"] for m in quarantined["results"]]
        for row in quarantined["results"]:
            assert row["reviewStatus"] == "quarantined"
            assert row["sourceRef"].startswith(f"codex:{session_id}#")
            assert row["metadata"].get("client") == "codex"
            assert row["metadata"].get("source_tool") == "memorize_transcript"
            assert row["metadata"].get("sessionId") == session_id

        # Field mapping assertions: prose extracted, tool and meta events dropped.
        # The fixture carries the shape a Codex 0.15x rollout log actually has
        # (`response_item` -> `payload` -> `message`), so a regression to the
        # non-current `payload.item` reading fails here as `skipped_empty`.
        assert any("local-only" in b for b in bodies), bodies
        assert not any("session_meta" in b for b in bodies)
        assert not any("Codex, an agent" in b for b in bodies), bodies
        assert not any("Database path checked" in b for b in bodies)
    finally:
        engine.close()


def test_hermes_transcript_maps_fields_and_lands_quarantined_with_provenance(tmp_path):
    env = _isolated_env(tmp_path)
    project = tmp_path / "hermes_proj"
    project.mkdir()
    session_id = "hermes-sess-003"

    result = mt.memorize(
        transcript_path=FIXTURE_HERMES,
        project_path=str(project),
        session_id=session_id,
        reason="clear",
        client="hermes",
        env=env,
    )
    assert result["status"] == "memorized", result

    decisions = result["result"]["decisions"]
    assert decisions, "expected decisions from hermes transcript"
    for d in decisions:
        assert d.get("reviewStatus") == "quarantined", d
        assert f"hermes:{session_id}#" in d.get("sourceRef", ""), d

    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        default_list = engine.list(project_path=str(project), scope="all", review_status="approved")
        assert len(default_list["results"]) == 0

        quarantined = engine.list(project_path=str(project), scope="all", review_status="quarantined")
        assert len(quarantined["results"]) >= 1
        bodies = [m["body"] for m in quarantined["results"]]
        for row in quarantined["results"]:
            assert row["reviewStatus"] == "quarantined"
            assert row["sourceRef"].startswith(f"hermes:{session_id}#")
            assert row["metadata"].get("client") == "hermes"
            assert row["metadata"].get("source_tool") == "memorize_transcript"
            assert row["metadata"].get("sessionId") == session_id

        # Field mapping assertions: prose extracted from messages JSON, tool calls ignored
        assert any("daemon socket" in b or "WAL file" in b for b in bodies), bodies
        assert not any("Socket active" in b for b in bodies)
        assert not any("inspect_socket" in b for b in bodies)
    finally:
        engine.close()


def test_grok_transcript_maps_fields_and_lands_quarantined_with_provenance(tmp_path):
    env = _isolated_env(tmp_path)
    project = tmp_path / "grok_proj"
    project.mkdir()
    session_id = "grok-sess-004"

    result = mt.memorize(
        transcript_path=FIXTURE_GROK,
        project_path=str(project),
        session_id=session_id,
        reason="clear",
        client="grok",
        env=env,
    )
    assert result["status"] == "memorized", result

    decisions = result["result"]["decisions"]
    assert decisions, "expected decisions from grok transcript"
    for d in decisions:
        assert d.get("reviewStatus") == "quarantined", d
        assert f"grok:{session_id}#" in d.get("sourceRef", ""), d

    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        default_list = engine.list(project_path=str(project), scope="all", review_status="approved")
        assert len(default_list["results"]) == 0

        quarantined = engine.list(project_path=str(project), scope="all", review_status="quarantined")
        assert len(quarantined["results"]) >= 1
        bodies = [m["body"] for m in quarantined["results"]]
        for row in quarantined["results"]:
            assert row["reviewStatus"] == "quarantined"
            assert row["sourceRef"].startswith(f"grok:{session_id}#")
            assert row["metadata"].get("client") == "grok"
            assert row["metadata"].get("source_tool") == "memorize_transcript"
            assert row["metadata"].get("sessionId") == session_id

        # Field mapping assertions: chat_history.jsonl prose mapped, tool noise dropped
        assert any("RRF" in b for b in bodies), bodies
        assert not any("Tests finished" in b for b in bodies)
    finally:
        engine.close()


def test_cli_client_flag_runs_collector_and_quarantines(tmp_path):
    env = _isolated_env(tmp_path)
    project = tmp_path / "cli_cursor_proj"
    project.mkdir()
    session_id = "sess-cli-cursor-001"
    result = subprocess.run(
        [
            sys.executable,
            str(MCP_DIR / "memorize_transcript.py"),
            "--transcript",
            str(FIXTURE_CURSOR),
            "--client",
            "cursor",
            "--project",
            str(project),
            "--session-id",
            session_id,
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout.strip().splitlines()[-1])
    assert output["status"] == "memorized"
    assert output["result"]["summary"]["ADD"] >= 1

    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        quarantined = engine.list(project_path=str(project), scope="all", review_status="quarantined")
        assert len(quarantined["results"]) >= 1
        for row in quarantined["results"]:
            assert row["reviewStatus"] == "quarantined"
            assert row["sourceRef"].startswith(f"cursor:{session_id}#")
    finally:
        engine.close()


def test_codex_adapter_reads_the_current_response_item_payload_shape(tmp_path):
    """Codex writes `{"type":"response_item","payload":{"type":"message","role":...}}`.

    The adapter used to look for `payload.item` and fall back to the outer
    envelope, which carries no role, so every user and assistant turn of a real
    session was discarded and the collector reported `skipped_empty`. This is the
    shape a Codex 0.15x rollout log on disk actually has.
    """
    from transcript_adapters.codex import load_codex_transcript

    rollout = tmp_path / "rollout-2026-09-05T03-52-43-01a06fb2.jsonl"
    rollout.write_text(
        "\n".join(
            [
                json.dumps(
                    {
                        "timestamp": "2026-09-05T03:52:51.043Z",
                        "ordinal": 0,
                        "type": "session_meta",
                        "payload": {"session_id": "01a06fb2", "cwd": "/tmp/p", "cli_version": "0.153.3"},
                    }
                ),
                json.dumps(
                    {
                        "timestamp": "2026-09-05T03:52:51.700Z",
                        "ordinal": 4,
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "id": "msg_dev",
                            "role": "developer",
                            "content": [{"type": "input_text", "text": "You are Codex, an agent based on GPT-6."}],
                        },
                    }
                ),
                json.dumps(
                    {
                        "timestamp": "2026-09-05T03:52:51.757Z",
                        "ordinal": 5,
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "id": "msg_user",
                            "role": "user",
                            "content": [{"type": "input_text", "text": "Keep the memory store local-only."}],
                        },
                    }
                ),
                json.dumps(
                    {
                        "timestamp": "2026-09-05T03:52:54.370Z",
                        "ordinal": 12,
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "id": "msg_asst",
                            "role": "assistant",
                            "content": [{"type": "output_text", "text": "Agreed, it stays on-device."}],
                            "phase": "commentary",
                        },
                    }
                ),
                json.dumps(
                    {
                        "type": "response_item",
                        "payload": {"type": "custom_tool_call", "name": "shell", "input": "sqlite3 store.db"},
                    }
                ),
            ]
        ),
        encoding="utf-8",
    )

    messages = load_codex_transcript(rollout)
    assert messages == [
        {"role": "user", "content": "Keep the memory store local-only."},
        {"role": "assistant", "content": "Agreed, it stays on-device."},
    ], messages


def test_collector_forces_quarantine_over_an_approved_request(tmp_path):
    """A capture path files rows for review; it does not grant approval.

    `--review-status approved`, `OPENBURNBAR_MEMORY_DEFAULT_REVIEW_STATUS`, and a
    `claude_code` client used to land rows straight into recall. Nothing a caller
    or an extractor asks for lets an unread, machine-authored row skip
    `burnbar_memory_review`.
    """
    env = _isolated_env(tmp_path)
    env["OPENBURNBAR_MEMORY_DEFAULT_REVIEW_STATUS"] = "approved"
    project = tmp_path / "forced_proj"
    project.mkdir()

    result = mt.memorize(
        transcript_path=FIXTURE_CODEX,
        project_path=str(project),
        session_id="forced-sess",
        reason="clear",
        client="codex",
        review_status="approved",
        env=env,
    )
    assert result["status"] == "memorized", result
    assert [d.get("reviewStatus") for d in result["result"]["decisions"]] != []
    for decision in result["result"]["decisions"]:
        assert decision.get("reviewStatus") == "quarantined", decision

    import memory_engine as me

    engine = me.MemoryEngine.open(db_path=env["OPENBURNBAR_MEMORY_DB_PATH"])
    try:
        assert engine.list(project_path=str(project), scope="all", review_status="approved")["results"] == []
    finally:
        engine.close()
