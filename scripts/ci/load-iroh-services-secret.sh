#!/bin/sh
# Load the iroh services API secret into the current shell.
#
# Resolution order (first match wins):
#   1. $IROH_SERVICES_API_SECRET already exported in the environment
#      (this is how GitHub Actions feeds the secret in CI).
#   2. The IROH_SERVICES_API_SECRET line of .secrets/iroh-services.env
#      (local-only, gitignored).
#
# Usage:
#   . scripts/ci/load-iroh-services-secret.sh
#   # IROH_SERVICES_API_SECRET is now exported.
#
# Exits non-zero if no source contains a non-empty value AND
# IROH_REQUIRE_SERVICES_SECRET=true. Otherwise it logs a warning and
# leaves the variable unset so unrelated targets still build.

set -u

# Resolve repo root. When sourced, $0 may be the parent shell (-bash, sh) or
# the script path; when executed, $0 is always the script. The loader has to
# work in both modes, so prefer BASH_SOURCE when sourced from bash and fall
# back to the IROH_REPO_ROOT override or the CWD otherwise.
_iroh_repo_root() {
    if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
        printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        return
    fi
    if [ -n "${IROH_REPO_ROOT:-}" ]; then
        printf '%s' "$IROH_REPO_ROOT"
        return
    fi
    case "$0" in
        */*)
            printf '%s' "$(cd "$(dirname "$0")/../.." && pwd)"
            ;;
        *)
            printf '%s' "$(pwd)"
            ;;
    esac
}

_iroh_root="$(_iroh_repo_root)"
local_secret_file="$_iroh_root/.secrets/iroh-services.env"

_iroh_secret_resolved="false"

if [ -n "${IROH_SERVICES_API_SECRET:-}" ]; then
    echo "[iroh-services] using IROH_SERVICES_API_SECRET from environment"
    _iroh_secret_resolved="true"
fi

if [ "$_iroh_secret_resolved" = "false" ] && [ -f "$local_secret_file" ]; then
    candidate="$(grep -E '^IROH_SERVICES_API_SECRET=' "$local_secret_file" | head -n1 | cut -d= -f2-)"
    if [ -n "$candidate" ]; then
        export IROH_SERVICES_API_SECRET="$candidate"
        echo "[iroh-services] loaded IROH_SERVICES_API_SECRET from .secrets/iroh-services.env"
        _iroh_secret_resolved="true"
    fi
fi

if [ "$_iroh_secret_resolved" = "false" ]; then
    if [ "${IROH_REQUIRE_SERVICES_SECRET:-false}" = "true" ]; then
        echo "::error::IROH_SERVICES_API_SECRET is not set and .secrets/iroh-services.env is empty." >&2
        exit 64
    fi
    echo "[iroh-services] IROH_SERVICES_API_SECRET not configured; iroh services API calls will be skipped." >&2
    : "${IROH_SERVICES_API_SECRET:=}"
fi
unset _iroh_secret_resolved _iroh_root _iroh_repo_root _iroh_done local_secret_file candidate 2>/dev/null || true
