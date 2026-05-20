#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_ID="${PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "Set PROJECT_ID or GOOGLE_CLOUD_PROJECT to the BurnBar Firebase/GCP project id." >&2
  exit 64
fi

REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-openburnbar-ots-verifier}"
SERVICE_DIR="${SERVICE_DIR:-tools/opentimestamps-verifier-service}"
REQUIRE_AUTH="${REQUIRE_AUTH:-true}"
MIN_INSTANCES="${MIN_INSTANCES:-0}"
MAX_INSTANCES="${MAX_INSTANCES:-3}"
MEMORY="${MEMORY:-512Mi}"
CPU="${CPU:-1}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"
IMAGE="${IMAGE:-gcr.io/${PROJECT_ID}/${SERVICE_NAME}:$(git rev-parse --short HEAD)}"
FUNCTIONS_ENV_FILE="${FUNCTIONS_ENV_FILE:-functions/.env.${PROJECT_ID}}"
WRITE_FUNCTIONS_ENV="${WRITE_FUNCTIONS_ENV:-true}"

if [[ ! -f "${SERVICE_DIR}/Dockerfile" || ! -f "${SERVICE_DIR}/server.py" ]]; then
  echo "Missing verifier service files under ${SERVICE_DIR}." >&2
  exit 66
fi

python3 -m py_compile "${SERVICE_DIR}/server.py"

gcloud builds submit "${SERVICE_DIR}" \
  --tag "${IMAGE}" \
  --project "${PROJECT_ID}"

AUTH_FLAG="--no-allow-unauthenticated"
if [[ "${REQUIRE_AUTH}" == "false" ]]; then
  AUTH_FLAG="--allow-unauthenticated"
fi

gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --platform managed \
  "${AUTH_FLAG}" \
  --min-instances "${MIN_INSTANCES}" \
  --max-instances "${MAX_INSTANCES}" \
  --timeout "${TIMEOUT_SECONDS}" \
  --cpu "${CPU}" \
  --memory "${MEMORY}"

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --format='value(status.url)')"

upsert_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  local escaped
  escaped="$(printf '%s' "${value}" | sed 's/[\/&]/\\&/g')"
  if grep -qE "^${key}=" "${file}"; then
    sed -i.bak "s/^${key}=.*/${key}=${escaped}/" "${file}"
    rm -f "${file}.bak"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${file}"
  fi
}

if [[ "${WRITE_FUNCTIONS_ENV}" == "true" ]]; then
  upsert_env_value "${FUNCTIONS_ENV_FILE}" "OPENBURNBAR_OTS_VERIFY_URL" "${SERVICE_URL}/verify"
  upsert_env_value "${FUNCTIONS_ENV_FILE}" "OPENBURNBAR_OTS_VERIFY_AUDIENCE" "${SERVICE_URL}"
fi

cat <<EOF
${SERVICE_URL}

Firebase Functions runtime params:

OPENBURNBAR_OTS_VERIFY_URL=${SERVICE_URL}/verify
OPENBURNBAR_OTS_VERIFY_AUDIENCE=${SERVICE_URL}

$(if [[ "${WRITE_FUNCTIONS_ENV}" == "true" ]]; then printf 'Updated %s with those values.\n\n' "${FUNCTIONS_ENV_FILE}"; else printf 'WRITE_FUNCTIONS_ENV=false, so no functions .env file was changed.\n\n'; fi)
Then deploy the callable:

firebase deploy --only functions:validateOpenTimestampsProof --project ${PROJECT_ID}
EOF
