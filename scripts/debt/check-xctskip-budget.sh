#!/usr/bin/env bash
# check-xctskip-budget.sh — shrink-only ratchet for XCTSkip sites (wave 4).
#
# Every skip is either time-boxed debt or a permanent environment guard, and
# the code must SAY which: each skip site requires a marker comment on the
# guard line or the line directly above it —
#   * `revive-by: YYYY-MM-DD — <what unblocks it>` for debt (bundled goldens,
#     missing fixtures, sandbox-exec, ...). The date is a revival TARGET, not
#     an expiry: when it passes, revive the test or move the date with a
#     reason in the same edit.
#   * `env-guard: <condition>` for permanent gates (OS version, keychain or
#     Secure Enclave entitlement, physical device, opt-in E2E env vars,
#     Firebase/plist provisioning). These run when the env exists; no date.
# This gate fails on (a) a total above the baseline, (b) any unmarked site.
#
# Usage:
#   scripts/debt/check-xctskip-budget.sh           # fail on growth/unmarked
#   scripts/debt/check-xctskip-budget.sh --update  # lower the ceiling (never raise)
set -euo pipefail
cd "$(dirname "$0")/../.."

BASELINE="budgets/xctskip-baseline.json"
MODE="${1:-}"

ROOTS=(AgentLensTests OpenBurnBarMobileTests OpenBurnBarCore OpenBurnBarDaemon)

python3 - "$MODE" "${ROOTS[@]}" <<'PY'
import json
import re
import sys
from pathlib import Path

mode = sys.argv[1] if len(sys.argv) > 1 else ""
roots = sys.argv[2:]
if mode not in ("", "--check", "--update"):
    print("usage: check-xctskip-budget.sh [--check|--update]", file=sys.stderr)
    sys.exit(2)

skip_re = re.compile(r"(?:throw\s+XCTSkip|XCTSkip)\s*\(")
marker_re = re.compile(r"(revive-by:\s*\d{4}-\d{2}-\d{2}|env-guard:)")

sites: list[str] = []
unmarked: list[str] = []
SKIP_DIR_PREFIXES = (".build", ".swiftpm", ".derived-data", "build", ".muse")
for root in roots:
    for path in sorted(Path(root).rglob("*.swift")):
        if not path.is_file():
            continue
        if "Quarantine" in path.parts:
            continue
        # Build checkouts and derived data a fresh CI checkout never has.
        if any(part == prefix or part.startswith(prefix + "-") or part.startswith(prefix + ".") for part in path.parts for prefix in SKIP_DIR_PREFIXES):
            continue
        try:
            lines = path.read_text().splitlines()
        except OSError:
            continue
        for index, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if not skip_re.search(line):
                continue
            # A trailing `//` comment may itself mention XCTSkip (e.g. docs);
            # only count real invocations: the match must precede any comment.
            code = line.split("//", 1)[0]
            if not skip_re.search(code):
                continue
            location = f"{path}:{index + 1}"
            sites.append(location)
            window = "\n".join(lines[max(0, index - 1) : index + 1])
            if not marker_re.search(window):
                unmarked.append(location)

with open("budgets/xctskip-baseline.json") as handle:
    baseline = json.load(handle)

if mode == "--update":
    if len(sites) > baseline["total"]:
        print(
            f"::error::--update refused: live {len(sites)} > baseline {baseline['total']}. "
            "The ceiling may only shrink — revive or consolidate skips first."
        )
        sys.exit(1)
    baseline["total"] = len(sites)
    with open("budgets/xctskip-baseline.json", "w") as handle:
        json.dump(baseline, handle, indent=2)
        handle.write("\n")
    print(f"XCTSkip baseline updated: {len(sites)} site(s).")
    sys.exit(0)

print(f"  XCTSkip sites: live {len(sites)} vs ceiling {baseline['total']}")
failed = False
if len(sites) > baseline["total"]:
    print(f"FAIL: XCTSkip sites grew {baseline['total']} -> {len(sites)}.", file=sys.stderr)
    failed = True
if unmarked:
    print(f"FAIL: {len(unmarked)} skip site(s) lack a revive-by:/env-guard: marker:", file=sys.stderr)
    for location in unmarked[:20]:
        print(f"  {location}", file=sys.stderr)
    if len(unmarked) > 20:
        print(f"  ... and {len(unmarked) - 20} more", file=sys.stderr)
    failed = True
if failed:
    sys.exit(1)
print("XCTSkip ratchet OK.")
PY
