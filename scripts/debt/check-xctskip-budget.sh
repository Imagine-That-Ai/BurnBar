#!/usr/bin/env bash
# Shrink-only XCTSkip ratchet. XCTSkip is a second quarantine; the count may
# only fall. Regenerate: scripts/debt/check-xctskip-budget.sh --update
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/xctskip-baseline.json"
mode="${1:-}"
python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""
roots = [
    "AgentLensTests",
    "OpenBurnBarMobileTests",
    "OpenBurnBarDaemon/Tests",
    "OpenBurnBarCore/Tests",
]
cmd = ["rg", "-c", r"XCTSkip", "--glob", "*.swift"]
total = 0
by_file = {}
for root in roots:
    path = repo / root
    if not path.exists():
        continue
    result = subprocess.run(cmd + [str(path)], capture_output=True, text=True)
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        file_path, count = line.rsplit(":", 1)
        n = int(count)
        rel = str(Path(file_path).relative_to(repo)) if Path(file_path).is_absolute() else file_path
        by_file[rel] = n
        total += n

live = {"total": total, "byFile": by_file}
if mode == "--print-live":
    print(json.dumps(live, indent=2, sort_keys=True))
    raise SystemExit(0)
if mode == "--update" or not baseline_path.exists():
    baseline_path.write_text(json.dumps({"total": total, "note": "Shrink-only XCTSkip count across first-party test trees."}, indent=2) + "\n")
    print(f"wrote {baseline_path} total={total}")
    raise SystemExit(0)
baseline = json.loads(baseline_path.read_text())
print(f"XCTSkip budget: live={total} baseline={baseline['total']}")
if total > baseline["total"]:
    raise SystemExit(f"XCTSkip rose from {baseline['total']} to {total}")
if total < baseline["total"]:
    print(f"Improved: XCTSkip dropped {baseline['total']} -> {total}; run --update to lock in")
print("XCTSkip ratchet OK")
PY
