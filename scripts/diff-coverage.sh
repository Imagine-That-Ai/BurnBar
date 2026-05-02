#!/usr/bin/env bash
# Compute diff coverage for changed Swift files in the current working tree.
#
# Usage:
#   diff-coverage.sh <base-ref> [coverage-summary-json]
#   diff-coverage.sh origin/main /path/to/coverage.json
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
# If second argument omitted, try to generate one from xcresult
data_dir=""
if [[ -z "$coverage_json" ]]; then
  for candidate in "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult"; do
    if [[ -d "$candidate" ]]; then
      data_dir="$candidate"
      break
    fi
  done
  if [[ -n "$data_dir" ]]; then
    coverage_json="$TMPDIR/openburnbar-diff-coverage-summary.json"
    "$repo_root/scripts/extract-coverage.sh" "$data_dir" > "$coverage_json"
  fi
fi

# Determine changed Swift files against base ref
changed_files=""
if ! changed_files="$(git diff --name-only "$base_ref" HEAD -- '*.swift' 2>/dev/null)" || [[ -z "$changed_files" ]]; then
  echo '{"diffCoverage":{"percent":100.0,"threshold"':"$threshold",'"passed":true,"changedFiles":0,"changedLines":0},"details":[]}'
  exit 0
fi

# Gather executable line info from coverage JSON
if [[ ! -f "${coverage_json:-}" ]]; then
  echo '::error::No coverage data found. Run tests with OPENBURNBAR_ENABLE_COVERAGE=YES first.' >&2
  exit 1
fi

python3 -c "
import json, sys, subprocess, os, re

threshold = int('$threshold')
base_ref = '$base_ref'
repo_root = '$repo_root'
coverage_json_path = '${coverage_json}'

with open(coverage_json_path) as f:
    cov = json.load(f)

file_map = {}
for item in cov.get('targets', []):
    name = item.get('name', '')
    file_map[os.path.basename(name)] = item

changed_file_list = [l.strip() for l in sys.stdin if l.strip()]
if not changed_file_list:
    changed_file_list = subprocess.check_output(
        ['git', 'diff', '--name-only', base_ref, 'HEAD', '--', '*.swift'],
        cwd=repo_root, text=True
    ).splitlines()
    changed_file_list = [l.strip() for l in changed_file_list if l.strip()]

# Get diff output for changed files
git_output = subprocess.run(
    ['git', 'diff', '-U0', base_ref, 'HEAD', '--'] + changed_file_list,
    cwd=repo_root, capture_output=True, text=True
).stdout

file_blocks = {}
current_file = None
for line in git_output.splitlines():
    m = re.match(r'^diff --git a/.* b/(.*)$', line)
    if m:
        current_file = m.group(1)
        if current_file not in file_blocks:
            file_blocks[current_file] = []
    if current_file and line.startswith('@@'):
        nm = re.search(r'\+\\d+(?:,\\d+)?', line)
        if nm:
            parts = nm.group(0).lstrip('+').split(',')
            start = int(parts[0])
            count = int(parts[1]) if len(parts) > 1 else 1
            file_blocks[current_file].append((start, start + count - 1))

covered_changed_exc = 0
covered_changed_hit = 0
details = []
for rel_path in changed_file_list:
    base = os.path.basename(rel_path)
    cov_item = file_map.get(base)
    if not cov_item:
        continue
    exc = cov_item.get('executable', 0)
    hit = cov_item.get('hit', 0)
    pct = cov_item.get('percent', 0.0)
    covered_changed_exc += exc
    covered_changed_hit += hit
    details.append({
        'file': rel_path,
        'executableLines': exc,
        'coveredLines': hit,
        'percent': pct
    })

total_pct = 0.0 if covered_changed_exc <= 0 else round(covered_changed_hit * 100.0 / covered_changed_exc, 2)
passed = total_pct >= threshold

output = {
    'diffCoverage': {
        'percent': total_pct,
        'threshold': threshold,
        'passed': passed,
        'changedFiles': len(details),
        'changedLines': covered_changed_exc
    },
    'details': details
}
print(json.dumps(output, indent=2))
if not passed and covered_changed_exc > 0:
    sys.exit(1)
" < <(printf '%s\n' "$changed_files")
# Feed changed files list to python via stdin
