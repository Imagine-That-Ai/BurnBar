#!/usr/bin/env bash
# Shrink-only privacy: .public log interpolation ratchet.
# See docs/PRIVACY_PUBLIC_LOG_AUDIT.md.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/privacy-public-baseline.json"
mode="${1:-}"
python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""
roots = ["AgentLens", "OpenBurnBarMobile", "OpenBurnBarDaemon/Sources", "OpenBurnBarCore/Sources"]
cmd = ["rg", "-c", r"privacy: \.public", "--glob", "*.swift"]
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

if mode == "--print-live":
    print(json.dumps({"total": total, "byFile": by_file}, indent=2, sort_keys=True))
    raise SystemExit(0)
if mode == "--update" or not baseline_path.exists():
    baseline_path.write_text(json.dumps({"total": total, "note": "Shrink-only privacy: .public interpolations."}, indent=2) + "\n")
    print(f"wrote {baseline_path} total={total}")
    raise SystemExit(0)
baseline = json.loads(baseline_path.read_text())
print(f"privacy: .public budget: live={total} baseline={baseline['total']}")
if total > baseline["total"]:
    raise SystemExit(f"privacy: .public rose from {baseline['total']} to {total}")
if total < baseline["total"]:
    print(f"Improved: privacy public dropped {baseline['total']} -> {total}; run --update to lock in")
print("privacy public ratchet OK")
PY
