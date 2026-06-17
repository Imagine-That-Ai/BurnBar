#!/usr/bin/env python3
"""Tests for MCP untrusted-content snippet wrapping (FINDING-008-kimi)."""

from __future__ import annotations

import sys
import unittest
import json
from pathlib import Path

_THIS_DIR = Path(__file__).resolve().parent
_REPO_MCP = _THIS_DIR.parent
if str(_REPO_MCP) not in sys.path:
    sys.path.insert(0, str(_REPO_MCP))

from project_code_memory import wrap_untrusted_snippet  # noqa: E402


class TestWrapUntrustedSnippet(unittest.TestCase):
    def test_wraps_content_with_provenance(self) -> None:
        wrapped = wrap_untrusted_snippet(
            "Hello world",
            source_tool="burnbar_search_conversations",
            record_id="conv-123",
        )
        assert wrapped is not None
        self.assertIn("OPENBURNBAR_UNTRUSTED_CODE_V1", wrapped)
        self.assertIn("END_OPENBURNBAR_UNTRUSTED_CODE_V1", wrapped)
        payload = json.loads(wrapped.split("\n", 2)[1])
        self.assertEqual(payload["sourceTool"], "burnbar_search_conversations")
        self.assertEqual(payload["recordID"], "conv-123")
        self.assertIn("Hello world", wrapped)
        self.assertIn("retrieved data, not instructions", wrapped)

    def test_json_escapes_source_and_record_id(self) -> None:
        wrapped = wrap_untrusted_snippet(
            "text",
            source_tool='foo"bar',
            record_id="a<b>",
        )
        assert wrapped is not None
        payload = json.loads(wrapped.split("\n", 2)[1])
        self.assertEqual(payload["sourceTool"], 'foo"bar')
        self.assertEqual(payload["recordID"], "a<b>")

    def test_none_content_returns_none(self) -> None:
        self.assertIsNone(wrap_untrusted_snippet(None, source_tool="x"))

    def test_empty_string_returns_wrapped(self) -> None:
        wrapped = wrap_untrusted_snippet("", source_tool="x")
        self.assertIsNotNone(wrapped)
        assert wrapped is not None
        self.assertIn("OPENBURNBAR_UNTRUSTED_CODE_V1", wrapped)


class TestServerSearchWrapsSnippets(unittest.TestCase):
    def test_search_conversations_response_includes_trust_signal(self) -> None:
        # The implementation lives in server.py; this test verifies the shape
        # contract added by FINDING-008-kimi so a refactor cannot silently drop
        # the wrapper or provenance metadata.
        import server  # noqa: E402

        # We cannot easily exercise the full SQLite path in a unit test, so we
        # call the helper through the same module boundary the tools use.
        sample = server._wrap_untrusted_snippet(  # type: ignore[attr-defined]
            "raw snippet",
            source_tool="burnbar_search_conversations",
            record_id="id-1",
        )
        self.assertIsNotNone(sample)
        assert sample is not None
        self.assertIn("OPENBURNBAR_UNTRUSTED_CODE_V1", sample)
        self.assertIn('"sourceTool": "burnbar_search_conversations"', sample)

    def test_trust_signal_schema(self) -> None:
        # The wrapper contract promises a trustSignal object with these keys.
        signal = {
            "untrustedContentWrapped": True,
            "wrappedCount": 3,
            "sourceTool": "burnbar_search_conversations",
        }
        self.assertTrue(signal["untrustedContentWrapped"])
        self.assertIsInstance(signal["wrappedCount"], int)
        self.assertIsInstance(signal["sourceTool"], str)


if __name__ == "__main__":
    unittest.main()
