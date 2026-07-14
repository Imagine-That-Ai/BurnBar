from __future__ import annotations

import copy
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", SCRIPT)
assert SPEC and SPEC.loader
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)


class DomainCoreLegacyDeletionGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name).resolve()
        (self.repo / "config").mkdir()
        (self.repo / "src").mkdir()
        self.manifest_path = self.repo / "config/domain-core-legacy-deletion.json"
        self.manifest = self.make_manifest()
        self.write_manifest()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_manifest(self) -> dict:
        rows = []
        for index, row_id in enumerate(GATE.ROW_IDS):
            path = f"src/legacy_{index}.txt"
            symbol = f"legacySymbol{index}"
            (self.repo / path).write_text(f"func {symbol}() {{}}\n", encoding="utf-8")
            rows.append(
                {
                    "id": row_id,
                    "state": "rollout",
                    "receipts": {},
                    "targets": [{"kind": "source_symbol", "root": "source", "path": path, "symbol": symbol}],
                }
            )
        return {"schemaVersion": 1, "sourceRoots": {"source": "src"}, "rows": rows, "sharedTargets": []}

    def write_manifest(self) -> None:
        self.manifest_path.write_text(json.dumps(self.manifest, indent=2) + "\n", encoding="utf-8")

    def gate(self) -> None:
        GATE.run_gate(self.repo, self.manifest_path)

    def expect_failure(self, pattern: str) -> None:
        with self.assertRaisesRegex(GATE.GateError, pattern):
            self.gate()

    def add_receipts(self, row_index: int, *, deleted: bool = False) -> None:
        row = self.manifest["rows"][row_index]
        receipts = {"promotion": "promotion", "stableRelease": "stable_release"}
        if deleted:
            receipts["deletionReview"] = "deletion_review"
        row["receipts"] = {}
        for key, transition in receipts.items():
            path = f"config/domain-core-legacy-deletion-receipts/{row['id']}/{transition}.json"
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / path).write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "rowId": row["id"],
                        "transition": transition,
                        "status": "active",
                        "evidence": [f"https://evidence.openburnbar.com/{row_index}/{transition}"],
                        "approvedBy": "@release-owner",
                        "approvedAt": "2026-01-01T00:00:00Z",
                        "commit": "a" * 40,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            row["receipts"][key] = path

    def delete_row_target(self, row_index: int) -> None:
        (self.repo / self.manifest["rows"][row_index]["targets"][0]["path"]).unlink()

    def test_committed_manifest_passes_against_checkout(self) -> None:
        GATE.run_gate(ROOT, ROOT / "config/domain-core-legacy-deletion.json")

    def test_rollout_manifest_passes(self) -> None:
        self.gate()

    def test_rollout_target_cannot_disappear(self) -> None:
        self.delete_row_target(0)
        self.expect_failure("absent before legacy_deleted")

    def test_authoritative_state_requires_both_active_receipts(self) -> None:
        self.manifest["rows"][0]["state"] = "rust_authoritative_with_rollback"
        self.write_manifest()
        self.expect_failure("missing fields: promotion, stableRelease")

        self.add_receipts(0)
        self.write_manifest()
        self.gate()

    def test_deleted_state_requires_receipts_and_absent_target(self) -> None:
        row = self.manifest["rows"][0]
        row["state"] = "legacy_deleted"
        self.add_receipts(0, deleted=True)
        self.write_manifest()
        self.expect_failure("remains after legacy_deleted")
        self.delete_row_target(0)
        self.gate()

    def test_deleted_state_cannot_drop_receipt(self) -> None:
        row = self.manifest["rows"][0]
        row["state"] = "legacy_deleted"
        self.add_receipts(0, deleted=True)
        del row["receipts"]["deletionReview"]
        self.delete_row_target(0)
        self.write_manifest()
        self.expect_failure("missing fields: deletionReview")

    def test_exact_stable_row_set_is_required(self) -> None:
        self.manifest["rows"].pop()
        self.write_manifest()
        self.expect_failure("exact stable row set")

    def test_duplicate_row_id_is_rejected(self) -> None:
        self.manifest["rows"][1]["id"] = self.manifest["rows"][0]["id"]
        self.write_manifest()
        self.expect_failure("duplicate row id")

    def test_unknown_manifest_row_and_target_fields_are_rejected(self) -> None:
        for location, pattern in (
            ("manifest", "manifest: unknown fields"),
            ("row", r"rows\[0\]: unknown fields"),
            ("target", r"targets\[0\]: unknown fields"),
        ):
            mutated = self.make_manifest()
            if location == "manifest":
                mutated["surprise"] = True
            elif location == "row":
                mutated["rows"][0]["surprise"] = True
            else:
                mutated["rows"][0]["targets"][0]["surprise"] = True
            self.manifest = mutated
            self.write_manifest()
            self.expect_failure(pattern)

    def test_unknown_state_kind_and_root_are_rejected(self) -> None:
        mutations = (
            ("state", "complete", "unknown state"),
            ("kind", "regex", "unknown target kind"),
            ("root", "missing", "unknown source root"),
        )
        for field, value, pattern in mutations:
            manifest = self.make_manifest()
            if field == "state":
                manifest["rows"][0][field] = value
            else:
                manifest["rows"][0]["targets"][0][field] = value
            self.manifest = manifest
            self.write_manifest()
            self.expect_failure(pattern)

    def test_duplicate_json_keys_and_malformed_json_are_rejected(self) -> None:
        self.manifest_path.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
        self.expect_failure("duplicate JSON key")
        self.manifest_path.write_text("{", encoding="utf-8")
        self.expect_failure("invalid JSON")

    def test_duplicate_root_paths_and_targets_are_rejected(self) -> None:
        self.manifest["sourceRoots"]["duplicate"] = "src"
        self.write_manifest()
        self.expect_failure("duplicate root path")

        self.manifest = self.make_manifest()
        self.manifest["rows"][1]["targets"][0] = copy.deepcopy(self.manifest["rows"][0]["targets"][0])
        self.write_manifest()
        self.expect_failure("duplicate target")

    def test_noncanonical_and_escaping_paths_are_rejected(self) -> None:
        for value in ("/src/file", "src/../file", "src\\file", "src/./file"):
            self.manifest = self.make_manifest()
            self.manifest["rows"][0]["targets"][0]["path"] = value
            self.write_manifest()
            self.expect_failure("canonical POSIX")

    def test_target_must_be_inside_declared_root(self) -> None:
        (self.repo / "outside.txt").write_text("legacySymbol0", encoding="utf-8")
        self.manifest["rows"][0]["targets"][0]["path"] = "outside.txt"
        self.write_manifest()
        self.expect_failure("outside declared source root")

    def test_missing_root_is_rejected(self) -> None:
        self.manifest["sourceRoots"]["source"] = "missing"
        self.write_manifest()
        self.expect_failure("required path is missing")

    @unittest.skipIf(os.name == "nt", "symlink setup is platform-specific")
    def test_root_and_target_symlinks_are_rejected(self) -> None:
        real = self.repo / "real"
        real.mkdir()
        (self.repo / "linked").symlink_to(real, target_is_directory=True)
        self.manifest["sourceRoots"]["source"] = "linked"
        self.write_manifest()
        self.expect_failure("symlink components are forbidden")

        self.manifest = self.make_manifest()
        target = self.repo / self.manifest["rows"][0]["targets"][0]["path"]
        target.unlink()
        outside = self.repo / "outside-source.txt"
        outside.write_text("legacySymbol0", encoding="utf-8")
        target.symlink_to(outside)
        self.write_manifest()
        self.expect_failure("symlink components are forbidden")

    def test_receipt_is_strict_active_and_bound_to_transition(self) -> None:
        self.manifest["rows"][0]["state"] = "rust_authoritative_with_rollback"
        self.add_receipts(0)
        self.write_manifest()
        receipt_path = self.repo / self.manifest["rows"][0]["receipts"]["promotion"]
        baseline = json.loads(receipt_path.read_text(encoding="utf-8"))
        mutations = (
            ("status", "revoked", "status must be active"),
            ("rowId", GATE.ROW_IDS[1], "rowId must be"),
            ("transition", "deletion_review", "transition must be promotion"),
            ("commit", "abc", "full lowercase Git SHA"),
            ("approvedBy", "release-owner", "GitHub handle"),
            ("approvedAt", "2999-01-01T00:00:00Z", "cannot be in the future"),
        )
        for field, value, pattern in mutations:
            receipt = dict(baseline)
            receipt[field] = value
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            self.expect_failure(pattern)

    def test_receipt_rejects_unknown_fields_duplicate_keys_and_unsafe_evidence(self) -> None:
        self.manifest["rows"][0]["state"] = "rust_authoritative_with_rollback"
        self.add_receipts(0)
        self.write_manifest()
        receipt_path = self.repo / self.manifest["rows"][0]["receipts"]["promotion"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["surprise"] = True
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("unknown fields")

        receipt_path.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
        self.expect_failure("duplicate JSON key")

        receipt.pop("surprise")
        receipt["evidence"] = ["https://user:secret@example.com/run?token=x"]
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("credential-free HTTPS URI")

        receipt["evidence"] = [{"url": "https://example.com"}]
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("expected HTTPS URI")

        receipt["evidence"] = ["https://example.com/run", "https://example.com/run"]
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("non-empty unique array")

    def test_receipt_paths_must_exist_and_be_unique(self) -> None:
        self.manifest["rows"][0]["state"] = "rust_authoritative_with_rollback"
        self.add_receipts(0)
        self.manifest["rows"][0]["receipts"]["stableRelease"] = self.manifest["rows"][0]["receipts"]["promotion"]
        self.write_manifest()
        self.expect_failure("must use exact path")

        self.manifest["rows"][0]["receipts"]["stableRelease"] = (
            "config/domain-core-legacy-deletion-receipts/"
            f"{GATE.ROW_IDS[0]}/stable_release.json"
        )
        (self.repo / self.manifest["rows"][0]["receipts"]["stableRelease"]).unlink()
        self.write_manifest()
        self.expect_failure("required path is missing")

    def test_mode_literal_and_path_targets_follow_state(self) -> None:
        row = self.manifest["rows"][0]
        source = self.repo / row["targets"][0]["path"]
        source.write_text("OPENBURNBAR_TEST_MODE\n", encoding="utf-8")
        row["targets"] = [
            {"kind": "mode_literal", "root": "source", "path": source.relative_to(self.repo).as_posix(), "literal": "OPENBURNBAR_TEST_MODE"}
        ]
        self.write_manifest()
        self.gate()

        row["targets"] = [
            {"kind": "path", "root": "source", "path": source.relative_to(self.repo).as_posix()}
        ]
        self.write_manifest()
        self.gate()

    @unittest.skipIf(os.name == "nt", "FIFO setup is platform-specific")
    def test_path_target_rejects_special_files(self) -> None:
        row = self.manifest["rows"][0]
        source = self.repo / row["targets"][0]["path"]
        source.unlink()
        os.mkfifo(source)
        row["targets"] = [
            {"kind": "path", "root": "source", "path": source.relative_to(self.repo).as_posix()}
        ]
        self.write_manifest()
        self.expect_failure("regular file or directory")

    def test_shared_target_remains_until_every_member_is_deleted(self) -> None:
        shared_path = self.repo / "src/shared.txt"
        shared_path.write_text("OPENBURNBAR_SHARED_MODE\n", encoding="utf-8")
        members = list(GATE.ROW_IDS[:2])
        self.manifest["sharedTargets"] = [
            {
                "rowIds": members,
                "target": {
                    "kind": "mode_literal",
                    "root": "source",
                    "path": "src/shared.txt",
                    "literal": "OPENBURNBAR_SHARED_MODE",
                },
            }
        ]
        for index in range(2):
            self.manifest["rows"][index]["state"] = "legacy_deleted"
            self.add_receipts(index, deleted=True)
            self.delete_row_target(index)
        self.write_manifest()
        self.expect_failure("remains after every member row")
        shared_path.unlink()
        self.gate()

    def test_shared_target_cannot_disappear_while_one_member_is_active(self) -> None:
        self.manifest["sharedTargets"] = [
            {
                "rowIds": list(GATE.ROW_IDS[:2]),
                "target": {
                    "kind": "mode_literal",
                    "root": "source",
                    "path": "src/missing-shared.txt",
                    "literal": "OPENBURNBAR_SHARED_MODE",
                },
            }
        ]
        self.write_manifest()
        self.expect_failure("absent while a member row is active")


if __name__ == "__main__":
    unittest.main()
