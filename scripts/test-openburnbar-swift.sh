#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

coverage_flags=()
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
  coverage_flags+=(--enable-code-coverage)
fi

swift test --package-path "$repo_root/OpenBurnBarCore" "${coverage_flags[@]}"
swift test --package-path "$repo_root/OpenBurnBarDaemon" "${coverage_flags[@]}"
