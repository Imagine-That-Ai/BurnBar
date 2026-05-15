#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENDPOINT="${OPENBURNBAR_MCP_ENDPOINT:-http://127.0.0.1:8080/mcp}"

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

echo "hosted MCP security smoke passed"
