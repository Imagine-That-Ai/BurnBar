#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

coverage_flags=()
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
  coverage_flags+=(--enable-code-coverage)
fi

# `set -u` + the empty-array expansion `${coverage_flags[@]}` triggers
# "unbound variable" on bash 3.2 (macOS default). Use the empty-safe
# `${coverage_flags[@]+"${coverage_flags[@]}"}` idiom instead.
swift test --package-path "$repo_root/OpenBurnBarCore" ${coverage_flags[@]+"${coverage_flags[@]}"}
swift test --package-path "$repo_root/OpenBurnBarDaemon" ${coverage_flags[@]+"${coverage_flags[@]}"}
