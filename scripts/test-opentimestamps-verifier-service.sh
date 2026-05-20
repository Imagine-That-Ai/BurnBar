#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-openburnbar-ots-verifier:local}"
CONTAINER_NAME="${CONTAINER_NAME:-openburnbar-ots-verifier-smoke}"
PORT="${PORT:-18080}"

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running; start Docker Desktop and rerun this smoke." >&2
  exit 69
fi

docker build -t "${IMAGE}" tools/opentimestamps-verifier-service

cleanup() {
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker run -d --name "${CONTAINER_NAME}" -p "127.0.0.1:${PORT}:8080" "${IMAGE}" >/dev/null

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS "http://127.0.0.1:${PORT}/health"
printf '\n'

INVALID_PROOF_BASE64="$(printf 'not an ots proof' | base64)"
STATUS="$(curl -sS -o /tmp/openburnbar-ots-smoke-response.json -w '%{http_code}' \
  -H 'content-type: application/json' \
  --data "{\"proofBase64\":\"${INVALID_PROOF_BASE64}\"}" \
  "http://127.0.0.1:${PORT}/verify")"

cat /tmp/openburnbar-ots-smoke-response.json
printf '\n'

if [[ "${STATUS}" != "422" ]]; then
  echo "Expected invalid proof to return 422, got ${STATUS}." >&2
  exit 65
fi

echo "OpenTimestamps verifier smoke passed."
