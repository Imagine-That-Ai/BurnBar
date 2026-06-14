#!/usr/bin/env bash
# Assert-zero gate for Rust unwrap()/expect() in in-tree shipping crates.
# Complements Cargo.toml [lints.clippy] denies and CI clippy -D flags.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

count="$(python3 - "${repo_root}" <<'PY'
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
roots = [repo / "crates/burnbar-remote", repo / "crates/openburnbar-iroh"]
pattern = re.compile(r"\.(unwrap|expect)\(|\.unwrap_err\(|\.expect_err\(")
total = 0
hits: list[str] = []

for root in roots:
    if not root.is_dir():
        continue
    for path in sorted(root.rglob("*.rs")):
        if "target" in path.parts:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            if pattern.search(line):
                total += 1
                hits.append(f"{path.relative_to(repo)}:{line_no}:{line.strip()}")

print(total)
for hit in hits[:20]:
    print(hit, file=sys.stderr)
if len(hits) > 20:
    print(f"... and {len(hits) - 20} more", file=sys.stderr)
PY
)"

echo "Rust panic debt (unwrap/expect): live=${count} budget=0"

if [[ "${count}" -gt 0 ]]; then
  echo "Rust panic budget exceeded. Replace unwrap/expect with typed errors or contextual panic! in tests." >&2
  exit 1
fi