#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path

checks = [
    (
        Path("services/hosted-mcp/src/toolRegistry.ts"),
        'OPENBURNBAR_HOSTED_CODE_MEMORY_TOOLS === "true"',
    ),
    (
        Path("services/hosted-mcp/src/auth.test.ts"),
        "hosted code tools are hidden and denied unless explicitly enabled",
    ),
    (
        Path("services/hosted-mcp/src/knowledge.test.ts"),
        "searchKnowledge refuses code rows; hosted code search requires project scoping",
    ),
    (
        Path("services/hosted-mcp/src/knowledge.ts"),
        "Code memory must be queried with burnbar_search_code",
    ),
    (
        Path("docs/PENSIEVE.md"),
        "Code Asset Class (Hosted Sync Gate)",
    ),
    (
        Path("docs/REMOTE_MCP_THREAT_MODEL.md"),
        "Hosted code responses are sealed-only",
    ),
    (
        Path("docs/PROJECT_CODE_MEMORY_RETENTION.md"),
        "Hosted code sync is disabled by default",
    ),
]

missing = []
for path, needle in checks:
    text = path.read_text(encoding="utf-8")
    if needle not in text:
        missing.append(f"{path}: missing {needle!r}")

if missing:
    raise SystemExit("Hosted code-memory policy drift:\n" + "\n".join(missing))

print("OK: hosted code-memory policy remains default-off and sealed-only documented.")
PY
