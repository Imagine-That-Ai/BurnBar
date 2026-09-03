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
