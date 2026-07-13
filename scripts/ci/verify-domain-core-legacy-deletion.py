#!/usr/bin/env python3
"""Fail-closed source gate for shared-Rust legacy implementation deletion."""

from __future__ import annotations

import argparse
import json
import re
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import urlsplit


ROW_IDS = (
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
    "quota.anthropic_headers",
    "cloudvault.portable_primitives",
    "cloudvault.document_rewrap",
    "cloudvault.search",
    "hermes.relay_crypto",
    "hermes.ratchet_transforms",
    "pricing.token_cost",
    "pricing.kimi_historical",
)
STATES = {"rollout", "rust_authoritative_with_rollback", "legacy_deleted"}
TARGET_KINDS = {"source_symbol", "mode_literal", "path"}
RECEIPT_TRANSITIONS = {
    "promotion": "promotion",
    "stableRelease": "stable_release",
    "deletionReview": "deletion_review",
}
RECEIPT_ROOT = "config/domain-core-legacy-deletion-receipts"
ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
ROW_ID_RE = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$")
SYMBOL_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
MODE_LITERAL_RE = re.compile(r"^[A-Z][A-Z0-9_]{2,127}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
RECEIPT_ACTOR_RE = re.compile(r"^@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
RFC3339_UTC_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$"
)


class GateError(ValueError):
    pass


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise GateError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=_no_duplicate_keys)
    except (OSError, json.JSONDecodeError, UnicodeError, GateError) as error:
        raise GateError(f"{label}: invalid JSON: {error}") from error


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GateError(f"{label}: expected object")
    return value


def require_array(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise GateError(f"{label}: expected array")
    return value


def exact_keys(value: dict[str, Any], allowed: set[str], required: set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    missing = sorted(required - set(value))
    if unknown:
        raise GateError(f"{label}: unknown fields: {', '.join(unknown)}")
    if missing:
        raise GateError(f"{label}: missing fields: {', '.join(missing)}")


def repository_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise GateError(f"{label}: expected non-empty repository-relative path")
    if "\\" in value or value.startswith("/") or value.endswith("/"):
        raise GateError(f"{label}: path must be canonical POSIX repository-relative form")
    path = PurePosixPath(value)
    if str(path) != value or any(part in {"", ".", ".."} for part in path.parts):
        raise GateError(f"{label}: path must be canonical POSIX repository-relative form")
    return value


def _inside_repo(repo_root: Path, candidate: Path, label: str) -> None:
    try:
        candidate.relative_to(repo_root)
    except ValueError as error:
        raise GateError(f"{label}: path escapes repository root") from error


def secure_path(repo_root: Path, relative: str, label: str, *, must_exist: bool) -> Path:
    lexical = repo_root.joinpath(*PurePosixPath(relative).parts)
    _inside_repo(repo_root, lexical, label)
    current = repo_root
    for part in PurePosixPath(relative).parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            break
        except OSError as error:
            raise GateError(f"{label}: cannot inspect path: {error}") from error
        if stat.S_ISLNK(mode):
            raise GateError(f"{label}: symlink components are forbidden: {relative}")
    if must_exist and not lexical.exists():
        raise GateError(f"{label}: required path is missing: {relative}")
    if lexical.exists():
        try:
            resolved = lexical.resolve(strict=True)
        except OSError as error:
            raise GateError(f"{label}: cannot resolve path: {error}") from error
        _inside_repo(repo_root, resolved, label)
    return lexical


def parse_rfc3339_utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not RFC3339_UTC_RE.fullmatch(value):
        raise GateError(f"{label}: expected RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise GateError(f"{label}: expected RFC3339 UTC timestamp") from error
    if parsed.tzinfo != timezone.utc:
        raise GateError(f"{label}: expected RFC3339 UTC timestamp")
    return parsed


def validate_receipt(
    repo_root: Path,
    receipt_path: str,
    row_id: str,
    transition: str,
    seen_receipts: set[str],
) -> None:
    expected_path = f"{RECEIPT_ROOT}/{row_id}/{transition}.json"
    if receipt_path != expected_path:
        raise GateError(
            f"receipt for {row_id}/{transition} must use exact path {expected_path}"
        )
    if receipt_path in seen_receipts:
        raise GateError(f"receipt path is referenced more than once: {receipt_path}")
    seen_receipts.add(receipt_path)
    path = secure_path(repo_root, receipt_path, f"receipt {receipt_path}", must_exist=True)
    if not path.is_file():
        raise GateError(f"receipt {receipt_path}: expected regular file")
    receipt = require_object(load_json(path, f"receipt {receipt_path}"), f"receipt {receipt_path}")
    exact_keys(
        receipt,
        {"schemaVersion", "rowId", "transition", "status", "evidence", "approvedBy", "approvedAt", "commit"},
        {"schemaVersion", "rowId", "transition", "status", "evidence", "approvedBy", "approvedAt", "commit"},
        f"receipt {receipt_path}",
    )
    if receipt["schemaVersion"] != 1 or isinstance(receipt["schemaVersion"], bool):
        raise GateError(f"receipt {receipt_path}: schemaVersion must be 1")
    if receipt["rowId"] != row_id:
        raise GateError(f"receipt {receipt_path}: rowId must be {row_id}")
    if receipt["transition"] != transition:
        raise GateError(f"receipt {receipt_path}: transition must be {transition}")
    if receipt["status"] != "active":
        raise GateError(f"receipt {receipt_path}: status must be active")
    evidence = require_array(
        receipt["evidence"], f"receipt {receipt_path}.evidence"
    )
    if not evidence:
        raise GateError(
            f"receipt {receipt_path}: evidence must be a non-empty unique array"
        )
    for index, uri in enumerate(evidence):
        if not isinstance(uri, str):
            raise GateError(f"receipt {receipt_path}.evidence[{index}]: expected HTTPS URI")
        try:
            parsed = urlsplit(uri)
            _ = parsed.port
            unsafe = (
                parsed.scheme != "https"
                or not parsed.netloc
                or parsed.hostname is None
                or parsed.username is not None
                or parsed.password is not None
                or bool(parsed.query)
                or bool(parsed.fragment)
            )
        except ValueError:
            unsafe = True
        if unsafe:
            raise GateError(
                f"receipt {receipt_path}.evidence[{index}]: expected "
                "credential-free HTTPS URI without query or fragment"
            )
    if len(evidence) != len(set(evidence)):
        raise GateError(
            f"receipt {receipt_path}: evidence must be a non-empty unique array"
        )
    approved_by = receipt["approvedBy"]
    if not isinstance(approved_by, str) or not RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GateError(f"receipt {receipt_path}: approvedBy must be a GitHub handle")
    approved_at = parse_rfc3339_utc(receipt["approvedAt"], f"receipt {receipt_path}.approvedAt")
    if approved_at > datetime.now(timezone.utc):
        raise GateError(f"receipt {receipt_path}: approvedAt cannot be in the future")
    if not isinstance(receipt["commit"], str) or not COMMIT_RE.fullmatch(receipt["commit"]):
        raise GateError(f"receipt {receipt_path}: commit must be a full lowercase Git SHA")


@dataclass(frozen=True)
class Target:
    kind: str
    root: str
    path: str
    value: str | None

    @property
    def identity(self) -> tuple[str, str, str]:
        return (self.kind, self.path, self.value or "")


def parse_target(raw: Any, label: str, roots: dict[str, str]) -> Target:
    value = require_object(raw, label)
    kind = value.get("kind")
    if not isinstance(kind, str) or kind not in TARGET_KINDS:
        raise GateError(f"{label}: unknown target kind: {kind!r}")
    required = {"kind", "root", "path"}
    allowed = set(required)
    if kind == "source_symbol":
        required.add("symbol")
        allowed.add("symbol")
    elif kind == "mode_literal":
        required.add("literal")
        allowed.add("literal")
    exact_keys(value, allowed, required, label)
    root_id = value["root"]
    if not isinstance(root_id, str) or root_id not in roots:
        raise GateError(f"{label}: unknown source root: {root_id!r}")
    path = repository_path(value["path"], f"{label}.path")
    root_path = roots[root_id]
    if path != root_path and not path.startswith(root_path + "/"):
        raise GateError(f"{label}: target path is outside declared source root {root_id}")
    target_value: str | None = None
    if kind == "source_symbol":
        target_value = value["symbol"]
        if not isinstance(target_value, str) or not SYMBOL_RE.fullmatch(target_value):
            raise GateError(f"{label}.symbol: expected exact source identifier")
    elif kind == "mode_literal":
        target_value = value["literal"]
        if not isinstance(target_value, str) or not MODE_LITERAL_RE.fullmatch(target_value):
            raise GateError(f"{label}.literal: expected exact uppercase mode identifier")
    return Target(kind=kind, root=root_id, path=path, value=target_value)


def target_present(repo_root: Path, target: Target, label: str) -> bool:
    path = secure_path(repo_root, target.path, label, must_exist=False)
    if not path.exists():
        return False
    if target.kind == "path":
        mode = path.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise GateError(f"{label}: path target must be a regular file or directory")
        return True
    if not path.is_file():
        raise GateError(f"{label}: source target must be a regular file")
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise GateError(f"{label}: cannot read UTF-8 source: {error}") from error
    if target.kind == "mode_literal":
        return target.value in source
    assert target.value is not None
    return re.search(rf"(?<![A-Za-z0-9_]){re.escape(target.value)}(?![A-Za-z0-9_])", source) is not None


def required_receipts(state: str) -> set[str]:
    if state == "rollout":
        return set()
    if state == "rust_authoritative_with_rollback":
        return {"promotion", "stableRelease"}
    return {"promotion", "stableRelease", "deletionReview"}


def run_gate(repo_root: Path, manifest_path: Path) -> None:
    if not repo_root.is_dir():
        raise GateError(f"repository root is missing: {repo_root}")
    repo_root = repo_root.resolve(strict=True)
    manifest_path = manifest_path if manifest_path.is_absolute() else repo_root / manifest_path
    try:
        manifest_relative = manifest_path.relative_to(repo_root).as_posix()
    except ValueError as error:
        raise GateError("manifest path must be inside repository root") from error
    manifest_path = secure_path(repo_root, manifest_relative, "manifest", must_exist=True)
    manifest = require_object(load_json(manifest_path, "manifest"), "manifest")
    manifest_fields = {"schemaVersion", "sourceRoots", "rows", "sharedTargets"}
    exact_keys(manifest, manifest_fields, manifest_fields, "manifest")
    if manifest["schemaVersion"] != 1 or isinstance(manifest["schemaVersion"], bool):
        raise GateError("manifest.schemaVersion must be 1")

    raw_roots = require_object(manifest["sourceRoots"], "manifest.sourceRoots")
    if not raw_roots:
        raise GateError("manifest.sourceRoots must not be empty")
    roots: dict[str, str] = {}
    seen_root_paths: set[str] = set()
    for root_id, raw_path in raw_roots.items():
        if not ID_RE.fullmatch(root_id):
            raise GateError(f"manifest.sourceRoots: invalid root id: {root_id!r}")
        path = repository_path(raw_path, f"manifest.sourceRoots.{root_id}")
        if path in seen_root_paths:
            raise GateError(f"manifest.sourceRoots: duplicate root path: {path}")
        seen_root_paths.add(path)
        root = secure_path(repo_root, path, f"source root {root_id}", must_exist=True)
        if not root.is_dir():
            raise GateError(f"source root {root_id}: expected directory: {path}")
        roots[root_id] = path

    raw_rows = require_array(manifest["rows"], "manifest.rows")
    rows: dict[str, tuple[str, list[Target]]] = {}
    seen_targets: set[tuple[str, str, str]] = set()
    seen_receipts: set[str] = set()
    for index, raw_row in enumerate(raw_rows):
        label = f"manifest.rows[{index}]"
        row = require_object(raw_row, label)
        row_fields = {"id", "state", "receipts", "targets"}
        exact_keys(row, row_fields, row_fields, label)
        row_id = row["id"]
        if not isinstance(row_id, str) or not ROW_ID_RE.fullmatch(row_id):
            raise GateError(f"{label}.id: invalid row id")
        if row_id in rows:
            raise GateError(f"duplicate row id: {row_id}")
        state = row["state"]
        if not isinstance(state, str) or state not in STATES:
            raise GateError(f"{label}.state: unknown state: {state!r}")
        receipts = require_object(row["receipts"], f"{label}.receipts")
        expected_receipts = required_receipts(state)
        exact_keys(receipts, expected_receipts, expected_receipts, f"{label}.receipts")
        for receipt_key, receipt_path_raw in receipts.items():
            receipt_path = repository_path(receipt_path_raw, f"{label}.receipts.{receipt_key}")
            validate_receipt(repo_root, receipt_path, row_id, RECEIPT_TRANSITIONS[receipt_key], seen_receipts)
        raw_targets = require_array(row["targets"], f"{label}.targets")
        if not raw_targets:
            raise GateError(f"{label}.targets must not be empty")
        targets: list[Target] = []
        for target_index, raw_target in enumerate(raw_targets):
            target = parse_target(raw_target, f"{label}.targets[{target_index}]", roots)
            if target.identity in seen_targets:
                raise GateError(f"duplicate target: {target.identity}")
            seen_targets.add(target.identity)
            targets.append(target)
        rows[row_id] = (state, targets)

    missing_rows = sorted(set(ROW_IDS) - set(rows))
    unknown_rows = sorted(set(rows) - set(ROW_IDS))
    if missing_rows or unknown_rows or len(raw_rows) != len(ROW_IDS):
        details = []
        if missing_rows:
            details.append("missing " + ", ".join(missing_rows))
        if unknown_rows:
            details.append("unknown " + ", ".join(unknown_rows))
        raise GateError("manifest.rows must contain the exact stable row set: " + "; ".join(details))

    for row_id in ROW_IDS:
        state, targets = rows[row_id]
        expected_present = state != "legacy_deleted"
        for index, target in enumerate(targets):
            label = f"row {row_id} target[{index}]"
            present = target_present(repo_root, target, label)
            if expected_present and not present:
                raise GateError(f"{label}: legacy target is absent before legacy_deleted: {target.identity}")
            if not expected_present and present:
                raise GateError(f"{label}: legacy target remains after legacy_deleted: {target.identity}")

    raw_shared = require_array(manifest["sharedTargets"], "manifest.sharedTargets")
    shared_memberships: set[tuple[str, ...]] = set()
    for index, raw_shared_target in enumerate(raw_shared):
        label = f"manifest.sharedTargets[{index}]"
        shared = require_object(raw_shared_target, label)
        exact_keys(shared, {"rowIds", "target"}, {"rowIds", "target"}, label)
        row_ids = require_array(shared["rowIds"], f"{label}.rowIds")
        if len(row_ids) < 2 or any(not isinstance(row_id, str) for row_id in row_ids):
            raise GateError(f"{label}.rowIds: expected at least two row ids")
        if len(row_ids) != len(set(row_ids)):
            raise GateError(f"{label}.rowIds: duplicate row ids")
        unknown = sorted(set(row_ids) - set(rows))
        if unknown:
            raise GateError(f"{label}.rowIds: unknown rows: {', '.join(unknown)}")
        membership = tuple(sorted(row_ids))
        target = parse_target(shared["target"], f"{label}.target", roots)
        if target.identity in seen_targets:
            raise GateError(f"duplicate target: {target.identity}")
        seen_targets.add(target.identity)
        membership_target = membership + (repr(target.identity),)
        if membership_target in shared_memberships:
            raise GateError(f"{label}: duplicate shared target")
        shared_memberships.add(membership_target)
        expected_present = any(rows[row_id][0] != "legacy_deleted" for row_id in row_ids)
        present = target_present(repo_root, target, f"{label}.target")
        if expected_present and not present:
            raise GateError(f"{label}: shared legacy target is absent while a member row is active")
        if not expected_present and present:
            raise GateError(f"{label}: shared legacy target remains after every member row is legacy_deleted")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--manifest", type=Path, default=Path("config/domain-core-legacy-deletion.json"))
    args = parser.parse_args(argv)
    try:
        run_gate(args.repo_root, args.manifest)
    except GateError as error:
        print(f"ERROR: domain-core legacy deletion gate failed: {error}", file=sys.stderr)
        return 1
    print("PASS: domain-core legacy deletion ledger and source targets are consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
