#!/usr/bin/env bash
# Shrink-only DataStore isolation ratchet.
#
# This freezes the known synchronous DataStore debt so the async GRDB migration
# can land in small, compiling slices. The budget has two counters:
#   1. `nonisolated` members on DataStore/DataStoreCoordinator/DataStore+*.swift.
#   2. synchronous `try dbQueue.read/write` sites under AgentLens/Services/DataStore.
#
# As a store stage moves to `try await dbQueue.read/write` and removes
# nonisolated pass-throughs, lower budgets/datastore-isolation-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/datastore-isolation-baseline.json"
mode="${1:-}"

python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""

data_store_root = repo_root / "AgentLens" / "Services" / "DataStore"
nonisolated_files = [
    data_store_root / "DataStore.swift",
    data_store_root / "DataStoreCoordinator.swift",
    *sorted(data_store_root.glob("DataStore+*.swift")),
]
sync_db_excluded_files = {
    "OpenBurnBarDatabase.swift",
    "OpenBurnBarQueryTracer.swift",
}


def is_code_line(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("//") and not stripped.startswith("/*") and not stripped.startswith("*")


def counted_lines(files, predicate):
    total = 0
    by_file = {}
    for path in files:
        if not path.exists():
            continue
        count = 0
        for line in path.read_text(encoding="utf-8").splitlines():
            if is_code_line(line) and predicate(line):
                count += 1
        if count:
            rel = path.relative_to(repo_root).as_posix()
            by_file[rel] = count
            total += count
    return total, by_file


nonisolated_total, nonisolated_by_file = counted_lines(
    nonisolated_files,
    lambda line: re.search(r"\bnonisolated\b", line) is not None,
)

sync_db_files = [
    path
    for path in sorted(data_store_root.glob("*.swift"))
    if path.name not in sync_db_excluded_files
]
sync_db_total, sync_db_by_file = counted_lines(
    sync_db_files,
    lambda line: re.search(r"\btry\s+(?!await\b).*dbQueue\.(read|write|writeWithoutTransaction)\s*\{", line)
    is not None,
)

live = {
    "nonisolatedDataStoreMembers": nonisolated_total,
    "syncDbQueueAccesses": sync_db_total,
    "total": nonisolated_total + sync_db_total,
    "details": {
        "nonisolatedDataStoreMembers": nonisolated_by_file,
        "syncDbQueueAccesses": sync_db_by_file,
    },
}

if mode == "--print-live":
    print(json.dumps(live, indent=2, sort_keys=True))
    sys.exit(0)

if not baseline_path.exists():
    print(f"Missing DataStore isolation baseline: {baseline_path}", file=sys.stderr)
    print("Run scripts/debt/check-datastore-isolation-budget.sh --print-live and check in the current baseline.", file=sys.stderr)
    sys.exit(1)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
metric_names = ("nonisolatedDataStoreMembers", "syncDbQueueAccesses", "total")

print(
    "DataStore isolation budget: "
    + " ".join(f"{name}={live[name]} baseline={baseline[name]}" for name in metric_names)
)

failed = False
for name in metric_names:
    if live[name] > baseline[name]:
        print(f"::error::DataStore {name} rose from {baseline[name]} to {live[name]}. Convert sync DB access to GRDB async or remove the new nonisolated exposure.", file=sys.stderr)
        failed = True
    elif live[name] < baseline[name]:
        print(f"::notice::DataStore {name} dropped from {baseline[name]} to {live[name]} — lower budgets/datastore-isolation-baseline.json to lock it in.")

if failed:
    print("\nLive detail:", file=sys.stderr)
    print(json.dumps(live["details"], indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)

print("DataStore isolation ratchet OK.")
PY
