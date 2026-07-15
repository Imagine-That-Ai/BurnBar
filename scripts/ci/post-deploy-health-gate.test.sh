#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/firebase" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"result":[]}'
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$url" == */healthLive ]]; then
  cp "$HEALTH_TEST_LIVE" "$output"
else
  cp "$HEALTH_TEST_READY" "$output"
fi
printf '200'
EOF
chmod +x "$TMP/bin/firebase" "$TMP/bin/curl"

commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
repository="https://github.com/Imagine-That-Ai/BurnBar"
core_version="0.3.0"
core_source="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
domain_core="{\"profile\":\"public-production\",\"candidateIdentity\":{\"candidateCommit\":\"$commit\",\"coreVersion\":\"$core_version\",\"abiVersion\":3,\"sourceSha256\":\"$core_source\"},\"pricingMode\":\"rust\"}"
cat > "$TMP/live.json" <<EOF
{"status":"alive","license":"AGPL-3.0-only","source":{"repository":"$repository","commit":"$commit","correspondingSource":"https://burnbar.ai/legal/source"},"domainCore":$domain_core}
EOF
cat > "$TMP/ready.json" <<EOF
{"status":"ready","version":"v1.2.3","license":"AGPL-3.0-only","source":{"repository":"$repository","commit":"$commit","correspondingSource":"https://burnbar.ai/legal/source"},"domainCore":$domain_core,"sentry":{"enabled":true,"environment":"production"}}
EOF

run_gate() {
  PATH="$TMP/bin:$PATH" \
  HEALTH_TEST_LIVE="$TMP/live.json" \
  HEALTH_TEST_READY="$TMP/ready.json" \
  FUNCTIONS_HEALTH_LIVE_URL="https://example.test/healthLive" \
  FUNCTIONS_HEALTH_READY_URL="https://example.test/healthReady" \
  HEALTH_GATE_RETRIES=1 \
  HEALTH_GATE_SLEEP_SEC=0 \
  HEALTH_GATE_REQUIRE_SENTRY=1 \
  HEALTH_GATE_EXPECTED_SOURCE_COMMIT="$1" \
  HEALTH_GATE_EXPECTED_VERSION=v1.2.3 \
  HEALTH_GATE_EXPECTED_DOMAIN_CORE_PROFILE=public-production \
  HEALTH_GATE_EXPECTED_DOMAIN_CORE_CANDIDATE_COMMIT="$commit" \
  HEALTH_GATE_EXPECTED_DOMAIN_CORE_VERSION="$core_version" \
  HEALTH_GATE_EXPECTED_DOMAIN_CORE_ABI_VERSION=3 \
  HEALTH_GATE_EXPECTED_DOMAIN_CORE_SOURCE_SHA256="$core_source" \
  HEALTH_GATE_EXPECTED_DOMAIN_CORE_PRICING_MODE="$2" \
  DEPLOY_TAG=v1.2.3 \
  DEPLOY_HEALTH_JSON="$3" \
    bash "$ROOT/scripts/ci/post-deploy-health-gate.sh"
}

run_gate "$commit" rust "$TMP/deploy-health.json" >/dev/null
test -s "$TMP/deploy-health.json"
jq -e --arg commit "$commit" '
  .tag == "v1.2.3"
  and .healthLive.source.commit == $commit
  and .healthReady.source.commit == $commit
  and .healthReady.version == "v1.2.3"
  and .healthReady.domainCore.pricingMode == "rust"
' "$TMP/deploy-health.json" >/dev/null

rm -f "$TMP/stale-health.json"
if run_gate "cccccccccccccccccccccccccccccccccccccccc" rust "$TMP/stale-health.json" >/dev/null 2>&1; then
  echo "expected stale deployed commit to fail" >&2
  exit 1
fi
test ! -e "$TMP/stale-health.json"

rm -f "$TMP/wrong-profile-health.json"
if run_gate "$commit" legacy "$TMP/wrong-profile-health.json" >/dev/null 2>&1; then
  echo "expected mismatched domain-core profile to fail" >&2
  exit 1
fi
test ! -e "$TMP/wrong-profile-health.json"

echo "post-deploy health identity tests passed"
