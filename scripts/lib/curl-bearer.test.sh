#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-curl-bearer-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "${FAKE_BIN}"

ARGV_LOG="${TMP_DIR}/argv.log"
STDIN_LOG="${TMP_DIR}/stdin.log"
CONFIG_LOG="${TMP_DIR}/config.log"

cat >"${FAKE_BIN}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CURL_BEARER_TEST_ARGV_LOG}"
config=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      config="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -n "${config}" ]]; then
  cat "${config}" >>"${CURL_BEARER_TEST_CONFIG_LOG}"
fi
cat >"${CURL_BEARER_TEST_STDIN_LOG}"
printf '{"ok":true}\n'
SH
chmod +x "${FAKE_BIN}/curl"

# shellcheck source=scripts/lib/curl-bearer.sh
source scripts/lib/curl-bearer.sh

secret="ya29.test-token-with/slash.and-plus"

CURL_BEARER_TEST_ARGV_LOG="${ARGV_LOG}" \
CURL_BEARER_TEST_STDIN_LOG="${STDIN_LOG}" \
CURL_BEARER_TEST_CONFIG_LOG="${CONFIG_LOG}" \
PATH="${FAKE_BIN}:${PATH}" \
  obb_curl_with_bearer "${secret}" -fsS --data-binary @- "https://example.test/api" <<'JSON' >/dev/null
{"hello":"world"}
JSON

if grep -Fq "${secret}" "${ARGV_LOG}"; then
  echo "FAIL: bearer token leaked into curl argv" >&2
  exit 1
fi
if ! grep -Fq "Authorization: Bearer ${secret}" "${CONFIG_LOG}"; then
  echo "FAIL: bearer token was not written to the private curl config" >&2
  exit 1
fi
if ! grep -Fq '{"hello":"world"}' "${STDIN_LOG}"; then
  echo "FAIL: request stdin was not preserved for --data-binary @-" >&2
  exit 1
fi

: >"${ARGV_LOG}"
: >"${STDIN_LOG}"
: >"${CONFIG_LOG}"

CURL_BEARER_TEST_ARGV_LOG="${ARGV_LOG}" \
CURL_BEARER_TEST_STDIN_LOG="${STDIN_LOG}" \
CURL_BEARER_TEST_CONFIG_LOG="${CONFIG_LOG}" \
PATH="${FAKE_BIN}:${PATH}" \
  obb_curl_with_bearer_user_project "${secret}" "burnbar-test" -fsS "https://example.test/appcheck" >/dev/null

if grep -Fq "${secret}" "${ARGV_LOG}"; then
  echo "FAIL: bearer token leaked into curl argv for user-project helper" >&2
  exit 1
fi
if ! grep -Fq "x-goog-user-project: burnbar-test" "${CONFIG_LOG}"; then
  echo "FAIL: x-goog-user-project header was not written to curl config" >&2
  exit 1
fi

: >"${ARGV_LOG}"
if CURL_BEARER_TEST_ARGV_LOG="${ARGV_LOG}" \
  CURL_BEARER_TEST_STDIN_LOG="${STDIN_LOG}" \
  CURL_BEARER_TEST_CONFIG_LOG="${CONFIG_LOG}" \
  PATH="${FAKE_BIN}:${PATH}" \
  obb_curl_with_bearer 'bad"token' -fsS "https://example.test" >/dev/null 2>"${TMP_DIR}/bad-token.err"; then
  echo "FAIL: invalid curl config token was accepted" >&2
  exit 1
fi
if [[ -s "${ARGV_LOG}" ]]; then
  echo "FAIL: curl ran after invalid token rejection" >&2
  exit 1
fi

echo "curl bearer helper test: all green"
