#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
services_root="${repo_root}/AgentLens/Services"

offenders=()
while IFS= read -r offender; do
  offenders+=("${offender}")
done < <(
  python3 - "${services_root}" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
matches = []
for path in sorted(root.rglob("*.swift")):
    try:
        if any(line.strip() == "import SwiftUI" for line in path.read_text(encoding="utf-8", errors="ignore").splitlines()):
            matches.append(path)
    except OSError:
        pass

for path in matches:
    print(path)
PY
)

echo "Service SwiftUI import budget: live=${#offenders[@]} target=0"

if ((${#offenders[@]} > 0)); then
  echo "SwiftUI is a presentation-layer dependency; remove it from AgentLens/Services:" >&2
  printf '  %s\n' "${offenders[@]#${repo_root}/}" >&2
  exit 1
fi
