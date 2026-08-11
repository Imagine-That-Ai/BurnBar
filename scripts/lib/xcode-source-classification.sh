#!/usr/bin/env bash

# Xcode 27 source-classification compatibility for locked transitive packages.
#
# These settings correct package file inventories; they do not disable warning
# classes. Abseil's SwiftPM target is rooted at the package directory, so Xcode
# otherwise tries to process compiler include fragments and package metadata as
# standalone sources.
#
# GoogleSignIn's separate macOS umbrella compatibility layer is sourced here so
# every canonical Xcode entrypoint uses one shared transitive-package contract.
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "xcode-source-classification.sh requires Bash." >&2
  return 64 2>/dev/null || exit 64
fi

_openburnbar_xcode_source_classification_dir="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
OPENBURNBAR_XCODE_REPOSITORY_ROOT="$(
  cd "$_openburnbar_xcode_source_classification_dir/../.." && pwd -P
)"

# SwiftPM asks Git for the current tag of local packages. Those package
# directories intentionally are not nested repositories, so Git must stop at
# the source root instead of walking into the parent OpenBurnBar worktree. The
# latter can block while opening shared worktree refs before Xcode reaches
# compilation. The ceiling still allows Git invoked at the repository root to
# use that repository directly.
export GIT_CEILING_DIRECTORIES="$OPENBURNBAR_XCODE_REPOSITORY_ROOT"

# shellcheck source=scripts/lib/googlesignin-macos-compat.sh
source "$_openburnbar_xcode_source_classification_dir/googlesignin-macos-compat.sh"
OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_XCCONFIG="$_openburnbar_xcode_source_classification_dir/xcode-source-classification.xcconfig"
# shellcheck disable=SC2034  # Public array consumed by scripts that source this file.
OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS=(
  -xcconfig
  "$OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_XCCONFIG"
)
unset _openburnbar_xcode_source_classification_dir

openburnbar_configure_xcode_process_tmpdir() {
  local process_tmp_root="${1:-${OPENBURNBAR_XCODE_PROCESS_TMPDIR:-/tmp}}"
  if [[ -z "$process_tmp_root" ]]; then
    echo "Xcode process TMPDIR cannot be empty." >&2
    return 1
  fi
  mkdir -p "$process_tmp_root"
  if [[ ! -d "$process_tmp_root" || ! -w "$process_tmp_root" ]]; then
    echo "Xcode process TMPDIR is not writable: $process_tmp_root" >&2
    return 1
  fi
  export TMPDIR="${process_tmp_root%/}/"
}
