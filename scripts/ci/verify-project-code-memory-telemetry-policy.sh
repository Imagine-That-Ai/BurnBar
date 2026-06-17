#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

policy="docs/ops/project-code-memory-telemetry-review.md"
test -f "$policy"

for needle in \
  "cannot carry plaintext source" \
  "Disallowed fields" \
  "raw LSP/helper stdout or stderr" \
  "Hosted telemetry remains blocked"; do
  if ! grep -Fq "$needle" "$policy"; then
    echo "Project Code Memory telemetry policy missing: $needle" >&2
    exit 1
  fi
done

if grep -RInE 'logger\.(notice|warning|error|debug|info).*(source|snippet|contextPack|raw stdout|raw stderr|body)' \
  OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory \
  tools/openburnbar-mcp/project_code_memory.py \
  tools/openburnbar-mcp/server.py; then
  echo "Project Code Memory telemetry appears to log source/snippet/body payloads." >&2
  exit 1
fi

echo "OK: Project Code Memory telemetry policy is documented and source-payload logging is blocked."
