#!/usr/bin/env bash
#
# check-firestore-ttl-declared.sh — fail-closed retention-policy registration gate.
#
# Unbounded / time-series Firestore collections MUST have a declared retention
# policy so storage cost does not grow forever (cost model:
# docs/ops/UNIT_ECONOMICS_COST_MODEL.md). This is the STATIC half of TTL
# governance and needs no cloud credentials:
#
#   ops/firestore-ttl-policies.json   — declared retention intent (source of truth)
#   firestore.indexes.json            — machine-readable `ttl:true` field overrides
#
# This gate asserts the two agree and fails closed when they do not:
#   1. ops/firestore-ttl-policies.json is valid JSON and every policy is well-formed.
#   2. Every `ttl:true` field override in firestore.indexes.json is registered as a
#      policy here — so a NEW time-series collection cannot ship a TTL without an
#      operator-readable retention + cost note.
#   3. Each policy's `indexDeclared` claim matches firestore.indexes.json in BOTH
#      directions (no policy may claim a TTL the index does not carry, and no
#      index TTL may hide behind a "pending" policy).
#
# Live GCP TTL state (ACTIVE/CREATING) is verified separately, with gcloud creds,
# by scripts/ci/verify-firestore-ttl-state.mjs and scripts/security/verify-deployed-ttl.sh.
#
# Usage: scripts/ci/check-firestore-ttl-declared.sh
# Exit:  0 = manifest valid and consistent with firestore.indexes.json; 1 = drift.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${ROOT_DIR}/ops/firestore-ttl-policies.json"
INDEXES="${ROOT_DIR}/firestore.indexes.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse the TTL manifest."
[ -f "$MANIFEST" ] || fail "missing TTL manifest: $MANIFEST"
[ -f "$INDEXES" ] || fail "missing firestore.indexes.json: $INDEXES"

python3 - "$MANIFEST" "$INDEXES" <<'PY'
import json
import sys

manifest_path, indexes_path = sys.argv[1], sys.argv[2]

ALLOWED_MECHANISMS = {"firestore-ttl-field", "aggregate-compaction", "recursive-delete"}
ALLOWED_STATUS = {"active", "pending-operator-enablement"}
REQUIRED_STR_FIELDS = ("collectionGroup", "path", "category", "retention", "rationale", "operatorAction")

errors = []


def load(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"FAIL: {label} is not valid JSON: {exc}", file=sys.stderr)
        sys.exit(1)


manifest = load(manifest_path, "ops/firestore-ttl-policies.json")
indexes = load(indexes_path, "firestore.indexes.json")

# Machine-readable TTL declarations already in firestore.indexes.json.
index_ttls = set()
for override in indexes.get("fieldOverrides", []) or []:
    if isinstance(override, dict) and override.get("ttl") is True:
        index_ttls.add((override.get("collectionGroup"), override.get("fieldPath")))

if not isinstance(manifest.get("policies"), list) or not manifest["policies"]:
    print("FAIL: ops/firestore-ttl-policies.json must contain a non-empty 'policies' array.", file=sys.stderr)
    sys.exit(1)

seen_keys = set()
ttl_field_index = {}  # (collectionGroup, ttlField) -> policy, for coverage lookup

for i, policy in enumerate(manifest["policies"]):
    tag = f"policies[{i}]"
    if not isinstance(policy, dict):
        errors.append(f"{tag}: policy must be an object.")
        continue
    cg = policy.get("collectionGroup")
    tag = f"policy '{cg or tag}'"

    for field in REQUIRED_STR_FIELDS:
        value = policy.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{tag}: '{field}' must be a non-empty string.")

    mechanism = policy.get("mechanism")
    if mechanism not in ALLOWED_MECHANISMS:
        errors.append(f"{tag}: 'mechanism' must be one of {sorted(ALLOWED_MECHANISMS)} (got {mechanism!r}).")

    status = policy.get("status")
    if status not in ALLOWED_STATUS:
        errors.append(f"{tag}: 'status' must be one of {sorted(ALLOWED_STATUS)} (got {status!r}).")

    index_declared = policy.get("indexDeclared")
    if not isinstance(index_declared, bool):
        errors.append(f"{tag}: 'indexDeclared' must be a boolean.")

    ttl_field = policy.get("ttlField")
    if ttl_field is not None and (not isinstance(ttl_field, str) or not ttl_field.strip()):
        errors.append(f"{tag}: 'ttlField' must be null or a non-empty string.")

    retention_seconds = policy.get("retentionSeconds")
    if retention_seconds is not None and not (isinstance(retention_seconds, int) and retention_seconds > 0):
        errors.append(f"{tag}: 'retentionSeconds' must be null or a positive integer.")

    # Duplicate guard: no two policies may own the same collection-group + field.
    key = (cg, ttl_field)
    if key in seen_keys:
        errors.append(f"{tag}: duplicate policy for collectionGroup={cg!r} ttlField={ttl_field!r}.")
    seen_keys.add(key)

    # Mechanism-specific consistency with firestore.indexes.json (two-way).
    if mechanism == "firestore-ttl-field":
        if not isinstance(ttl_field, str) or not ttl_field.strip():
            errors.append(f"{tag}: firestore-ttl-field policies require a 'ttlField'.")
        else:
            ttl_field_index[(cg, ttl_field)] = policy
            declared_in_index = (cg, ttl_field) in index_ttls
            if isinstance(index_declared, bool) and index_declared != declared_in_index:
                errors.append(
                    f"{tag}: indexDeclared={index_declared} disagrees with firestore.indexes.json "
                    f"(ttl:true for {cg}.{ttl_field} is {'present' if declared_in_index else 'absent'})."
                )
            if status == "active" and index_declared is not True:
                errors.append(f"{tag}: status 'active' requires indexDeclared=true.")
            if status == "pending-operator-enablement" and index_declared is not False:
                errors.append(f"{tag}: status 'pending-operator-enablement' requires indexDeclared=false.")
    else:
        if index_declared is not False:
            errors.append(f"{tag}: mechanism '{mechanism}' cannot set indexDeclared=true (no GCP field TTL).")
        if status != "pending-operator-enablement":
            errors.append(f"{tag}: mechanism '{mechanism}' must be status 'pending-operator-enablement'.")
        if ttl_field is not None:
            errors.append(f"{tag}: mechanism '{mechanism}' must set ttlField=null (field TTL does not apply).")

# Fail-closed coverage: every ttl:true override in firestore.indexes.json must be
# registered here. A new time-series collection cannot get a TTL silently.
for cg, field in sorted(x for x in index_ttls if x[0] is not None):
    if (cg, field) not in ttl_field_index:
        errors.append(
            f"firestore.indexes.json declares ttl:true on {cg}.{field} but no policy in "
            f"ops/firestore-ttl-policies.json covers it — register it (retention + rationale + cost note)."
        )

if errors:
    print(f"FAIL: {len(errors)} Firestore TTL manifest problem(s):", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

total = len(manifest["policies"])
active = sum(1 for p in manifest["policies"] if p.get("status") == "active")
pending = total - active
print(
    f"PASS: {total} Firestore retention policies declared "
    f"({active} active/index-declared, {pending} pending operator enablement); "
    f"all {len(index_ttls)} ttl:true index overrides are registered."
)
PY
