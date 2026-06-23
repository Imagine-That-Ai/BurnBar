#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/cutover-n0-hosted-relay.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "cutover-n0-hosted-relay test: jq is required" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d -t cutover-n0-hosted-relay-test-XXXXXX)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "${FAKE_BIN}"
ARGV_LOG="${TMP_DIR}/curl-argv.log"
STDIN_LOG="${TMP_DIR}/curl-stdin.log"
touch "${ARGV_LOG}" "${STDIN_LOG}"

cat > "${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${CUTOVER_TEST_ARGV_LOG}"
cat >> "${CUTOVER_TEST_STDIN_LOG}"

headers_path=""
output_path=""
while [[ $# -gt 0 ]]; do
  case "${1}" in
    --dump-header)
      headers_path="${2}"
      shift 2
      ;;
    --output)
      output_path="${2}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "${headers_path}" ]]; then
  printf 'HTTP/2 200\r\netag: test-etag\r\n\r\n' > "${headers_path}"
fi
if [[ -n "${output_path}" ]]; then
  printf '{"parameters":{}}\n' > "${output_path}"
fi
EOF
chmod +x "${FAKE_BIN}/curl"

fail() {
  echo "cutover-n0-hosted-relay test: $*" >&2
  exit 1
}

SECRET_TOKEN="ya29.test-token-with-slash/and.plus"
PROJECT_ID="burnbar-test" \
FIREBASE_TOKEN="${SECRET_TOKEN}" \
CUTOVER_TEST_ARGV_LOG="${ARGV_LOG}" \
CUTOVER_TEST_STDIN_LOG="${STDIN_LOG}" \
PATH="${FAKE_BIN}:${PATH}" \
  bash "${SCRIPT}" publish "https://relay.example.test" --dry-run >/dev/null

if grep -Fq "${SECRET_TOKEN}" "${ARGV_LOG}"; then
  fail "bearer token leaked into curl argv"
fi
if ! grep -Fq "Authorization: Bearer ${SECRET_TOKEN}" "${STDIN_LOG}"; then
  fail "bearer token was not passed through curl config stdin"
fi

: > "${ARGV_LOG}"
: > "${STDIN_LOG}"
if PROJECT_ID="burnbar-test" \
  FIREBASE_TOKEN='bad"token' \
  CUTOVER_TEST_ARGV_LOG="${ARGV_LOG}" \
  CUTOVER_TEST_STDIN_LOG="${STDIN_LOG}" \
  PATH="${FAKE_BIN}:${PATH}" \
  bash "${SCRIPT}" publish "https://relay.example.test" --dry-run >/dev/null 2>"${TMP_DIR}/invalid-token.err"; then
  fail "token containing config metacharacters was accepted"
fi
if [[ -s "${ARGV_LOG}" ]]; then
  fail "curl was invoked after invalid token rejection"
fi

echo "cutover-n0-hosted-relay test: all green"
