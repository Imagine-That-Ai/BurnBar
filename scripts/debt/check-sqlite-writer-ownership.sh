#!/usr/bin/env bash
# Freeze dual-writer SQLite tables. New tables must have a single process owner
# in docs/ARCHITECTURE/005-sync-ownership.md; INSERT INTO from both app and
# daemon is only allowed for tables listed in the dual-writer baseline.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/sqlite-dual-writer-baseline.json"
mode="${1:-}"
python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""
insert_re = re.compile(r"INSERT\s+(?:OR\s+\w+\s+)?INTO\s+([A-Za-z_][A-Za-z0-9_]*)", re.I)

def tables_in(root: Path) -> set[str]:
    found = set()
    if not root.exists():
        return found
    result = subprocess.run(
        ["rg", "-n", r"INSERT\s+(OR\s+\w+\s+)?INTO\s+", "--glob", "*.swift", str(root)],
        capture_output=True,
        text=True,
    )
    for line in result.stdout.splitlines():
        path = line.split(":", 1)[0]
        if "/Tests/" in path or path.endswith("Tests.swift"):
            continue
        match = insert_re.search(line)
        if match:
            found.add(match.group(1))
    return found

app = tables_in(repo / "AgentLens") | tables_in(repo / "OpenBurnBarCore/Sources/OpenBurnBarData")
daemon = tables_in(repo / "OpenBurnBarDaemon/Sources")
dual = sorted(app & daemon)
live = {"dualWriterTables": dual}

if mode == "--print-live":
    print(json.dumps(live, indent=2))
    raise SystemExit(0)
if mode == "--update" or not baseline_path.exists():
    baseline_path.write_text(json.dumps({
        "dualWriterTables": dual,
        "note": "Tables that both AgentLens/OpenBurnBarData and the daemon INSERT INTO. Shrink-only; new dual-writers are forbidden. Assign a writer in ADR-005 before adding INSERT.",
    }, indent=2) + "\n")
    print(f"wrote {baseline_path} ({len(dual)} dual-writer tables)")
    raise SystemExit(0)

baseline = json.loads(baseline_path.read_text())
allowed = set(baseline["dualWriterTables"])
extra = [name for name in dual if name not in allowed]
print(f"sqlite dual-writer tables: live={len(dual)} baseline={len(allowed)}")
if extra:
    raise SystemExit("new dual-writer tables (assign a single writer in ADR-005):\n" + "\n".join(extra))
gone = sorted(allowed - set(dual))
if gone:
    print("Improved: dual-writer tables dropped: " + ", ".join(gone) + " — run --update")
print("sqlite writer ownership ratchet OK")
PY
