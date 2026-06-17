#!/usr/bin/env bash
#
# Blocks new Mac/iOS Swift files that share a basename unless the current pair
# is explicitly allowlisted with a reason category in docs/LINT_RATIONALE.md.
set -euo pipefail

if [[ -n "${TWIN_BASELINE_ROOT:-}" ]]; then
  cd "$TWIN_BASELINE_ROOT"
else
  cd "$(dirname "${BASH_SOURCE[0]}")/../.."
fi

exec python3 - <<'PY'
import os
import re
import subprocess
import sys
from collections import defaultdict

RATIONALE = "docs/LINT_RATIONALE.md"
BEGIN = re.compile(r"^\s*<!--\s*BEGIN:twin-basename-allowlist\s*-->\s*$")
END = re.compile(r"^\s*<!--\s*END:twin-basename-allowlist\s*-->\s*$")
ALLOWED_CATEGORIES = {
    "storage-backend-divergence",
    "platform-ui",
    "transport",
}


def fatal(message):
    print(f"FATAL: {message}", file=sys.stderr)
    sys.exit(2)


try:
    doc_lines = open(RATIONALE, encoding="utf-8").read().splitlines()
except OSError as exc:
    fatal(f"cannot read {RATIONALE}: {exc}")

begins = [i for i, line in enumerate(doc_lines) if BEGIN.match(line)]
ends = [i for i, line in enumerate(doc_lines) if END.match(line)]
if len(begins) != 1 or len(ends) != 1 or ends[0] <= begins[0]:
    fatal(
        f"{RATIONALE} must contain exactly one BEGIN:twin-basename-allowlist and "
        "one END:twin-basename-allowlist marker, BEGIN first."
    )

tracked_all = subprocess.run(
    ["git", "ls-files"],
    capture_output=True,
    text=True,
    check=True,
).stdout.splitlines()
tracked = [path for path in tracked_all if os.path.exists(path)]
tracked_set = set(tracked)
if not tracked:
    fatal("git ls-files returned no tracked files")


def has_glob(path):
    return any(char in path for char in "*?[]")


def root_for(path):
    if path.startswith("AgentLens/"):
        return "AgentLens"
    if path.startswith("OpenBurnBarMobile/"):
        return "OpenBurnBarMobile"
    return None


allowlist = {}
warnings = []
errors = []
for raw in doc_lines[begins[0] + 1:ends[0]]:
    line = raw.strip()
    if not line or line.startswith("#") or line.startswith("```"):
        continue
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    parts = [part.strip() for part in line.split("|")]
    if len(parts) != 3:
        errors.append(f"malformed allowlist entry: {raw}")
        continue
    mac_path, mobile_path, category = parts
    if category not in ALLOWED_CATEGORIES:
        errors.append(f"{mac_path} | {mobile_path}: unknown category '{category}'")
    if has_glob(mac_path) or has_glob(mobile_path):
        errors.append(f"{mac_path} | {mobile_path}: globs are not allowed")
    if mac_path not in tracked_set or mobile_path not in tracked_set:
        warnings.append(f"stale twin allowlist entry: {mac_path} | {mobile_path}")
        continue
    if root_for(mac_path) != "AgentLens" or root_for(mobile_path) != "OpenBurnBarMobile":
        errors.append(f"{mac_path} | {mobile_path}: paths must be AgentLens | OpenBurnBarMobile")
    if not mac_path.endswith(".swift") or not mobile_path.endswith(".swift"):
        errors.append(f"{mac_path} | {mobile_path}: only .swift entries are accepted")
    if os.path.basename(mac_path) != os.path.basename(mobile_path):
        errors.append(f"{mac_path} | {mobile_path}: basenames differ")
    allowlist[(mac_path, mobile_path)] = category

if errors:
    print("FATAL: invalid twin-basename allowlist:", file=sys.stderr)
    print("\n".join(f"  {error}" for error in errors), file=sys.stderr)
    sys.exit(2)
for warning in warnings:
    print(f"warning: {warning}", file=sys.stderr)

swift_by_root = {"AgentLens": defaultdict(list), "OpenBurnBarMobile": defaultdict(list)}
for path in tracked:
    root = root_for(path)
    if root is None or not path.endswith(".swift"):
        continue
    swift_by_root[root][os.path.basename(path)].append(path)

current_pairs = set()
for basename, mac_paths in swift_by_root["AgentLens"].items():
    mobile_paths = swift_by_root["OpenBurnBarMobile"].get(basename, [])
    for mac_path in mac_paths:
        for mobile_path in mobile_paths:
            current_pairs.add((mac_path, mobile_path))

violations = sorted(current_pairs - set(allowlist))
if violations:
    print("FAIL: new Mac/iOS Swift twin basenames require an allowlist entry:", file=sys.stderr)
    for mac_path, mobile_path in violations:
        print(f"  {mac_path} | {mobile_path}", file=sys.stderr)
    print(
        "\nAdd an exact-path entry under BEGIN:twin-basename-allowlist with one "
        "category: storage-backend-divergence, platform-ui, or transport.",
        file=sys.stderr,
    )
    sys.exit(1)

stale_pairs = sorted(set(allowlist) - current_pairs)
for mac_path, mobile_path in stale_pairs:
    print(f"warning: stale twin allowlist pair no longer present: {mac_path} | {mobile_path}", file=sys.stderr)

print(f"PASS: {len(current_pairs)} tracked Swift twin basename pair(s) are allowlisted")
PY
