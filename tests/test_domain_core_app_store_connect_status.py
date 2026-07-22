from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts/ci/verify-domain-core-app-store-connect-status.py"
SPEC = importlib.util.spec_from_file_location("domain_core_asc_status", PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class AppStoreConnectStatusTests(unittest.TestCase):
    def response(self, value: object) -> Path:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        path = root / "status.json"
        path.write_text(json.dumps(value) + "\n")
        return path

    def test_accepts_one_nested_terminal_success_and_binds_exact_bytes(self) -> None:
        path = self.response({"data": {"delivery-status": "Complete"}})
        result = MODULE.validate(path)
        self.assertEqual(result["processedStatus"], "complete")
        self.assertEqual(result["statusResponseSha256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def test_rejects_nonterminal_status(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one successful"):
            MODULE.validate(self.response({"status": "processing"}))

    def test_rejects_success_mixed_with_failure(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one successful"):
            MODULE.validate(self.response({"status": "complete", "issues": [{"state": "failed"}]}))

    def test_rejects_ambiguous_duplicate_successes(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one successful"):
            MODULE.validate(self.response({"status": "complete", "state": "success"}))


if __name__ == "__main__":
    unittest.main()
