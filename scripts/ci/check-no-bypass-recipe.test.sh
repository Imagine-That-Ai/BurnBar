#!/usr/bin/env bash
# Positive + negative controls for check-no-bypass-recipe.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

GATE="scripts/ci/check-no-bypass-recipe.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 1. Positive control: the real tree must be clean (recipe removed) -> exit 0.
if ! bash "$GATE" >"$tmpdir/tree.out" 2>&1; then
  echo "FAIL: gate reported a bypass recipe in the tree; it must be clean." >&2
  cat "$tmpdir/tree.out" >&2
  exit 1
fi

# 2. Negative controls: every banned recipe form must trip the gate (non-zero).
i=0
while IFS= read -r form; do
  [[ -n "$form" ]] || continue
  i=$((i + 1))
  bad="$tmpdir/bad-${i}.txt"
  printf '%s\n' "$form" >"$bad"
  if bash "$GATE" "$bad" >/dev/null 2>&1; then
    echo "FAIL: banned form #${i} was not caught: ${form}" >&2
    exit 1
  fi
done <<'FORMS'
gh api -X PUT repos/o/r/branches/main/protection/enforce_admins   # disable
gh api -X DELETE repos/o/r/branches/main/protection/enforce_admins
curl -X DELETE https://api.github.com/repos/o/r/branches/main/protection/enforce_admins
gh api --method DELETE repos/o/r/branches/main/protection/enforce_admins
gh api --request DELETE repos/o/r/branches/main/protection/enforce_admins
curl --request PUT https://api.github.com/repos/o/r/branches/main/protection -d '{"enforce_admins": false, "required_status_checks": null}'
the branch response shows "enforce_admins": {"enabled": false} after the toggle
FORMS

# 3. Clean controls: legit mentions must NOT trip the gate (exit 0). This
#    includes the `--field enforce_admins=false` form owned by the sibling
#    redaction scanner, which this gate must leave alone.
clean="$tmpdir/clean.txt"
cat >"$clean" <<'EOF'
enforce_admins stays on; it is never toggled to merge.
protection.enforce_admins?.enabled === true
gh api repos/o/r/branches/main/protection --field enforce_admins=false
EOF
if ! bash "$GATE" "$clean" >"$tmpdir/clean.out" 2>&1; then
  echo "FAIL: clean fixture was flagged as a bypass recipe (false positive)." >&2
  cat "$tmpdir/clean.out" >&2
  exit 1
fi

echo "PASS: check-no-bypass-recipe controls (positive + ${i} negative + clean)."
