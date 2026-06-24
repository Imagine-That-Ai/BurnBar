#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${CURL_BEARER_BOUNDARY_ROOT:-}" ]]; then
  cd "${CURL_BEARER_BOUNDARY_ROOT}"
else
  cd "$(dirname "$0")/../.."
fi

python3 <<'PY'
from pathlib import Path
import re
import sys

SCAN_ROOTS = [Path("scripts"), Path(".github/workflows")]
SUFFIXES = {".sh", ".bash", ".yml", ".yaml", ".mjs"}

curl_re = re.compile(r"(^|[|;&({\s])curl(\s|$)")
header_re = re.compile(r"(^|\s)(?:-H|--header)(?:\s|=)")
bearer_re = re.compile(r"authorization\s*:\s*bearer", re.IGNORECASE)


def iter_files():
    for root in SCAN_ROOTS:
        for path in root.rglob("*"):
            if path.is_file() and path.suffix in SUFFIXES:
                yield path


def logical_curl_blocks(lines):
    index = 0
    while index < len(lines):
        line = lines[index]
        if not curl_re.search(line):
            index += 1
            continue

        block_lines = [line.rstrip("\n")]
        cursor = index
        while block_lines[-1].rstrip().endswith("\\") and cursor + 1 < len(lines):
            cursor += 1
            block_lines.append(lines[cursor].rstrip("\n"))
        yield index + 1, "\n".join(block_lines)
        index = cursor + 1


failures = []
for path in sorted(iter_files()):
    try:
        lines = path.read_text(encoding="utf-8").splitlines(True)
    except UnicodeDecodeError:
        continue

    for line_no, block in logical_curl_blocks(lines):
        if header_re.search(block) and bearer_re.search(block):
            failures.append(f"{path}:{line_no}: bearer Authorization header is passed via curl argv; use scripts/lib/curl-bearer.sh")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sys.exit(1)

print("PASS: curl bearer tokens are kept out of argv")
PY
