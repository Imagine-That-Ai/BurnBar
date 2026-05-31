#!/usr/bin/env bash
# Fail when functions/src uses raw fetch outside the resilience allowlist.
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 <<'PY'
import re
from pathlib import Path

ROOT = Path("functions/src")
ALLOWLIST = {
    ROOT / "resilienceHelpers.ts",
}

await_violations: list[str] = []
fetch_violations: list[str] = []
for path in sorted(ROOT.rglob("*.ts")):
    if path in ALLOWLIST:
        continue
    if "/__tests__/" in path.as_posix():
        continue
    text = path.read_text()
    for match in re.finditer(r"await fetch\(", text):
        line = text[: match.start()].count("\n") + 1
        await_violations.append(f"{path}:{line}")
    for match in re.finditer(r"(?<![\w.])fetch\(", text):
        line = text[: match.start()].count("\n") + 1
        fetch_violations.append(f"{path}:{line}")

if await_violations:
    print("FAIL: raw await fetch() outside allowlist:")
    for v in await_violations:
        print(f"  {v}")
    raise SystemExit(1)

if fetch_violations:
    print("FAIL: raw fetch() outside allowlist:")
    for v in fetch_violations:
        print(f"  {v}")
    print("Use providerFetch, resilientFetch, or *WithResilience helpers.")
    raise SystemExit(1)

helpers = Path("functions/src/resilienceHelpers.ts").read_text()
if "resilientFetch" not in helpers or "fetch(url" not in helpers:
    raise SystemExit("FAIL: resilienceHelpers.ts must own the canonical fetch() call")

print("PASS: no unallowlisted fetch in functions/src")
PY
