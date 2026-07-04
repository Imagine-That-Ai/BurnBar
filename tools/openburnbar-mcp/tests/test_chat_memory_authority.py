"""Tests for chat-memory authority read helpers (B6)."""

from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import chat_memory_authority as chat_mem


def _chat_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE agent_memories (
            id TEXT PRIMARY KEY,
            kind TEXT,
            user_id TEXT,
            agent_id TEXT,
            run_id TEXT,
            app_id TEXT,
            project_id TEXT,
            confidence REAL,
            body_redacted TEXT,
            review_status TEXT,
            source_kind TEXT,
            valid_from TEXT,
            valid_to TEXT,
            created_at TEXT,
            updated_at TEXT
        );
        """
    )
    conn.execute(
        """
        INSERT INTO agent_memories VALUES (
            'mem-1', 'preference', 'user-a', NULL, NULL, 'openburnbar', NULL,
            0.9, 'sealed::mem-1', 'approved', 'chat',
            '2026-01-01T00:00:00Z', NULL,
            '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
        )
        """
    )
    conn.execute(
        """
        INSERT INTO agent_memories VALUES (
            'mem-2', 'fact', 'user-a', NULL, NULL, 'openburnbar', NULL,
            0.5, 'sealed::mem-2', 'quarantined', 'chat',
            '2026-01-01T00:00:00Z', NULL,
            '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
        )
        """
    )
    conn.commit()


class ChatMemoryAuthorityTests(unittest.TestCase):
    def test_get_chat_memory_returns_row(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "openburnbar.sqlite"
            conn = sqlite3.connect(path)
            _chat_schema(conn)
            payload = chat_mem.get_chat_memory(conn, "mem-1")
            self.assertEqual(payload["status"], "ok")
            self.assertEqual(payload["memory"]["id"], "mem-1")
            self.assertEqual(payload["memory"]["reviewStatus"], "approved")

    def test_list_chat_memories_pages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "openburnbar.sqlite"
            conn = sqlite3.connect(path)
            _chat_schema(conn)
            payload = chat_mem.list_chat_memories(conn, review_status="approved")
            self.assertEqual(payload["status"], "ok")
            self.assertEqual(payload["total"], 1)
            self.assertEqual(len(payload["items"]), 1)

    def test_list_entities_groups_approved(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "openburnbar.sqlite"
            conn = sqlite3.connect(path)
            _chat_schema(conn)
            payload = chat_mem.list_chat_memory_entities(conn)
            self.assertEqual(payload["status"], "ok")
            self.assertTrue(any(e["value"] == "user-a" for e in payload["entities"]))

    def test_missing_schema_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "openburnbar.sqlite"
            conn = sqlite3.connect(path)
            conn.execute("CREATE TABLE agent_memories (id TEXT PRIMARY KEY)")
            payload = chat_mem.get_chat_memory(conn, "mem-1")
            self.assertEqual(payload["status"], "unavailable")


class ChatMemoryMcpToolTests(unittest.TestCase):
    def test_b6_tools_registered(self) -> None:
        import server

        names = {
            "burnbar_get_memory",
            "burnbar_list_memories",
            "burnbar_list_entities",
            "burnbar_update_memory",
            "burnbar_forget_all",
        }
        for name in names:
            self.assertTrue(hasattr(server, name), f"missing tool {name}")

    def test_update_and_forget_all_fail_closed(self) -> None:
        import server

        denied = json.loads(server.burnbar_update_memory("mem-1", review_status="approved"))
        self.assertEqual(denied["status"], "denied")
        self.assertEqual(denied["code"], "CHAT_MEMORY_WRITE_REQUIRES_MAC")
        bulk = json.loads(server.burnbar_forget_all(user_id="user-a"))
        self.assertEqual(bulk["code"], "CHAT_MEMORY_WRITE_REQUIRES_MAC")


if __name__ == "__main__":
    unittest.main()
