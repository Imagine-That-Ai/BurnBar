#!/usr/bin/env python3
"""Drain the Memory Blind Sync inbox into the local engine store.

Runs from the SessionStart hook (`hooks/claude-code-session-start.sh`) or by
hand. It reuses the server's own `burnbar_memory_sync_pull` wrapper, so the
capability gate, the signed CLI courier, the daemon's consent-marker scope check,
and §5's merge semantics all behave exactly as they do for the MCP tool — this
module adds a deadline and a receipt, nothing else.

Why it exists: the app's pull lane parks verified `memory_facts` documents in
`agent_memory_inbox` on its own cadence, and the engine merges them only when
something calls the tool. Nothing did. A member who turned "Sync memories to my
other devices" on could wait indefinitely and see nothing in `burnbar_recall`
until an agent happened to invoke `burnbar_memory_sync_pull` by name.

It never blocks session start: every outcome is one JSON line on stdout and exit
code 0 (2 only for a usage error), and the whole call sits under a deadline.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
from pathlib import Path
from typing import Any

HOOK_ENV = "OPENBURNBAR_MEMORY_SYNC_HOOK"
DEFAULT_BUDGET_SECONDS = 20
DEFAULT_LIMIT = 200
_DISABLED = {"0", "off", "false", "no", "disabled"}


class _Deadline(TimeoutError):
    """Raised on SIGALRM when the drain outlives its budget."""


def hook_disabled(env: dict[str, str]) -> bool:
    return env.get(HOOK_ENV, "").strip().lower() in _DISABLED


def _server_module() -> Any:
    """The MCP server module whose tool this drain calls.

    A function rather than a top-level import for two reasons: loading FastMCP
    is only worth it once we know there is work, and `server` reads its
    configuration from the environment at import time, so it must not be
    imported before `_pull` has installed the overrides. It is also the seam a
    test points at its own loaded copy of `server.py`.
    """
    import server  # noqa: PLC0415 — deferred; see above

    return server


def _pull(*, project_path: str | None, limit: int, env: dict[str, str]) -> dict[str, Any]:
    """Call the server's own tool, with the memory toolset enabled.

    Mirrors `memorize_transcript._memorize_messages`: `server` reads its
    configuration from the environment at import time, so the overrides go in
    first and come back out after — an in-process caller owns its own os.environ.
    """
    overrides = {k: v for k, v in env.items() if k.startswith(("OPENBURNBAR_", "BURNBAR_"))}
    if "BURNBAR_MCP_TOOLSET" not in overrides and "BURNBAR_MCP_TOOLSET" not in os.environ:
        overrides["BURNBAR_MCP_TOOLSET"] = "memory"
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    previous = {key: os.environ.get(key) for key in overrides}
    os.environ.update(overrides)
    try:
        raw = _server_module().burnbar_memory_sync_pull(project_path=project_path, limit=limit)
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    return json.loads(raw)


def drain(
    *,
    project_path: str | None,
    limit: int = DEFAULT_LIMIT,
    budget_seconds: float = DEFAULT_BUDGET_SECONDS,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Drain the inbox once, reporting every outcome as a status dict.

    The `budget_seconds` deadline is enforced with `signal.setitimer`, so it
    requires POSIX and the main thread; the hook only ever runs it on
    macOS/Linux from the process's main thread.
    """
    env = dict(os.environ if env is None else env)
    if hook_disabled(env):
        return {"status": "skipped_disabled"}

    def _alarm(_signum: int, _frame: Any) -> None:
        raise _Deadline

    previous = signal.signal(signal.SIGALRM, _alarm)
    signal.setitimer(signal.ITIMER_REAL, budget_seconds)
    try:
        result = _pull(project_path=project_path, limit=limit, env=env)
    except _Deadline:
        return {"status": "timeout", "budgetSeconds": budget_seconds}
    except Exception as exc:  # noqa: BLE001 — a hook must never fail the session; report and exit 0
        return {"status": "error", "error": f"{type(exc).__name__}: {exc}"}
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    return {"status": _cli_status(result), "result": result}


def _cli_status(result: dict[str, Any]) -> str:
    """Map the tool's response onto this CLI's status vocabulary.

    The tool answers `{"status": "ok", ...}` for a *call* that succeeded, which
    is not the same as a session that gained a memory. `drained` means at least
    one row landed or folded in; `nothing_pending` means the inbox was empty (or
    held only rows this store had already applied), which is the common case and
    must not read as a failure.
    """
    status = str(result.get("status") or "")
    if status != "ok":
        return status or "error"
    if int(result.get("applied") or 0) or int(result.get("reinforced") or 0):
        return "drained"
    return "nothing_pending"


# What may be printed. stdout is appended to a log file by the hook, so the line
# is a receipt — counts and vocabulary constants — and never a memory body. The
# tool's `decisions` carry remote text; none of it is echoed. (CodeQL:
# py/clear-text-logging-sensitive-data.)
_KNOWN_STATUSES = (
    "drained",
    "nothing_pending",
    "skipped_disabled",
    "timeout",
    "error",
    "ok",
    "denied",
    "unavailable",
)
_KNOWN_CODES = (
    "MCP_CAPABILITY_DISABLED",
    "MCP_RATE_LIMITED",
    "DAEMON_PEER_REJECTED",
    "DAEMON_UNREACHABLE",
    "DAEMON_WRITE_REQUIRED",
    "INVALID_INBOX_RESPONSE",
)
_COUNTERS = ("applied", "reinforced", "parked", "refused", "unchanged", "acked")


def _vocab(value: Any, vocabulary: tuple[str, ...], fallback: str = "other") -> str:
    """The vocabulary constant equal to `value`, never `value` itself."""
    for known in vocabulary:
        if value == known:
            return known
    return fallback


def _count(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, list | dict | str):
        return len(value)
    return 0


def _redacted_output(result: dict[str, Any]) -> dict[str, Any]:
    """The status line as a receipt: counts, flags and vocabulary constants."""
    printed: dict[str, Any] = {
        "status": _vocab(result.get("status"), _KNOWN_STATUSES),
        "budgetSeconds": float(result["budgetSeconds"])
        if isinstance(result.get("budgetSeconds"), int | float)
        else None,
        "errored": bool(result.get("error")),
    }
    inner = result.get("result")
    if not isinstance(inner, dict):
        return printed
    printed["result"] = {
        "status": _vocab(inner.get("status"), _KNOWN_STATUSES),
        "code": _vocab(inner.get("code"), _KNOWN_CODES, fallback="none") if inner.get("code") else None,
        **{name: _count(inner.get(name)) for name in _COUNTERS},
        "decisionCount": _count(inner.get("decisions")),
        "members": _count(inner.get("watermark")),
        "ackFailed": bool(inner.get("ackFailure")),
    }
    return printed


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="sync_remote_memories.py",
        description="Merge this member's memories from their other devices into the local engine store.",
    )
    parser.add_argument(
        "--hook-stdin",
        action="store_true",
        help="read the Claude Code SessionStart hook JSON payload from stdin",
    )
    parser.add_argument("--project", help="project root the memories belong to (default: the working directory)")
    parser.add_argument(
        "--limit", type=int, default=DEFAULT_LIMIT, help=f"inbox rows per drain (default: {DEFAULT_LIMIT})"
    )
    parser.add_argument(
        "--budget-seconds",
        type=float,
        default=DEFAULT_BUDGET_SECONDS,
        help=f"deadline for the drain (default: {DEFAULT_BUDGET_SECONDS})",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(list(sys.argv[1:] if argv is None else argv))
    project = args.project
    if args.hook_stdin:
        try:
            payload = json.loads(sys.stdin.read() or "{}")
        except ValueError as exc:
            print(json.dumps({"status": "error", "error": f"invalid hook payload: {exc}"}))
            return 0
        if not isinstance(payload, dict):
            print(json.dumps({"status": "error", "error": "hook payload is not a JSON object"}))
            return 0
        project = payload.get("cwd") or project
    result = drain(
        project_path=str(project) if project else None,
        limit=args.limit,
        budget_seconds=args.budget_seconds,
    )
    print(json.dumps(_redacted_output(result), default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
