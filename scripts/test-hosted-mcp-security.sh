#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENDPOINT="${OPENBURNBAR_MCP_ENDPOINT:-http://127.0.0.1:8080/mcp}"

# ---------------------------------------------------------------------------
# LOCAL deterministic adversarial proofs — secret-free, every PR.
#
# Boots the REAL hosted MCP server in-process against a seeded in-memory
# Firestore + storage and proves cross-tenant isolation, revoked-client
# rejection, non-entitled gating, the rate-limit cap, and at-rest-sealed
# payloads through the actual route + auth + entitlement + cursor + resource
# code paths. Unlike the Pensieve cases below (which gate on PENSIEVE_* and skip
# in token-less CI), this runs unconditionally and needs no live endpoint or
# secrets. Requires services/hosted-mcp/lib (the CI job builds it first).
node scripts/prove-hosted-mcp-live.mjs --local
echo

missing_auth_status="$(curl -sS -o /tmp/openburnbar-mcp-missing-auth.json -w '%{http_code}' \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  "$ENDPOINT")"
test "$missing_auth_status" = "401"

bad_origin_status="$(curl -sS -o /tmp/openburnbar-mcp-bad-origin.json -w '%{http_code}' \
  -H 'origin: https://attacker.invalid' \
  -H 'authorization: Bearer invalid.invalid' \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "$ENDPOINT")"
test "$bad_origin_status" = "403"

large_status="$(python3 - <<'PY' | curl -sS -o /tmp/openburnbar-mcp-large.json -w '%{http_code}' -H 'content-type: application/json' --data-binary @- "$ENDPOINT"
import json
print(json.dumps({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"burnbar_search_conversations","arguments":{"query":"x"*200000}}}))
PY
)"
test "$large_status" = "401" -o "$large_status" = "413"

echo "hosted MCP security smoke passed (3 base cases)"

# ---------------------------------------------------------------------------
# Pensieve E2EE knowledge-memory adversarial cases.
#
# These run against a LIVE endpoint with real bearer tokens + seeded data. Each
# case skips (loudly, never silently) when its required env is absent so the
# base smoke test still passes in token-less CI. To run the full suite, export:
#   PENSIEVE_BEARER_A     bearer for tenant A (Cloud Pro, knowledge:read)
#   PENSIEVE_UID_B        a different tenant's uid (for cross-tenant probes)
#   PENSIEVE_VECTORID_B   a vectorId known to belong to tenant B
#   PENSIEVE_FREE_BEARER  bearer for a NON-entitled (free) user
#   PENSIEVE_REVOKED_BEARER  a bearer whose MCP client was revoked
#   PENSIEVE_FUNCTIONS_URL   base URL of the callable functions (for cap/freq cases)
#   PENSIEVE_DB_INSPECT=1 + gcloud/firestore access (for at-rest + verbatim cases)
# A 384-float zero vector stands in for an on-device-cloaked query.
# ---------------------------------------------------------------------------

PASS=0
SKIP=0
ZERO_VEC="$(python3 -c 'import json;print(json.dumps([0.0]*384))')"

call_knowledge() { # $1=bearer  $2=arguments-json -> prints http_code, body in /tmp/pk.json
  python3 - "$2" <<'PY' | curl -sS -o /tmp/pk.json -w '%{http_code}' \
    -H "authorization: Bearer $1" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' --data-binary @- "$ENDPOINT"
import json,sys
print(json.dumps({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"burnbar_search_knowledge","arguments":json.loads(sys.argv[1])}}))
PY
}

# Case 1 — Cross-tenant: bearer A + a forged namespace/uid arg must NOT return B's data.
if [ -n "${PENSIEVE_BEARER_A:-}" ] && [ -n "${PENSIEVE_UID_B:-}" ] && [ -n "${PENSIEVE_VECTORID_B:-}" ]; then
  args="$(ZV="$ZERO_VEC" UB="$PENSIEVE_UID_B" python3 -c "import json,os;print(json.dumps({'query':'anything','queryVector':json.loads(os.environ['ZV']),'namespace':os.environ['UB'],'uid':os.environ['UB'],'user_id':os.environ['UB']}))")"
  call_knowledge "$PENSIEVE_BEARER_A" "$args" >/dev/null
  if grep -q "$PENSIEVE_VECTORID_B" /tmp/pk.json; then
    echo "FAIL case1: forged namespace leaked tenant B data"; exit 1
  fi
  echo "PASS case1: cross-tenant forged namespace ignored (server uses claims.sub only)"; PASS=$((PASS+1))
else echo "SKIP case1 cross-tenant (set PENSIEVE_BEARER_A/UID_B/VECTORID_B)"; SKIP=$((SKIP+1)); fi

# Case 6 — Revoked client: an old token on burnbar_search_knowledge must 403.
if [ -n "${PENSIEVE_REVOKED_BEARER:-}" ]; then
  code="$(call_knowledge "$PENSIEVE_REVOKED_BEARER" "{\"queryVector\":$ZERO_VEC}")"
  test "$code" = "403"; echo "PASS case6: revoked client -> 403"; PASS=$((PASS+1))
else echo "SKIP case6 revoked-client (set PENSIEVE_REVOKED_BEARER)"; SKIP=$((SKIP+1)); fi

# Case 8 — Non-entitled gate: free user calling configureKnowledgeSource must 403/permission-denied.
if [ -n "${PENSIEVE_FREE_BEARER:-}" ] && [ -n "${PENSIEVE_FUNCTIONS_URL:-}" ]; then
  code="$(curl -sS -o /tmp/pk.json -w '%{http_code}' -H "authorization: Bearer $PENSIEVE_FREE_BEARER" \
    -H 'content-type: application/json' --data '{"data":{"sourceKind":"notes"}}' \
    "$PENSIEVE_FUNCTIONS_URL/configureKnowledgeSource")"
  if [ "$code" = "403" ] || grep -q "permission-denied" /tmp/pk.json; then
    echo "PASS case8: non-entitled configureKnowledgeSource denied"; PASS=$((PASS+1))
  else echo "FAIL case8: free user not denied (got $code)"; exit 1; fi
else echo "SKIP case8 non-entitled (set PENSIEVE_FREE_BEARER + PENSIEVE_FUNCTIONS_URL)"; SKIP=$((SKIP+1)); fi

# Case 4 — Chunk-cap: pushing past the tier cap must fail-precondition (not silently overflow).
if [ -n "${PENSIEVE_BEARER_A:-}" ] && [ -n "${PENSIEVE_FUNCTIONS_URL:-}" ] && [ "${PENSIEVE_RUN_CAP:-}" = "1" ]; then
  echo "RUN case4: chunk-cap — see prove-hosted-mcp-live.mjs (commits past cap, expects failed-precondition)"
  node scripts/prove-hosted-mcp-live.mjs --case chunk-cap; PASS=$((PASS+1))
else echo "SKIP case4 chunk-cap (set PENSIEVE_RUN_CAP=1 + functions url; heavy)"; SKIP=$((SKIP+1)); fi

# Case 5 — Sync-frequency: hammering manual sync past the daily bucket must 429.
if [ -n "${PENSIEVE_BEARER_A:-}" ] && [ "${PENSIEVE_RUN_FREQ:-}" = "1" ]; then
  echo "RUN case5: sync-frequency — see prove-hosted-mcp-live.mjs (hammers Sync now, expects 429)"
  node scripts/prove-hosted-mcp-live.mjs --case sync-frequency; PASS=$((PASS+1))
else echo "SKIP case5 sync-frequency (set PENSIEVE_RUN_FREQ=1; heavy)"; SKIP=$((SKIP+1)); fi

# Case 2 + 7 — At-rest plaintext + verbatim integrity require Firestore inspection.
if [ "${PENSIEVE_DB_INSPECT:-}" = "1" ]; then
  echo "RUN case2/case7: at-rest + verbatim — see prove-hosted-mcp-live.mjs (dumps a doc; asserts only ciphertext+floats; round-trips a chunk byte-identically)"
  node scripts/prove-hosted-mcp-live.mjs --case at-rest --case verbatim; PASS=$((PASS+2))
else echo "SKIP case2 at-rest + case7 verbatim (set PENSIEVE_DB_INSPECT=1 + firestore access)"; SKIP=$((SKIP+1)); fi

# Case 3 — Query-text confidentiality is a CONTRACT verified at the shim:
#   the request body carries only queryVector (numbers), never the raw query.
# Covered by the shim unit test "query-text never leaves the device"
# (tools/openburnbar-mcp-remote: knowledge.test.ts). Asserted here as a reminder.
echo "NOTE case3: query-text confidentiality is enforced by the shim (prepareKnowledgeRequest strips raw query); see knowledge.test.ts"

echo "Pensieve adversarial cases: ${PASS} ran, ${SKIP} skipped (set the documented env to run skipped cases)"
