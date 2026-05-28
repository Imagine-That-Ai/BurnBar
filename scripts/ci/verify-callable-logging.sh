#!/usr/bin/env bash
# Verify every v2 onCall export uses wrapCallableHandler (callable_start/success/error).
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 <<'PY'
import re
from pathlib import Path

src = Path("functions/src")
exports: list[tuple[str, str]] = []
for path in sorted(src.rglob("*.ts")):
    text = path.read_text()
    for m in re.finditer(r"export const (\w+) = onCall\(", text):
        exports.append((m.group(1), str(path)))

missing = []
for name, path in exports:
    text = Path(path).read_text()
    if f'wrapCallableHandler("{name}"' in text or re.search(
        rf'loggedOnCall\(\s*"{name}"', text
    ):
        continue
    missing.append(f"{path}:{name}")

print(f"onCall exports: {len(exports)}")
print(f"structured-log wrapped: {len(exports) - len(missing)}/{len(exports)}")
if len(exports) < 49:
    raise SystemExit(f"FAIL: expected >= 49 callables, got {len(exports)}")
if missing:
    print("FAIL: missing wrap for:")
    for m in missing:
        print(f"  {m}")
    raise SystemExit(1)
print("PASS: all callables structured-logged")
PY
