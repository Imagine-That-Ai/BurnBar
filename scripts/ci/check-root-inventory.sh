#!/usr/bin/env bash
# Shrink-only tracked-root inventory gate.
#
# The manifest is deliberately outside budgets/: it records the current root
# shape and prevents accidental root growth without pretending that a new
# absolute allowlist is practical. A path can leave only when the file really
# leaves the tracked root and the manifest is ratcheted down in the same change.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest_path="${repo_root}/governance/root-inventory.json"

case "${1:-}" in
  "")
    mode="check"
    ;;
  --self-test)
    mode="self-test"
    ;;
  *)
    echo "Usage: $0 [--self-test]" >&2
    exit 2
    ;;
esac

python3 - "$repo_root" "$manifest_path" "$mode" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
mode = sys.argv[3]


def git(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ).stdout


def tracked_root_blobs(root):
    # Read the index rather than HEAD so the gate is useful before a commit:
    # `git mv`/`git rm` are already visible to the local check, while CI's
    # clean checkout has an index identical to HEAD. `git ls-tree HEAD` was
    # used to measure the initial 57-blob inventory and remains recorded in
    # the manifest metadata.
    output = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--stage", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    paths = set()
    for record in output.split(b"\0"):
        if not record:
            continue
        metadata, path = record.split(b"\t", 1)
        fields = metadata.split()
        if len(fields) >= 1 and fields[0] != b"160000" and b"/" not in path:
            paths.add(os.fsdecode(path))
    return paths


def load_manifest(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return None, [f"cannot read {path}: {error}"]

    errors = []
    version = data.get("schemaVersion")
    if version not in (1, 2):
        errors.append("schemaVersion must be 1 (frozen base) or 2 (base + explicit amendments)")
    amendments = data.get("amendments", []) if version == 2 else []
    if version == 2 and not isinstance(amendments, list):
        errors.append("schemaVersion 2 requires an amendments array (explicit, attributed root-path additions)")
    if isinstance(amendments, list):
        for index, entry in enumerate(amendments):
            if not isinstance(entry, dict):
                errors.append(f"amendments[{index}] must be an object")
                continue
            for key in ("path", "addedBy", "reason"):
                value = entry.get(key)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"amendments[{index}] is missing a non-empty {key}")
            if isinstance(entry.get("path"), str) and "/" in entry["path"]:
                errors.append(f"amendments[{index}] path is not a root path: {entry['path']}")
    entries = data.get("paths")
    if not isinstance(entries, list):
        return None, ["manifest paths must be an array"]

    paths = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"manifest paths[{index}] must be an object")
            continue
        item = entry.get("path")
        purpose = entry.get("purpose")
        if not isinstance(item, str) or not item:
            errors.append(f"manifest paths[{index}] has no path")
            continue
        if "/" in item or item in {".", ".."}:
            errors.append(f"manifest path is not a root path: {item}")
        if not isinstance(purpose, str) or not purpose.strip() or "\n" in purpose:
            errors.append(f"manifest path has no one-line purpose: {item}")
        paths.append(item)

    if len(paths) != len(set(paths)):
        errors.append("manifest paths must be unique")
    expected_count = data.get("measuredRootBlobCount")
    if expected_count != len(paths):
        errors.append(
            f"measuredRootBlobCount={expected_count!r} does not match manifest length {len(paths)}"
        )
    maximum = data.get("maxRootBlobCount")
    if not isinstance(maximum, int):
        errors.append("maxRootBlobCount must be an integer")
    elif maximum != len(paths):
        errors.append(
            f"maxRootBlobCount={maximum} does not match manifest length {len(paths)}"
        )
    if not isinstance(expected_count, int) or expected_count != maximum:
        errors.append(
            "measuredRootBlobCount and maxRootBlobCount must match the live ratchet count"
        )
    if isinstance(data.get("initialRootBlobCount"), int) and data["initialRootBlobCount"] < len(paths):
        errors.append(
            f"manifest grew: {len(paths)} entries exceeds initialRootBlobCount={data['initialRootBlobCount']}"
        )

    historical = data.get("historicalRootPaths")
    if not isinstance(historical, list) or not all(isinstance(item, str) for item in historical):
        errors.append("historicalRootPaths must be a string array")
    else:
        initial_count = data.get("initialRootBlobCount")
        if not isinstance(initial_count, int):
            errors.append("initialRootBlobCount must be an integer")
        elif initial_count != len(historical):
            errors.append(
                "initialRootBlobCount does not match historicalRootPaths length"
            )
        allowed = set(historical) | {
            entry["path"] for entry in amendments if isinstance(entry, dict) and isinstance(entry.get("path"), str)
        }
        unknown = sorted(set(paths) - allowed)
        if unknown:
            errors.append(
                "manifest contains root paths outside its original inventory and amendments: "
                + ", ".join(unknown)
            )
    return set(paths), errors


def check_state(root, manifest):
    expected, errors = load_manifest(manifest)
    if errors:
        return errors
    actual = tracked_root_blobs(root)
    missing_from_tree = sorted(expected - actual)
    unlisted = sorted(actual - expected)
    missing_on_disk = sorted(
        item for item in expected if not (root / item).is_file()
    )
    maximum = json.loads(manifest.read_text(encoding="utf-8"))["maxRootBlobCount"]

    if unlisted:
        errors.append(
            "NEW unlisted tracked root path(s): " + ", ".join(unlisted)
        )
    if missing_from_tree:
        errors.append(
            "manifest-listed root path(s) are no longer tracked: "
            + ", ".join(missing_from_tree)
        )
    if missing_on_disk:
        errors.append(
            "manifest-listed root path(s) are missing on disk: "
            + ", ".join(missing_on_disk)
        )
    if len(actual) > maximum:
        errors.append(
            f"tracked root grew: {len(actual)} blobs exceeds maxRootBlobCount={maximum}"
        )
    if len(actual) != len(expected):
        errors.append(
            f"root count mismatch: manifest={len(expected)} tracked={len(actual)}"
        )
    return errors


def write_fixture_manifest(path, paths, maximum, historical=None):
    historical = historical or sorted(paths)
    payload = {
        "schemaVersion": 1,
        "initialRootBlobCount": len(historical),
        "measuredRootBlobCount": len(paths),
        "maxRootBlobCount": maximum,
        "historicalRootPaths": sorted(historical),
        "paths": [
            {"path": item, "purpose": f"fixture purpose for {item}"}
            for item in sorted(paths)
        ],
    }
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")


def fixture(root, names=("a.txt", "b.txt")):
    root.mkdir(parents=True)
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.name", "root-inventory-self-test")
    git(root, "config", "user.email", "root-inventory-self-test@example.invalid")
    for name in names:
        (root / name).write_text(f"{name}\n", encoding="utf-8")
    git(root, "add", *names)
    git(root, "commit", "-qm", "fixture")


def self_test():
    scratch = Path(tempfile.mkdtemp(prefix="burnbar-root-inventory-", dir="/tmp"))
    try:
        checks = []

        unlisted_root = scratch / "unlisted"
        fixture(unlisted_root)
        unlisted_manifest = unlisted_root / "manifest.json"
        write_fixture_manifest(unlisted_manifest, {"a.txt", "b.txt"}, 2)
        (unlisted_root / "new.txt").write_text("new\n", encoding="utf-8")
        git(unlisted_root, "add", "new.txt")
        git(unlisted_root, "commit", "-qm", "new root")
        checks.append(("unlisted new root file", bool(check_state(unlisted_root, unlisted_manifest))))

        removed_root = scratch / "removed"
        fixture(removed_root)
        removed_manifest = removed_root / "manifest.json"
        write_fixture_manifest(
            removed_manifest, {"a.txt"}, 1, {"a.txt", "b.txt"}
        )
        checks.append(
            (
                "removed manifest entry with root file still present",
                bool(check_state(removed_root, removed_manifest)),
            )
        )

        grown_manifest_root = scratch / "grown-manifest"
        fixture(grown_manifest_root)
        grown_manifest = grown_manifest_root / "manifest.json"
        write_fixture_manifest(grown_manifest, {"a.txt", "b.txt", "c.txt"}, 2)
        checks.append(("grown manifest", bool(check_state(grown_manifest_root, grown_manifest))))

        failed = [name for name, rejected in checks if not rejected]
        for name, rejected in checks:
            if rejected:
                print(f"PASS: self-test rejects {name}")
            else:
                print(f"FAIL: self-test accepted {name}", file=sys.stderr)
        if failed:
            print("self-test failed: " + ", ".join(failed), file=sys.stderr)
            return 1
        print("PASS: root inventory self-test (three negative cases)")
        return 0
    finally:
        shutil.rmtree(scratch)


if mode == "self-test":
    raise SystemExit(self_test())

errors = check_state(repo_root, manifest_path)
if errors:
    print("FAIL: root inventory ratchet", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)

manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
print(
    "PASS: root inventory matches "
    f"{manifest_data['measuredRootBlobCount']} tracked root blob(s)"
)
PY
