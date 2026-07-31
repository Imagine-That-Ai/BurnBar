#!/usr/bin/env bash
# Shrink-only refresh-tick performance ratchet (macOS AgentLens).
#
# The July 2026 perf work made the periodic refresh tick O(delta) instead of
# O(total-history): idle ticks skip the full `token_usage` reload via
# `UsageTableWriteMarker` + `DataStoreCoordinator.reloadUsagesIfChanged`, the
# billing reconcile uses a bounded-window baseline + SQL credential rollup,
# and the cloud total uses a server-side SUM aggregation.
#
# This ratchet keeps that true with two counters:
#   1. `fetchAllUsageCallSites` — production call sites of the unbounded
#      `fetchAllUsage()` full-table load in AgentLens. New call sites put
#      O(total-history) work back on some path; use a bounded window
#      (`fetchUsage(in:limit:)`), a SQL aggregate, or the marker-gated
#      `reloadUsagesIfChanged()` instead.
#   2. `rawTokenUsageWriteStatements` — raw INSERT/UPDATE/DELETE statements
#      against `token_usage` OUTSIDE the allowlisted writer files. Must stay
#      at ZERO: every writer must bump `UsageTableWriteMarker` (via the
#      `UsageStore` mutators or `AtomicIngestionTransaction`), otherwise the
#      marker-gated tick would render stale data until the next
#      time-window boundary.
#
# Lower budgets/usage-refresh-tick-baseline.json as call sites are removed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/usage-refresh-tick-baseline.json"
mode="${1:-}"

python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""

agentlens_root = repo_root / "AgentLens"

# Files allowed to issue raw token_usage write statements. Each of these
# either bumps UsageTableWriteMarker itself or runs before the marker is
# consulted (startup migrations). The migration match is deliberately the
# singular "+Migration" prefix: the schema files use both batched
# (+MigrationsV1toV20) and per-version (+MigrationV57) naming, and a
# plural-only match silently stopped exempting every per-version file.
raw_writer_allowlist = {
    "AgentLens/Services/DataStore/ParserCheckpointStore.swift",
}


def is_code_line(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("//") and not stripped.startswith("/*") and not stripped.startswith("*")


fetch_all_total = 0
fetch_all_by_file = {}
raw_writer_total = 0
raw_writer_by_file = {}

fetch_all_pattern = re.compile(r"fetchAllUsage\(\)")
raw_write_pattern = re.compile(r"\b(INSERT INTO|UPDATE|DELETE FROM)\s+token_usage\b")

for path in sorted(agentlens_root.rglob("*.swift")):
    rel = path.relative_to(repo_root).as_posix()
    text = path.read_text(encoding="utf-8")

    fetch_count = 0
    raw_count = 0
    for line in text.splitlines():
        if not is_code_line(line):
            continue
        if fetch_all_pattern.search(line) and not line.strip().startswith("func "):
            fetch_count += 1
        if raw_write_pattern.search(line):
            raw_count += 1

    if fetch_count:
        fetch_all_by_file[rel] = fetch_count
        fetch_all_total += fetch_count

    is_allowed_writer = (
        rel in raw_writer_allowlist
        or rel.startswith("AgentLens/Services/DataStore/UsageStore")
        or "OpenBurnBarDatabase+Migration" in rel
    )
    if raw_count and not is_allowed_writer:
        raw_writer_by_file[rel] = raw_count
        raw_writer_total += raw_count

live = {
    "fetchAllUsageCallSites": fetch_all_total,
    "rawTokenUsageWriteStatements": raw_writer_total,
    "details": {
        "fetchAllUsageCallSites": fetch_all_by_file,
        "rawTokenUsageWriteStatements": raw_writer_by_file,
    },
}

if mode == "--print-live":
    print(json.dumps(live, indent=2, sort_keys=True))
    sys.exit(0)

if not baseline_path.exists():
    print(f"Missing usage refresh-tick baseline: {baseline_path}", file=sys.stderr)
    print("Run scripts/debt/check-usage-refresh-tick-budget.sh --print-live and check in the current baseline.", file=sys.stderr)
    sys.exit(1)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
metric_names = ("fetchAllUsageCallSites", "rawTokenUsageWriteStatements")

print(
    "Usage refresh-tick budget: "
    + " ".join(f"{name}={live[name]} baseline={baseline[name]}" for name in metric_names)
)

failed = False
for name in metric_names:
    if live[name] > baseline[name]:
        print(
            f"::error::Refresh-tick {name} rose from {baseline[name]} to {live[name]}. "
            "New fetchAllUsage() call sites reintroduce O(total-history) tick work "
            "(use a bounded fetchUsage(in:limit:) window, a SQL aggregate, or "
            "reloadUsagesIfChanged()); new raw token_usage writers must go through "
            "UsageStore so UsageTableWriteMarker stays accurate.",
            file=sys.stderr,
        )
        failed = True
    elif live[name] < baseline[name]:
        print(f"::notice::Refresh-tick {name} dropped from {baseline[name]} to {live[name]} — lower budgets/usage-refresh-tick-baseline.json to lock it in.")

if failed:
    print("\nLive detail:", file=sys.stderr)
    print(json.dumps(live["details"], indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)

print("Usage refresh-tick ratchet OK.")
PY
