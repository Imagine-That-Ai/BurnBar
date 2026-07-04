"""D8 — MCP tool parity matrix drift guard."""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
MATRIX = REPO_ROOT / "docs/reviews/MCP_TOOL_PARITY_MATRIX.md"
GENERATOR = REPO_ROOT / "scripts/ci/generate-mcp-tool-parity-matrix.mjs"


class ToolParityMatrixTests(unittest.TestCase):
    def test_committed_matrix_matches_generator(self) -> None:
        self.assertTrue(MATRIX.is_file(), "committed parity matrix missing")
        self.assertTrue(GENERATOR.is_file(), "parity generator missing")
        proc = subprocess.run(
            ["node", str(GENERATOR), "--check"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg=proc.stderr or proc.stdout or "parity matrix drift",
        )


if __name__ == "__main__":
    unittest.main()
