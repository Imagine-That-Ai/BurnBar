#!/usr/bin/env bash
# Fail CI when UniFFI Swift bindings lack inbound peer NodeId (P0 iroh binding).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GENERATED="${ROOT}/OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/openburnbar_iroh.swift"

if [[ ! -f "${GENERATED}" ]]; then
  echo "verify-iroh-remote-node-id-binding: missing ${GENERATED}" >&2
  exit 1
fi

if ! grep -q 'func remoteNodeId()' "${GENERATED}"; then
  echo "verify-iroh-remote-node-id-binding: rebuild Vendor/OpenBurnBarIroh.xcframework (missing remoteNodeId)" >&2
  exit 1
fi

echo "verify-iroh-remote-node-id-binding: ok"