#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import stat
import sys
import time
import types
import uuid
from pathlib import Path


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import resume_core  # noqa: E402


def _load_server():
    if "mcp.server.fastmcp" not in sys.modules:
        mcp_mod = types.ModuleType("mcp")
        server_mod = types.ModuleType("mcp.server")
        fastmcp_mod = types.ModuleType("mcp.server.fastmcp")

        class _FastMCP:
            def __init__(self, _name: str):
                pass

            def tool(self):
                def decorator(func):
                    return func

                return decorator

            def run(self):
                raise AssertionError("test stub should not run the MCP server")

        fastmcp_mod.FastMCP = _FastMCP
        sys.modules["mcp"] = mcp_mod
        sys.modules["mcp.server"] = server_mod
        sys.modules["mcp.server.fastmcp"] = fastmcp_mod

    spec = importlib.util.spec_from_file_location("openburnbar_mcp_server_resume_test", str(_PARENT / "server.py"))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_resume_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _schema(with_working_dir: bool = True) -> str:
    working_dir_col = ", workingDirectory TEXT" if with_working_dir else ""
    return f"""
    CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        sessionId TEXT NOT NULL,
        projectName TEXT NOT NULL,
        startTime TEXT,
        endTime TEXT,
        messageCount INTEGER NOT NULL DEFAULT 0,
        userWordCount INTEGER NOT NULL DEFAULT 0,
        assistantWordCount INTEGER NOT NULL DEFAULT 0,
        keyFiles TEXT,
        keyCommands TEXT,
        keyTools TEXT,
        inferredTaskTitle TEXT NOT NULL DEFAULT '',
        lastAssistantMessage TEXT NOT NULL DEFAULT '',
        fullText TEXT NOT NULL DEFAULT '',
        indexedAt TEXT NOT NULL,
        fileModifiedAt TEXT,
        summary TEXT,
        conversationSyncedAt TEXT,
        sourceType TEXT NOT NULL DEFAULT 'provider_log',
        logSyncedAt TEXT,
        summaryTitle TEXT,
        summaryUpdatedAt TEXT,
        summaryProvider TEXT,
        summaryModel TEXT,
        summaryAttemptedAt TEXT,
        sourceDeviceId TEXT,
        sourceDeviceName TEXT,
        isRemote INTEGER NOT NULL DEFAULT 0
        {working_dir_col}
    );
    CREATE TABLE search_chunks (
        id TEXT PRIMARY KEY,
        documentID TEXT,
        sourceKind TEXT NOT NULL,
        sourceID TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        messageStartOffset INTEGER,
        messageEndOffset INTEGER,
        sectionPath TEXT,
        text TEXT NOT NULL
    );
    CREATE TABLE token_usage (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        sessionId TEXT NOT NULL,
        projectName TEXT,
        model TEXT,
        inputTokens INTEGER NOT NULL DEFAULT 0,
        outputTokens INTEGER NOT NULL DEFAULT 0,
        cost DOUBLE NOT NULL DEFAULT 0
    );
    """


def _insert_conv(
    conn: sqlite3.Connection,
    *,
    provider: str,
    session_id: str,
    conversation_id: str | None = None,
    title: str = "Refactor auth layer",
    full_text: str = "User asked for auth refactor.\n\nAssistant updated middleware.\n\nNext: add a 401 test.",
    working_directory: str | None = "/tmp/project",
    with_working_dir: bool = True,
) -> str:
    conversation_id = conversation_id or f"{provider}:{session_id}"
    columns = [
        "id", "provider", "sessionId", "projectName", "startTime", "endTime",
        "messageCount", "userWordCount", "assistantWordCount", "keyFiles",
        "keyCommands", "keyTools", "inferredTaskTitle", "lastAssistantMessage",
        "fullText", "indexedAt", "summary", "summaryTitle", "summaryModel",
        "sourceDeviceId", "sourceDeviceName", "isRemote",
    ]
    values: list[object] = [
        conversation_id, provider, session_id, "FixtureApp", "2026-05-01 10:00:00.000", "2026-05-01 11:00:00.000",
        3, 10, 20, json.dumps(["/tmp/project/src/auth.ts"]),
        json.dumps(["npm test"]), json.dumps(["Bash", "Edit"]), title, "Next, add a 401 test.",
        full_text, "2026-05-01 11:01:00.000", "Short summary", title, "fixture-model",
        "mac-fixture", "Mac Fixture", 0,
    ]
    if with_working_dir:
        columns.append("workingDirectory")
        values.append(working_directory)
    placeholders = ",".join("?" for _ in values)
    conn.execute(f"INSERT INTO conversations ({','.join(columns)}) VALUES ({placeholders})", values)
    conn.execute(
        "INSERT INTO token_usage (id, provider, sessionId, projectName, model, inputTokens, outputTokens, cost) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (f"usage-{conversation_id}", provider, session_id, "FixtureApp", "fixture-model", 100, 20, 0.42),
    )
    return conversation_id


def _fixture(tmp_path: Path, *, with_working_dir: bool = True) -> tuple[resume_core.ResumeEnvironment, sqlite3.Connection]:
    db_path = tmp_path / "openburnbar.sqlite"
    conn = sqlite3.connect(db_path)
    conn.executescript(_schema(with_working_dir=with_working_dir))
    home = tmp_path / "home"
    home.mkdir()
    return resume_core.ResumeEnvironment(db_path=db_path, home=home), conn


def _make_claude_handle(home: Path, handle: str) -> None:
    path = home / ".claude" / "projects" / "-tmp-project"
    path.mkdir(parents=True, exist_ok=True)
    (path / f"{handle}.jsonl").write_text("{}", encoding="utf-8")


def _make_claude_subagent_only(home: Path, handle: str) -> None:
    path = home / ".claude" / "projects" / "-tmp-project" / "subagents"
    path.mkdir(parents=True, exist_ok=True)
    (path / f"{handle}.jsonl").write_text("{}", encoding="utf-8")


def _make_codex_state(home: Path, handle: str) -> None:
    sessions = home / ".codex" / "sessions" / "2026" / "05" / "01"
    sessions.mkdir(parents=True, exist_ok=True)
    rollout = sessions / f"rollout-2026-05-01T10-00-00-{handle}.jsonl"
    rollout.write_text("{}", encoding="utf-8")
    state = home / ".codex" / "state_5.sqlite"
    state.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(state)
    conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)")
    conn.execute("INSERT INTO threads (id, rollout_path) VALUES (?, ?)", (handle, str(rollout)))
    conn.commit()
    conn.close()


def _make_codex_archive(home: Path, handle: str) -> None:
    sessions = home / ".codex" / "sessions" / "2026" / "05" / "02"
    sessions.mkdir(parents=True, exist_ok=True)
    (sessions / f"rollout-2026-05-02T10-00-00-{handle}.jsonl").write_text("{}", encoding="utf-8")


def _golden_ccms() -> dict[str, dict[str, object]]:
    base = {
        "context": {
            "key_files": ["src/auth.ts"],
            "key_commands": ["npm test"],
            "key_tools": ["Read", "Edit"],
            "attachments": [],
        },
        "token_summary": {"input": 100, "output": 20, "cost_usd": 0.42},
    }
    return {
        "briefing_claude_code.md": {
            **base,
            "header": {
                "provider": "Claude Code",
                "provider_normalized": "claude_code",
                "model": "claude-opus-4-5",
                "project_name": "FixtureApp",
                "working_directory": "/tmp/project",
                "started_at": "2026-05-01T10:00:00Z",
                "last_message_at": "2026-05-01T11:00:00Z",
                "summary_title": "Refactor auth layer",
                "summary": "Replaced JWT helpers with middleware guards.",
            },
            "conversation_trail": {
                "source": "search_chunks",
                "total_messages": 2,
                "messages": [
                    {"role": "user", "content": "Please refactor auth.", "timestamp": None},
                    {"role": "assistant", "content": "Updated middleware.", "timestamp": None},
                ],
            },
            "hand_off": {"last_assistant_message": "Next, add a 401 test.", "open_threads_inferred": ["add a 401 test."]},
            "source": {"composite_id": "Claude Code:uuid-1", "native_handle_validated": True},
        },
        "briefing_goose_cross_port.md": {
            **base,
            "header": {
                "provider": "Goose",
                "provider_normalized": "goose",
                "model": "unknown",
                "project_name": "FixtureApp",
                "working_directory": "/tmp/project",
                "started_at": "2026-05-01T10:00:00Z",
                "last_message_at": "2026-05-01T11:00:00Z",
                "summary_title": "Move Goose session",
                "summary": "Goose completed the transport sketch.",
            },
            "conversation_trail": {
                "source": "search_chunks",
                "total_messages": 2,
                "messages": [
                    {"role": "user", "content": "Port this to Claude Code.", "timestamp": None},
                    {"role": "assistant", "content": "Use the iroh pairing notes.", "timestamp": None},
                ],
            },
            "hand_off": {"last_assistant_message": "Follow up on relay cleanup.", "open_threads_inferred": ["relay cleanup."]},
            "source": {"composite_id": "Goose:goose-1", "native_handle_validated": False},
        },
        "briefing_fulltext_paragraphs.md": {
            **base,
            "header": {
                "provider": "Factory",
                "provider_normalized": "factory",
                "model": "unknown",
                "project_name": "FixtureApp",
                "working_directory": None,
                "started_at": "2026-05-01T10:00:00Z",
                "last_message_at": "2026-05-01T11:00:00Z",
                "summary_title": "Fallback trail",
                "summary": "",
            },
            "conversation_trail": {
                "source": "fulltext_paragraphs",
                "total_messages": 2,
                "messages": [
                    {"role": "unknown", "content": "User asked for fallback rendering.", "timestamp": None},
                    {"role": "unknown", "content": "Assistant produced paragraphs.", "timestamp": None},
                ],
            },
            "hand_off": {"last_assistant_message": "", "open_threads_inferred": []},
            "source": {"composite_id": "Factory:factory-1", "native_handle_validated": False},
        },
    }


def test_claude_root_uuid_uses_native_resume(tmp_path):
    env, conn = _fixture(tmp_path)
    handle = str(uuid.uuid4())
    _insert_conv(conn, provider="Claude Code", session_id=handle)
    conn.commit()
    _make_claude_handle(env.resolved_home, handle)

    payload = resume_core.dispatch_resume(handle, env=env)

    assert payload["kind"] == "native"
    assert payload["argv"] == ["claude", "--resume", handle]


def test_claude_subagent_and_subagent_folder_force_port(tmp_path):
    env, conn = _fixture(tmp_path)
    _insert_conv(conn, provider="Claude Code", session_id="parent/child")
    root_uuid = str(uuid.uuid4())
    _insert_conv(conn, provider="Claude Code", session_id=root_uuid)
    conn.commit()
    _make_claude_subagent_only(env.resolved_home, root_uuid)

    composite = resume_core.dispatch_resume("parent/child", target_harness="claudeCode", env=env)
    subagent_file = resume_core.dispatch_resume(root_uuid, target_harness="Claude Code", env=env)

    assert composite["kind"] == "ported"
    assert subagent_file["kind"] == "ported"
    assert subagent_file["note"] == "native_handle_invalid_fell_back_to_port"


def test_codex_state_and_archived_jsonl_validate_native(tmp_path):
    env, conn = _fixture(tmp_path)
    state_handle = str(uuid.uuid4())
    archived_handle = str(uuid.uuid4())
    _insert_conv(conn, provider="Codex", session_id=state_handle)
    _insert_conv(conn, provider="Codex", session_id=archived_handle)
    conn.commit()
    _make_codex_state(env.resolved_home, state_handle)
    _make_codex_archive(env.resolved_home, archived_handle)

    active = resume_core.dispatch_resume(state_handle, env=env)
    archived = resume_core.dispatch_resume(archived_handle, env=env)

    assert active["kind"] == "native"
    assert active["argv"] == ["codex", "resume", state_handle]
    assert archived["kind"] == "native"


def test_missing_native_codex_falls_back_to_port(tmp_path):
    env, conn = _fixture(tmp_path)
    handle = str(uuid.uuid4())
    _insert_conv(conn, provider="Codex", session_id=handle)
    conn.commit()

    payload = resume_core.dispatch_resume(handle, env=env)

    assert payload["kind"] == "ported"
    assert payload["note"] == "native_handle_invalid_fell_back_to_port"


def test_non_native_source_requires_target_then_ports(tmp_path):
    env, conn = _fixture(tmp_path)
    _insert_conv(conn, provider="Goose", session_id="goose-1")
    conn.commit()

    missing_target = resume_core.dispatch_resume("goose-1", env=env)
    ported = resume_core.dispatch_resume("goose-1", target_harness="claudeCode", env=env)
    source_target = resume_core.dispatch_resume("goose-1", target_harness="goose", env=env)

    assert missing_target["kind"] == "error"
    assert missing_target["code"] == "target_required"
    assert ported["kind"] == "ported"
    assert ported["target_harness"] == "claude_code"
    assert source_target["kind"] == "ported"
    assert source_target["target_harness"] == "goose"
    assert source_target["target_argv"][0] == "goose"


def test_search_chunks_and_fulltext_fallback(tmp_path):
    env, conn = _fixture(tmp_path)
    with_chunks = _insert_conv(conn, provider="Factory", session_id="factory-1")
    _insert_conv(conn, provider="Factory", session_id="factory-2")
    conn.execute(
        "INSERT INTO search_chunks (id, documentID, sourceKind, sourceID, ordinal, sectionPath, text) VALUES (?, ?, 'conversation', ?, 2, 'You / Request', 'Please fix auth')",
        ("chunk-2", "doc-1", with_chunks),
    )
    conn.execute(
        "INSERT INTO search_chunks (id, documentID, sourceKind, sourceID, ordinal, sectionPath, text) VALUES (?, ?, 'conversation', ?, 3, 'Assistant / Reply', 'Updated middleware')",
        ("chunk-3", "doc-1", with_chunks),
    )
    conn.commit()

    chunks = resume_core.build_ccm("factory-1", env=env)
    fulltext = resume_core.build_ccm("factory-2", env=env)

    assert chunks["conversation_trail"]["source"] == "search_chunks"
    assert [item["role"] for item in chunks["conversation_trail"]["messages"]] == ["user", "assistant"]
    assert fulltext["conversation_trail"]["source"] == "fulltext_paragraphs"


def test_ambiguous_bare_session_and_composite_resolution(tmp_path):
    env, conn = _fixture(tmp_path)
    native_handle = str(uuid.uuid4())
    _insert_conv(conn, provider="Codex", session_id=native_handle, conversation_id=f"Codex:{native_handle}")
    _insert_conv(conn, provider="Codex", session_id="bare-id-owner", conversation_id="same")
    _insert_conv(conn, provider="Codex", session_id="same", conversation_id="Codex:same")
    _insert_conv(conn, provider="Claude Code", session_id="same", conversation_id="Claude Code:same")
    conn.commit()
    _make_codex_state(env.resolved_home, native_handle)

    ambiguous = resume_core.dispatch_resume("same", env=env)
    composite = resume_core.dispatch_resume("Codex:same", target_harness="claudeCode", env=env)
    composite_native = resume_core.dispatch_resume(f"Codex:{native_handle}", env=env)

    assert ambiguous["kind"] == "error"
    assert ambiguous["code"] == "ambiguous_session"
    assert composite["kind"] == "ported"
    assert composite_native["kind"] == "native"
    assert composite_native["argv"] == ["codex", "resume", native_handle]


def test_session_not_found_and_old_db_without_working_directory(tmp_path):
    env, conn = _fixture(tmp_path, with_working_dir=False)
    _insert_conv(conn, provider="Factory", session_id="old-1", with_working_dir=False)
    conn.commit()

    missing = resume_core.dispatch_resume("missing", env=env)
    ccm = resume_core.build_ccm("old-1", env=env)
    ported = resume_core.dispatch_resume("old-1", target_harness="codex", env=env)

    assert missing["code"] == "session_not_found"
    assert ccm["header"]["working_directory"] is None
    assert "Directory:" not in ported["briefing_md"]


def test_temp_file_is_0600_and_print_only_does_not_create_file(tmp_path):
    env, conn = _fixture(tmp_path)
    _insert_conv(conn, provider="Factory", session_id="factory-1")
    conn.commit()

    printed = resume_core.dispatch_resume("factory-1", target_harness="claudeCode", print_only=True, env=env)
    opened = resume_core.dispatch_resume("factory-1", target_harness="claudeCode", print_only=False, env=env)

    assert printed["briefing_path"] is None
    path = Path(opened["briefing_path"])
    assert path.exists()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_gui_targets_write_workspace_resume_hint(tmp_path):
    env, conn = _fixture(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    _insert_conv(conn, provider="Goose", session_id="goose-1", working_directory=str(workspace))
    conn.commit()

    payload = resume_core.dispatch_resume("goose-1", target_harness="cursor", print_only=False, env=env)

    hint_path = Path(payload["resume_hint_path"])
    assert payload["kind"] == "ported"
    assert payload["target_argv"] == ["open", "-a", "Cursor", str(workspace)]
    assert hint_path == workspace / ".cursor" / "burnbar-resume.md"
    assert hint_path.exists()
    assert stat.S_IMODE(hint_path.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(hint_path.stat().st_mode) == 0o600
    assert "# BurnBar Resume:" in hint_path.read_text(encoding="utf-8")


def test_print_only_gui_target_has_no_file_side_effect(tmp_path):
    env, conn = _fixture(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    _insert_conv(conn, provider="Goose", session_id="goose-1", working_directory=str(workspace))
    conn.commit()

    payload = resume_core.dispatch_resume("goose-1", target_harness="cursor", env=env)

    assert payload["kind"] == "ported"
    assert payload["briefing_path"] is None
    assert "resume_hint_path" not in payload
    assert not (workspace / ".cursor" / "burnbar-resume.md").exists()


def test_spawn_resume_launches_detached_target_and_schedules_cleanup(tmp_path, monkeypatch):
    env, conn = _fixture(tmp_path)
    _insert_conv(conn, provider="Goose", session_id="goose-1")
    conn.commit()
    spawned: dict[str, object] = {}
    scheduled: dict[str, object] = {}

    class FakeProcess:
        pid = 4242

    def fake_popen(argv, cwd=None, stdin=None, stdout=None, stderr=None, start_new_session=False):
        spawned["argv"] = argv
        spawned["cwd"] = cwd
        spawned["stdin"] = stdin
        spawned["stdout"] = stdout
        spawned["stderr"] = stderr
        spawned["start_new_session"] = start_new_session
        return FakeProcess()

    monkeypatch.setattr(resume_core.shutil, "which", lambda executable: f"/usr/bin/{executable}")
    monkeypatch.setattr(resume_core.subprocess, "Popen", fake_popen)
    monkeypatch.setattr(
        resume_core,
        "_schedule_delete",
        lambda path, seconds: scheduled.update({"path": path, "seconds": seconds}),
    )

    payload = resume_core.spawn_resume("goose-1", target_harness="claudeCode", cleanup_after_seconds=1, env=env)

    assert payload["kind"] == "spawned"
    assert payload["pid"] == 4242
    assert spawned["argv"][0] == "/usr/bin/claude"
    assert "--append-system-prompt" in spawned["argv"]
    assert spawned["stdin"] == resume_core.subprocess.DEVNULL
    assert spawned["stdout"] == resume_core.subprocess.DEVNULL
    assert spawned["stderr"] == resume_core.subprocess.DEVNULL
    assert spawned["start_new_session"] is True
    assert scheduled == {"path": payload["briefing_path"], "seconds": 1}


def test_golden_briefings_are_byte_stable():
    golden_dir = _HERE / "golden"
    for filename, ccm in _golden_ccms().items():
        expected = (golden_dir / filename).read_text(encoding="utf-8")
        rendered = resume_core.render_briefing(ccm)
        assert rendered == expected
        for _ in range(100):
            assert resume_core.render_briefing(ccm) == expected


def test_renderer_is_deterministic_fast_redacts_secrets_and_infers_threads():
    ccm = {
        "header": {
            "provider": "Factory",
            "provider_normalized": "factory",
            "model": "fixture",
            "project_name": "FixtureApp",
            "working_directory": "/tmp/project",
            "started_at": "2026-05-01",
            "last_message_at": "2026-05-01",
            "summary_title": "Do work",
            "summary": "Use api_key=sk-123456789012345678901234",
        },
        "context": {"key_files": [], "key_commands": [], "key_tools": [], "attachments": []},
        "conversation_trail": {
            "source": "search_chunks",
            "total_messages": 500,
            "messages": [{"role": "assistant", "content": f"message {idx}", "timestamp": None} for idx in range(500)],
        },
        "hand_off": {"last_assistant_message": "Done", "open_threads_inferred": resume_core.infer_open_threads("Next: add tests\nTODO: update docs")},
        "source": {"composite_id": "Factory:fixture", "native_handle_validated": False},
    }

    first = resume_core.render_briefing(ccm)
    for _ in range(100):
        assert resume_core.render_briefing(ccm) == first
    start = time.perf_counter()
    resume_core.render_briefing(ccm)
    assert (time.perf_counter() - start) < 0.1
    assert "sk-123" not in first
    assert "[REDACTED]" in first
    assert "add tests" in first
    assert "update docs" in first


def test_mcp_tool_wrappers_return_json(tmp_path, monkeypatch):
    env, conn = _fixture(tmp_path)
    _insert_conv(conn, provider="Goose", session_id="goose-1")
    conn.commit()
    monkeypatch.setenv("BURNBAR_DB_PATH", str(env.resolved_db_path))
    monkeypatch.setenv("HOME", str(env.resolved_home))
    server = _load_server()

    listed = json.loads(server.burnbar_list_resumable_conversations(limit=1))
    resumed = json.loads(server.burnbar_resume_conversation("goose-1", target_harness="claudeCode"))

    assert listed["items"][0]["session_id"] == "goose-1"
    assert resumed["kind"] == "ported"
