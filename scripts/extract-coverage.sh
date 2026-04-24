#!/usr/bin/env bash
# Extract code coverage from an xcresult bundle produced by xcodebuild.
#
# Usage:
#   extract-coverage.sh <xcresult-path>
#
# Emits JSON summary to stdout and exits with 0.
# If no xcresult path is provided, searches for a default.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
xcresult_path="${1:-$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult}"

if [[ ! -d "$xcresult_path" ]]; then
  echo '{"error":"xcresult bundle not found","xcresult_path":"'"$xcresult_path"'"}' >&2
  exit 1
fi

# Resolve the Coverage Archive directory within the xcresult.
coverage_archive=""
# macOS 15+ / Xcode 16: the archive path changed; xcresulttool is the reliable probe.
if command -v xcrun &>/dev/null && command -v xcodebuild &>/dev/null; then
  coverage_archive="$(xcrun xcresulttool get --format json --path "$xcresult_path" 2>/dev/null \
    | python3 -c "
import sys, json
try:
  data=json.load(sys.stdin)
  # Walk legacy coverage archive path
  actions = data.get('actions', {}).get('_values', [])
  for a in actions:
    for ref in a.get('actionResult', {}).get('coverage', {}).get('archiveRef', {}).get('id', {}).get('_values', []):
      print(ref.get('_value', ''))
except Exception: pass
" 2>/dev/null || true)"
fi

total_line_count=0
total_hit_count=0
files=()

# If a coverage archive path was resolved and exists, walk it with xccov.
if [[ -n "$coverage_archive" && -d "$xcresult_path/$coverage_archive" ]]; then
  # Xcode 16+ legacy archive structure
  archive_dir="$xcresult_path/$coverage_archive"
  if command -v xcrun &>/dev/null; then
    xcrun xccov view --report --json "$archive_dir" > "$TMPDIR/openburnbar-coverage.json" 2>/dev/null || true
    if [[ -f "$TMPDIR/openburnbar-coverage.json" ]]; then
      python3 -c "
import sys, json

def main():
    with open('$TMPDIR/openburnbar-coverage.json') as f:
        data = json.load(f)
    targets = data.get('targets', [])
    for t in targets:
        if any(x in t.get('name','') for x in ['OpenBurnBarTests','OpenBurnBarDaemonTests']):
            continue  # skip test bundles
        files = t.get('files', [])
        for f in files:
            nm = f.get('name', '')
            exc = f.get('executableLines', 0)
            hi  = f.get('coveredLines', 0)
            pct = 0.0 if exc <= 0 else round(hi * 100.0 / exc, 2)
            print(f'${nm}\t${exc}\t${hi}\t${pct}')
main()
" > "$TMPDIR/openburnbar-coverage-per-file.txt" 2>/dev/null || true
    fi
  fi
fi

# Fallback: use xccov directly on the result bundle (Xcode 15+ path) when legacy archive not found.
if ! [[ -s "$TMPDIR/openburnbar-coverage-per-file.txt" >/dev/null ]]; then
  if command -v xcrun &>/dev/null; then
    xcrun xccov view --report --json "$xcresult_path" > "$TMPDIR/openburnbar-coverage.json" 2>/dev/null || true
    if [[ -f "$TMPDIR/openburnbar-coverage.json" ]]; then
      python3 -c "
import sys, json

def main():
    with open('$TMPDIR/openburnbar-coverage.json') as f:
        data = json.load(f)
    targets = data.get('targets', [])
    for t in targets:
        if any(x in t.get('name','') for x in ['OpenBurnBarTests','OpenBurnBarDaemonTests']):
            continue
        files = t.get('files', [])
        for f in files:
            nm = f.get('name', '')
            exc = f.get('executableLines', 0)
            hi  = f.get('coveredLines', 0)
            pct = 0.0 if exc <= 0 else round(hi * 100.0 / exc, 2)
            print(f'${nm}\t${exc}\t${hi}\t${pct}')
main()
" > "$TMPDIR/openburnbar-coverage-per-file.txt" 2>/dev/null || true
    fi
  fi
fi

# Build summary JSON
if [[ -f "$TMPDIR/openburnbar-coverage-per-file.txt" ]]; then
  python3 -c "
import json, sys

total_exc = 0
total_hi  = 0
file_rows = []
with open('$TMPDIR/openburnbar-coverage-per-file.txt') as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) < 4:
            continue
        nm, exc, hi, pct = parts[0], int(parts[1]), int(parts[2]), float(parts[3])
        total_exc += exc
        total_hi  += hi
        file_rows.append({'name': nm, 'executable': exc, 'hit': hi, 'percent': pct})

total_pct = 0.0 if total_exc <= 0 else round(total_hi * 100.0 / total_exc, 2)

output = {
    'summary': {
        'percent': total_pct,
        'executableLines': total_exc,
        'coveredLines': total_hi
    },
    'targets': file_rows
}
print(json.dumps(output, indent=2))
"
else
  echo '{"summary":{"percent":0.0,"executableLines":0,"coveredLines":0},"targets":[]}'
fi
