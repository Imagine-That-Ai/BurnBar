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

changed_files=""
if ! changed_files="$(git diff --name-only "$base_ref" HEAD -- '*.swift' 2>/dev/null)"; then
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
    ["git", "diff", "--name-only", base_ref, "HEAD", "--", "*.swift"],
    cwd=repo_root,
    text=True,
).splitlines()
changed_file_list = [line.strip() for line in changed_file_list if line.strip()]

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

total_exc = 0
total_hit = 0
details = []

for rel_path in changed_file_list:
    changed_lines = sorted(set(file_blocks.get(rel_path, [])))
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
