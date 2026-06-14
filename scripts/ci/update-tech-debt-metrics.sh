#!/usr/bin/env bash
# Computes tech-debt trend metrics and refreshes docs/TECH_DEBT_METRICS.md.
# Safe to run locally or in CI (read-only scans except the metrics doc write).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
metrics_doc="${repo_root}/docs/TECH_DEBT_METRICS.md"
existing_generated_at=""
if [[ -f "${metrics_doc}" ]]; then
  existing_generated_at="$(sed -n 's/^\*\*Generated at (UTC):\*\* //p' "${metrics_doc}" | head -1)"
fi
if [[ -n "${OPENBURNBAR_REFRESH_TECH_DEBT_TIMESTAMP:-}" || -z "${existing_generated_at}" ]]; then
  generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
else
  generated_at="${existing_generated_at}"
fi

count_swift_lines() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    wc -l < "${path}" | tr -d ' '
  else
    echo "0"
  fi
}

count_swift_glob_lines() {
  local total=0
  local file
  shopt -s nullglob
  for file in "$@"; do
    if [[ -f "${file}" ]]; then
      total=$((total + $(wc -l < "${file}" | tr -d ' ')))
    fi
  done
  shopt -u nullglob
  echo "${total}"
}

count_rg() {
  local pattern="$1"
  shift
  python3 - "${pattern}" "$@" <<'PY'
import pathlib
import re
import sys

pattern = re.compile(sys.argv[1])
total = 0

def swift_files(root: pathlib.Path):
    if root.is_file() and root.suffix == ".swift":
        yield root
    elif root.is_dir():
        yield from root.rglob("*.swift")

for raw in sys.argv[2:]:
    for path in swift_files(pathlib.Path(raw)):
        try:
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                if pattern.search(line):
                    total += 1
        except OSError:
            pass

print(total)
PY
}

count_swift_files_containing() {
  local needle="$1"
  shift
  python3 - "${needle}" "$@" <<'PY'
import pathlib
import sys

needle = sys.argv[1]
total = 0

def swift_files(root: pathlib.Path):
    if root.is_file() and root.suffix == ".swift":
        yield root
    elif root.is_dir():
        yield from root.rglob("*.swift")

for raw in sys.argv[2:]:
    for path in swift_files(pathlib.Path(raw)):
        try:
            if needle in path.read_text(encoding="utf-8", errors="ignore"):
                total += 1
        except OSError:
            pass

print(total)
PY
}

quarantine_files="$(find "${repo_root}/AgentLensTests/Archive" -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')"
quarantine_lines="$(find "${repo_root}/AgentLensTests/Archive" -name '*.swift' -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')"
legacy_reference_files="$(find "${repo_root}/AgentLensTests/LegacyReference" -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')"

types_ts_lines="$(count_swift_lines "${repo_root}/functions/src/types.ts")"
types_legacy_lines="$(count_swift_lines "${repo_root}/functions/src/types/legacy.ts")"
index_ts_lines="$(count_swift_lines "${repo_root}/functions/src/index.ts")"

cloud_sync_lines="$(count_swift_lines "${repo_root}/AgentLens/Services/CloudSyncService.swift")"
search_lines="$(count_swift_glob_lines "${repo_root}/AgentLens/Services/Search/SearchService"*.swift)"
usage_agg_lines="$(count_swift_lines "${repo_root}/AgentLens/Services/UsageAggregator.swift")"
projection_lines="$(count_swift_glob_lines "${repo_root}/AgentLens/Services/ProjectionPipeline/"*.swift)"
top_four_total=$((cloud_sync_lines + search_lines + usage_agg_lines + projection_lines))

task_detached_services="$(count_rg 'Task\.detached' "${repo_root}/AgentLens/Services")"

swiftui_services="$(count_swift_files_containing 'import SwiftUI' "${repo_root}/AgentLens/Services" "${repo_root}/AgentLens/Services/DataStore")"

try_optional_services="$(python3 "${repo_root}/tools/error-debt/count-error-debt.py" --repo-root "${repo_root}" --metric try-optional --format json | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>console.log(JSON.parse(s).tryOptional.total))")"

empty_catch_blocks="$(python3 "${repo_root}/tools/error-debt/count-error-debt.py" --repo-root "${repo_root}" --metric empty-catch --format json | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>console.log(JSON.parse(s).emptyCatch.total))")"

main_actor_io_services=0
for rel in \
  "AgentLens/Services/CloudSyncService.swift" \
  "AgentLens/Services/UsageAggregator.swift" \
  "AgentLens/Services/CloudSync/DownloadSyncService.swift" \
  "AgentLens/Services/CloudSync/ConversationSyncService.swift" \
  "AgentLens/Services/CloudSync/CLIAgentSessionMirror.swift" \
  "AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager.swift"
do
  if [[ -f "${repo_root}/${rel}" ]] && python3 - <<'PY' "${repo_root}/${rel}"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
# Class-scoped @MainActor on listed I/O facades (excludes @MainActor static shared accessors).
if re.search(r"@MainActor\s*\n(?:@\w+\s*\n)*(?:final\s+)?class\s", text):
    raise SystemExit(0)
raise SystemExit(1)
PY
  then
    main_actor_io_services=$((main_actor_io_services + 1))
  fi
done

unsafe_cast_total="n/a"
if [[ -f "${repo_root}/budgets/unsafe-cast-baseline.json" ]]; then
  unsafe_cast_total="$(node -e "const fs=require('node:fs'); console.log(JSON.parse(fs.readFileSync(process.argv[1],'utf8')).total)" "${repo_root}/budgets/unsafe-cast-baseline.json")"
fi

cat > "${metrics_doc}" <<EOF
# Tech debt metrics snapshot

Auto-generated by [\`scripts/ci/update-tech-debt-metrics.sh\`](../scripts/ci/update-tech-debt-metrics.sh).  
**Generated at (UTC):** ${generated_at}

Track trends monthly against targets in [TECH_DEBT_STRATEGY.md](TECH_DEBT_STRATEGY.md#11-metrics-and-governance). Do not hand-edit this file — re-run the script.

## Summary

| Metric | Current | 30-day target | 90-day target |
|--------|---------|---------------|---------------|
| Quarantined test files | ${quarantine_files} | shrinking | 0 |
| Quarantined test lines | ${quarantine_lines} | shrinking | 0 |
| Legacy reference suites (ADR, not quarantined) | ${legacy_reference_files} | stable | — |
| \`@MainActor\` on I/O facades (listed set) | ${main_actor_io_services} | 4 | 0 |
| Empty \`catch {}\` blocks (app + daemon) | ${empty_catch_blocks} | 0 | 0 |
| \`Task.detached\` in \`AgentLens/Services/\` | ${task_detached_services} | ≤ 10 | 0 |
| \`try?\` in \`AgentLens/Services/\` | ${try_optional_services} | ≤ 120 | ≤ 50 |
| Unsafe cast budget (\`budgets/unsafe-cast-baseline.json\`) | ${unsafe_cast_total} | 0 | 0 |
| Top-4 service LOC (CloudSync + Search + UsageAgg + Projection) | ${top_four_total} | ≤ 5000 | ≤ 3500 |
| \`functions/src/types.ts\` LOC (barrel) | ${types_ts_lines} | stable (re-export) | — |
| \`functions/src/types/legacy.ts\` LOC | ${types_legacy_lines} | shrinking (TypeSpec migration) | — |
| \`functions/src/index.ts\` LOC | ${index_ts_lines} | modularize | — |
| \`import SwiftUI\` in Services/ + DataStore/ | ${swiftui_services} | ≤ 3 | 0 |

## Top service files (lines)

| File | LOC |
|------|-----|
| \`AgentLens/Services/CloudSyncService.swift\` | ${cloud_sync_lines} |
| \`AgentLens/Services/Search/\` (SearchService + extensions) | ${search_lines} |
| \`AgentLens/Services/UsageAggregator.swift\` | ${usage_agg_lines} |
| \`AgentLens/Services/ProjectionPipeline/\` | ${projection_lines} |

## Remediation links

- [Architecture ADRs](ARCHITECTURE/README.md)
- [SLO runbook](runbooks/slos.md)
- [Type debt budget](TYPE_DEBT.md)
- [Technical readiness](TECHNICAL_READINESS.md)
EOF

echo "Updated ${metrics_doc}"
