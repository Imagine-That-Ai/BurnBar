#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="${ROOT}/scripts/ci/require-product-lane-freshness.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-product-freshness.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat >"${TMP_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
conclusion="${GH_MOCK_CONCLUSION:-failure}"
if [[ "${conclusion}" == "success" ]]; then
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
  created_at="2000-01-01T00:00:00Z"
fi
printf '[{"conclusion":"%s","createdAt":"%s","event":"schedule","status":"completed","databaseId":1,"url":"https://example.invalid/run/1"}]\n' \
  "${conclusion}" "${created_at}"
EOF
chmod +x "${TMP_DIR}/gh"

run_subject() {
  env \
    PATH="${TMP_DIR}:${PATH}" \
    GITHUB_REPOSITORY="Imagine-That-Ai/BurnBar" \
    PRODUCT_LANE_MAX_AGE_SECONDS=86400 \
    "$@" \
    bash "${SUBJECT}"
}

observe_output="$(
  run_subject \
    GITHUB_EVENT_NAME=merge_group \
    PRODUCT_LANE_CIRCUIT_BREAKER_MODE=observe
)"
grep -q 'mode=observe, so this event remains non-blocking' <<<"${observe_output}"

pull_request_output="$(
  run_subject \
    GITHUB_EVENT_NAME=pull_request \
    PRODUCT_LANE_CIRCUIT_BREAKER_MODE=enforce
)"
grep -q 'mode=enforce will block merge_group' <<<"${pull_request_output}"

if run_subject \
  GITHUB_EVENT_NAME=merge_group \
  PRODUCT_LANE_CIRCUIT_BREAKER_MODE=enforce \
  >"${TMP_DIR}/enforce.out" 2>&1; then
  echo "FAIL: enforce mode accepted stale red product lanes on merge_group" >&2
  exit 1
fi
grep -q 'mode=enforce' "${TMP_DIR}/enforce.out"

success_output="$(
  run_subject \
    GITHUB_EVENT_NAME=merge_group \
    PRODUCT_LANE_CIRCUIT_BREAKER_MODE=enforce \
    GH_MOCK_CONCLUSION=success
)"
grep -q 'have a success inside the window' <<<"${success_output}"

echo "PASS: product-lane freshness observe/enforce policy"
