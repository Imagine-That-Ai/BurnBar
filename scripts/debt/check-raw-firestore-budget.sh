#!/usr/bin/env bash
# Shrink-only raw Firestore access ratchet (R-GH6).
#
# Drives direct Firestore singleton construction out of Views/Models/Services and
# into the sanctioned gateway/repository layer. Every call site that resolves the
# global Firestore handle itself is one more place that has to reason about
# offline persistence, auth gating, and settings — instead of leaning on a
# gateway that already does. The budget counts raw handles created OUTSIDE the
# allowlisted gateway files:
#   * Swift   `Firestore.firestore(`  under AgentLens/, OpenBurnBarMobile/,
#             OpenBurnBarCore/Sources/, OpenBurnBarDaemon/Sources/
#   * Android `FirebaseFirestore.getInstance()` / `Firebase.firestore`
#             under android/app/src/main
#
# The sanctioned gateways are exempt — they are *meant* to own the handle:
#   AgentLens/Services/CloudSync/CloudSyncFirestoreGateway.swift
#   AgentLens/Services/ComputerUse/ComputerUseFirestoreGateway.swift
#   AgentLens/Services/WarRoom/WarRoomFirestoreGateway.swift
#   OpenBurnBarMobile/Services/FirestoreRepository.swift
#   android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRepository.kt
#
# The gate fails when the live count EXCEEDS budgets/raw-firestore-baseline.json.
# As each call site is routed through a gateway, lower the baseline to lock the
# win in. Run with --print-live to capture a fresh baseline snapshot.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/raw-firestore-baseline.json"
mode="${1:-}"

python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""

# Sanctioned gateway/repository layer. These files own the raw Firestore handle
# on purpose, so they are exempt from the ratchet. Exact repo-relative paths,
# verified present when this baseline was captured.
allowlist = {
    "AgentLens/Services/CloudSync/CloudSyncFirestoreGateway.swift",
    "AgentLens/Services/ComputerUse/ComputerUseFirestoreGateway.swift",
    # reason: feature-scoped gateway in the same shape as the two above — it owns
    # the handle for users/{uid}/hermes_bodies and war_wire_grants so the War
    # Room's stores, publisher, and faces never resolve Firestore themselves.
    "AgentLens/Services/WarRoom/WarRoomFirestoreGateway.swift",
    "OpenBurnBarMobile/Services/FirestoreRepository.swift",
    "android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRepository.kt",
}

swift_roots = [
    repo_root / "AgentLens",
    repo_root / "OpenBurnBarMobile",
    repo_root / "OpenBurnBarCore" / "Sources",
    repo_root / "OpenBurnBarDaemon" / "Sources",
]
android_root = repo_root / "android" / "app" / "src" / "main"

swift_pattern = re.compile(r"Firestore\.firestore\(")
android_pattern = re.compile(r"FirebaseFirestore\.getInstance\(\)|Firebase\.firestore\b")

excluded_parts = {".build", ".derived-data", ".swiftpm", "Preview Content", "build"}


def is_code_line(line: str) -> bool:
    stripped = line.strip()
    return (
        bool(stripped)
        and not stripped.startswith("//")
        and not stripped.startswith("/*")
        and not stripped.startswith("*")
    )


def iter_files(root: Path, suffix: str):
    if not root.exists():
        return
    for path in sorted(root.rglob(f"*{suffix}")):
        if any(part in excluded_parts for part in path.parts):
            continue
        yield path


def count(files, pattern):
    total = 0
    by_file = {}
    for path in files:
        rel = path.relative_to(repo_root).as_posix()
        if rel in allowlist:
            continue
        file_count = 0
        for line in path.read_text(encoding="utf-8").splitlines():
            if not is_code_line(line):
                continue
            file_count += len(pattern.findall(line))
        if file_count:
            by_file[rel] = file_count
            total += file_count
    return total, by_file


swift_files = []
for root in swift_roots:
    swift_files.extend(iter_files(root, ".swift"))
swift_total, swift_by_file = count(swift_files, swift_pattern)
android_total, android_by_file = count(iter_files(android_root, ".kt"), android_pattern)

by_file = {}
by_file.update(swift_by_file)
by_file.update(android_by_file)

live = {
    "swiftFirestoreFirestore": swift_total,
    "androidFirestoreSingletons": android_total,
    "total": swift_total + android_total,
    "details": by_file,
}

# A gateway that was renamed away leaves its raw calls counting under the new
# path — warn so the allowlist gets updated instead of silently masking debt.
for entry in sorted(allowlist):
    if not (repo_root / entry).exists():
        print(f"::warning::Allowlisted gateway missing: {entry} — update scripts/debt/check-raw-firestore-budget.sh.", file=sys.stderr)

if mode == "--print-live":
    print(json.dumps(live, indent=2, sort_keys=True))
    sys.exit(0)

if not baseline_path.exists():
    print(f"Missing raw Firestore baseline: {baseline_path}", file=sys.stderr)
    print("Run scripts/debt/check-raw-firestore-budget.sh --print-live and check in the current baseline.", file=sys.stderr)
    sys.exit(1)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
metric_names = ("swiftFirestoreFirestore", "androidFirestoreSingletons", "total")

print(
    "Raw Firestore budget: "
    + " ".join(f"{name}={live[name]} baseline={baseline[name]}" for name in metric_names)
)

top = sorted(by_file.items(), key=lambda kv: (-kv[1], kv[0]))[:10]
if top:
    print("Top offending files:")
    for rel, n in top:
        print(f"  {n:>3}  {rel}")

failed = False
for name in metric_names:
    if live[name] > baseline[name]:
        print(f"::error::Raw Firestore {name} rose from {baseline[name]} to {live[name]}. Route the new access through the gateway/repository layer instead of resolving Firestore.firestore()/FirebaseFirestore directly.", file=sys.stderr)
        failed = True
    elif live[name] < baseline[name]:
        print(f"::notice::Raw Firestore {name} dropped from {baseline[name]} to {live[name]} — lower budgets/raw-firestore-baseline.json to lock it in.")

if failed:
    print("\nLive detail:", file=sys.stderr)
    print(json.dumps(live["details"], indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)

print("Raw Firestore ratchet OK.")
PY
