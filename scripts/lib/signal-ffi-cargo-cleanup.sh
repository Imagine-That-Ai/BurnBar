#!/usr/bin/env bash
# Small, fail-closed helpers for opt-in Signal FFI Cargo-target pruning.
#
# This file is sourced by build-signal-ffi-xcframework.sh and is also safe to
# source from deterministic shell tests. It deliberately does not change
# shell options in its caller.

signal_ffi_prune_cargo_target_dir() {
  local cargo_target_root="$1"
  local target="$2"

  if [[ "$cargo_target_root" != /* ]]; then
    echo "Signal FFI Cargo target root must be absolute: ${cargo_target_root}" >&2
    return 64
  fi
  # Target names come from SIGNAL_FFI_BUILD_TARGETS. Reject separators and
  # traversal tokens before constructing a path that will be removed.
  if [[ ! "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$target" == "." || "$target" == ".." ]]; then
    echo "Refusing to prune unsafe Signal FFI target name: ${target}" >&2
    return 64
  fi

  local target_dir="${cargo_target_root}/${target}"
  [[ -d "$target_dir" ]] || return 0
  if [[ -L "$target_dir" ]]; then
    echo "Refusing to prune symlinked Signal FFI target directory: ${target_dir}" >&2
    return 64
  fi

  local canonical_root canonical_target
  canonical_root="$(python3 - "$cargo_target_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
  canonical_target="$(python3 - "$target_dir" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"

  case "$canonical_target" in
    "${canonical_root}/"*) ;;
    *)
      echo "Refusing to prune Signal FFI path outside Cargo target root: ${target_dir}" >&2
      return 64
      ;;
  esac
  [[ "$canonical_target" != "$canonical_root" ]] || {
    echo "Refusing to prune the Signal FFI Cargo target root itself: ${canonical_target}" >&2
    return 64
  }

  rm -rf "$target_dir"
}
