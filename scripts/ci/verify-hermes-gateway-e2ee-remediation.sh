#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FOCUSED_FUNCTION_TESTS=(
  "src/__tests__/hermesGateway.test.ts"
  "src/__tests__/hermesGatewaySealedEvent.test.ts"
  "src/__tests__/hermesGatewayKeyImmutability.test.ts"
  "src/__tests__/hermesGatewayAttachmentInit.test.ts"
  "src/__tests__/dataExport.test.ts"
  "src/__tests__/privacyBackfill.test.ts"
)

HERMES_GATEWAY_PYTESTS=(
  "tests/gateway/test_relay_e2ee.py"
  "tests/gateway/test_relay_e2ee_v2.py"
  "tests/gateway/test_relay_e2ee_v3.py"
  "tests/gateway/test_hermes_ratchet.py"
  "tests/gateway/test_burnbar_plugin.py"
  "tests/gateway/test_burnbar_plugin_v3.py"
  "tests/gateway/test_burnbar_hpke_v3_vectors.py"
)

HERMES_AGENT_CHECKOUT="${HERMES_AGENT_CHECKOUT:-$HOME/.hermes/hermes-agent}"
HERMES_ADAPTER="${HERMES_AGENT_CHECKOUT}/plugins/platforms/burnbar/adapter.py"

run_step() {
  local label="$1"
  shift
  echo "==> ${label}"
  "$@"
}

quarantined_external_hermes_gate() {
  local reason="$1"
  local owner="${HERMES_GATEWAY_EXTERNAL_PYTEST_QUARANTINE_OWNER:-platform-security}"
  local until="${HERMES_GATEWAY_EXTERNAL_PYTEST_QUARANTINE_UNTIL:-2026-06-14}"
  if [[ "${HERMES_GATEWAY_EXTERNAL_PYTEST_REQUIRED:-0}" == "1" ]]; then
    echo "Hermes external pytest gate is required but unavailable: ${reason}" >&2
    exit 1
  fi
  echo "::warning::Hermes external pytest gate quarantined until ${until} (owner: ${owner}): ${reason}"
}

assert_gateway_vector_mirrors() {
  local v2_core="$ROOT/OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesGatewayWireVector.json"
  local v2_android="$ROOT/android/app/src/test/resources/hermes-relay/HermesGatewayWireVector.json"
  local v2_hermes="$HERMES_AGENT_CHECKOUT/tests/gateway/fixtures/HermesGatewayWireVector.json"
  local v3_core="$ROOT/OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/BurnBarHpkeV3Vector.json"
  local v3_android="$ROOT/android/app/src/test/resources/hermes-relay/HermesGatewayWireVectorV3.json"
  local v3_hermes="$HERMES_AGENT_CHECKOUT/tests/gateway/fixtures/BurnBarHpkeV3Vector.json"

  for local_fixture in "$v2_core" "$v2_android" "$v3_core" "$v3_android"; do
    if [[ ! -f "$local_fixture" ]]; then
      echo "Missing local gateway vector fixture: $local_fixture" >&2
      exit 1
    fi
  done

  if [[ ! -f "$v2_hermes" || ! -f "$v3_hermes" ]]; then
    quarantined_external_hermes_gate "missing Hermes vector fixture(s) under ${HERMES_AGENT_CHECKOUT}/tests/gateway/fixtures"
    return 0
  fi

  diff -q "$v2_core" "$v2_android"
  diff -q "$v2_core" "$v2_hermes"
  diff -q "$v3_core" "$v3_android"
  diff -q "$v3_core" "$v3_hermes"
}

run_step "Privacy plaintext scanner" node scripts/privacy/scan-chat-cloud-plaintext.mjs
run_step "Functions Hermes Gateway contract test" npm --prefix functions run test:hermes-gateway
run_step "Focused Functions Hermes/privacy vitest suite" \
  npm --prefix functions run test:unit -- "${FOCUSED_FUNCTION_TESTS[@]}"
run_step "Firestore rules emulator suite" npm --prefix functions run test:firestore-rules
run_step "Schema sync drift, hand mirror, and budget gate" ./tools/schema-sync/check-drift.sh
run_step "Gateway vector mirror diff" assert_gateway_vector_mirrors

if [[ -f "$HERMES_ADAPTER" ]]; then
  run_step "BurnBar adapter mirror diff" \
    diff -q "$ROOT/tools/hermes-platform-burnbar/adapter.py" "$HERMES_ADAPTER"
  if [[ "${HERMES_GATEWAY_OVERLAY_ADAPTER:-0}" == "1" ]]; then
    run_step "Overlay BurnBar adapter into Hermes checkout for external tests" \
      cp "$ROOT/tools/hermes-platform-burnbar/adapter.py" "$HERMES_ADAPTER"
  fi
else
  quarantined_external_hermes_gate "missing adapter mirror at ${HERMES_ADAPTER}"
fi

if [[ -d "$HERMES_AGENT_CHECKOUT/tests/gateway" ]]; then
  HERMES_PYTHON="${HERMES_PYTHON:-$HERMES_AGENT_CHECKOUT/venv/bin/python}"
  if [[ ! -x "$HERMES_PYTHON" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      HERMES_PYTHON="$(command -v python3)"
    else
      quarantined_external_hermes_gate "no Python interpreter available for ${HERMES_AGENT_CHECKOUT}"
      exit 0
    fi
  fi
  run_step "BurnBar adapter local gateway smoke" \
    "$HERMES_PYTHON" "$ROOT/tools/hermes-platform-burnbar/smoke_local.py" smoke --hermes-repo "$HERMES_AGENT_CHECKOUT"
  (
    cd "$HERMES_AGENT_CHECKOUT"
    run_step "External Hermes gateway pytest" \
      "$HERMES_PYTHON" -m pytest "${HERMES_GATEWAY_PYTESTS[@]}" -q
  )
else
  quarantined_external_hermes_gate "missing Hermes tests under ${HERMES_AGENT_CHECKOUT}/tests/gateway"
fi

echo "Hermes Gateway E2EE remediation proof passed."
