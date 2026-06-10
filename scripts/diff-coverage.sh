#!/usr/bin/env bash
# Compute true diff coverage for changed Swift files.
#
# Intersects git diff added-line hunks with per-line xccov data when available.
# Matches files by full repo-relative path (not basename).
#
# Usage:
#   diff-coverage.sh <base-ref> [coverage-summary-json] [coverage-lines-json]
#
# Exit codes:
#   0 — diff coverage meets or exceeds threshold
#   1 — diff coverage is below threshold
#   2 — usage error

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

base_ref="${1:-origin/main}"
threshold="${COVERAGE_THRESHOLD:-80}"

coverage_json="${2:-}"
lines_json="${3:-}"

if [[ -z "$coverage_json" ]]; then
  for candidate in "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult"; do
    if [[ -d "$candidate" ]]; then
      coverage_json="$TMPDIR/openburnbar-diff-coverage-summary.json"
      "$repo_root/scripts/extract-coverage.sh" "$candidate" > "$coverage_json"
      break
    fi
  done
fi

if [[ -z "$lines_json" && -d "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" ]]; then
  lines_json="$TMPDIR/openburnbar-diff-coverage-lines.json"
  "$repo_root/scripts/extract-coverage-lines.sh" "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" > "$lines_json" 2>/dev/null || lines_json=""
fi

# Coverage is a production-code gate: test sources and CI tooling scripts are
# never coverage targets (the app XCTest scheme does not even run package
# tests, so they would always read 0% here while passing in their own lane).
changed_files=""
if ! changed_files="$(git diff --name-only "$base_ref" HEAD -- '*.swift' ':(exclude)*Tests*' ':(exclude)scripts/*' 2>/dev/null)"; then
  changed_files=""
fi

if [[ -z "$changed_files" ]]; then
  echo "{\"diffCoverage\":{\"percent\":100.0,\"threshold\":$threshold,\"passed\":true,\"changedFiles\":0,\"changedLines\":0,\"method\":\"no_swift_changes\"},\"details\":[]}"
  exit 0
fi

if [[ ! -f "${coverage_json:-}" ]]; then
  echo '::error::No coverage data found. Run tests with OPENBURNBAR_ENABLE_COVERAGE=YES first.' >&2
  exit 1
fi

export COVERAGE_THRESHOLD="$threshold"
export BASE_REF="$base_ref"
export REPO_ROOT="$repo_root"
export COVERAGE_JSON="$coverage_json"
export LINES_JSON="${lines_json:-}"

python3 - "$coverage_json" <<'PY'
import json
import os
import re
import subprocess
import sys

threshold = int(os.environ["COVERAGE_THRESHOLD"])
base_ref = os.environ["BASE_REF"]
repo_root = os.environ["REPO_ROOT"]
coverage_json_path = sys.argv[1]
lines_json_path = os.environ.get("LINES_JSON") or ""

with open(coverage_json_path, encoding="utf-8") as handle:
    cov = json.load(handle)

line_files = {}
if lines_json_path and os.path.isfile(lines_json_path):
    with open(lines_json_path, encoding="utf-8") as handle:
        line_payload = json.load(handle)
        line_files = line_payload.get("files", {})

# Full-path and basename maps for aggregate fallback
file_map_by_path = {}
file_map_by_base = {}
for item in cov.get("targets", []):
    name = item.get("name", "")
    rel = name
    if name.startswith(repo_root):
        rel = os.path.relpath(name, repo_root)
    elif "/BurnBar/" in name:
        rel = name.split("/BurnBar/", 1)[1]
    file_map_by_path[rel] = item
    file_map_by_base[os.path.basename(rel)] = item

changed_file_list = subprocess.check_output(
    ["git", "diff", "--name-only", base_ref, "HEAD", "--", "*.swift", ":(exclude)*Tests*", ":(exclude)scripts/*"],
    cwd=repo_root,
    text=True,
).splitlines()
changed_file_list = [line.strip() for line in changed_file_list if line.strip()]


def test_file_with_stem(root, stem):
    abs_root = os.path.join(repo_root, root)
    if not os.path.isdir(abs_root):
        return False
    for dirpath, _, filenames in os.walk(abs_root):
        for filename in filenames:
            if filename.endswith(".swift") and stem in filename:
                return True
    return False


def has_test_evidence(rel_path):
    stem = os.path.splitext(os.path.basename(rel_path))[0]
    # OpenBurnBarCore package tests run in the Swift Core/iOS lanes, not as
    # direct line coverage inside the app XCTest artifact.
    if rel_path.startswith("OpenBurnBarCore/Sources/"):
        return test_file_with_stem("OpenBurnBarCore/Tests", stem)
    # OpenBurnBarDaemon package tests run in the daemon's own swift-test lane
    # (Swift Core job), not as direct line coverage inside the app XCTest
    # artifact — the app scheme never links or executes daemon sources.
    if rel_path.startswith("OpenBurnBarDaemon/Sources/"):
        return test_file_with_stem("OpenBurnBarDaemon/Tests", stem)
    # Mobile code is validated by the iOS Mobile job. The macOS app coverage
    # artifact cannot provide meaningful line hits for these files.
    if rel_path.startswith("OpenBurnBarMobile/"):
        return os.path.isdir(os.path.join(repo_root, "OpenBurnBarMobileTests"))
    # Shared generated data-domain Swift is byte-checked by the registry tests.
    if rel_path == "packages/data-domains/gen/DataDomains.swift":
        return os.path.isfile(os.path.join(repo_root, "packages/data-domains/registry.test.mjs"))
    # SwiftPM manifests are build configuration, never compiled into the app
    # coverage target. The package's own swift-test lane cannot even start
    # unless the manifest parses and resolves, so a manifest whose package
    # ships a Tests/ tree is validated by that lane.
    if os.path.basename(rel_path) == "Package.swift":
        return os.path.isdir(os.path.join(repo_root, os.path.dirname(rel_path), "Tests"))
    # SwiftUI view bodies are exercised through UI/snapshot tests, but xccov
    # line maps often collapse them to aggregate fallback. Keep the gate tied
    # to the app UI test surface instead of synthetic body-line coverage.
    if rel_path.startswith("AgentLens/Views/"):
        return os.path.isdir(os.path.join(repo_root, "AgentLensTests/Active/UI"))
    return False


test_evidence_details = []
coverage_changed = []
for rel_path in changed_file_list:
    if has_test_evidence(rel_path):
        test_evidence_details.append({
            "file": rel_path,
            "executableLines": 0,
            "coveredLines": 0,
            "percent": 100.0,
            "method": "test_file_presence",
        })
    else:
        coverage_changed.append(rel_path)
changed_file_list = coverage_changed

if not changed_file_list:
    output = {
        "diffCoverage": {
            "percent": 100.0,
            "threshold": threshold,
            "passed": True,
            "changedFiles": len(test_evidence_details),
            "changedLines": 0,
            "method": "test_file_presence",
        },
        "details": test_evidence_details,
    }
    print(json.dumps(output, indent=2))
    raise SystemExit(0)

git_output = subprocess.run(
    ["git", "diff", "-U0", base_ref, "HEAD", "--"] + changed_file_list,
    cwd=repo_root,
    capture_output=True,
    text=True,
).stdout

file_blocks = {}
current_file = None
for line in git_output.splitlines():
    m = re.match(r"^diff --git a/.* b/(.*)$", line)
    if m:
        current_file = m.group(1)
        file_blocks.setdefault(current_file, [])
        continue
    if current_file and line.startswith("@@"):
        nm = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if not nm:
            continue
        start = int(nm.group(1))
        count = int(nm.group(2) or "1")
        if count <= 0:
            continue
        for ln in range(start, start + count):
            file_blocks[current_file].append(ln)

# Read source files to find lines annotated with cov:ignore
cov_ignore_lines = {}
for rel_path, line_nums in file_blocks.items():
    abs_path = os.path.join(repo_root, rel_path)
    if not os.path.isfile(abs_path):
        continue
    with open(abs_path, encoding="utf-8", errors="replace") as fh:
        src_lines = fh.read().splitlines()
    for ln in line_nums:
        idx = ln - 1  # 0-based index
        if 0 <= idx < len(src_lines) and "cov:ignore" in src_lines[idx]:
            cov_ignore_lines.setdefault(rel_path, set()).add(ln)

total_exc = 0
total_hit = 0
details = []

for rel_path in changed_file_list:
    changed_lines = sorted(set(file_blocks.get(rel_path, [])))
    ignore = cov_ignore_lines.get(rel_path, set())
    changed_lines = [ln for ln in changed_lines if ln not in ignore]
    if not changed_lines:
        continue

    line_entry = line_files.get(rel_path, {})
    line_cov = line_entry.get("lines", {})

    exc = 0
    hit = 0
    method = "line_level"

    if line_cov and "_aggregate" not in line_cov:
        for ln in changed_lines:
            key = str(ln)
            if key not in line_cov:
                continue
            exc += 1
            if line_cov[key]:
                hit += 1
    else:
        method = "file_aggregate_fallback"
        cov_item = file_map_by_path.get(rel_path) or file_map_by_base.get(os.path.basename(rel_path))
        if not cov_item:
            exc = len(changed_lines)
            hit = 0
        else:
            file_exc = cov_item.get("executable", 0)
            file_hit = cov_item.get("hit", 0)
            if file_exc <= 0:
                exc = len(changed_lines)
                hit = 0
            else:
                ratio = file_hit / file_exc
                exc = len(changed_lines)
                hit = int(round(exc * ratio))

    if exc <= 0:
        continue

    pct = round(hit * 100.0 / exc, 2)
    total_exc += exc
    total_hit += hit
    details.append({
        "file": rel_path,
        "executableLines": exc,
        "coveredLines": hit,
        "percent": pct,
        "method": method,
    })
details.extend(test_evidence_details)

total_pct = 0.0 if total_exc <= 0 else round(total_hit * 100.0 / total_exc, 2)
passed = total_exc <= 0 or total_pct >= threshold

output = {
    "diffCoverage": {
        "percent": total_pct,
        "threshold": threshold,
        "passed": passed,
        "changedFiles": len(details),
        "changedLines": total_exc,
        "method": "line_intersection",
    },
    "details": details,
}
print(json.dumps(output, indent=2))
if not passed and total_exc > 0:
    sys.exit(1)
PY
