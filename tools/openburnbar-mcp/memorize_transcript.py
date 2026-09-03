#!/usr/bin/env python3
"""Memorize a Claude Code session transcript into the local OpenBurnBar memory store.

Runs from the SessionEnd hook (`hooks/claude-code-session-end.sh`) or by hand. It reuses the
server's `burnbar_memorize` wrapper so the secret/PII gate, encryption, audit chain, and daemon
mirror behave exactly as they do for the MCP tool. It never blocks session end: every outcome is
one JSON line on stdout and exit code 0 (2 only for a usage error).
"""

from __future__ import annotations

import argparse
import collections
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
WRAPPER_TAGS = (
    "system-reminder",
    "command-name",
    "command-message",
    "command-args",
    "local-command-stdout",
    "local-command-stderr",
)
_WRAPPER_RE = re.compile("|".join(rf"<{tag}>.*?</{tag}>" for tag in WRAPPER_TAGS), re.DOTALL)
_DISABLED = {"0", "off", "false", "no", "disabled"}
# The engine answers a replayed transcript with this code instead of re-writing it.
_ALREADY_INGESTED_CODE = "ALREADY_INGESTED"


class _Deadline(TimeoutError):
    """Raised on SIGALRM when the memorize call outlives its budget."""


def hook_disabled(env: dict[str, str]) -> bool:
    return env.get(HOOK_ENV, "").strip().lower() in _DISABLED


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"]
        return "\n".join(part for part in parts if isinstance(part, str))
    return ""


def load_transcript(path: Path | str, *, max_messages: int = MAX_MESSAGES) -> list[dict[str, str]]:
    """Read a Claude Code JSONL transcript, keeping only user/assistant prose.

    The transcript format is documented as internal and changes between versions,
    so every line is parsed defensively: anything that is not a user/assistant
    turn with text content is skipped rather than raising.

    Only the last `max_messages` turns are retained while reading. `trim_messages`
    takes the same tail afterwards, but it can only take it from a list that is
    already in memory -- a session with a hundred thousand turns would be
    materialized in full first, inside the deadline, for nothing. The character
    budget stays where it was: this bounds the count, `trim_messages` the size.
    """
    messages: collections.deque[dict[str, str]] = collections.deque(maxlen=max(1, int(max_messages)))
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
                messages.append({"role": str(message["role"]), "content": text})
    return list(messages)


def trim_messages(
    messages: list[dict[str, str]],
    *,
    max_messages: int = MAX_MESSAGES,
    max_chars: int = MAX_TRANSCRIPT_CHARS,
) -> list[dict[str, str]]:
    """Keep the tail of the conversation: the end of a session holds its conclusions.

    The character cap is hard. A single turn larger than `max_chars` leaves nothing
    to memorize, which `memorize` reports as `skipped_empty` rather than sending a
    transcript past the budget.
    """
    kept = list(messages[-max_messages:])
    total = sum(len(m["content"]) for m in kept)
    while kept and total > max_chars:
        total -= len(kept.pop(0)["content"])
    return kept


def _memorize_messages(
    *,
    messages: list[dict[str, str]],
    project_path: str | None,
    session_id: str,
    reason: str,
    env: dict[str, str],
) -> dict[str, Any]:
    overrides = {k: v for k, v in env.items() if k.startswith(("OPENBURNBAR_", "BURNBAR_"))}
    if "BURNBAR_MCP_TOOLSET" not in overrides and "BURNBAR_MCP_TOOLSET" not in os.environ:
        overrides["BURNBAR_MCP_TOOLSET"] = "memory"
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    # `server` reads its configuration from the environment at import time, so the
    # overrides go in first -- and come back out after, because an in-process
    # caller (a test, or a library embedding this module) owns its own os.environ.
    previous = {key: os.environ.get(key) for key in overrides}
    os.environ.update(overrides)
    try:
        import server  # noqa: PLC0415 — deferred: loading FastMCP is only worth it once we know there is work

        raw = server.burnbar_memorize(
            messages=messages,
            project_path=project_path,
            source_kind="session",
            source_ref=f"claude-code:{session_id}",
            metadata={"hook": "SessionEnd", "reason": reason, "sessionId": session_id},
        )
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    return json.loads(raw)


def _decision_wrote(decision: Any) -> bool:
    """Whether one ingest decision actually changed a memory.

    ADD / UPDATE / DELETE are writes by name. NONE is the ambiguous one: a
    reinforcement of an identical memory reports NONE and still bumps the row,
    while a NONE carrying a `code` (`PREVIOUSLY_REJECTED`, `NON_APPROVED_DUPLICATE`,
    `IMMUTABLE_CONFLICT`) is a refusal that touched nothing.
    """
    if not isinstance(decision, dict):
        return False
    event = decision.get("event")
    if event in {"ADD", "UPDATE", "DELETE"}:
        return True
    return event == "NONE" and not decision.get("code") and bool(decision.get("memoryID"))


def _cli_status(result: dict[str, Any]) -> str:
    """Map the server's response onto the CLI's status vocabulary.

    `burnbar_memorize` answers `{"status": "ok", ...}` for a *call* that
    succeeded, which is not the same as a session that produced a memory. The
    status has to say which:

    * `already_ingested` -- the transcript's content hash already has a receipt;
    * `skipped_no_facts` -- the extractor found nothing worth keeping;
    * `rejected` -- facts were considered and none of them wrote or reinforced
      anything (the gate refused them, or review blocked every duplicate);
    * `memorized` -- at least one decision wrote or reinforced a memory.

    Any other status (rate limit, capability denial, empty input) passes through.
    """
    if result.get("code") == _ALREADY_INGESTED_CODE:
        return "already_ingested"
    if result.get("status") not in {"ok", "memorized"}:
        return str(result.get("status", "memorized"))
    decisions = result.get("decisions")
    decisions = list(decisions) if isinstance(decisions, list) else []
    considered = result.get("factsConsidered")
    considered = int(considered) if isinstance(considered, int) else len(decisions)
    if not considered and not decisions:
        return "skipped_no_facts"
    if any(_decision_wrote(decision) for decision in decisions):
        return "memorized"
    return "rejected"


def memorize(
    *,
    transcript_path: Path | str,
    project_path: str | None,
    session_id: str,
    reason: str,
    budget_seconds: float = DEFAULT_BUDGET_SECONDS,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Memorize one transcript, reporting every outcome as a status dict.

    The `budget_seconds` deadline is enforced with `signal.setitimer`, so it
    requires POSIX and the main thread; on any other platform, or when called
    off the main thread, the deadline cannot be armed and the call raises rather
    than running unbounded. The hook only ever runs it on macOS/Linux from the
    process's main thread.
    """
    env = dict(os.environ if env is None else env)
    if hook_disabled(env):
        return {"status": "skipped_disabled"}
    path = Path(transcript_path)
    if not path.is_file():
        # Report what the caller gave us; `Path("")` renders as "." and would lie.
        return {"status": "skipped_missing_transcript", "transcriptPath": str(transcript_path)}

    def _alarm(_signum: int, _frame: Any) -> None:
        raise _Deadline

    messages: list[dict[str, str]] = []
    # The deadline is armed before the read, not after it: a transcript large or
    # pathological enough to be slow to parse would otherwise hold session end
    # open for as long as the read took, entirely outside the budget.
    previous = signal.signal(signal.SIGALRM, _alarm)
    signal.setitimer(signal.ITIMER_REAL, budget_seconds)
    try:
        try:
            messages = trim_messages(load_transcript(path))
        except _Deadline:
            # `TimeoutError` is an `OSError`; the deadline must not be reported
            # as a failure to read the file.
            raise
        except OSError as exc:
            return {"status": "error", "error": f"{type(exc).__name__}: {exc}"}
        if not messages:
            return {"status": "skipped_empty"}
        result = _memorize_messages(
            messages=messages,
            project_path=project_path,
            session_id=session_id,
            reason=reason,
            env=env,
        )
    except _Deadline:
        return {"status": "timeout", "budgetSeconds": budget_seconds, "messages": len(messages)}
    except Exception as exc:  # noqa: BLE001 — a hook must never fail the session; report and exit 0
        return {"status": "error", "error": f"{type(exc).__name__}: {exc}"}
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    return {"status": _cli_status(result), "messages": len(messages), "result": result}


# What may be printed. stdout is appended to a log file by the hook, so the line
# is a receipt -- counts, ids and hashes -- and never the memory text, the
# transcript, or a decision's body. (CodeQL: clear-text logging of sensitive
# information.)
_PRINTABLE_TOP = ("status", "messages", "budgetSeconds", "transcriptPath", "error")
_PRINTABLE_RESULT = (
    "status",
    "code",
    "extractor",
    "extractionError",
    "sourceHash",
    "ingestedAt",
    "receiptStored",
    "factsConsidered",
    "summary",
    "projectID",
    "projectName",
)


def _redacted_output(result: dict[str, Any]) -> dict[str, Any]:
    """The status line, with every field that could carry memory text removed.

    Decisions are reduced to their shape -- what happened, to which id -- because
    `decisions[].text` is the memory body verbatim, and `reason` can quote it.
    """
    printed = {key: result[key] for key in _PRINTABLE_TOP if key in result}
    inner = result.get("result")
    if not isinstance(inner, dict):
        return printed
    summary = {key: inner[key] for key in _PRINTABLE_RESULT if key in inner}
    decisions = inner.get("decisions")
    if isinstance(decisions, list):
        summary["decisions"] = [
            {
                key: decision[key]
                for key in ("event", "code", "memoryID", "kind", "scope", "sensitivity", "reviewStatus")
                if key in decision
            }
            for decision in decisions
            if isinstance(decision, dict)
        ]
    printed["result"] = summary
    return printed


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="memorize_transcript.py",
        description="Memorize a Claude Code session transcript into the local OpenBurnBar memory store.",
    )
    parser.add_argument(
        "--hook-stdin",
        action="store_true",
        help="read the Claude Code SessionEnd hook JSON payload from stdin",
    )
    parser.add_argument("--transcript", help="path to the session transcript JSONL")
    parser.add_argument("--project", help="project root the memories belong to (default: the working directory)")
    parser.add_argument("--session-id", default="", help="session identifier used in the memory source ref")
    parser.add_argument("--reason", default="other", help="why the session ended (clear|resume|logout|...)")
    parser.add_argument(
        "--budget-seconds",
        type=float,
        default=DEFAULT_BUDGET_SECONDS,
        help=f"deadline for the memorize call (default: {DEFAULT_BUDGET_SECONDS})",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(list(sys.argv[1:] if argv is None else argv))
    if args.hook_stdin:
        try:
            payload = json.loads(sys.stdin.read() or "{}")
        except ValueError as exc:
            print(json.dumps({"status": "error", "error": f"invalid hook payload: {exc}"}))
            return 0
        if not isinstance(payload, dict):
            print(json.dumps({"status": "error", "error": "hook payload is not a JSON object"}))
            return 0
        transcript = payload.get("transcript_path")
        project = payload.get("cwd")
        session_id = str(payload.get("session_id") or "")
        reason = str(payload.get("reason") or "other")
    else:
        transcript = args.transcript
        project = args.project
        session_id = args.session_id
        reason = args.reason
        # Only the by-hand form can commit a usage error. A hook payload without a
        # transcript is a runtime fact to report, not a reason to fail session end.
        if not transcript:
            print("pass --hook-stdin or --transcript <path>", file=sys.stderr)
            return 2
    result = memorize(
        transcript_path=str(transcript or ""),
        project_path=str(project) if project else None,
        session_id=session_id,
        reason=reason,
        budget_seconds=args.budget_seconds,
    )
    print(json.dumps(_redacted_output(result), default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
