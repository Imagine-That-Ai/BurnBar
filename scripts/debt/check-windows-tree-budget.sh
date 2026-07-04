#!/usr/bin/env bash
# Shrink-only per-tree size ratchet for the Windows source tree (windows/).
#
# Mirrors scripts/debt/check-swift-file-size-budget.sh, but is rooted at
# `windows/` and PARTITIONED by the eight documented sub-trees so counters cannot
# collide across trees:
#
#   • A macOS-tree change (AgentLens/, OpenBurnBarCore/, OpenBurnBarDaemon/) or an
#     Android-tree change (android/) is NEVER scanned — the scan root is windows/ —
#     so it cannot move any Windows counter, and vice-versa.
#   • Each area counter (app / pal / native / storage / particles / pretext /
#     integrations / tests) is computed ONLY from windows/<area>/, so growth in
#     one area cannot move another area's counter.
#
# Fails CI if EITHER:
#   - a NEW Windows source file crosses the size target (not in the baseline), or
#   - a baselined file GROWS beyond its recorded line count, or
#   - a Windows source file lives OUTSIDE the seven documented sub-trees.
# Baselined files may only shrink. As they drop below the target, regenerate the
# baseline (`--print-live`) to ratchet down.
#
# Usage:
#   scripts/debt/check-windows-tree-budget.sh              # verify against baseline
#   scripts/debt/check-windows-tree-budget.sh --print-live # emit a fresh baseline JSON
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/windows-tree-baseline.json"
mode="${1:-}"

python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""

WIN_ROOT = repo_root / "windows"
AREAS = ("app", "pal", "native", "storage", "particles", "pretext", "integrations", "tests")
SOURCE_SUFFIXES = {".cs", ".xaml", ".cpp", ".cxx", ".cc", ".c", ".h", ".hpp", ".rs"}
DEFAULT_TARGET = 800


def count_lines(path: Path) -> int:
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


baseline = None
if baseline_path.exists():
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))

target = int(baseline["target"]) if baseline and "target" in baseline else DEFAULT_TARGET

# ── Enumerate windows/ source files, partition strictly by top-level area ─────
oversized = {area: {} for area in AREAS}
stray = []
if WIN_ROOT.is_dir():
    for path in sorted(WIN_ROOT.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
            continue
        rel_repo = path.relative_to(repo_root).as_posix()
        parts = path.relative_to(WIN_ROOT).parts
        area = parts[0] if parts and parts[0] in AREAS else None
        if area is None:
            stray.append(rel_repo)
            continue
        lines = count_lines(path)
        if lines > target:
            oversized[area][rel_repo] = lines

live = {
    "tree": "windows",
    "target": target,
    "areas": list(AREAS),
    "oversized": {
        area: [
            {"path": path, "lines": lines}
            for path, lines in sorted(oversized[area].items())
        ]
        for area in AREAS
    },
}

if mode == "--print-live":
    print(json.dumps(live, indent=2))
    sys.exit(0)

if baseline is None:
    print(f"Missing Windows tree baseline: {baseline_path}", file=sys.stderr)
    print(
        "Run scripts/debt/check-windows-tree-budget.sh --print-live and commit the baseline.",
        file=sys.stderr,
    )
    sys.exit(1)

base_over = {
    area: {entry["path"]: entry["lines"] for entry in baseline.get("oversized", {}).get(area, [])}
    for area in AREAS
}

print(f"Windows tree budget: root=windows/ target={target} areas={','.join(AREAS)}")

failed = False
for area in AREAS:
    live_area = oversized[area]
    base_area = base_over[area]
    new_files = [(p, n) for p, n in sorted(live_area.items()) if p not in base_area]
    grown = [
        (p, base_area[p], n)
        for p, n in sorted(live_area.items())
        if p in base_area and n > base_area[p]
    ]
    removed = [p for p in sorted(base_area) if p not in live_area]
    print(f"  [{area}] baselined-oversized={len(base_area)} live-oversized={len(live_area)}")
    if new_files:
        failed = True
        print(
            f"::error::Windows area '{area}': {len(new_files)} NEW file(s) over {target} lines "
            "(decompose before merging):",
            file=sys.stderr,
        )
        for path, lines in new_files:
            print(f"    {lines}  {path}", file=sys.stderr)
    if grown:
        failed = True
        print(
            f"::error::Windows area '{area}': {len(grown)} baselined file(s) GREW "
            "(they may only shrink):",
            file=sys.stderr,
        )
        for path, was, now in grown:
            print(f"    {was} -> {now}  {path}", file=sys.stderr)
    if removed:
        print(
            f"::notice::Windows area '{area}': {len(removed)} file(s) dropped below {target} "
            "lines — regenerate the baseline to ratchet down."
        )

if stray:
    failed = True
    documented = ", ".join(f"windows/{area}" for area in AREAS)
    print(
        f"::error::{len(stray)} Windows source file(s) live outside the documented sub-trees "
        f"({documented}):",
        file=sys.stderr,
    )
    for path in stray:
        print(f"    {path}", file=sys.stderr)
    print(
        "Place Windows source under windows/{app,pal,native,tests}/ (see windows/README.md).",
        file=sys.stderr,
    )

if failed:
    print(
        "\nThe canonical Windows budget is budgets/windows-tree-baseline.json.",
        file=sys.stderr,
    )
    sys.exit(1)

print("OK: Windows tree within per-area size budget; no new oversized files and no baselined file grew.")
PY
