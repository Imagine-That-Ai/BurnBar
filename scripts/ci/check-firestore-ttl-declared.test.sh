#!/usr/bin/env bash
# Controls for check-firestore-ttl-declared.sh: one positive case (the real
# manifest passes) and three fail-closed negatives (unregistered index TTL,
# a lying indexDeclared claim, and invalid JSON). The check resolves its inputs
# relative to its own location, so each case runs inside a throwaway repo-root
# skeleton built from the real files — the real ops/ + firestore.indexes.json
# are never mutated.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/ci/check-firestore-ttl-declared.sh"
REAL_MANIFEST="$REPO/ops/firestore-ttl-policies.json"
REAL_INDEXES="$REPO/firestore.indexes.json"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT
mkdir -p "$tmproot/scripts/ci" "$tmproot/ops"
cp "$CHECK" "$tmproot/scripts/ci/check-firestore-ttl-declared.sh"

MANIFEST="$tmproot/ops/firestore-ttl-policies.json"
INDEXES="$tmproot/firestore.indexes.json"
SANDBOX_CHECK="$tmproot/scripts/ci/check-firestore-ttl-declared.sh"

reset_fixtures() {
  cp "$REAL_MANIFEST" "$MANIFEST"
  cp "$REAL_INDEXES" "$INDEXES"
}

out="$tmproot/out.txt"

# Case 0 — the committed manifest passes.
reset_fixtures
if ! bash "$SANDBOX_CHECK" >"$out" 2>&1; then
  echo "FAIL: real manifest did not pass" >&2
  cat "$out" >&2
  exit 1
fi
grep -q "^PASS:" "$out" || { echo "FAIL: expected PASS line" >&2; cat "$out" >&2; exit 1; }

# Case 1 — a new ttl:true override with no policy must fail closed (coverage).
reset_fixtures
python3 - "$INDEXES" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("fieldOverrides", []).append(
    {"collectionGroup": "brand_new_events", "fieldPath": "expireAt", "ttl": True, "indexes": []}
)
json.dump(d, open(p, "w"), indent=2)
PY
if bash "$SANDBOX_CHECK" >"$out" 2>&1; then
  echo "FAIL: unregistered index TTL unexpectedly passed" >&2
  cat "$out" >&2
  exit 1
fi
grep -q "no policy in" "$out" || { echo "FAIL: coverage message missing" >&2; cat "$out" >&2; exit 1; }

# Case 2 — a policy claiming indexDeclared it does not have must fail (honesty).
reset_fixtures
python3 - "$MANIFEST" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for pol in d["policies"]:
    if pol["collectionGroup"] == "usage_counter_days":
        pol["indexDeclared"] = True
json.dump(d, open(p, "w"), indent=2)
PY
if bash "$SANDBOX_CHECK" >"$out" 2>&1; then
  echo "FAIL: lying indexDeclared unexpectedly passed" >&2
  cat "$out" >&2
  exit 1
fi
grep -q "disagrees with firestore.indexes.json" "$out" || { echo "FAIL: honesty message missing" >&2; cat "$out" >&2; exit 1; }

# Case 3 — invalid JSON manifest must fail closed (parse).
reset_fixtures
printf '{ "policies": [ { "collectionGroup": ' >"$MANIFEST"
if bash "$SANDBOX_CHECK" >"$out" 2>&1; then
  echo "FAIL: invalid JSON unexpectedly passed" >&2
  cat "$out" >&2
  exit 1
fi
grep -q "not valid JSON" "$out" || { echo "FAIL: JSON-parse message missing" >&2; cat "$out" >&2; exit 1; }

echo "PASS: check-firestore-ttl-declared controls (1 positive, 3 fail-closed negatives)"
