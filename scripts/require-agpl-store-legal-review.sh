#!/usr/bin/env bash
set -euo pipefail

if [[ "${OPENBURNBAR_AGPL_STORE_LEGAL_REVIEW:-}" != "approved" ]]; then
  cat >&2 <<'EOF'
ERROR: AGPL/App Store legal review approval is required for store-bound release actions.

Set OPENBURNBAR_AGPL_STORE_LEGAL_REVIEW=approved only after counsel approves
the current AGPL/libsignal release posture for the target store channel.
EOF
  exit 1
fi
