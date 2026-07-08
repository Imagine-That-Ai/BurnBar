#!/usr/bin/env bash
# Losslessness normalization — strips lines that are ONLY:
#   - `import ...` statements (added to each new piece file)
#   - blank lines
# so the primary file + all moved pieces, concatenated, can be diffed
# against the original single-file version byte-for-byte.
# Usage: normalize.sh <input.swift> <output.norm>
set -euo pipefail
in="$1"
out="$2"
# Remove lines matching ^import , then drop all blank lines.
grep -v '^import ' "$in" | grep -v '^[[:space:]]*$' > "$out"