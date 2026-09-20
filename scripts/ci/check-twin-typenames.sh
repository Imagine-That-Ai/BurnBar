#!/usr/bin/env bash
# Fail if AgentLens and OpenBurnBarMobile define the same type name for
# settings-search / budget types that should live in OpenBurnBarUI.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import re
from pathlib import Path

def types(root: Path) -> set[str]:
    found = set()
    for path in root.rglob("*.swift"):
        text = path.read_text(errors="ignore")
        for m in re.finditer(r"^(?:public |internal |private |fileprivate )?(?:struct|class|enum|actor)\s+(\w+)", text, re.M):
            found.add(m.group(1))
    return found

mac = types(Path("AgentLens"))
mobile = types(Path("OpenBurnBarMobile"))
watch = {
    "SettingsSearchEngine",
    "SettingsSearchResultsView",
    "SettingsManifest",
    "BudgetLedger",
}
overlap = sorted((mac & mobile) & watch)
baseline_path = Path("budgets/twin-type-names-baseline.txt")
if not baseline_path.exists():
    baseline_path.write_text("\n".join(overlap) + ("\n" if overlap else ""))
    print(f"wrote {baseline_path} ({len(overlap)} twins)")
else:
    allowed = {line for line in baseline_path.read_text().splitlines() if line.strip()}
    extra = [name for name in overlap if name not in allowed]
    if extra:
        raise SystemExit("new twin type names across AgentLens/OpenBurnBarMobile:\n" + "\n".join(extra))
    gone = sorted(allowed - set(overlap))
    if gone:
        print("twin type names paid down (lower the baseline):", ", ".join(gone))
    print(f"twin type-name gate OK ({len(overlap)} baselined twins)")
PY
