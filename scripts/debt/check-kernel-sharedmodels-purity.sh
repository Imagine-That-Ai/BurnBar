#!/usr/bin/env bash
# Kernel SharedModels deny-gate: no SwiftUI/AppKit/UIKit imports.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
import re
root = Path("OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels")
ui = re.compile(r"^\s*import\s+(SwiftUI|AppKit|UIKit)\b")
hits = []
for path in sorted(root.rglob("*.swift")):
    for i, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
        if ui.search(line):
            hits.append(f"{path}:{i}:{line.strip()}")
if hits:
    raise SystemExit("Kernel SharedModels UI imports are forbidden:\n" + "\n".join(hits))
print(f"Kernel SharedModels purity OK ({sum(1 for _ in root.rglob('*.swift'))} files, 0 UI imports)")
PY
