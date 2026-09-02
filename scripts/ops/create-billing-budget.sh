#!/usr/bin/env bash
# Create (or verify) the GCP billing budget that feeds the alert plane
# (Wave 0 workstream W0-5; human queue items 7-9).
#
# HUMAN-RUN ONLY: creating a budget needs billing.admin on the billing
# account. The ops-verifier identity (governance/ops-plane-verifier-sa.json)
# is deliberately viewer-only and can never do this — which is why this is a
# documented runbook step and not a CI job.
#
# Usage:
#   scripts/ops/create-billing-budget.sh --dry-run   # print the exact gcloud commands
#   scripts/ops/create-billing-budget.sh             # apply (idempotent by display name)
#
# Env:
#   BILLING_ACCOUNT  billing account id (required)
#   PROJECT_ID       project the budget watches + hosts the Pub/Sub topic (default: burnbar)
#   BUDGET_AMOUNT    monthly amount in USD (default: 200)
set -euo pipefail

cd "$(dirname "$0")/../.."

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ -n "${1:-}" ]]; then
  echo "usage: $0 [--dry-run]" >&2
  exit 2
fi

BILLING_ACCOUNT="${BILLING_ACCOUNT:-<billing-account-id>}"
PROJECT_ID="${PROJECT_ID:-burnbar}"
BUDGET_NAME="burnbar-ops-alert-budget"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-200}"
PUBSUB_TOPIC="projects/${PROJECT_ID}/topics/ops-billing-alerts"

if $DRY_RUN; then
  echo "DRY-RUN (export BILLING_ACCOUNT=<billing account id> to run for real):"
  echo "DRY-RUN: gcloud billing budgets list --billing-account='${BILLING_ACCOUNT}' --filter='displayName=\"${BUDGET_NAME}\"' --format='value(name)'"
  echo "DRY-RUN: gcloud billing budgets create --billing-account='${BILLING_ACCOUNT}' --display-name='${BUDGET_NAME}' --budget-amount='${BUDGET_AMOUNT}USD' --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 --notifications-rule-pubsub-topic='${PUBSUB_TOPIC}'"
  echo "DRY-RUN: (one-time, if the topic does not exist yet) gcloud pubsub topics create ops-billing-alerts --project='${PROJECT_ID}'"
  exit 0
fi

BILLING_ACCOUNT="${BILLING_ACCOUNT:?set BILLING_ACCOUNT (the billing account id)}"
if [[ "${BILLING_ACCOUNT}" == "<billing-account-id>" ]]; then
  echo "BILLING_ACCOUNT is not set (see --dry-run for the commands it would run)" >&2
  exit 1
fi

# Idempotent: a budget with this display name is not created twice.
existing="$(gcloud billing budgets list \
  --billing-account="${BILLING_ACCOUNT}" \
  --filter="displayName='${BUDGET_NAME}'" \
  --format="value(name)")"

if [[ -n "${existing}" ]]; then
  echo "Budget '${BUDGET_NAME}' already exists: ${existing}"
  echo "Nothing to do (idempotent re-run)."
  exit 0
fi

echo "Creating billing budget '${BUDGET_NAME}' (amount: \$${BUDGET_AMOUNT}, thresholds: 50%/90%/100%, topic: ${PUBSUB_TOPIC})..."
gcloud billing budgets create \
  --billing-account="${BILLING_ACCOUNT}" \
  --display-name="${BUDGET_NAME}" \
  --budget-amount="${BUDGET_AMOUNT}USD" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --notifications-rule-pubsub-topic="${PUBSUB_TOPIC}"

echo "Done. The budget's Pub/Sub notifications feed the alert plane verified by"
echo "scripts/ops/check-ops-alert-plane-drift.mjs (schedule lanes in ops-plane-verify.yml)."
