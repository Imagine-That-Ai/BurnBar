#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

exec python3 - <<'PY'
import json
import subprocess
import sys

tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.splitlines()
violations = []

for path in tracked:
    if not (path.startswith("launch-evidence/") and "commercial-launch-gate" in path and path.endswith(".json")):
        continue
    try:
        raw = subprocess.run(["git", "show", f":{path}"], capture_output=True, text=True, check=True).stdout
        data = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        violations.append(f"{path}: unreadable launch-gate JSON ({exc})")
        continue
    verdict = data.get("verdict") if isinstance(data, dict) else None
    status = verdict.get("status") if isinstance(verdict, dict) else None
    if status == "NO_GO":
        reason = verdict.get("reason", "no reason") if isinstance(verdict, dict) else "no reason"
        violations.append(f"{path}: verdict.status=NO_GO ({reason})")

if violations:
    print("FAIL: stale failed commercial launch evidence is tracked:", file=sys.stderr)
    for item in violations:
        print(f"  {item}", file=sys.stderr)
    print("Regenerate fresh GO evidence locally/CI, but do not commit stale NO_GO launch-gate artifacts.", file=sys.stderr)
    sys.exit(1)

print("PASS: no tracked stale commercial launch evidence")
PY
