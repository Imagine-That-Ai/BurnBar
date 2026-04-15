#!/usr/bin/env python3
"""
OpenBurnBar local MCP: read-only access to the OpenBurnBar macOS SQLite database (conversations, usage).

Install: ./setup.sh  (creates .venv and installs deps)

Configure Cursor / Claude Desktop to run:
  command: <repo>/tools/openburnbar-mcp/.venv/bin/python
  args: [ "<repo>/tools/openburnbar-mcp/server.py" ]

Optional env:
  BURNBAR_DB_PATH — override path to openburnbar.sqlite (default: ~/Library/Application Support/OpenBurnBar/openburnbar.sqlite)
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("openburnbar-local")


def _sanitize_db_path(raw: str) -> Path:
    """
    Validate a developer-supplied SQLite path before opening it read-only.

    The MCP only ever opens this file in `mode=ro`, but we still constrain the
    input to: no NUL bytes, resolves to an absolute path, and the basename
    matches a conservative SQLite filename pattern. This neutralizes the
    py/path-injection taint flow CodeQL traces from the env var into sqlite3.
    """
    if "\x00" in raw:
        raise ValueError("BURNBAR_DB_PATH must not contain NUL bytes.")
    candidate = Path(raw).expanduser().resolve()
    if not candidate.is_absolute():
        raise ValueError("BURNBAR_DB_PATH must resolve to an absolute path.")
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.sqlite[0-9]?", candidate.name):
        raise ValueError(
            "BURNBAR_DB_PATH basename must match [A-Za-z0-9._-]+\\.sqlite[0-9]?"
        )
    return candidate


def _default_db_path() -> Path:
    if env := os.environ.get("BURNBAR_DB_PATH", "").strip():
        return _sanitize_db_path(env)
    home = Path.home()
    support = home / "Library" / "Application Support"
    for app_dir in ("OpenBurnBar", "AgentLens"):
        base = support / app_dir
        for name in ("openburnbar.sqlite", "agentlens.sqlite"):
            p = base / name
            if p.is_file():
                return p
    return support / "OpenBurnBar" / "openburnbar.sqlite"


def _connect_ro(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise FileNotFoundError(
            f"OpenBurnBar database not found at {path}. Open OpenBurnBar once or set BURNBAR_DB_PATH."
        )
    uri = f"file:{path}?mode=ro"
    return sqlite3.connect(uri, uri=True)
    # check_same_thread: default True; MCP tools run sync on one thread


def fts5_safe_query(user_input: str) -> str:
    """
    Natural-language friendly FTS5 query builder, matching BurnBarFTSQueryBuilder.naturalLanguage().
    Uses OR for longer queries to improve recall; AND for short precision queries.
    Strips common English stopwords from NL queries.
    """
    # Common English stopwords
    stopwords = {
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "where", "why", "how",
        "what", "who", "which", "is", "are", "was", "were", "be", "been", "being", "to", "of", "in",
        "on", "for", "with", "about", "into", "from", "at", "by", "as", "it", "its", "this", "that",
        "these", "those", "i", "you", "we", "they", "he", "she", "my", "your", "our", "their", "me",
        "him", "her", "them", "do", "does", "did", "have", "has", "had", "can", "could", "would",
        "should", "will", "just", "not", "no", "yes", "so", "very", "too", "also", "only", "even",
        "there", "here", "some", "any", "all", "each", "every", "both", "few", "more", "most", "other",
        "such", "than", "up", "out", "off", "over", "under", "again", "once", "ever", "please", "tell",
        "give", "show", "find", "search", "look", "get", "got", "make", "made", "using", "use", "used"
    }

    trimmed = user_input.strip()
    if not trimmed:
        return ""

    raw_parts = re.split(r"[\s\n]+", trimmed)
    lowered = [p.lower() for p in raw_parts]

    # Filter stopwords and tokens < 2 chars
    filtered = [p for p in lowered if len(p) >= 2 and p not in stopwords]

    if not filtered:
        # Fallback to raw tokens if all were filtered
        parts = [p.lower() for p in raw_parts if p]
    else:
        parts = filtered

    if not parts:
        return ""

    # Use OR for longer queries (> 48 chars or >= 5 tokens), AND for short precision queries
    unique_parts = sorted(set(parts))
    use_or = len(trimmed) > 48 or len(unique_parts) >= 5

    def quote_token(t: str) -> str:
        return '"' + t.replace('"', '""') + '"'

    if use_or:
        return " OR ".join(quote_token(t) for t in unique_parts)
    elif len(unique_parts) <= 3:
        return " AND ".join(quote_token(t) for t in unique_parts)
    else:
        # 4+ tokens that don't trigger OR: use OR for better recall
        return " OR ".join(quote_token(t) for t in unique_parts)


def _row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {k: row[k] for k in row.keys()}


@mcp.tool()
def burnbar_resolve_db_path() -> str:
    """Return the SQLite path that will be used (for debugging)."""
    p = _default_db_path()
    exists = p.is_file()
    return json.dumps({"path": str(p), "exists": exists}, indent=2)


@mcp.tool()
def burnbar_list_providers() -> str:
    """List distinct conversation providers (e.g. Codex, Claude Code) present in the DB."""
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            "SELECT DISTINCT provider FROM conversations ORDER BY provider"
        )
        rows = [r[0] for r in cur.fetchall()]
    return json.dumps({"providers": rows}, indent=2)


@mcp.tool()
def burnbar_search_conversations(
    query: str,
    provider: str | None = None,
    project_name: str | None = None,
    limit: int = 30,
) -> str:
    """
    Full-text search over indexed conversations (FTS5 on title + fullText), same family of queries as the OpenBurnBar app.
    `provider` must match stored values (see burnbar_list_providers), e.g. \"Codex\", \"Claude Code\".
    """
    q = fts5_safe_query(query)
    if not q:
        return json.dumps({"error": "empty query after sanitization"}, indent=2)
    lim = max(1, min(int(limit), 200))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        try:
            sql = """
            SELECT c.id, c.provider, c.sessionId, c.projectName, c.startTime, c.inferredTaskTitle,
                   bm25(conversations_fts) AS rank,
                   snippet(conversations_fts, 1, '<b>', '</b>', '…', 12) AS snippet
            FROM conversations_fts
            JOIN conversations AS c ON c.rowid = conversations_fts.rowid
            WHERE conversations_fts MATCH ?
            """
            args: list[Any] = [q]
            if provider:
                sql += " AND c.provider = ?"
                args.append(provider)
            if project_name:
                sql += " AND c.projectName = ?"
                args.append(project_name)
            sql += " ORDER BY rank ASC LIMIT ?"
            args.append(lim)
            cur = conn.execute(sql, args)
            out = [_row_to_dict(row) for row in cur.fetchall()]
        except sqlite3.OperationalError as e:
            return json.dumps(
                {"error": str(e), "hint": "FTS missing or DB schema mismatch; is this a OpenBurnBar DB?"},
                indent=2,
            )
    return json.dumps({"results": out}, indent=2)


@mcp.tool()
def burnbar_get_conversation(conversation_id: str, max_full_text_chars: int = 120_000) -> str:
    """Load one conversation row by id, including fullText (truncated if over max_full_text_chars)."""
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute("SELECT * FROM conversations WHERE id = ?", (conversation_id,))
        row = cur.fetchone()
    if not row:
        return json.dumps({"error": "not found", "id": conversation_id}, indent=2)
    d = _row_to_dict(row)
    ft = d.get("fullText")
    if isinstance(ft, str) and len(ft) > max_full_text_chars:
        d["fullText"] = ft[: max_full_text_chars // 2] + "\n… [truncated] …\n" + ft[-max_full_text_chars // 2 :]
        d["fullTextTruncated"] = True
    return json.dumps(d, indent=2, default=str)


@mcp.tool()
def burnbar_recent_usage(limit: int = 40) -> str:
    """Recent token_usage rows (cost, model, provider, session, times)."""
    lim = max(1, min(int(limit), 500))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            """
            SELECT id, provider, sessionId, projectName, model, totalTokens, cost, startTime, endTime
            FROM token_usage
            ORDER BY startTime DESC
            LIMIT ?
            """,
            (lim,),
        )
        rows = [_row_to_dict(r) for r in cur.fetchall()]
    return json.dumps({"usage": rows}, indent=2, default=str)


@mcp.tool()
def burnbar_project_summary(project_name: str | None = None, days: int = 30) -> str:
    """
    Pre-aggregated cost and session summary per project over a rolling time window.
    Pass project_name to narrow to one project, or omit for all projects ranked by total cost.
    """
    lim_days = max(1, min(int(days), 365))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        sql = """
            SELECT
                projectName,
                COUNT(DISTINCT sessionId) AS sessions,
                SUM(totalTokens) AS totalTokens,
                SUM(cost) AS totalCost,
                MIN(startTime) AS firstSession,
                MAX(startTime) AS lastSession,
                COUNT(DISTINCT model) AS modelsUsed,
                COUNT(DISTINCT provider) AS providersUsed
            FROM token_usage
            WHERE startTime >= datetime('now', ? || ' days')
        """
        args: list[Any] = [f"-{lim_days}"]
        if project_name:
            sql += " AND projectName = ?"
            args.append(project_name)
        sql += " GROUP BY projectName ORDER BY totalCost DESC"
        cur = conn.execute(sql, args)
        rows = [_row_to_dict(r) for r in cur.fetchall()]
    return json.dumps({"days": lim_days, "projects": rows}, indent=2, default=str)


@mcp.tool()
def burnbar_chat_messages(limit: int = 80) -> str:
    """In-app assistant chat_messages rows (role + content), most recent last."""
    lim = max(1, min(int(limit), 500))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            """
            SELECT id, role, content, timestamp, cliUsed
            FROM chat_messages
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            (lim,),
        )
        rows = [_row_to_dict(r) for r in cur.fetchall()]
    return json.dumps({"messages": list(reversed(rows))}, indent=2, default=str)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
