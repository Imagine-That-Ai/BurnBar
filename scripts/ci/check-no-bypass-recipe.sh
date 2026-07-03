#!/usr/bin/env bash
#
# R-G3 — keep the branch-protection bypass recipe OUT of the repo. The diligence
# reviews (see docs/SOLO_OPERATOR_POLICY.md) found `enforce_admins` was toggled
# off around merges, and a copy-paste "disable enforce_admins -> admin-merge ->
# restore" recipe was even committed in a handoff doc. This gate fails closed if
# any tracked text file reintroduces that recipe, so the only sanctioned bypass
# stays the audit-logged break-glass path in the policy — never an API call that
# disables admin enforcement.
#
# It matches the RUNNABLE disable/toggle forms only:
#   * the REST endpoint path `.../protection/enforce_admins` (GitHub's admin-
#     enforcement endpoint — it only ever appears inside a command);
#   * a mutating verb (`-X DELETE|PUT`, `--method DELETE|PUT`, or curl's
#     long-form `--request DELETE|PUT`) next to `enforce_admins`;
#   * a disabled-state body (`enforce_admins ... "enabled": false`).
# It deliberately does NOT match the `enforce_admins=false` field-assignment form
# — that shape is owned by scripts/security/check-public-evidence-redaction.mjs,
# whose own test fixture carries the string; double-flagging it here would break
# that sibling control. Plain policy prose ("`enforce_admins` stays on") never
# matches, and this gate plus the policy doc are allowlisted so they can name the
# ban without tripping it.
#
# No network, no credentials, no repo mutation: it reads `git grep` + file
# contents only. With file arguments it scans exactly those paths (used by the
# self-test); with none it scans every tracked file that mentions the token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

SELF="scripts/ci/check-no-bypass-recipe.sh"
POLICY="docs/SOLO_OPERATOR_POLICY.md"
TEST="scripts/ci/check-no-bypass-recipe.test.sh"

# Extended regex (POSIX ERE — portable across GNU/BSD grep) for the banned
# enforce_admins-disable / admin-bypass recipe forms. grep is line-oriented, so
# `.*` is same-line proximity. Every branch anchors on the `enforce_admins`
# literal, which is why the literal prefilter below loses nothing.
PATTERN='protection/enforce_admins'
PATTERN+='|(-x|--method|--request)[[:space:]]*(delete|put).*enforce_admins'
PATTERN+='|enforce_admins.*(-x|--method|--request)[[:space:]]*(delete|put)'
PATTERN+='|enforce_admins.*enabled"?[[:space:]]*:[[:space:]]*false'
PATTERN+='|enabled"?[[:space:]]*:[[:space:]]*false.*enforce_admins'

if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "FATAL: not inside a git work tree; cannot enumerate tracked files." >&2
    exit 2
  fi
  # Literal prefilter: only tracked text files that mention the token can hold a
  # recipe. This keeps the precise scan off the ~1M-LOC tree.
  candidates=()
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    # Allowlist: this gate, its self-test, and the policy doc name the ban on
    # purpose (the self-test carries the banned forms as negative-control
    # fixtures; the arg-mode scan below still exercises them via temp files).
    [[ "$file" == "$SELF" || "$file" == "$POLICY" || "$file" == "$TEST" ]] && continue
    candidates+=("$file")
  done < <(git grep -lIi --fixed-strings -e 'enforce_admins' -- . || true)
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "PASS: no tracked file references the enforce_admins bypass recipe."
  exit 0
fi

set +e
hits="$(grep -inE "$PATTERN" -- "${candidates[@]}")"
status=$?
set -e

if [[ $status -eq 0 ]]; then
  echo "FAIL: committed branch-protection bypass recipe detected:" >&2
  echo "$hits" >&2
  echo >&2
  echo "Remove the runnable recipe. The only sanctioned bypass is the audit-logged" >&2
  echo "break-glass path in ${POLICY} — it never disables enforce_admins." >&2
  exit 1
elif [[ $status -eq 1 ]]; then
  echo "PASS: no tracked file contains the enforce_admins bypass recipe (${#candidates[@]} scanned)."
  exit 0
else
  echo "FATAL: grep failed (status ${status}) while scanning for the bypass recipe." >&2
  exit 2
fi
