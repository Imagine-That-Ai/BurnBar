#!/bin/bash
# Normalization for losslessness proof.
# Strips from BOTH original and reconstructed:
#   - import ... lines
#   - "extension UsageStore {" lines (added wrappers)
#   - ALL standalone "}" at column 0 (class close + extension closes — structural)
#   - pure-move annotation comments
#   - access level keywords that changed: "private " and "fileprivate " prefixes
#     on declarations (intentional pure-move promotions to internal)
#   - blank lines
# Keeps: MARK headers, all code, struct definitions (with their internal }s).
#
# Rationale: the split adds structural wrappers (extensions) and changes access
# levels. Both are pure-move artifacts, not behavioral changes. Stripping them
# from both sides produces a lossless content comparison.
set -euo pipefail

INPUT="$1"
OUTPUT="$2"

python3 - "$INPUT" "$OUTPUT" <<'PYEOF'
import sys
import re

with open(sys.argv[1]) as f:
    content = f.read()

lines = content.split('\n')
result = []

for line in lines:
    stripped = line.strip()
    
    # Skip import lines
    if stripped.startswith('import '):
        continue
    # Skip blank lines
    if stripped == '':
        continue
    # Skip "extension UsageStore {" lines
    if stripped == 'extension UsageStore {':
        continue
    # Skip standalone "}" at column 0 (class/extension closing braces)
    if line == '}':
        continue
    # Remove pure-move annotations
    line = re.sub(r'\s*// pure-move: was (private|fileprivate)', '', line)
    # Normalize access level: remove "private " and "fileprivate " prefixes
    # that were changed to internal (pure-move). Only on declaration lines
    # (indented members of the class/extension).
    # Match patterns like: "    private func ", "    private static func ",
    # "    fileprivate static func "
    line = re.sub(r'^(\s+)private (func|static func|struct) ', r'\1\2 ', line)
    line = re.sub(r'^(\s+)fileprivate (func|static func) ', r'\1\2 ', line)
    # Also handle top-level private structs
    line = re.sub(r'^private struct ', 'struct ', line)
    
    result.append(line)

normalized = '\n'.join(result)
with open(sys.argv[2], 'w') as f:
    f.write(normalized)
PYEOF