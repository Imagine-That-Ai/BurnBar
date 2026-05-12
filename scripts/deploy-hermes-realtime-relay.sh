#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID to the BurnBar Firebase/GCP project id}"
REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-hermes-realtime-relay}"
REDIS_URL="${REDIS_URL:?Set REDIS_URL, for example redis://10.0.0.3:6379 or rediss://10.0.0.3:6378}"
REDIS_URL_SECRET="${REDIS_URL_SECRET:-}"
REDIS_TLS_CA_PEM_SECRET="${REDIS_TLS_CA_PEM_SECRET:-}"
REDIS_TLS_CA_BASE64_SECRET="${REDIS_TLS_CA_BASE64_SECRET:-}"
REDIS_TLS_SERVERNAME="${REDIS_TLS_SERVERNAME:-}"
REDIS_INSTANCE_NAME="${REDIS_INSTANCE_NAME:-hermes-realtime-relay-redis-prod-secure}"
SKIP_REDIS_PROJECT_GUARD="${SKIP_REDIS_PROJECT_GUARD:-false}"
DEPLOY_PROFILE="${DEPLOY_PROFILE:-prod-safe}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-3600}"
SESSION_AFFINITY="${SESSION_AFFINITY:-true}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-}"
VPC_CONNECTOR="${VPC_CONNECTOR:-}"
DIRECT_VPC_NETWORK="${DIRECT_VPC_NETWORK:-}"
DIRECT_VPC_SUBNET="${DIRECT_VPC_SUBNET:-}"
DIRECT_VPC_TAGS="${DIRECT_VPC_TAGS:-}"
VPC_EGRESS="${VPC_EGRESS:-private-ranges-only}"
HOSTED_RELAY_PRODUCT_IDS="${HOSTED_RELAY_PRODUCT_IDS:-${HOSTED_QUOTA_PRODUCT_ID:-com.openburnbar.hostedQuotaSync.cloud.monthly}}"
ENFORCE_APP_CHECK="${ENFORCE_APP_CHECK:-true}"
VERIFY_REVOKED_ID_TOKENS="${VERIFY_REVOKED_ID_TOKENS:-false}"
APP_CHECK_ALLOWED_APP_IDS="${APP_CHECK_ALLOWED_APP_IDS:-}"

case "${DEPLOY_PROFILE}" in
  staging-cheap)
    MIN_INSTANCES="${MIN_INSTANCES:-0}"
    MAX_INSTANCES="${MAX_INSTANCES:-2}"
    CONCURRENCY="${CONCURRENCY:-300}"
    CPU="${CPU:-1}"
    MEMORY="${MEMORY:-256Mi}"
    ;;
  prod-safe)
    MIN_INSTANCES="${MIN_INSTANCES:-1}"
    MAX_INSTANCES="${MAX_INSTANCES:-10}"
    CONCURRENCY="${CONCURRENCY:-500}"
    CPU="${CPU:-1}"
    MEMORY="${MEMORY:-512Mi}"
    ;;
  prod-scale)
    MIN_INSTANCES="${MIN_INSTANCES:-2}"
    MAX_INSTANCES="${MAX_INSTANCES:-50}"
    CONCURRENCY="${CONCURRENCY:-800}"
    CPU="${CPU:-1}"
    MEMORY="${MEMORY:-768Mi}"
    ;;
  *)
    echo "Unknown DEPLOY_PROFILE '${DEPLOY_PROFILE}'. Use staging-cheap, prod-safe, or prod-scale." >&2
    exit 64
    ;;
esac

MAX_FRAME_BYTES="${MAX_FRAME_BYTES:-524288}"
MAX_HOST_SOCKETS_PER_USER="${MAX_HOST_SOCKETS_PER_USER:-2}"
MAX_CLIENT_SOCKETS_PER_USER="${MAX_CLIENT_SOCKETS_PER_USER:-4}"
MAX_REQUEST_STARTS_PER_MINUTE="${MAX_REQUEST_STARTS_PER_MINUTE:-60}"
MAX_BYTES_PER_MINUTE="${MAX_BYTES_PER_MINUTE:-26214400}"
MAX_IN_FLIGHT_REQUESTS_PER_USER="${MAX_IN_FLIGHT_REQUESTS_PER_USER:-6}"
ENTITLEMENT_CACHE_TTL_SECONDS="${ENTITLEMENT_CACHE_TTL_SECONDS:-60}"
ENTITLEMENT_NEGATIVE_CACHE_TTL_SECONDS="${ENTITLEMENT_NEGATIVE_CACHE_TTL_SECONDS:-15}"
SOCKET_LEASE_SECONDS="${SOCKET_LEASE_SECONDS:-120}"
IN_FLIGHT_LEASE_SECONDS="${IN_FLIGHT_LEASE_SECONDS:-600}"

if [[ -n "${VPC_CONNECTOR}" && ( -n "${DIRECT_VPC_NETWORK}" || -n "${DIRECT_VPC_SUBNET}" ) ]]; then
  echo "Set either VPC_CONNECTOR or DIRECT_VPC_NETWORK/DIRECT_VPC_SUBNET, not both." >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_DIR="${ROOT_DIR}/services/hermes-realtime-relay"

if [[ "${SKIP_REDIS_PROJECT_GUARD}" != "true" ]]; then
  REDIS_TARGET="$(REDIS_URL="${REDIS_URL}" node -e '
const url = new URL(process.env.REDIS_URL);
if (url.protocol !== "redis:" && url.protocol !== "rediss:") {
  throw new Error(`REDIS_URL must use redis:// or rediss://, got ${url.protocol}`);
}
console.log(JSON.stringify({ host: url.hostname, protocol: url.protocol, hasPassword: url.password.length > 0 }));
')"
  REDIS_HOST="$(REDIS_TARGET="${REDIS_TARGET}" node -e 'console.log(JSON.parse(process.env.REDIS_TARGET).host)')"
  REDIS_SCHEME="$(REDIS_TARGET="${REDIS_TARGET}" node -e 'console.log(JSON.parse(process.env.REDIS_TARGET).protocol.replace(":", ""))')"
  REDIS_URL_HAS_PASSWORD="$(REDIS_TARGET="${REDIS_TARGET}" node -e 'console.log(JSON.parse(process.env.REDIS_TARGET).hasPassword ? "true" : "false")')"
  REDIS_DESCRIBE="$(gcloud redis instances describe "${REDIS_INSTANCE_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --format json)"
  REDIS_ACTUAL_HOST="$(REDIS_DESCRIBE="${REDIS_DESCRIBE}" node -e 'console.log(JSON.parse(process.env.REDIS_DESCRIBE).host || "")')"
  REDIS_STATE="$(REDIS_DESCRIBE="${REDIS_DESCRIBE}" node -e 'console.log(JSON.parse(process.env.REDIS_DESCRIBE).state || "")')"
  REDIS_TIER="$(REDIS_DESCRIBE="${REDIS_DESCRIBE}" node -e 'console.log(JSON.parse(process.env.REDIS_DESCRIBE).tier || "")')"
  REDIS_AUTH_ENABLED="$(REDIS_DESCRIBE="${REDIS_DESCRIBE}" node -e 'console.log(JSON.parse(process.env.REDIS_DESCRIBE).authEnabled === true ? "true" : "false")')"
  REDIS_TRANSIT_ENCRYPTION_MODE="$(REDIS_DESCRIBE="${REDIS_DESCRIBE}" node -e 'console.log(JSON.parse(process.env.REDIS_DESCRIBE).transitEncryptionMode || "DISABLED")')"
  if [[ "${REDIS_STATE}" != "READY" ]]; then
    echo "Redis instance ${REDIS_INSTANCE_NAME} in ${PROJECT_ID}/${REGION} is ${REDIS_STATE}, not READY." >&2
    exit 65
  fi
  if [[ "${REDIS_HOST}" != "${REDIS_ACTUAL_HOST}" ]]; then
    echo "REDIS_URL host ${REDIS_HOST} does not match ${PROJECT_ID}/${REGION}/${REDIS_INSTANCE_NAME} host ${REDIS_ACTUAL_HOST}." >&2
    exit 65
  fi
  if [[ "${DEPLOY_PROFILE}" != "staging-cheap" && "${REDIS_TIER}" != "STANDARD_HA" ]]; then
    echo "Production relay profiles require STANDARD_HA Redis; ${REDIS_INSTANCE_NAME} is ${REDIS_TIER}." >&2
    exit 65
  fi
  if [[ "${DEPLOY_PROFILE}" != "staging-cheap" && "${REDIS_TRANSIT_ENCRYPTION_MODE}" != "SERVER_AUTHENTICATION" ]]; then
    echo "Production relay profiles require Redis in-transit encryption SERVER_AUTHENTICATION; ${REDIS_INSTANCE_NAME} is ${REDIS_TRANSIT_ENCRYPTION_MODE}." >&2
    exit 65
  fi
  if [[ "${DEPLOY_PROFILE}" != "staging-cheap" && "${REDIS_AUTH_ENABLED}" != "true" ]]; then
    echo "Production relay profiles require Redis AUTH; ${REDIS_INSTANCE_NAME} has auth disabled." >&2
    exit 65
  fi
  if [[ "${REDIS_TRANSIT_ENCRYPTION_MODE}" == "SERVER_AUTHENTICATION" && "${REDIS_SCHEME}" != "rediss" ]]; then
    echo "Redis ${REDIS_INSTANCE_NAME} requires TLS; REDIS_URL must use rediss://." >&2
    exit 65
  fi
  if [[ "${DEPLOY_PROFILE}" != "staging-cheap" && "${REDIS_AUTH_ENABLED}" == "true" && -z "${REDIS_URL_SECRET}" ]]; then
    echo "Production AUTH Redis deploys must set REDIS_URL_SECRET so credentials are injected from Secret Manager, not plain Cloud Run env vars." >&2
    exit 65
  fi
  if [[ "${DEPLOY_PROFILE}" != "staging-cheap" && "${REDIS_URL_HAS_PASSWORD}" == "true" && -z "${REDIS_URL_SECRET}" ]]; then
    echo "Production REDIS_URL contains a password; store it in Secret Manager and pass REDIS_URL_SECRET instead." >&2
    exit 65
  fi
  if [[ "${DEPLOY_PROFILE}" != "staging-cheap" && "${REDIS_TRANSIT_ENCRYPTION_MODE}" == "SERVER_AUTHENTICATION" && -z "${REDIS_TLS_CA_PEM_SECRET}" && -z "${REDIS_TLS_CA_BASE64_SECRET}" ]]; then
    echo "Production TLS Redis deploys must set REDIS_TLS_CA_PEM_SECRET or REDIS_TLS_CA_BASE64_SECRET for server certificate validation." >&2
    exit 65
  fi
fi

cd "${SERVICE_DIR}"
npm ci
npm run build

IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}:$(date +%Y%m%d%H%M%S)"
gcloud builds submit --project "${PROJECT_ID}" --tag "${IMAGE}" .

ARGS=(
  run deploy "${SERVICE_NAME}"
  --project "${PROJECT_ID}"
  --region "${REGION}"
  --image "${IMAGE}"
  --platform managed
  --allow-unauthenticated
  --min-instances "${MIN_INSTANCES}"
  --max-instances "${MAX_INSTANCES}"
  --timeout "${REQUEST_TIMEOUT_SECONDS}"
  --concurrency "${CONCURRENCY}"
  --cpu "${CPU}"
  --memory "${MEMORY}"
  --cpu-throttling
)

ENV_VARS="^|^ENFORCE_APP_CHECK=${ENFORCE_APP_CHECK}|VERIFY_REVOKED_ID_TOKENS=${VERIFY_REVOKED_ID_TOKENS}|HOSTED_RELAY_PRODUCT_IDS=${HOSTED_RELAY_PRODUCT_IDS}|APP_CHECK_ALLOWED_APP_IDS=${APP_CHECK_ALLOWED_APP_IDS}|MAX_FRAME_BYTES=${MAX_FRAME_BYTES}|MAX_HOST_SOCKETS_PER_USER=${MAX_HOST_SOCKETS_PER_USER}|MAX_CLIENT_SOCKETS_PER_USER=${MAX_CLIENT_SOCKETS_PER_USER}|MAX_REQUEST_STARTS_PER_MINUTE=${MAX_REQUEST_STARTS_PER_MINUTE}|MAX_BYTES_PER_MINUTE=${MAX_BYTES_PER_MINUTE}|MAX_IN_FLIGHT_REQUESTS_PER_USER=${MAX_IN_FLIGHT_REQUESTS_PER_USER}|ENTITLEMENT_CACHE_TTL_SECONDS=${ENTITLEMENT_CACHE_TTL_SECONDS}|ENTITLEMENT_NEGATIVE_CACHE_TTL_SECONDS=${ENTITLEMENT_NEGATIVE_CACHE_TTL_SECONDS}|SOCKET_LEASE_SECONDS=${SOCKET_LEASE_SECONDS}|IN_FLIGHT_LEASE_SECONDS=${IN_FLIGHT_LEASE_SECONDS}"
if [[ -z "${REDIS_URL_SECRET}" ]]; then
  ENV_VARS="${ENV_VARS}|REDIS_URL=${REDIS_URL}"
fi
if [[ -n "${REDIS_TLS_SERVERNAME}" ]]; then
  ENV_VARS="${ENV_VARS}|REDIS_TLS_SERVERNAME=${REDIS_TLS_SERVERNAME}"
fi
ARGS+=(--set-env-vars "${ENV_VARS}")

SECRET_VARS=()
[[ -n "${REDIS_URL_SECRET}" ]] && SECRET_VARS+=("REDIS_URL=${REDIS_URL_SECRET}:latest")
[[ -n "${REDIS_TLS_CA_PEM_SECRET}" ]] && SECRET_VARS+=("REDIS_TLS_CA_PEM=${REDIS_TLS_CA_PEM_SECRET}:latest")
[[ -n "${REDIS_TLS_CA_BASE64_SECRET}" ]] && SECRET_VARS+=("REDIS_TLS_CA_BASE64=${REDIS_TLS_CA_BASE64_SECRET}:latest")
if [[ "${#SECRET_VARS[@]}" -gt 0 ]]; then
  SECRET_ENV="$(IFS=,; echo "${SECRET_VARS[*]}")"
  ARGS+=(--set-secrets "${SECRET_ENV}")
fi

if [[ -n "${SERVICE_ACCOUNT}" ]]; then
  ARGS+=(--service-account "${SERVICE_ACCOUNT}")
fi

if [[ "${SESSION_AFFINITY}" == "true" ]]; then
  ARGS+=(--session-affinity)
else
  ARGS+=(--no-session-affinity)
fi

if [[ -n "${VPC_CONNECTOR}" ]]; then
  ARGS+=(--vpc-connector "${VPC_CONNECTOR}" --vpc-egress "${VPC_EGRESS}")
elif [[ -n "${DIRECT_VPC_NETWORK}" || -n "${DIRECT_VPC_SUBNET}" ]]; then
  [[ -n "${DIRECT_VPC_NETWORK}" ]] && ARGS+=(--network "${DIRECT_VPC_NETWORK}")
  [[ -n "${DIRECT_VPC_SUBNET}" ]] && ARGS+=(--subnet "${DIRECT_VPC_SUBNET}")
  [[ -n "${DIRECT_VPC_TAGS}" ]] && ARGS+=(--network-tags "${DIRECT_VPC_TAGS}")
  ARGS+=(--vpc-egress "${VPC_EGRESS}")
fi

gcloud "${ARGS[@]}"
gcloud run services describe "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --format 'value(status.url)'
