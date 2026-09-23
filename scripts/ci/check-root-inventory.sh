#!/usr/bin/env bash
# Shrink-only tracked-root inventory gate.
#
# The manifest is deliberately outside budgets/: it records the current root
# shape and prevents accidental root growth without pretending that a new
# absolute allowlist is practical. A path can leave only when the file really
# leaves the tracked root and the manifest is ratcheted down in the same change.
# Since Wave-0 0.6 the inventory covers root blobs AND top-level directories:
# --help/ and reports/ both slipped in as directories that the blob-only
# ratchet could not see.
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


def tracked_root_dirs(root):
    # First segments of tracked nested paths, from the same index read as the
    # blobs. Gitlinks are skipped symmetrically: a submodule mount point must
    # not conjure a directory entry on its own.
    output = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--stage", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    dirs = set()
    for record in output.split(b"\0"):
        if not record:
            continue
        metadata, path = record.split(b"\t", 1)
        fields = metadata.split()
        if len(fields) >= 1 and fields[0] == b"160000":
            continue
        name = os.fsdecode(path)
        if "/" in name:
            dirs.add(name.split("/", 1)[0])
    return dirs


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
        return None, None, ["manifest paths must be an array"]

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

    dir_entries = data.get("directories")
    if not isinstance(dir_entries, list):
        return None, None, ["manifest directories must be an array"]

    dirs = []
    for index, entry in enumerate(dir_entries):
        if not isinstance(entry, dict):
            errors.append(f"manifest directories[{index}] must be an object")
            continue
        item = entry.get("path")
        purpose = entry.get("purpose")
        if not isinstance(item, str) or not item:
            errors.append(f"manifest directories[{index}] has no path")
            continue
        if "/" in item or item in {".", ".."}:
            errors.append(f"manifest directory is not a root path: {item}")
        if not isinstance(purpose, str) or not purpose.strip() or "\n" in purpose:
            errors.append(f"manifest directory has no one-line purpose: {item}")
        dirs.append(item)

    if len(dirs) != len(set(dirs)):
        errors.append("manifest directories must be unique")
    expected_dir_count = data.get("measuredRootDirCount")
    if expected_dir_count != len(dirs):
        errors.append(
            f"measuredRootDirCount={expected_dir_count!r} does not match manifest length {len(dirs)}"
        )
    dir_maximum = data.get("maxRootDirCount")
    if not isinstance(dir_maximum, int):
        errors.append("maxRootDirCount must be an integer")
    elif dir_maximum != len(dirs):
        errors.append(
            f"maxRootDirCount={dir_maximum} does not match manifest length {len(dirs)}"
        )
    if not isinstance(expected_dir_count, int) or expected_dir_count != dir_maximum:
        errors.append(
            "measuredRootDirCount and maxRootDirCount must match the live ratchet count"
        )
    if isinstance(data.get("initialRootDirCount"), int) and data["initialRootDirCount"] < len(dirs):
        errors.append(
            f"manifest grew: {len(dirs)} directory entries exceeds initialRootDirCount={data['initialRootDirCount']}"
        )

    historical_dirs = data.get("historicalRootDirs")
    if not isinstance(historical_dirs, list) or not all(isinstance(item, str) for item in historical_dirs):
        errors.append("historicalRootDirs must be a string array")
    else:
        initial_dir_count = data.get("initialRootDirCount")
        if not isinstance(initial_dir_count, int):
            errors.append("initialRootDirCount must be an integer")
        elif initial_dir_count != len(historical_dirs):
            errors.append(
                "initialRootDirCount does not match historicalRootDirs length"
            )
        allowed_dirs = set(historical_dirs) | {
            entry["path"] for entry in amendments if isinstance(entry, dict) and isinstance(entry.get("path"), str)
        }
        unknown_dirs = sorted(set(dirs) - allowed_dirs)
        if unknown_dirs:
            errors.append(
                "manifest contains root directories outside its original inventory and amendments: "
                + ", ".join(unknown_dirs)
            )
    return set(paths), set(dirs), errors


def check_state(root, manifest):
    expected, expected_dirs, errors = load_manifest(manifest)
    if errors:
        return errors
    actual = tracked_root_blobs(root)
    actual_dirs = tracked_root_dirs(root)
    missing_from_tree = sorted(expected - actual)
    unlisted = sorted(actual - expected)
    missing_on_disk = sorted(
        item for item in expected if not (root / item).is_file()
    )
    missing_dirs_from_tree = sorted(expected_dirs - actual_dirs)
    unlisted_dirs = sorted(actual_dirs - expected_dirs)
    missing_dirs_on_disk = sorted(
        item for item in expected_dirs if not (root / item).is_dir()
    )
    manifest_data = json.loads(manifest.read_text(encoding="utf-8"))
    maximum = manifest_data["maxRootBlobCount"]
    dir_maximum = manifest_data["maxRootDirCount"]

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
    if unlisted_dirs:
        errors.append(
            "NEW unlisted tracked root director(ies): " + ", ".join(unlisted_dirs)
        )
    if missing_dirs_from_tree:
        errors.append(
            "manifest-listed root director(ies) are no longer tracked: "
            + ", ".join(missing_dirs_from_tree)
        )
    if missing_dirs_on_disk:
        errors.append(
            "manifest-listed root director(ies) are missing on disk: "
            + ", ".join(missing_dirs_on_disk)
        )
    if len(actual_dirs) > dir_maximum:
        errors.append(
            f"tracked root grew: {len(actual_dirs)} dirs exceeds maxRootDirCount={dir_maximum}"
        )
    if len(actual_dirs) != len(expected_dirs):
        errors.append(
            f"root directory count mismatch: manifest={len(expected_dirs)} tracked={len(actual_dirs)}"
        )
    return errors


def write_fixture_manifest(path, paths, maximum, historical=None, dir_paths=(), dir_maximum=None, dir_historical=None):
    historical = historical or sorted(paths)
    dir_paths = sorted(dir_paths)
    dir_historical = sorted(dir_historical) if dir_historical is not None else list(dir_paths)
    payload = {
        "schemaVersion": 1,
        "initialRootBlobCount": len(historical),
        "measuredRootBlobCount": len(paths),
        "maxRootBlobCount": maximum,
        "initialRootDirCount": len(dir_historical),
        "measuredRootDirCount": len(dir_paths),
        "maxRootDirCount": len(dir_paths) if dir_maximum is None else dir_maximum,
        "historicalRootPaths": sorted(historical),
        "historicalRootDirs": dir_historical,
        "paths": [
            {"path": item, "purpose": f"fixture purpose for {item}"}
            for item in sorted(paths)
        ],
        "directories": [
            {"path": item, "purpose": f"fixture purpose for {item}/"}
            for item in dir_paths
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

        unlisted_dir_root = scratch / "unlisted-dir"
        fixture(unlisted_dir_root)
        unlisted_dir_manifest = unlisted_dir_root / "manifest.json"
        write_fixture_manifest(unlisted_dir_manifest, {"a.txt", "b.txt"}, 2)
        (unlisted_dir_root / "newdir").mkdir()
        (unlisted_dir_root / "newdir" / "f.txt").write_text("new\n", encoding="utf-8")
        git(unlisted_dir_root, "add", "newdir")
        git(unlisted_dir_root, "commit", "-qm", "new root dir")
        checks.append(("unlisted new root directory", bool(check_state(unlisted_dir_root, unlisted_dir_manifest))))

        failed = [name for name, rejected in checks if not rejected]
        for name, rejected in checks:
            if rejected:
                print(f"PASS: self-test rejects {name}")
            else:
                print(f"FAIL: self-test accepted {name}", file=sys.stderr)
        if failed:
            print("self-test failed: " + ", ".join(failed), file=sys.stderr)
            return 1
        print("PASS: root inventory self-test (four negative cases)")
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
    f"{manifest_data['measuredRootBlobCount']} tracked root blob(s) and "
    f"{manifest_data['measuredRootDirCount']} tracked root director(ies)"
)
PY
