#!/bin/bash
# normalize.sh — normalize a Swift file for losslessness comparison.
# Strips organizational lines (imports, MARKs, extension/class wrappers,
# attributes, blank lines, standalone closing braces), reverts the
# pure-move access-level changes (internal→private, internal(set)→private(set),
# removes "// pure-move: was private" trailing comments), then sorts
# so that member ordering differences from the split are irrelevant.
#
# Usage: normalize.sh <input.swift> > <output.norm>
set -euo pipefail

INPUT="$1"

# Step 1–7: strip organizational lines and revert access-level changes
grep -v '^$' "$INPUT" \
  | grep -v '^import ' \
  | grep -v '// MARK:' \
  | grep -v '^extension ProviderQuotaService {' \
  | grep -v '^@Observable$' \
  | grep -v '^@MainActor$' \
  | grep -v '^final class ProviderQuotaService {' \
  | grep -v '^\s*}$' \
  | sed 's/internal(set) /private(set) /g' \
  | sed 's/internal /private /g' \
  | sed 's/  \/\/ pure-move: was private$//' \
  | sort
