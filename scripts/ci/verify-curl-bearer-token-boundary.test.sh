#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-curl-bearer-boundary.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCRIPT="scripts/ci/verify-curl-bearer-token-boundary.sh"

bash "${SCRIPT}" >/dev/null

mkdir -p "${TMP_DIR}/scripts"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'tok="${TOKEN}"'
  printf '%s%s -fsS \\\n' "cu" "rl"
  printf '  -H "%s%s ${tok}" \\\n' "Authorization: " "Bearer"
  printf '%s\n' '  "https://example.test"'
} >"${TMP_DIR}/scripts/bad.sh"

if CURL_BEARER_BOUNDARY_ROOT="${TMP_DIR}" bash "${SCRIPT}" >/dev/null 2>"${TMP_DIR}/bad.err"; then
  echo "FAIL: direct curl bearer header in argv was accepted" >&2
  exit 1
fi
if ! grep -Fq "bearer Authorization header is passed via curl argv" "${TMP_DIR}/bad.err"; then
  echo "FAIL: verifier did not explain the rejected curl bearer argv pattern" >&2
  exit 1
fi

rm -f "${TMP_DIR}/scripts/bad.sh"
cat >"${TMP_DIR}/scripts/good.sh" <<'SH'
#!/usr/bin/env bash
source scripts/lib/curl-bearer.sh
obb_curl_with_bearer "${TOKEN}" -fsS "https://example.test"
SH

mkdir -p "${TMP_DIR}/scripts/lib" "${TMP_DIR}/.github/workflows"
cp scripts/lib/curl-bearer.sh "${TMP_DIR}/scripts/lib/curl-bearer.sh"
cat >"${TMP_DIR}/.github/workflows/good.yml" <<'YAML'
name: good
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: |
          source scripts/lib/curl-bearer.sh
          obb_curl_with_bearer "${TOKEN}" --request POST --url https://example.test
YAML

CURL_BEARER_BOUNDARY_ROOT="${TMP_DIR}" bash "${SCRIPT}" >/dev/null

echo "curl bearer argv boundary test: all green"
