#!/usr/bin/env bash
# Validate the public handover/access-inventory skeleton without reading secrets.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "${1:-}" in
  --schema)
    mode="schema"
    ;;
  --live)
    echo "FAIL: --live requires provider credentials and a human-approved live verification; credentialed mode is out of scope." >&2
    exit 1
    ;;
  *)
    echo "Usage: $0 --schema|--live" >&2
    exit 2
    ;;
esac

python3 - "$repo_root" "$mode" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
mode = sys.argv[2]

if mode != "schema":
    raise SystemExit(2)

documents = {
    "docs/runbooks/HANDOVER.md": [
        "## Required slots",
        "## Transfer checklist",
        "## Escalation",
    ],
    "docs/ops/ACCESS_INVENTORY.md": [
        "## Inventory rules",
        "## Required access slots",
        "## Verification cadence",
    ],
}
placeholder_values = {"", "-", "—", "TBD", "TODO", "N/A", "NA", "UNKNOWN"}
failures = []


def table_cells(line):
    line = line.strip()
    if not line.startswith("|"):
        return None
    if line.endswith("|"):
        line = line[:-1]
    return [cell.strip() for cell in line[1:].split("|")]


def separator(cells):
    return cells and all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells)


for relative, required_sections in documents.items():
    path = root / relative
    if not path.is_file():
        failures.append(f"{relative}: missing document")
        continue
    text = path.read_text(encoding="utf-8")
    headings = set(re.findall(r"^##\s+(.+?)\s*$", text, re.MULTILINE))
    for section in required_sections:
        if section[3:] not in headings:
            failures.append(f"{relative}: missing section {section}")

    rows = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        cells = table_cells(line)
        if cells is not None:
            rows.append((line_number, cells))
    if not rows:
        failures.append(f"{relative}: no schema table found")
        continue
    for line_number, cells in rows:
        if separator(cells):
            continue
        if any(cell.lower() in {"slot", "system / capability"} for cell in cells):
            continue
        if any("UNSET" in cell and cell != "UNSET" for cell in cells):
            failures.append(
                f"{relative}:{line_number}: UNSET must be the complete slot value"
            )
        if any(cell in placeholder_values for cell in cells):
            failures.append(
                f"{relative}:{line_number}: every slot value must be populated or exactly UNSET"
            )
        if any("\n" in cell or not cell for cell in cells):
            failures.append(f"{relative}:{line_number}: table cells must be non-empty")

    unset_count = text.count("UNSET")
    if unset_count == 0:
        failures.append(f"{relative}: expected explicit UNSET slot markers")
    else:
        print(f"{relative}: {unset_count} explicit UNSET marker(s)")

if failures:
    print("FAIL: access-inventory schema", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    raise SystemExit(1)

print("PASS: handover and access inventory schema is well-formed")
PY
