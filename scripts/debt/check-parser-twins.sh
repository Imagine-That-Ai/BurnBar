#!/usr/bin/env bash
# Shrink-only list of LogParser type names defined in both AgentLens and Core.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import re
from pathlib import Path

def parser_types(root: Path) -> set[str]:
    found = set()
    for path in root.rglob("*.swift"):
        text = path.read_text(errors="ignore")
        for m in re.finditer(r"class\s+(\w+Parser)\b", text):
            found.add(m.group(1))
    return found

agent = parser_types(Path("AgentLens/Services"))
core = parser_types(Path("OpenBurnBarCore/Sources/OpenBurnBarLogParsers"))
twins = sorted(agent & core)
baseline = Path("budgets/parser-twin-baseline.txt")
if not baseline.exists():
    baseline.write_text("\n".join(twins) + ("\n" if twins else ""))
    print(f"wrote {baseline} ({len(twins)} twins)")
else:
    allowed = {line for line in baseline.read_text().splitlines() if line.strip()}
    extra = [name for name in twins if name not in allowed]
    if extra:
        raise SystemExit("new parser twins:\n" + "\n".join(extra))
    print(f"parser-twin gate OK ({len(twins)} baselined)")
PY
