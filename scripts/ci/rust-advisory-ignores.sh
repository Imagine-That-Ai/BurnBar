#!/usr/bin/env bash
# Single source of truth for the accepted (ignored) RustSec advisories.
#
# crates/openburnbar-iroh/deny.toml's [advisories].ignore is the ONLY place the
# accepted-risk advisory set is declared (with per-id rationale comments). Both
# cargo-deny (reads deny.toml directly) and cargo-audit (which has no deny.toml
# support) must agree on that set. cargo-audit takes repeated --ignore flags, so
# this script emits one advisory id per line, read straight from deny.toml — no
# second hand-maintained list to drift out of lockstep.
#
# STILL LOAD-BEARING, despite the SAST lane no longer calling it directly.
# scripts/ci/check-cargo-audit-fail-closed.mjs is what CI runs now, and it reads
# deny.toml itself. Two readers of one source is fine; two readers that DISAGREE
# is the drift this file exists to prevent — so
# scripts/ci/check-advisory-ignore-single-source.sh asserts both extract an
# identical set. Deleting this script would remove that cross-check.
#
# Usage:
#   mapfile -t IDS < <(scripts/ci/rust-advisory-ignores.sh)   # ids, one per line
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DENY_TOML="${ROOT_DIR}/crates/openburnbar-iroh/deny.toml"

if [[ ! -f "$DENY_TOML" ]]; then
  echo "ERROR: deny.toml not found at ${DENY_TOML}" >&2
  exit 1
fi

python3 - "$DENY_TOML" <<'PY'
import sys

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover - fallback for older runners
    import tomli as tomllib  # type: ignore

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

ignores = (data.get("advisories", {}) or {}).get("ignore", []) or []
ids = [str(entry).strip() for entry in ignores if str(entry).strip()]
if not ids:
    print("ERROR: deny.toml [advisories].ignore is empty — refusing to emit an empty audit ignore set.", file=sys.stderr)
    sys.exit(1)
for advisory_id in ids:
    print(advisory_id)
PY
