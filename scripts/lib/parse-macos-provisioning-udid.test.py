#!/usr/bin/env python3

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("parse-macos-provisioning-udid.py")


class ParseMacOSProvisioningUDIDTests(unittest.TestCase):
    def run_parser(self, payload: object | str) -> subprocess.CompletedProcess[str]:
        input_text = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=input_text,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_and_trims_one_valid_identifier(self) -> None:
        result = self.run_parser(
            {
                "SPHardwareDataType": [
                    {"provisioning_UDID": " AAAAAAAA-BBBBBBBB "},
                ]
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "AAAAAAAA-BBBBBBBB\n")

    def test_rejects_malformed_json(self) -> None:
        result = self.run_parser("not-json")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed JSON", result.stderr)

    def test_rejects_missing_identifier(self) -> None:
        result = self.run_parser({"SPHardwareDataType": []})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)

    def test_rejects_ambiguous_identifiers(self) -> None:
        result = self.run_parser(
            {
                "SPHardwareDataType": [
                    {"provisioning_UDID": "AAAAAAAA-BBBBBBBB"},
                    {"provisioning_UDID": "CCCCCCCC-DDDDDDDD"},
                ]
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 2", result.stderr)

    def test_rejects_malformed_identifier(self) -> None:
        result = self.run_parser(
            {"SPHardwareDataType": [{"provisioning_UDID": "not valid"}]}
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed provisioning_UDID", result.stderr)


if __name__ == "__main__":
    unittest.main()
