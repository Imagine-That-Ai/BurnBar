#!/usr/bin/env python3
"""Prove deleted legacy code is absent from source, build inputs, and loaded final binaries."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import struct
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", GATE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {GATE_PATH}")
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)

REQUIRED_FINAL_ARTIFACTS = {
    "swift-xcframework",
    "kotlin-aar",
    "csharp-native",
    "browser-wasm",
    "node-wasm",
    "windows-native-x64-binary",
    "windows-native-arm64-binary",
    "linux-arm64-native-binary",
}
BUILD_GRAPH_SUFFIXES = {
    ".csproj",
    ".gradle",
    ".kts",
    ".pbxproj",
    ".swift",
    ".toml",
    ".xcconfig",
    ".xml",
    ".yaml",
    ".yml",
}


def artifact_sha256(path: Path) -> str:
    if path.is_symlink():
        raise GATE.GateError(f"final artifact cannot be a symlink: {path}")
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    if not path.is_dir():
        raise GATE.GateError(f"final artifact is neither a file nor directory: {path}")
    digest = hashlib.sha256()
    count = 0
    for child in sorted(value for value in path.rglob("*") if value.is_file() or value.is_symlink()):
        if child.is_symlink():
            raise GATE.GateError(f"final artifact directory contains a symlink: {child}")
        relative = child.relative_to(path).as_posix().encode()
        contents = child.read_bytes()
        digest.update(struct.pack(">I", len(relative)))
        digest.update(relative)
        digest.update(struct.pack(">Q", len(contents)))
        digest.update(contents)
        count += 1
    if count == 0:
        raise GATE.GateError(f"final artifact directory is empty: {path}")
    return digest.hexdigest()


def tracked_files(repo_root: Path) -> list[str]:
    output = GATE.git_output(repo_root, ["ls-files", "-z"], "tracked build graph")
    return [value for value in output.split("\0") if value]


def verify_source_and_build_graph(repo_root: Path, manifest: dict[str, Any]) -> list[str]:
    roots = GATE.require_object(manifest["sourceRoots"], "manifest.sourceRoots")
    deleted = []
    graph_files = [
        path
        for path in tracked_files(repo_root)
        if Path(path).suffix in BUILD_GRAPH_SUFFIXES and not path.startswith(("config/domain-core-legacy-deletion", "docs/", "tests/"))
    ]
    graph_text = {path: (repo_root / path).read_text(encoding="utf-8", errors="replace") for path in graph_files if (repo_root / path).is_file()}
    for raw_row in GATE.require_array(manifest["rows"], "manifest.rows"):
        row = GATE.require_object(raw_row, "manifest row")
        if row.get("state") != "legacy_deleted":
            continue
        row_id = row["id"]
        deleted.append(row_id)
        for index, raw_target in enumerate(GATE.require_array(row["targets"], f"row {row_id}.targets")):
            target = GATE.parse_target(raw_target, f"row {row_id}.targets[{index}]", roots)
            if target.role != "legacy_implementation":
                continue
            if GATE.target_present(repo_root, target, f"row {row_id} target[{index}]"):
                raise GATE.GateError(f"row {row_id}: inventoried legacy target still exists")
            root = repo_root / roots[target.root]
            if target.kind != "path":
                for source in root.rglob("*"):
                    if source.is_file() and not source.is_symlink():
                        if target.value in source.read_text(encoding="utf-8", errors="replace"):
                            raise GATE.GateError(f"row {row_id}: deleted legacy identifier remains elsewhere in source root: {source.relative_to(repo_root)}")
            needles = {target.path, Path(target.path).name}
            for graph_path, contents in graph_text.items():
                if any(needle in contents for needle in needles):
                    raise GATE.GateError(f"row {row_id}: build graph still references deleted legacy input in {graph_path}")
    return deleted


def verify_final_artifacts(repo_root: Path, fragments_root: Path, artifacts_root: Path) -> dict[str, str]:
    expected_identity = GATE.candidate_identity_at_commit(repo_root, GATE.git_output(repo_root, ["rev-parse", "HEAD"], "HEAD").strip())
    declared: dict[str, dict[str, Any]] = {}
    for path in fragments_root.rglob("*.json"):
        value = json.loads(path.read_text())
        for item in value.get("artifacts", []) if isinstance(value, dict) else []:
            artifact_id = item.get("id")
            if artifact_id in declared:
                raise GATE.GateError(f"duplicate final artifact proof: {artifact_id}")
            declared[artifact_id] = item
    if set(declared) != REQUIRED_FINAL_ARTIFACTS:
        missing = sorted(REQUIRED_FINAL_ARTIFACTS - set(declared))
        extra = sorted(set(declared) - REQUIRED_FINAL_ARTIFACTS)
        raise GATE.GateError(f"final artifact proof set mismatch; missing={missing}; extra={extra}")
    staged: list[tuple[str, str, dict[str, Any]]] = []
    for report in artifacts_root.rglob("observed-identity.json"):
        artifact = report.parent / "artifact"
        if not artifact.exists():
            raise GATE.GateError(f"observed identity has no staged artifact: {report}")
        identity = GATE.require_object(json.loads(report.read_text()), f"observed identity {report}")
        staged.append(
            (
                artifact_sha256(artifact),
                hashlib.sha256(report.read_bytes()).hexdigest(),
                identity,
            )
        )
    resolved: dict[str, str] = {}
    for artifact_id, item in declared.items():
        matches = [entry for entry in staged if entry[0] == item.get("artifactSha256") and entry[1] == item.get("identityReportSha256")]
        if len(matches) != 1:
            raise GATE.GateError(f"{artifact_id}: final binary bytes and observed identity are not uniquely staged")
        if item.get("loadedIdentity") != expected_identity or matches[0][2] != expected_identity:
            raise GATE.GateError(f"{artifact_id}: final loaded Rust identity does not equal the deletion head build")
        resolved[artifact_id] = item["artifactSha256"]
    return resolved


def run(repo_root: Path, manifest_path: Path, fragments: Path | None, artifacts: Path | None) -> dict[str, Any]:
    manifest = GATE.require_object(GATE.load_json(manifest_path, "manifest"), "manifest")
    deleted = verify_source_and_build_graph(repo_root, manifest)
    final_artifacts: dict[str, str] = {}
    if deleted:
        if fragments is None or artifacts is None:
            raise GATE.GateError("legacy_deleted requires exact proof fragments and staged final binaries")
        final_artifacts = verify_final_artifacts(repo_root, fragments, artifacts)
    return {
        "schemaVersion": 1,
        "deletedRows": sorted(deleted),
        "finalArtifacts": final_artifacts,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--manifest", type=Path, default=Path("config/domain-core-legacy-deletion.json"))
    parser.add_argument("--fragments", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    manifest = args.manifest if args.manifest.is_absolute() else repo_root / args.manifest
    try:
        result = run(repo_root, manifest, args.fragments, args.artifacts)
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.write_text(encoded)
        else:
            print(encoded, end="")
    except (GATE.GateError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: domain-core legacy absence proof failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
