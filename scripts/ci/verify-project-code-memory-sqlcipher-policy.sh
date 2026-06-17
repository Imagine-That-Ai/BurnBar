#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ "${PROJECT_CODE_MEMORY_RELEASE_READY:-false}" == "true" && "${DAEMON_SQLCIPHER_PRESENT:-}" != "1" ]]; then
  echo "ERROR: PROJECT_CODE_MEMORY_RELEASE_READY=true requires DAEMON_SQLCIPHER_PRESENT=1." >&2
  echo "Run the daemon SQLCipher keyed-open/migration proof before enabling Project Code Memory release readiness." >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path

checks = [
    (
        Path("docs/ARCHITECTURE/011-project-code-memory-sqlcipher-release-policy.md"),
        "Project Code Memory release readiness requires a SQLCipher-capable daemon build",
    ),
    (
        Path("OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift"),
        "SQLCipher codec not linked; Project Code Memory release readiness is blocked",
    ),
    (
        Path("tools/openburnbar-mcp/project_code_memory.py"),
        "SQLCipher codec not linked; Project Code Memory release readiness is blocked",
    ),
]

missing = []
for path, needle in checks:
    text = path.read_text(encoding="utf-8")
    if needle not in text:
        missing.append(f"{path}: missing {needle!r}")

if missing:
    raise SystemExit("Project Code Memory SQLCipher policy drift:\n" + "\n".join(missing))

print("OK: Project Code Memory SQLCipher release policy is enforced.")
PY
