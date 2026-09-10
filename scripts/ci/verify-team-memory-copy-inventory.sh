#!/usr/bin/env bash
# Team-memory copy inventory gate (memory program D16 / P22, PR 4 review L9).
#
# `TeamMemoryCopy.allCopy` is the list the in-process honesty mirror
# (`TeamMemoryCopyGateTests.test_no_team_copy_string_contains_a_banned_over_claim`)
# walks. It was hand-maintained with NOTHING checking it, so a new shipped string
# could silently escape the fast gate — the CI phrase scan would still catch a
# banned phrase in the file's text, but the unit test that is supposed to catch it
# in seconds would be walking an incomplete list and reporting green.
#
# This gate makes the completeness claim true: every `static let` / `static func`
# declared in TeamMemoryCopy must appear in `allCopy`. A declaration that must NOT
# be listed (a non-shipped helper) opts out with a `// copy-inventory: exempt`
# comment on the line directly above it, which puts the exemption in review.
#
# Usage:
#   scripts/ci/verify-team-memory-copy-inventory.sh
#   scripts/ci/verify-team-memory-copy-inventory.sh --self-test
set -euo pipefail
cd "$(dirname "$0")/../.."

SOURCE="AgentLens/Views/Memory/TeamMemoryCopy.swift"

check_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "verify-team-memory-copy-inventory: missing $file" >&2
    return 2
  fi

  # The declared names, minus `allCopy` itself and minus exempted declarations.
  local declared
  declared="$(awk '
    /\/\/ copy-inventory: exempt/ { exempt = 1; next }
    /^[[:space:]]*static (let|func) [A-Za-z_][A-Za-z0-9_]*/ {
      name = $0
      sub(/^[[:space:]]*static (let|func) /, "", name)
      sub(/[^A-Za-z0-9_].*$/, "", name)
      if (name != "allCopy" && exempt != 1) print name
      exempt = 0
      next
    }
    { exempt = 0 }
  ' "$file")"

  # The inventory body: everything between the `allCopy` declaration and its `]`.
  local inventory
  inventory="$(awk '
    /static let allCopy: \[String\] = \[/ { inside = 1; next }
    inside && /^[[:space:]]*\]/ { inside = 0 }
    inside { print }
  ' "$file")"

  if [[ -z "$inventory" ]]; then
    echo "verify-team-memory-copy-inventory: could not find allCopy in $file" >&2
    return 2
  fi

  local missing=0 name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! grep -Eq "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)" <<<"$inventory"; then
      echo "MISSING from TeamMemoryCopy.allCopy: ${name}" >&2
      missing=1
    fi
  done <<<"$declared"

  return "$missing"
}

if [[ "${1:-scan}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat >"$tmp/Good.swift" <<'SWIFT'
enum TeamMemoryCopy {
    static let alpha = "a"
    // copy-inventory: exempt
    static let internalOnly = "not shipped"
    static func beta(x: String) -> String { "b" }
    static let allCopy: [String] = [
        alpha,
        beta(x: "x")
    ]
}
SWIFT
  cat >"$tmp/Bad.swift" <<'SWIFT'
enum TeamMemoryCopy {
    static let alpha = "a"
    static let gamma = "escaped the inventory"
    static let allCopy: [String] = [
        alpha
    ]
}
SWIFT
  if ! check_file "$tmp/Good.swift"; then
    echo "SELF-TEST FAILED: a complete inventory was rejected" >&2
    exit 1
  fi
  if check_file "$tmp/Bad.swift" 2>/dev/null; then
    echo "SELF-TEST FAILED: a missing string was not detected" >&2
    exit 1
  fi
  echo "verify-team-memory-copy-inventory: self-test OK"
  exit 0
fi

if check_file "$SOURCE"; then
  echo "verify-team-memory-copy-inventory: OK — every TeamMemoryCopy string is in allCopy"
else
  status=$?
  if [[ "$status" == "2" ]]; then exit 2; fi
  echo "" >&2
  echo "Add the string(s) above to TeamMemoryCopy.allCopy, or mark the declaration" >&2
  echo "with '// copy-inventory: exempt' on the line above it if it is not shipped copy." >&2
  exit 1
fi
