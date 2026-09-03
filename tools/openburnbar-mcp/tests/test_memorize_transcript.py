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
