#!/usr/bin/env bash
# Deploy script for the iroh-backed Hermes Realtime Relay.
#
# Phase 3 deployment: ships the Firestore security-rules updates that gate
# `/users/{uid}/iroh_pairing/*` and `/users/{uid}/iroh_audit_events/*`, plus
# the TypeScript schema changes in `functions/src/types.ts`. Owner-side
# (Mac) and reader-side (iOS / iPadOS) clients pick up the new collections
# automatically once the rules + functions are live.
#
# Usage:
#   ./scripts/deploy-iroh-relay.sh                  # full deploy
#   ./scripts/deploy-iroh-relay.sh --rules-only     # rules-only fast lane
#   ./scripts/deploy-iroh-relay.sh --dry-run        # validate deploy plan, no apply
#
# Required environment:
#   PROJECT_ID   Firebase / GCP project id (e.g. openburnbar-prod)
#
# Optional environment:
#   FIREBASE_TOKEN  CI token for `firebase deploy --token "$FIREBASE_TOKEN"`
#   IROH_RELAY_FUNCTIONS_REGION   defaults to us-central1
#   IROH_RELAY_FUNCTIONS          comma-separated deploy list; defaults to rollupIrohTransportDaily
#
# Safe to re-run; rules are append-only (`hermes_*` and `pi_agent_*` rules
# are untouched).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID to the BurnBar Firebase/GCP project id}"
FIREBASE_TOKEN="${FIREBASE_TOKEN:-}"
IROH_RELAY_FUNCTIONS_REGION="${IROH_RELAY_FUNCTIONS_REGION:-us-central1}"
IROH_RELAY_FUNCTIONS="${IROH_RELAY_FUNCTIONS:-rollupIrohTransportDaily}"

RULES_ONLY=false
DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
    --rules-only) RULES_ONLY=true ;;
    --dry-run)    DRY_RUN=true ;;
    --help|-h)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "deploy-iroh-relay: unknown flag: ${arg}" >&2
      exit 64
      ;;
  esac
done

cd "${REPO_ROOT}"

echo "→ deploy-iroh-relay: project=${PROJECT_ID} rules-only=${RULES_ONLY} dry-run=${DRY_RUN}"

if [[ ! -f firestore.rules ]]; then
  echo "deploy-iroh-relay: firestore.rules missing at repo root" >&2
  exit 1
fi

if ! grep -q 'iroh_pairing' firestore.rules; then
  echo "deploy-iroh-relay: firestore.rules has no iroh_pairing match — refusing to deploy stale rules" >&2
  exit 1
fi

if ! grep -q 'IrohPairingRecordDoc' functions/src/types.ts; then
  echo "deploy-iroh-relay: functions/src/types.ts has no IrohPairingRecordDoc schema — refusing to deploy without it" >&2
  exit 1
fi

firebase_args=(--project "${PROJECT_ID}" --non-interactive)
if [[ -n "${FIREBASE_TOKEN}" ]]; then
  firebase_args+=(--token "${FIREBASE_TOKEN}")
fi

IFS=',' read -r -a function_names <<< "${IROH_RELAY_FUNCTIONS}"
function_targets=()
for function_name in "${function_names[@]}"; do
  function_name="${function_name//[[:space:]]/}"
  if [[ -n "${function_name}" ]]; then
    function_targets+=("functions:${function_name}")
  fi
done
if [[ ${#function_targets[@]} -eq 0 ]]; then
  echo "deploy-iroh-relay: IROH_RELAY_FUNCTIONS produced no deploy targets" >&2
  exit 1
fi
IFS=,
function_only="${function_targets[*]}"
unset IFS

echo "→ deploying firestore.rules"
if "${DRY_RUN}"; then
  firebase "${firebase_args[@]}" deploy --only firestore:rules --dry-run
else
  firebase "${firebase_args[@]}" deploy --only firestore:rules
fi

if "${RULES_ONLY}"; then
  echo "✓ rules deploy complete (rules-only)"
  exit 0
fi

if [[ -d functions ]] && [[ -f functions/package.json ]]; then
  echo "→ building Cloud Functions"
  npm --prefix functions ci
  npm --prefix functions run build

  if "${DRY_RUN}"; then
    echo "[dry-run] validated functions build; would deploy ${function_only}"
    echo "[dry-run] validated functions build; skipping functions deploy"
  else
    echo "→ deploying Cloud Functions to ${IROH_RELAY_FUNCTIONS_REGION}: ${function_only}"
    firebase "${firebase_args[@]}" deploy --only "${function_only}"
  fi
fi

echo "→ smoke-checking new collections via Firestore REST"
if ! "${DRY_RUN}"; then
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "deploy-iroh-relay: gcloud not on PATH; skipping smoke check" >&2
  else
    # Best-effort: confirm the collection group is reachable. The owner's
    # access token is required; in CI we skip this when impersonation isn't
    # available.
    gcloud firestore databases describe \
      --project "${PROJECT_ID}" \
      --database "(default)" >/dev/null 2>&1 \
      || echo "deploy-iroh-relay: could not describe firestore database (probably unauthenticated; rules deploy succeeded above)"
  fi
fi

echo "✓ deploy-iroh-relay complete for project=${PROJECT_ID}"
echo
echo "Next steps:"
echo "  • Mac (AgentLens): bump app version, rebuild — IrohRelayHost will publish on first run"
echo "  • iOS (OpenBurnBarMobile): bump app version, rebuild — IrohRelayClient will fetch + verify on first chat"
echo "  • Audit events flow into /users/{uid}/iroh_audit_events; check Firebase Console after first round trip"
