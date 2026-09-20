#!/usr/bin/env bash
# When OPENBURNBAR_DECLARED_XCFRAMEWORKS=1, Package.swift fatalErrors if
# required Vendor binaries are missing. This script records SHA-256 of the
# declared Apple xcframeworks so a swapped binary is visible.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import hashlib
import json
from pathlib import Path

baseline = Path("budgets/vendor-xcframework-checksums.json")
roots = [
    Path("Vendor/OpenBurnBarIroh.xcframework"),
    Path("Vendor/OpenBurnBarSignalFfiMac.xcframework"),
]
live = {}
for root in roots:
    if not root.exists():
        live[root.as_posix()] = None
        continue
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode())
            digest.update(path.read_bytes())
    live[root.as_posix()] = digest.hexdigest()

if not baseline.exists():
    baseline.write_text(json.dumps({"checksums": live, "note": "SHA-256 over xcframework file bytes. Missing binaries are null until present."}, indent=2) + "\n")
    print(f"wrote {baseline}")
else:
    expected = json.loads(baseline.read_text())["checksums"]
    for key, value in live.items():
        if key not in expected:
            raise SystemExit(f"new xcframework {key} — add to baseline")
        if expected[key] is None and value is None:
            continue
        if expected[key] != value and expected[key] is not None and value is not None:
            raise SystemExit(f"checksum mismatch for {key}")
    print("vendor xcframework checksums OK")
print(json.dumps(live, indent=2))
PY
