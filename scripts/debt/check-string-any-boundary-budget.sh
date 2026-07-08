#!/usr/bin/env bash
# Shrink-only untyped `[String: Any]` Firebase-boundary ratchet.
#
# The Swift<->Firestore boundary is threaded almost entirely through untyped
# `[String: Any]` dictionaries: DocumentSnapshot.data(), setData(_:), update(_:),
# FieldValue payloads, Functions call arguments. Each site is a place with NO
# compile-time contract — a renamed field, a wrong value type, or a dropped key
# fails silently at runtime instead of at build time. The diligence review counted
# 1,204 such matching lines (743 AgentLens/, 461 OpenBurnBarMobile/); measured as
# code-line OCCURRENCES (comments excluded, the sibling debt-budget convention)
# the count is captured in budgets/string-any-boundary-baseline.json.
#
# This gate does NOT migrate those sites — it caps growth so the untyped boundary
# can only SHRINK. The budget counts `[String: Any]` occurrences on code lines
# under:
#   * AgentLens/          (macOS app)
#   * OpenBurnBarMobile/  (iOS app)
#
# The gate fails when a live counter EXCEEDS its baseline in
# budgets/string-any-boundary-baseline.json. As each site is replaced with a typed
# Codable model / typed accessor, lower the baseline to lock the win in. Run with
# --print-live to capture a fresh baseline snapshot.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/string-any-boundary-baseline.json"
mode="${1:-}"

python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""

# Roots whose untyped boundary is being capped. Exact, verified present when this
# baseline was captured.
scopes = {
    "agentLensStringAny": repo_root / "AgentLens",
    "mobileStringAny": repo_root / "OpenBurnBarMobile",
}

# Canonical spelling of the untyped boundary dict. Swift's formatter normalises to
# a single space after the colon, so `[String: Any]` is the one on-disk form (a
# repo-wide search finds zero `[String:Any]` / `[String : Any]` variants); the
# ratchet keys off that canonical spelling and a normalisation drift would surface
# as a count DROP that the reviewer can investigate.
pattern = re.compile(r"\[String: Any\]")

excluded_parts = {".build", ".derived-data", ".swiftpm", "Preview Content", "build"}


def is_code_line(line: str) -> bool:
    stripped = line.strip()
    return (
        bool(stripped)
        and not stripped.startswith("//")
        and not stripped.startswith("/*")
        and not stripped.startswith("*")
    )


def iter_files(root: Path):
    if not root.exists():
        return
    for path in sorted(root.rglob("*.swift")):
        if any(part in excluded_parts for part in path.parts):
            continue
        yield path


def count(root: Path):
    total = 0
    by_file = {}
    for path in iter_files(root):
        rel = path.relative_to(repo_root).as_posix()
        file_count = 0
        for line in path.read_text(encoding="utf-8").splitlines():
            if not is_code_line(line):
                continue
            file_count += len(pattern.findall(line))
        if file_count:
            by_file[rel] = file_count
            total += file_count
    return total, by_file


live = {"details": {}}
grand_total = 0
for key, root in scopes.items():
    total, by_file = count(root)
    live[key] = total
    live["details"].update(by_file)
    grand_total += total
live["total"] = grand_total

# A scope that was renamed/removed leaves its `[String: Any]` sites counting under
# some other path — warn so the scope list gets updated instead of drifting.
for key, root in scopes.items():
    if not root.exists():
        print(
            f"::warning::String-any scope missing: {root} — update scripts/debt/check-string-any-boundary-budget.sh.",
            file=sys.stderr,
        )

if mode == "--print-live":
    print(json.dumps(live, indent=2, sort_keys=True))
    sys.exit(0)

if not baseline_path.exists():
    print(f"Missing string-any boundary baseline: {baseline_path}", file=sys.stderr)
    print(
        "Run scripts/debt/check-string-any-boundary-budget.sh --print-live and check in the current baseline.",
        file=sys.stderr,
    )
    sys.exit(1)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
metric_names = ("agentLensStringAny", "mobileStringAny", "total")

print(
    "String-any boundary budget: "
    + " ".join(f"{name}={live[name]} baseline={baseline[name]}" for name in metric_names)
)

top = sorted(live["details"].items(), key=lambda kv: (-kv[1], kv[0]))[:10]
if top:
    print("Top offending files:")
    for rel, n in top:
        print(f"  {n:>3}  {rel}")

failed = False
for name in metric_names:
    if live[name] > baseline[name]:
        print(
            f"::error::String-any boundary {name} rose from {baseline[name]} to {live[name]}. "
            "The untyped [String: Any] Firebase boundary may only shrink. Model the new payload with a "
            "typed Codable struct / typed accessor instead of a raw [String: Any] dictionary, "
            "or if you paid other sites down, lower budgets/string-any-boundary-baseline.json.",
            file=sys.stderr,
        )
        failed = True
    elif live[name] < baseline[name]:
        print(
            f"::notice::String-any boundary {name} dropped from {baseline[name]} to {live[name]} — "
            "lower budgets/string-any-boundary-baseline.json to lock it in."
        )

if failed:
    print("\nLive detail:", file=sys.stderr)
    print(json.dumps(live["details"], indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)

print("String-any boundary ratchet OK.")
PY
