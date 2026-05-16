#!/usr/bin/env bash
# Cuts the OpenBurnBar iroh transport over from n0's public relay mesh to a
# paid n0 hosted relay (Phase 6 of the migration plan).
#
# The hosted tier is provisioned through the Iroh Services dashboard:
# https://services.iroh.computer/alberto8793/burnbar/relays
#
# Output: a single relay URL we ship through Firebase Remote Config so all
# Macs + iOS devices pick it up on next boot.
#
# Usage:
#   ./scripts/cutover-n0-hosted-relay.sh provision      # print dashboard steps
#   ./scripts/cutover-n0-hosted-relay.sh status         # print dashboard URL
#   ./scripts/cutover-n0-hosted-relay.sh publish <url> [--dry-run]  # push to Remote Config
#   ./scripts/cutover-n0-hosted-relay.sh rollback [--dry-run]       # clear Remote Config (back to public relay)
#
# Required environment (sourced from .secrets/iroh-services.env if present):
#   IROH_SERVICES_API_SECRET   Iroh Services endpoint metrics API key
#   PROJECT_ID                 Firebase project id for the Remote Config push
#
# Optional environment:
#   IROH_SERVICES_RELAYS_URL   defaults to the BurnBar dashboard relays URL

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
IROH_SERVICES_RELAYS_URL="${IROH_SERVICES_RELAYS_URL:-https://services.iroh.computer/alberto8793/burnbar/relays}"
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

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "cutover-n0-hosted-relay: jq is required to merge Remote Config templates" >&2
    exit 1
  fi
}

provision() {
  require_secret
  cat <<EOF
Iroh Services does not expose a documented relay provisioning REST API.

Provision the hosted relay in the dashboard:
  ${IROH_SERVICES_RELAYS_URL}

Recommended BurnBar production config:
  Region: US East (use1)
  Version: v1.0.0-rc.0 or the dashboard default promoted by Iroh Services
  Plan: Pro managed relay (~\$199/month)

After the dashboard reports a stable relay URL, publish it with:
  PROJECT_ID=burnbar ./scripts/cutover-n0-hosted-relay.sh publish <relay-url>
EOF
}

status() {
  require_secret
  cat <<EOF
Check Iroh Services relay status in the dashboard:
  ${IROH_SERVICES_RELAYS_URL}

The dashboard must show the target relay URL as running before Phase D can
publish it to Firebase Remote Config.
EOF
}

publish() {
  require_project
  require_jq
  if [[ $# -lt 1 ]]; then
    echo "cutover-n0-hosted-relay: publish requires a relay URL" >&2
    exit 64
  fi
  local url="${1}"
  local dry_run=false
  shift || true
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) dry_run=true ;;
      *)
        echo "cutover-n0-hosted-relay: unknown publish flag: ${arg}" >&2
        exit 64
        ;;
    esac
  done
  echo "→ publishing iroh hosted relay URL via Firebase Remote Config (project=${PROJECT_ID})"

  local firebase_args=(--project "${PROJECT_ID}" --non-interactive)
  if [[ -n "${FIREBASE_TOKEN}" ]]; then
    firebase_args+=(--token "${FIREBASE_TOKEN}")
  fi

  local current_path
  current_path="$(mktemp -t iroh-rc-current-XXXXXX.json)"
  local template_path
  template_path="$(mktemp -t iroh-rc-XXXXXX.json)"

  firebase "${firebase_args[@]}" remoteconfig:get --json > "${current_path}"
  jq --arg url "${url}" '
    (.result // .) as $template
    | $template
    | .parameters = (.parameters // {})
    | .parameters.hermes_iroh_hosted_relay_url = {
        defaultValue: { value: $url },
        valueType: "STRING",
        description: "n0 hosted relay URL for the Hermes iroh transport. Empty string means use n0 public relay mesh."
      }
  ' "${current_path}" > "${template_path}"

  if "${dry_run}"; then
    echo "[dry-run] Remote Config template preview:"
    jq '.parameters.hermes_iroh_hosted_relay_url' "${template_path}"
    rm -f "${current_path}" "${template_path}"
    return
  fi

  firebase "${firebase_args[@]}" remoteconfig:templates:set "${template_path}"
  rm -f "${current_path}" "${template_path}"
  echo "✓ Remote Config updated; clients will pick up the new relay URL on next boot"
}

rollback() {
  require_project
  echo "→ clearing iroh hosted relay URL (devices revert to n0 public relay mesh)"
  publish "" "$@"
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
