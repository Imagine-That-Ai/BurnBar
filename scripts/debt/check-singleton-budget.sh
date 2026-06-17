#!/usr/bin/env bash
# Shrink-only singleton retirement ratchet.
#
# The structural-debt program retires SettingsManager.shared and
# AccountManager.shared from AgentLens onto the runtime composition root.
# This gate prevents new direct global reads while each bucket is converted to
# injected SettingsManager/AccountManager dependencies.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/singleton-baseline.json"
mode="${1:-}"

python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""
agentlens_root = repo_root / "AgentLens"


def is_code_line(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("//") and not stripped.startswith("/*") and not stripped.startswith("*")


def swift_files():
    excluded_parts = {
        ".build",
        ".derived-data",
        ".swiftpm",
        "Preview Content",
    }
    for path in sorted(agentlens_root.rglob("*.swift")):
        if any(part in excluded_parts for part in path.parts):
            continue
        yield path


def inside_runtime_context_function(line: str, state: dict) -> bool:
    if "private static func makeRuntimeContext" in line:
        state["inside_runtime_context"] = True
        state["brace_depth"] = 0

    if state.get("inside_runtime_context"):
        state["brace_depth"] += line.count("{")
        state["brace_depth"] -= line.count("}")
        inside = True
        if state["brace_depth"] <= 0 and "}" in line:
            state["inside_runtime_context"] = False
        return inside

    return False


def count_settings_account_shared_references():
    total = 0
    by_file = {}
    construction_site = agentlens_root / "App" / "AgentLensApp.swift"
    for path in swift_files():
        file_count = 0
        state = {"inside_runtime_context": False, "brace_depth": 0}
        for line in path.read_text(encoding="utf-8").splitlines():
            inside_runtime_context = path == construction_site and inside_runtime_context_function(line, state)
            if not is_code_line(line):
                continue
            if "SettingsManager.shared" not in line and "AccountManager.shared" not in line:
                continue
            if inside_runtime_context:
                continue
            file_count += 1
        if file_count:
            rel = path.relative_to(repo_root).as_posix()
            by_file[rel] = file_count
            total += file_count
    return total, by_file


def count(predicate):
    total = 0
    by_file = {}
    for path in swift_files():
        file_count = 0
        for line in path.read_text(encoding="utf-8").splitlines():
            if is_code_line(line) and predicate(line):
                file_count += 1
        if file_count:
            rel = path.relative_to(repo_root).as_posix()
            by_file[rel] = file_count
            total += file_count
    return total, by_file


settings_account_total, settings_account_by_file = count_settings_account_shared_references()
static_shared_total, static_shared_by_file = count(
    lambda line: re.search(r"\bstatic\s+(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+)*let\s+shared\b", line)
    is not None
)

live = {
    "settingsAccountSharedReferences": settings_account_total,
    "staticSharedSingletons": static_shared_total,
    "total": settings_account_total + static_shared_total,
    "details": {
        "settingsAccountSharedReferences": settings_account_by_file,
        "staticSharedSingletons": static_shared_by_file,
    },
}

if mode == "--print-live":
    print(json.dumps(live, indent=2, sort_keys=True))
    sys.exit(0)

if not baseline_path.exists():
    print(f"Missing singleton baseline: {baseline_path}", file=sys.stderr)
    print("Run scripts/debt/check-singleton-budget.sh --print-live and check in the current baseline.", file=sys.stderr)
    sys.exit(1)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
metric_names = ("settingsAccountSharedReferences", "staticSharedSingletons", "total")

print(
    "Singleton budget: "
    + " ".join(f"{name}={live[name]} baseline={baseline[name]}" for name in metric_names)
)

failed = False
for name in metric_names:
    if live[name] > baseline[name]:
        print(f"::error::Singleton {name} rose from {baseline[name]} to {live[name]}. Use runtime-context injection instead of adding global shared access.", file=sys.stderr)
        failed = True
    elif live[name] < baseline[name]:
        print(f"::notice::Singleton {name} dropped from {baseline[name]} to {live[name]} — lower budgets/singleton-baseline.json to lock it in.")

if failed:
    print("\nLive detail:", file=sys.stderr)
    print(json.dumps(live["details"], indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)

print("Singleton ratchet OK.")
PY
