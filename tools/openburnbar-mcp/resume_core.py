#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import tiktoken  # type: ignore[import-not-found]
except Exception:  # pragma: no cover - optional dependency in older local setups.
    tiktoken = None  # type: ignore[assignment]


THIS_DIR = Path(__file__).resolve().parent
PROVIDER_CONFIG_PATH = THIS_DIR / "eligible_providers.json"
CCM_VERSION = "1"
MAX_LIST_LIMIT = 50
DEFAULT_MAX_TOKENS = 8_000
SEARCH_CHUNKS_FETCH_LIMIT = 30
SECRET_PATTERNS = [
    re.compile(
        r"(?i)\b((?:api|access|secret|session|refresh|auth)[_-]?token|api[_-]?key|password)\s*[:=]\s*([^\s`'\"<>]{8,})"
    ),
    re.compile(r"\b(sk-[A-Za-z0-9_-]{20,})\b"),
    re.compile(r"\b(gh[pousr]_[A-Za-z0-9_]{20,})\b"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.DOTALL),
]


@dataclass(frozen=True)
class ResumeEnvironment:
    db_path: Path | None = None
    home: Path | None = None

    @property
    def resolved_home(self) -> Path:
        return self.home or Path.home()

    @property
    def resolved_db_path(self) -> Path:
        return self.db_path or default_db_path()


_HANDLE_CACHE: dict[tuple[str, str, str], str | None] = {}
_PROVIDER_CONFIG: dict[str, Any] | None = None


def _sanitize_db_path(raw: str) -> Path:
    if "\x00" in raw:
        raise ValueError("BURNBAR_DB_PATH must not contain NUL bytes.")
    candidate = Path(raw).expanduser().resolve()
    if not candidate.is_absolute():
        raise ValueError("BURNBAR_DB_PATH must resolve to an absolute path.")
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.sqlite[0-9]?", candidate.name):
        raise ValueError("BURNBAR_DB_PATH basename must match [A-Za-z0-9._-]+\\.sqlite[0-9]?")
    return candidate


def default_db_path() -> Path:
    if env := os.environ.get("BURNBAR_DB_PATH", "").strip():
        return _sanitize_db_path(env)
    support = Path.home() / "Library" / "Application Support"
    for app_dir in ("OpenBurnBar", "AgentLens"):
        base = support / app_dir
        for name in ("openburnbar.sqlite", "agentlens.sqlite"):
            candidate = base / name
            if candidate.is_file():
                return candidate
    return support / "OpenBurnBar" / "openburnbar.sqlite"


def connect_ro(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise FileNotFoundError(
            f"OpenBurnBar database not found at {path}. Open OpenBurnBar once or set BURNBAR_DB_PATH."
        )
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout = 1000")
    return conn


def provider_config() -> dict[str, Any]:
    global _PROVIDER_CONFIG
    if _PROVIDER_CONFIG is None:
        _PROVIDER_CONFIG = json.loads(PROVIDER_CONFIG_PATH.read_text(encoding="utf-8"))
    return _PROVIDER_CONFIG


def search_chunks_source_kind() -> str:
    value = provider_config().get("search_chunks_source_kind")
    return value if isinstance(value, str) and value else "conversation"


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")
    return {
        "claude_code": "claude_code",
        "claudecode": "claude_code",
        "gemini_cli": "gemini_cli",
        "pi_agent": "pi_agent",
        "open_code": "open_code",
        "forge_dev": "forge",
    }.get(slug, slug)


def normalize_provider(raw_or_none: str | None) -> str | None:
    if not raw_or_none:
        return None
    cfg = provider_config()
    aliases = cfg.get("aliases", {})
    if isinstance(aliases, dict) and raw_or_none in aliases and isinstance(aliases[raw_or_none], str):
        return aliases[raw_or_none]
    native = cfg.get("native_eligible", {})
    if isinstance(native, dict) and raw_or_none in native and isinstance(native[raw_or_none], str):
        return native[raw_or_none]
    all_known = cfg.get("all_known", [])
    if isinstance(all_known, list):
        for item in all_known:
            if isinstance(item, str) and item == raw_or_none:
                return slugify(item)
    return slugify(raw_or_none)


def _has_column(conn: sqlite3.Connection, table: str, column: str) -> bool:
    try:
        return column in {str(row["name"]) for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    except sqlite3.Error:
        return False


def _safe_json_array(raw: Any, limit: int | None = None) -> list[str]:
    if not raw:
        return []
    if isinstance(raw, list):
        items = raw
    elif isinstance(raw, str):
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            return []
        items = decoded if isinstance(decoded, list) else []
    else:
        return []
    strings = [str(item) for item in items if isinstance(item, str) and item.strip()]
    return strings[:limit] if limit else strings


def _cap_list(items: list[str], cap: int) -> list[str]:
    if len(items) <= cap:
        return items
    return items[:cap] + [f"... {len(items) - cap} more"]


def _redact_text(text: str) -> str:
    redacted = text
    for pattern in SECRET_PATTERNS:

        def repl(match: re.Match[str]) -> str:
            if len(match.groups()) >= 2:
                return f"{match.group(1)}=[REDACTED]"
            return "[REDACTED_SECRET]"

        redacted = pattern.sub(repl, redacted)
    return redacted


def _row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {key: row[key] for key in row.keys()}


def _conversation_lookup(conn: sqlite3.Connection, session_id_input: str) -> list[sqlite3.Row]:
    if ":" in session_id_input:
        return conn.execute("SELECT * FROM conversations WHERE id = ?", (session_id_input,)).fetchall()
    return conn.execute("SELECT * FROM conversations WHERE sessionId = ?", (session_id_input,)).fetchall()


def _infer_role(section_path: str | None) -> str:
    value = (section_path or "").lower()
    if "user" in value or value.startswith("you") or " / you" in value:
        return "user"
    if "assistant" in value or "agent" in value:
        return "assistant"
    if "system" in value or "developer" in value:
        return "system"
    return "unknown"


def _resolve_trail(conn: sqlite3.Connection, conv: sqlite3.Row, k: int = SEARCH_CHUNKS_FETCH_LIMIT) -> dict[str, Any]:
    source_id = conv["id"]
    if _has_column(conn, "search_chunks", "sourceID"):
        section_expr = "sectionPath" if _has_column(conn, "search_chunks", "sectionPath") else "NULL AS sectionPath"
        # S608: section_expr is selected from fixed schema-column literals above.
        sql = f"""
            SELECT text, ordinal, messageStartOffset, {section_expr}
            FROM search_chunks
            WHERE sourceID = ? AND sourceKind = ?
            ORDER BY ordinal DESC
            LIMIT ?
        """
        try:
            rows = conn.execute(sql, (source_id, search_chunks_source_kind(), k)).fetchall()
        except sqlite3.Error:
            rows = []
        if rows:
            messages = [
                {
                    "role": _infer_role(row["sectionPath"]),
                    "content": _redact_text(str(row["text"] or "")),
                    "timestamp": None,
                }
                for row in reversed(rows)
                if str(row["text"] or "").strip()
            ]
            return {
                "source": "search_chunks",
                "total_messages": len(messages),
                "messages": messages,
                "trail_items": messages,
            }

    paragraphs = [p.strip() for p in str(conv["fullText"] or "").split("\n\n") if p.strip()][-k:]
    messages = [{"role": "unknown", "content": _redact_text(p), "timestamp": None} for p in paragraphs]
    return {
        "source": "fulltext_paragraphs",
        "total_messages": len(messages),
        "messages": messages,
        "trail_items": messages,
    }


def _uuid_like(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except (TypeError, ValueError):
        return False


def validate_native_handle(
    provider_normalized: str | None, raw_handle: str | None, env: ResumeEnvironment | None = None
) -> str | None:
    if not provider_normalized or not raw_handle or "/" in raw_handle:
        return None
    resolved_env = env or ResumeEnvironment()
    home = resolved_env.resolved_home
    cache_key = (provider_normalized, raw_handle, str(home))
    if cache_key in _HANDLE_CACHE:
        return _HANDLE_CACHE[cache_key]

    result: str | None = None
    if provider_normalized == "claude_code" and _uuid_like(raw_handle):
        root = home / ".claude" / "projects"
        if root.exists():
            for path in root.rglob(f"{raw_handle}.jsonl"):
                if "subagents" not in path.parts and path.is_file():
                    result = raw_handle
                    break
    elif provider_normalized == "codex":
        state_db = home / ".codex" / "state_5.sqlite"
        if state_db.exists():
            try:
                with sqlite3.connect(f"file:{state_db}?mode=ro", uri=True, timeout=0.5) as conn:
                    conn.row_factory = sqlite3.Row
                    conn.execute("PRAGMA busy_timeout = 500")
                    row = conn.execute(
                        "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1", (raw_handle,)
                    ).fetchone()
                    if row:
                        rollout_path = row["rollout_path"]
                        if not rollout_path or Path(str(rollout_path)).expanduser().is_file():
                            result = raw_handle
            except sqlite3.Error:
                pass
        if not result:
            sessions_root = home / ".codex" / "sessions"
            if sessions_root.exists():
                for path in sessions_root.rglob(f"*{raw_handle}*.jsonl"):
                    if path.is_file():
                        result = raw_handle
                        break

    _HANDLE_CACHE[cache_key] = result
    return result


def _token_summary(conn: sqlite3.Connection, provider: str, session_id: str) -> dict[str, Any]:
    where = "provider = ? AND sessionId = ?"
    args: list[Any] = [provider, session_id]
    if provider == "Claude Code" and "/" not in session_id:
        where = "provider = ? AND (sessionId = ? OR sessionId LIKE ?)"
        args.append(f"{session_id}/%")
    cost_column = "cost" if _has_column(conn, "token_usage", "cost") else "costUSD"
    try:
        row = conn.execute(
            # S608: cost_column and where are built from fixed provider/session branches above.
            f"""
            SELECT
              COALESCE(SUM(inputTokens), 0) AS input,
              COALESCE(SUM(outputTokens), 0) AS output,
              COALESCE(SUM({cost_column}), 0) AS cost_usd
            FROM token_usage
            WHERE {where}
            """,
            args,
        ).fetchone()
    except sqlite3.Error:
        row = None
    return {
        "input": int(row["input"] or 0) if row else 0,
        "output": int(row["output"] or 0) if row else 0,
        "cost_usd": float(row["cost_usd"] or 0.0) if row else 0.0,
    }


def materialize_ccm(
    conn: sqlite3.Connection, conv: sqlite3.Row, env: ResumeEnvironment | None = None
) -> dict[str, Any]:
    resolved_env = env or ResumeEnvironment()
    has_working_dir = _has_column(conn, "conversations", "workingDirectory")
    provider = str(conv["provider"])
    session_id = str(conv["sessionId"])
    provider_norm = normalize_provider(provider)
    native_handle = validate_native_handle(provider_norm, session_id, resolved_env)
    working_directory = conv["workingDirectory"] if has_working_dir and "workingDirectory" in conv.keys() else None
    title = conv["summaryTitle"] or conv["inferredTaskTitle"] or session_id
    trail = _resolve_trail(conn, conv)
    ccm = {
        "ccm_version": CCM_VERSION,
        "header": {
            "provider": provider,
            "provider_normalized": provider_norm,
            "model": conv["summaryModel"] if "summaryModel" in conv.keys() else None,
            "project_name": conv["projectName"],
            "working_directory": working_directory,
            "started_at": conv["startTime"],
            "last_message_at": conv["endTime"] or conv["indexedAt"],
            "summary_title": _redact_text(str(title)),
            "summary": _redact_text(str(conv["summary"] or "")),
        },
        "context": {
            "key_files": _cap_list(_safe_json_array(conv["keyFiles"]), 20),
            "key_commands": _cap_list(_safe_json_array(conv["keyCommands"]), 20),
            "key_tools": _cap_list(_safe_json_array(conv["keyTools"]), 20),
            "attachments": [],
        },
        "conversation_trail": trail,
        "hand_off": {
            "last_assistant_message": _redact_text(str(conv["lastAssistantMessage"] or "")),
            "open_threads_inferred": infer_open_threads(str(conv["fullText"] or "")),
        },
        "source": {
            "session_id": session_id,
            "composite_id": conv["id"],
            "source_device_id": conv["sourceDeviceId"] if "sourceDeviceId" in conv.keys() else None,
            "provider_native_session_handle": native_handle,
            "native_handle_validated": native_handle is not None,
        },
        "token_summary": _token_summary(conn, provider, session_id),
    }
    return ccm


def build_ccm(session_id_input: str, env: ResumeEnvironment | None = None) -> dict[str, Any] | None:
    resolved_env = env or ResumeEnvironment()
    with connect_ro(resolved_env.resolved_db_path) as conn:
        rows = _conversation_lookup(conn, session_id_input)
        if not rows:
            return None
        if len(rows) > 1:
            return {"_error": "ambiguous_session", "_matches": [row["id"] for row in rows]}
        return materialize_ccm(conn, rows[0], resolved_env)


def infer_open_threads(full_text: str, cap: int = 5) -> list[str]:
    pattern = re.compile(
        r"^\s*(?:Next:|TODO:|Then,?|After this,?|Next steps?:?|Follow[- ]?up:?)\s*(.+?)$", re.MULTILINE | re.IGNORECASE
    )
    items: list[str] = []
    for match in pattern.finditer(full_text or ""):
        item = " ".join(match.group(1).split())
        if item:
            items.append(_redact_text(item[:80]))
        if len(items) >= cap:
            break
    return items


def estimate_tokens(text: str, model: str | None = None) -> int:
    if tiktoken is not None and model:
        try:
            encoder = tiktoken.encoding_for_model(model)
            return max(1, len(encoder.encode(text)))
        except Exception:
            try:
                encoder = tiktoken.get_encoding("o200k_base")
                return max(1, len(encoder.encode(text)))
            except Exception:
                return max(1, (len(text) + 3) // 4)
    return max(1, (len(text) + 3) // 4)


def _render_list(title: str, items: list[str]) -> str:
    if not items:
        return f"**{title}:** none\n"
    return f"**{title}:**\n" + "".join(f"- `{item}`\n" for item in items)


def _truncate_to_tokens(text: str, target_tokens: int) -> str:
    max_chars = max(0, target_tokens * 4)
    if len(text) <= max_chars:
        return text
    return text[:max_chars].rstrip() + "\n...[truncated]\n"


def _render_header(header: dict[str, Any]) -> str:
    title = header.get("summary_title") or "(no title)"
    project = header.get("project_name") or "-"
    directory = header.get("working_directory")
    source = header.get("provider") or "unknown"
    model = header.get("model") or "unknown"
    started = header.get("started_at") or "unknown"
    ended = header.get("last_message_at") or "unknown"
    line = f"**Project:** {project}"
    if directory:
        line += f"  **Directory:** `{directory}`"
    return (
        f"# BurnBar Resume: {title}\n\n{line}\n**Source:** {source} / `{model}`\n**Session:** {started} -> {ended}\n\n"
    )


def _render_summary(header: dict[str, Any]) -> str:
    summary = str(header.get("summary") or "").strip()
    return "## Summary\n" + (summary if summary else "No generated summary is available.") + "\n\n"


def _render_context(context: dict[str, Any]) -> str:
    return (
        "## Context\n"
        + _render_list("Key files", list(context.get("key_files") or []))
        + _render_list("Key commands", list(context.get("key_commands") or []))
        + _render_list("Key tools", list(context.get("key_tools") or []))
        + "\n"
    )


def _render_message(msg: dict[str, Any]) -> str:
    role = str(msg.get("role") or "unknown")
    content = str(msg.get("content") or "")
    if len(content) > 1200:
        content = content[:1200] + " [...truncated]"
    timestamp = f" `{msg['timestamp']}`" if msg.get("timestamp") else ""
    if role == "unknown":
        return content
    return f"**[{role.upper()}]**{timestamp}\n{content}"


def _render_handoff(ccm: dict[str, Any]) -> str:
    handoff = ccm.get("hand_off") or {}
    last = str(handoff.get("last_assistant_message") or "").strip()
    threads = list(handoff.get("open_threads_inferred") or [])
    parts = ["## Handoff\n"]
    parts.append(last if last else "No final assistant message was recorded.")
    parts.append("\n")
    if threads:
        parts.append("\n**Open threads inferred:**\n")
        parts.extend(f"- {item}\n" for item in threads[:5])
    parts.append("\n")
    return "".join(parts)


def render_briefing(ccm: dict[str, Any], max_tokens: int = DEFAULT_MAX_TOKENS, target_model: str | None = None) -> str:
    budget = max(512, int(max_tokens * 0.7))
    parts = [
        _render_header(ccm["header"]),
        _render_summary(ccm["header"]),
        _render_context(ccm["context"]),
    ]
    if sum(estimate_tokens(part, target_model) for part in parts) > budget:
        parts[1] = _truncate_to_tokens(parts[1], int(budget * 0.4))
        parts[2] = _truncate_to_tokens(parts[2], int(budget * 0.2))
    used = sum(estimate_tokens(part, target_model) for part in parts)
    remaining = max(0, budget - used - 80)
    trail = ccm.get("conversation_trail") or {}
    messages = list(trail.get("messages") or [])
    included: list[str] = []
    trail_tokens = 0
    for msg in messages:
        rendered = _render_message(msg)
        token_count = estimate_tokens(rendered, target_model)
        if trail_tokens + token_count > remaining and included:
            break
        included.append(rendered)
        trail_tokens += token_count
    if messages:
        parts.append(
            f"## Conversation Trail\n"
            f"> Showing last {len(included)} of {trail.get('total_messages', len(messages))} items "
            f"(source: {trail.get('source', 'unknown')}).\n\n" + "\n\n".join(included) + "\n\n"
        )
    parts.append(_render_handoff(ccm))
    parts.append("## Source\n")
    parts.append(f"- Composite ID: `{ccm['source']['composite_id']}`\n")
    parts.append(f"- Native handle validated: `{str(ccm['source']['native_handle_validated']).lower()}`\n")
    parts.append(
        "\nUse this briefing as the canonical handoff context. Verify current repository state before editing.\n"
    )
    return _redact_text("".join(parts))


def write_temp_briefing_0600(briefing_md: str) -> str:
    fd, path = tempfile.mkstemp(prefix="burnbar-resume-", suffix=".md")
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(briefing_md)
    return path


def write_workspace_resume_hint(working_directory: str | None, target_norm: str, briefing_md: str) -> str:
    workspace = Path(working_directory).expanduser() if working_directory else None
    if workspace and workspace.is_dir():
        hint_dir_name = {
            "cursor": ".cursor",
            "windsurf": ".windsurf",
        }.get(target_norm, ".openburnbar")
        hint_dir = workspace / hint_dir_name
        hint_dir.mkdir(parents=True, exist_ok=True)
        hint_dir.chmod(0o700)
        hint_path = hint_dir / "burnbar-resume.md"
        fd = os.open(str(hint_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(briefing_md)
        return str(hint_path)
    return write_temp_briefing_0600(briefing_md)


def _model_args(target_norm: str | None, target_model: str | None) -> list[str]:
    if not target_model:
        return []
    if target_norm in {"claude_code", "codex"}:
        return ["--model", target_model]
    return []


def prepare_target_invocation(
    target_norm: str,
    briefing_md: str,
    working_directory: str | None,
    target_model: str | None = None,
    write_resume_hint: bool = True,
) -> tuple[list[str], str | None]:
    model = _model_args(target_norm, target_model)
    if target_norm == "claude_code":
        return (
            [
                "claude",
                *model,
                "--append-system-prompt",
                "Use the OpenBurnBar Resume briefing as canonical handoff context.",
                briefing_md,
            ],
            None,
        )
    if target_norm == "codex":
        argv = ["codex", *model]
        if working_directory:
            argv.extend(["-C", working_directory])
        argv.append(briefing_md)
        return (argv, None)
    if target_norm == "cursor":
        if not write_resume_hint:
            return (["open", "-a", "Cursor", *([working_directory] if working_directory else [])], None)
        hint_path = write_workspace_resume_hint(working_directory, target_norm, briefing_md)
        return (["open", "-a", "Cursor", working_directory or str(Path(hint_path).parent)], hint_path)
    if target_norm == "windsurf":
        if not write_resume_hint:
            return (["open", "-a", "Windsurf", *([working_directory] if working_directory else [])], None)
        hint_path = write_workspace_resume_hint(working_directory, target_norm, briefing_md)
        return (["open", "-a", "Windsurf", working_directory or str(Path(hint_path).parent)], hint_path)
    if target_norm == "goose":
        argv = ["goose"]
        if working_directory:
            argv.extend(["--path", working_directory])
        argv.append(briefing_md)
        return (argv, None)
    if not write_resume_hint:
        return (["open", *([working_directory] if working_directory else [])], None)
    hint_path = write_workspace_resume_hint(working_directory, target_norm, briefing_md)
    return (["open", working_directory or str(Path(hint_path).parent)], hint_path)


def resolve_target_argv(
    target_norm: str,
    briefing_md: str,
    working_directory: str | None,
    target_model: str | None = None,
) -> list[str]:
    return prepare_target_invocation(target_norm, briefing_md, working_directory, target_model)[0]


def dispatch_resume(
    session_id: str,
    target_harness: str | None = None,
    target_model: str | None = None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    print_only: bool = True,
    env: ResumeEnvironment | None = None,
) -> dict[str, Any]:
    ccm = build_ccm(session_id, env=env)
    if ccm is None:
        return {
            "kind": "error",
            "code": "session_not_found",
            "session_id": session_id,
            "recovery": "Run burnbar_list_resumable_conversations to find a valid sessionId.",
        }
    if ccm.get("_error") == "ambiguous_session":
        return {
            "kind": "error",
            "code": "ambiguous_session",
            "session_id": session_id,
            "matches": ccm["_matches"],
            "recovery": "Pass the full composite id, for example Codex:abc-123.",
        }

    source_norm = ccm["header"]["provider_normalized"]
    target_norm = normalize_provider(target_harness) or source_norm
    native_handle = (
        ccm["source"].get("provider_native_session_handle") if ccm["source"].get("native_handle_validated") else None
    )
    is_native_eligible = source_norm in {"claude_code", "codex"}
    is_same_harness = target_norm == source_norm

    if target_harness is None and not (is_same_harness and is_native_eligible and native_handle):
        if not is_native_eligible:
            return {
                "kind": "error",
                "code": "target_required",
                "session_id": session_id,
                "recovery": f"Source provider '{ccm['header']['provider']}' has no native resume. Pass --as <harness> to choose a cross-port target.",
            }

    if is_same_harness and is_native_eligible and native_handle:
        argv = (
            ["claude", "--resume", native_handle]
            if source_norm == "claude_code"
            else ["codex", "resume", native_handle]
        )
        if target_model:
            argv[1:1] = _model_args(source_norm, target_model)
        return {
            "kind": "native",
            "session_id": session_id,
            "source_harness": source_norm,
            "target_harness": target_norm,
            "argv": argv,
            "working_directory": ccm["header"].get("working_directory"),
        }

    briefing_md = render_briefing(ccm, max_tokens=max_tokens, target_model=target_model)
    briefing_path = None if print_only else write_temp_briefing_0600(briefing_md)
    note = (
        "native_handle_invalid_fell_back_to_port"
        if is_same_harness and is_native_eligible and not native_handle
        else None
    )
    target_argv, resume_hint_path = prepare_target_invocation(
        target_norm or "claude_code",
        briefing_md,
        ccm["header"].get("working_directory"),
        target_model,
        write_resume_hint=not print_only,
    )
    response = {
        "kind": "ported",
        "session_id": session_id,
        "source_harness": source_norm,
        "target_harness": target_norm,
        "target_argv": target_argv,
        "briefing_md": briefing_md,
        "briefing_path": briefing_path,
        "working_directory": ccm["header"].get("working_directory"),
    }
    if resume_hint_path:
        response["resume_hint_path"] = resume_hint_path
    if note:
        response["note"] = note
    return response


def list_resumable_conversations(
    provider: str | None = None,
    project: str | None = None,
    since: str | None = None,
    limit: int = 20,
    offset: int = 0,
    env: ResumeEnvironment | None = None,
) -> dict[str, Any]:
    resolved_env = env or ResumeEnvironment()
    clauses: list[str] = []
    args: list[Any] = []
    if provider:
        normalized = normalize_provider(provider)
        raw_matches = [
            raw
            for raw in provider_config().get("all_known", [])
            if isinstance(raw, str) and normalize_provider(raw) == normalized
        ]
        if raw_matches:
            placeholders = ",".join("?" for _ in raw_matches)
            clauses.append(f"provider IN ({placeholders})")
            args.extend(raw_matches)
        else:
            clauses.append("provider = ?")
            args.append(provider)
    if project:
        clauses.append("projectName = ?")
        args.append(project)
    if since:
        clauses.append("COALESCE(endTime, startTime, indexedAt) >= ?")
        args.append(since)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    safe_limit = max(1, min(int(limit), MAX_LIST_LIMIT))
    safe_offset = max(0, int(offset))
    with connect_ro(resolved_env.resolved_db_path) as conn:
        has_working_dir = _has_column(conn, "conversations", "workingDirectory")
        rows = conn.execute(
            # S608: where is assembled only from fixed clauses with bound parameters.
            f"""
            SELECT *
            FROM conversations
            {where}
            ORDER BY COALESCE(endTime, startTime, indexedAt) DESC, id ASC
            LIMIT ? OFFSET ?
            """,
            [*args, safe_limit, safe_offset],
        ).fetchall()
        items = []
        for row in rows:
            provider_norm = normalize_provider(row["provider"])
            native_handle = validate_native_handle(provider_norm, row["sessionId"], resolved_env)
            items.append(
                {
                    "id": row["id"],
                    "session_id": row["sessionId"],
                    "provider": row["provider"],
                    "provider_normalized": provider_norm,
                    "project_name": row["projectName"],
                    "summary_title": row["summaryTitle"] or row["inferredTaskTitle"] or row["sessionId"],
                    "started_at": row["startTime"],
                    "last_message_at": row["endTime"] or row["indexedAt"],
                    "working_directory": row["workingDirectory"]
                    if has_working_dir and "workingDirectory" in row.keys()
                    else None,
                    "can_resume_native": native_handle is not None,
                }
            )
        return {
            "items": items,
            "limit": safe_limit,
            "offset": safe_offset,
            "next_offset": safe_offset + len(items) if len(items) == safe_limit else None,
        }


def _schedule_delete(path: str | None, seconds: int) -> None:
    if not path:
        return

    def cleanup() -> None:
        try:
            Path(path).unlink(missing_ok=True)
        except OSError:
            pass

    timer = threading.Timer(seconds, cleanup)
    timer.daemon = True
    timer.start()


def spawn_resume(
    session_id: str,
    target_harness: str | None = None,
    target_model: str | None = None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    cleanup_after_seconds: int = 600,
    env: ResumeEnvironment | None = None,
) -> dict[str, Any]:
    response = dispatch_resume(
        session_id,
        target_harness=target_harness,
        target_model=target_model,
        max_tokens=max_tokens,
        print_only=False,
        env=env,
    )
    if response.get("kind") == "error":
        return response
    argv = response.get("argv") if response.get("kind") == "native" else response.get("target_argv")
    if not isinstance(argv, list) or not argv:
        return {
            "kind": "error",
            "code": "spawn_unavailable",
            "recovery": "No target argv was available for this resume target.",
        }
    executable = shutil.which(str(argv[0]))
    if not executable:
        return {
            "kind": "error",
            "code": "target_executable_not_found",
            "recovery": f"Install `{argv[0]}` or choose a different --as target.",
        }
    cwd = response.get("working_directory")
    if isinstance(cwd, str) and cwd and Path(cwd).is_dir():
        resolved_cwd = cwd
    else:
        resolved_cwd = None
    child = subprocess.Popen(
        [executable, *map(str, argv[1:])],
        cwd=resolved_cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    _schedule_delete(response.get("briefing_path"), cleanup_after_seconds)
    return {
        "kind": "spawned",
        "pid": child.pid,
        "target_harness": response.get("target_harness"),
        "argv": argv,
        "working_directory": response.get("working_directory"),
        "briefing_path": response.get("briefing_path"),
        "cleanup_after_seconds": cleanup_after_seconds,
    }


def _cli() -> int:
    parser = argparse.ArgumentParser(description="OpenBurnBar Resume core")
    sub = parser.add_subparsers(dest="command", required=True)
    dispatch = sub.add_parser("dispatch")
    dispatch.add_argument("session_id")
    dispatch.add_argument("--as", dest="target_harness")
    dispatch.add_argument("--target-model")
    dispatch.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    dispatch.add_argument("--write-temp", action="store_true")
    list_cmd = sub.add_parser("list")
    list_cmd.add_argument("--provider")
    list_cmd.add_argument("--project")
    list_cmd.add_argument("--since")
    list_cmd.add_argument("--limit", type=int, default=20)
    list_cmd.add_argument("--offset", type=int, default=0)
    args = parser.parse_args()
    if args.command == "dispatch":
        payload = dispatch_resume(
            args.session_id,
            target_harness=args.target_harness,
            target_model=args.target_model,
            max_tokens=args.max_tokens,
            print_only=not args.write_temp,
        )
    else:
        payload = list_resumable_conversations(
            provider=args.provider,
            project=args.project,
            since=args.since,
            limit=args.limit,
            offset=args.offset,
        )
    print(json.dumps(payload, indent=2, default=str))
    return 0 if payload.get("kind") != "error" else 2


if __name__ == "__main__":
    raise SystemExit(_cli())
