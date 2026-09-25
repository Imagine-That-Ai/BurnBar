#!/usr/bin/env bash
# check-swiftlint-rules-budget.sh — per-rule shrink-only ratchet for the five
# brownfield SwiftLint opt-ins (.swiftlint.yml documents why they are not in
# the strict gate: each needs an API-changing rewrite to reach zero).
#
# The old posture (a comment table nobody enforced) let every rule grow:
# implicitly_unwrapped_optional +92% and discouraged_optional_boolean +130%
# between 2026-06-12 and 2026-09-22. This gate fails on ANY per-rule growth.
#
# Mechanism: generate a temp config with only_rules=[5 debt rules] plus the
# repo's excluded list (read live from .swiftlint.yml so the two cannot drift)
# and bird-dog local-only junk a fresh CI checkout never has, then compare
# per-rule counts against budgets/swiftlint-rules-baseline.json.
#
# Usage:
#   scripts/debt/check-swiftlint-rules-budget.sh           # fail on any growth
#   scripts/debt/check-swiftlint-rules-budget.sh --update  # lower ceilings to
#     today's counts (refuses to raise any ceiling; run after burning debt).
#
# Requires the pinned SwiftLint (see baseline version; CI installs it in the
# pr-native-fast swiftlint-native job, which runs this script).
set -euo pipefail
cd "$(dirname "$0")/../.."

MODE="${1:-}"

SWIFTLINT_BIN="${SWIFTLINT_BIN:-swiftlint}"
if ! command -v "$SWIFTLINT_BIN" >/dev/null 2>&1; then
  echo "FAIL: swiftlint is not on PATH (CI installs the pinned build in pr-native-fast; override with SWIFTLINT_BIN)." >&2
  exit 2
fi

TMP_CONFIG=".swiftlint-rules-budget-tmp.yml"
trap 'rm -f "$TMP_CONFIG"' EXIT
python3 - "$TMP_CONFIG" <<'PY'
import sys
import yaml

with open(".swiftlint.yml") as handle:
    repo_config = yaml.safe_load(handle)
excluded = list(repo_config.get("excluded", []))
# Local-only junk a fresh CI checkout never has (.swiftlint.yml calls this
# out: re-measure with the same scope). Nested .build* dirs come from
# agent/validator runs inside package dirs.
excluded += [".muse", ".build-*", "OpenBurnBarCore/.build*", "OpenBurnBarDaemon/.build*", "tools/*/.build*"]
tmp = {
    "only_rules": [
        "force_unwrapping",
        "discouraged_optional_collection",
        "implicitly_unwrapped_optional",
        "no_extension_access_modifier",
        "discouraged_optional_boolean",
    ],
    "excluded": excluded,
}
with open(sys.argv[1], "w") as handle:
    yaml.safe_dump(tmp, handle)
PY

"$SWIFTLINT_BIN" lint --config "$TMP_CONFIG" --reporter json > /tmp/swiftlint-rules-budget.json 2>/dev/null || true

export SWIFTLINT_BIN
python3 - "$MODE" <<'PY'
import json
import os
import subprocess
import sys
from collections import Counter

RULES = [
    "force_unwrapping",
    "discouraged_optional_collection",
    "implicitly_unwrapped_optional",
    "no_extension_access_modifier",
    "discouraged_optional_boolean",
]
mode = sys.argv[1] if len(sys.argv) > 1 else ""

with open("budgets/swiftlint-rules-baseline.json") as handle:
    baseline = json.load(handle)

live_version = subprocess.run(
    [os.environ["SWIFTLINT_BIN"], "version"], capture_output=True, text=True, check=True
).stdout.strip()
if live_version != baseline["version"]:
    print(
        f"FAIL: SwiftLint version drift (live {live_version} != baseline {baseline['version']}). "
        "Counts are only comparable on the pinned build — upgrade deliberately and re-baseline.",
        file=sys.stderr,
    )
    sys.exit(1)

with open("/tmp/swiftlint-rules-budget.json") as handle:
    violations = json.load(handle)
live = Counter(v["rule_id"] for v in violations)
# Rules with zero violations are absent from the report; pin them at zero so
# a rule that hits zero can never silently regrow.
live_counts = {rule: live.get(rule, 0) for rule in RULES}

if mode == "--update":
    grew = {rule: (baseline["rules"][rule], live_counts[rule]) for rule in RULES if live_counts[rule] > baseline["rules"][rule]}
    if grew:
        for rule, (old, new) in grew.items():
            print(f"::error::--update refused: {rule} grew {old} -> {new}. Baselines may only shrink — remove sites first.")
        sys.exit(1)
    baseline["rules"] = live_counts
    with open("budgets/swiftlint-rules-baseline.json", "w") as handle:
        json.dump(baseline, handle, indent=2)
        handle.write("\n")
    print(f"SwiftLint rules baseline updated: {live_counts}")
    sys.exit(0)

if mode not in ("", "--check"):
    print(f"usage: check-swiftlint-rules-budget.sh [--check|--update]", file=sys.stderr)
    sys.exit(2)

failures = []
for rule in RULES:
    ceiling = baseline["rules"][rule]
    count = live_counts[rule]
    status = "OK " if count <= ceiling else "UP "
    print(f"  {status} {rule}: live {count} vs ceiling {ceiling}")
    if count > ceiling:
        failures.append(f"{rule} grew {ceiling} -> {count}")
if failures:
    print("FAIL: SwiftLint debt grew: " + "; ".join(failures), file=sys.stderr)
    print("Remove sites (do not raise ceilings). Then lower the baseline via --update.", file=sys.stderr)
    sys.exit(1)
print("SwiftLint per-rule ratchet OK.")
PY
