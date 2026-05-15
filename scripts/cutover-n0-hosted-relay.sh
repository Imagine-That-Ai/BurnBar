#!/usr/bin/env bash
# Cuts the OpenBurnBar iroh transport over from n0's public relay mesh to a
# paid n0 hosted relay (Phase 6 of the migration plan).
#
# The hosted tier is provisioned through the n0 services API
# (https://docs.iroh.computer/services/) using the secret stashed in
# `.secrets/iroh-services.env`. Output: a single relay URL we ship through
# Firebase Remote Config so all Macs + iOS devices pick it up on next boot.
#
# Usage:
#   ./scripts/cutover-n0-hosted-relay.sh provision      # create a fresh relay
#   ./scripts/cutover-n0-hosted-relay.sh status         # describe the existing relay
#   ./scripts/cutover-n0-hosted-relay.sh publish <url>  # push to Remote Config
#   ./scripts/cutover-n0-hosted-relay.sh rollback       # clear Remote Config (back to public relay)
#
# Required environment (sourced from .secrets/iroh-services.env if present):
#   IROH_SERVICES_API_SECRET   token for the n0 services API
#   PROJECT_ID                 Firebase project id for the Remote Config push
#
# Optional environment:
#   IROH_HOSTED_RELAY_REGION   defaults to "us-east"
#   IROH_HOSTED_RELAY_TIER     defaults to "team-200" ($200/mo SLA)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load the n0 services secret if available.
SECRET_FILE="${REPO_ROOT}/.secrets/iroh-services.env"
if [[ -f "${SECRET_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${SECRET_FILE}"
fi

IROH_SERVICES_API_SECRET="${IROH_SERVICES_API_SECRET:-}"
IROH_HOSTED_RELAY_REGION="${IROH_HOSTED_RELAY_REGION:-us-east}"
IROH_HOSTED_RELAY_TIER="${IROH_HOSTED_RELAY_TIER:-team-200}"
PROJECT_ID="${PROJECT_ID:-}"
FIREBASE_TOKEN="${FIREBASE_TOKEN:-}"

usage() {
  grep '^# ' "$0" | sed 's/^# //'
}

require_secret() {
  if [[ -z "${IROH_SERVICES_API_SECRET}" ]]; then
    echo "cutover-n0-hosted-relay: IROH_SERVICES_API_SECRET unset (place it in .secrets/iroh-services.env)" >&2
    exit 1
  fi
}

require_project() {
  if [[ -z "${PROJECT_ID}" ]]; then
    echo "cutover-n0-hosted-relay: PROJECT_ID unset" >&2
    exit 1
  fi
}

provision() {
  require_secret
  echo "→ provisioning n0 hosted relay (region=${IROH_HOSTED_RELAY_REGION}, tier=${IROH_HOSTED_RELAY_TIER})"
  local response
  response=$(curl -sS -X POST \
    -H "Authorization: Bearer ${IROH_SERVICES_API_SECRET}" \
    -H "Content-Type: application/json" \
    -d "{\"region\":\"${IROH_HOSTED_RELAY_REGION}\",\"tier\":\"${IROH_HOSTED_RELAY_TIER}\"}" \
    https://api.iroh.computer/v1/relays)
  echo "${response}" | jq .
  local url
  url=$(echo "${response}" | jq -r '.relay_url // empty')
  if [[ -z "${url}" ]]; then
    echo "cutover-n0-hosted-relay: response did not include relay_url" >&2
    exit 1
  fi
  echo "✓ provisioned relay URL: ${url}"
  echo "${url}"
}

status() {
  require_secret
  curl -sS \
    -H "Authorization: Bearer ${IROH_SERVICES_API_SECRET}" \
    https://api.iroh.computer/v1/relays | jq .
}

publish() {
  require_project
  local url="${1:?publish requires a relay URL}"
  echo "→ publishing iroh hosted relay URL via Firebase Remote Config (project=${PROJECT_ID})"

  local template_path
  template_path="$(mktemp -t iroh-rc-XXXXXX.json)"
  cat > "${template_path}" <<JSON
{
  "parameters": {
    "hermes_iroh_hosted_relay_url": {
      "defaultValue": {
        "value": "${url}"
      },
      "valueType": "STRING",
      "description": "n0 hosted relay URL for the Hermes iroh transport. Empty string means use n0's public relay mesh."
    }
  }
}
JSON

  local firebase_args=(--project "${PROJECT_ID}" --non-interactive)
  if [[ -n "${FIREBASE_TOKEN}" ]]; then
    firebase_args+=(--token "${FIREBASE_TOKEN}")
  fi
  firebase "${firebase_args[@]}" remoteconfig:rollouts:rollback --version-number=latest 2>/dev/null || true
  firebase "${firebase_args[@]}" remoteconfig:templates:set "${template_path}"
  rm -f "${template_path}"
  echo "✓ Remote Config updated; clients will pick up the new relay URL on next boot"
}

rollback() {
  require_project
  echo "→ clearing iroh hosted relay URL (devices revert to n0 public relay mesh)"
  publish ""
}

cmd="${1:-}"
shift || true
case "${cmd}" in
  provision) provision "$@" ;;
  status)    status "$@" ;;
  publish)   publish "$@" ;;
  rollback)  rollback "$@" ;;
  --help|-h|"") usage ;;
  *)
    echo "cutover-n0-hosted-relay: unknown command: ${cmd}" >&2
    usage
    exit 64
    ;;
esac
