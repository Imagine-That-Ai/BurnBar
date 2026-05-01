#!/usr/bin/env bash
# Extract line coverage from an xcresult bundle produced by xcodebuild.
#
# Usage:
#   scripts/extract-coverage.sh <xcresult-path>
#
# Emits JSON summary to stdout. Extraction failures are fatal by default because
# CI runs this only after requesting coverage from xcodebuild.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
xcresult_path="${1:-$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-coverage.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -d "$xcresult_path" ]]; then
  echo "xcresult bundle not found: $xcresult_path" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to extract Xcode coverage" >&2
  exit 1
fi

coverage_json="$tmp_dir/coverage.json"
if ! xcrun xccov view --report --json "$xcresult_path" > "$coverage_json"; then
  echo "xcrun xccov failed for xcresult: $xcresult_path" >&2
  exit 1
fi

python3 - "$coverage_json" <<'PY'
import json
import sys

coverage_path = sys.argv[1]
with open(coverage_path, encoding="utf-8") as handle:
    data = json.load(handle)

skip_target_markers = (
    "Tests",
    "TestHost",
    "UITests",
)
skip_path_markers = (
    "/AgentLensTests/",
    "/OpenBurnBarDaemon/Tests/",
    "/Tests/",
    ".build/",
    ".derived-data/",
)

total_executable = 0
total_covered = 0
files = []

for target in data.get("targets", []):
    target_name = target.get("name", "")
    if any(marker in target_name for marker in skip_target_markers):
        continue

    for file_record in target.get("files", []):
        name = file_record.get("name") or file_record.get("path") or ""
        if not name or any(marker in name for marker in skip_path_markers):
            continue

        executable = int(file_record.get("executableLines") or 0)
        covered = int(file_record.get("coveredLines") or 0)
        if executable <= 0:
            continue

        percent = round((covered * 100.0) / executable, 2)
        total_executable += executable
        total_covered += covered
        files.append({
            "name": name,
            "executable": executable,
            "hit": covered,
            "percent": percent,
        })

if total_executable <= 0:
    print("coverage extraction found zero executable production lines", file=sys.stderr)
    sys.exit(2)

summary = {
    "summary": {
        "percent": round((total_covered * 100.0) / total_executable, 2),
        "executableLines": total_executable,
        "coveredLines": total_covered,
    },
    "targets": sorted(files, key=lambda item: item["name"]),
}
print(json.dumps(summary, indent=2))
PY
