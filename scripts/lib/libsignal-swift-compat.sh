#!/usr/bin/env bash

# Xcode 27 / Swift 6.4 compatibility for the pinned OpenBurnBar libsignal fork.
#
# The public submodule remains pinned to an immutable, remotely available commit.
# Canonical build/test wrappers source this file, acquire an exclusive per-checkout
# lock, apply the two reviewed Swift compatibility edits for the duration of the
# build, and restore the submodule byte-for-byte on every normal exit.
#
# A SIGKILL cannot run an EXIT trap. To keep that failure recoverable, the lock
# contains original files plus precomputed original/patched hashes. The next
# invocation can therefore distinguish a fully or partially applied known patch
# from an unrelated human edit and restore only the known state. Unknown edits
# fail closed and are never overwritten.

OPENBURNBAR_LIBSIGNAL_COMPAT_EXPECTED_COMMIT_DEFAULT="fc81268b27d83be7dd961a2ccd5e0f5fed554188"
OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE="${OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE:-0}"
OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT="${OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT:-}"
OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR="${OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR:-}"

openburnbar_libsignal_compat_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

openburnbar_libsignal_compat_lock_dir() {
  local repo_root="$1"
  local repo_fingerprint
  repo_fingerprint="$(
    printf '%s' "$repo_root" \
      | shasum -a 256 \
      | awk '{print substr($1, 1, 20)}'
  )"
  printf '%s/openburnbar-libsignal-swift-compat-%s.lock\n' \
    "${OPENBURNBAR_LIBSIGNAL_COMPAT_TMPDIR:-/tmp}" \
    "$repo_fingerprint"
}

openburnbar_libsignal_compat_read_state_value() {
  local state_path="$1"
  local key="$2"
  awk -F= -v requested_key="$key" '
    $1 == requested_key {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$state_path"
}

openburnbar_libsignal_compat_clear_active_state() {
  OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE=0
  OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT=""
  OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR=""
}

openburnbar_libsignal_compat_restore_lock() {
  local repo_root="$1"
  local lock_dir="$2"
  local libsignal_dir="$repo_root/Vendor/libsignal"
  local auth_relative="swift/Sources/LibSignalClient/chat/AuthMessagesService.swift"
  local tokio_relative="swift/Sources/LibSignalClient/TokioAsyncContext.swift"
  local auth_path="$libsignal_dir/$auth_relative"
  local tokio_path="$libsignal_dir/$tokio_relative"
  local state_path="$lock_dir/state"
  local backup_dir="$lock_dir/backup"

  if [[ ! -f "$state_path" \
    || ! -f "$backup_dir/AuthMessagesService.swift" \
    || ! -f "$backup_dir/TokioAsyncContext.swift" ]]
  then
    # Preparation writes the complete state file before touching either source
    # file. A process that died earlier therefore leaves a clean submodule and
    # an incomplete lock that is safe to discard.
    if [[ -z "$(
      env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
        git -C "$libsignal_dir" status --porcelain --untracked-files=no
    )" ]]; then
      rm -rf "$lock_dir"
      return 0
    fi
    echo "LibSignal compatibility lock is incomplete and cannot be recovered safely: $lock_dir" >&2
    return 1
  fi

  local recorded_repo_root
  recorded_repo_root="$(openburnbar_libsignal_compat_read_state_value "$state_path" repo_root)"
  if [[ "$recorded_repo_root" != "$repo_root" ]]; then
    echo "LibSignal compatibility lock belongs to a different checkout: ${recorded_repo_root:-<missing>}" >&2
    return 1
  fi

  local auth_original_hash auth_patched_hash tokio_original_hash tokio_patched_hash
  auth_original_hash="$(openburnbar_libsignal_compat_read_state_value "$state_path" auth_original_sha256)"
  auth_patched_hash="$(openburnbar_libsignal_compat_read_state_value "$state_path" auth_patched_sha256)"
  tokio_original_hash="$(openburnbar_libsignal_compat_read_state_value "$state_path" tokio_original_sha256)"
  tokio_patched_hash="$(openburnbar_libsignal_compat_read_state_value "$state_path" tokio_patched_sha256)"

  local auth_current_hash tokio_current_hash
  auth_current_hash="$(openburnbar_libsignal_compat_sha256 "$auth_path")"
  tokio_current_hash="$(openburnbar_libsignal_compat_sha256 "$tokio_path")"

  case "$auth_current_hash" in
    "$auth_original_hash"|"$auth_patched_hash") ;;
    *)
      echo "Refusing to overwrite an unknown AuthMessagesService.swift edit while recovering $lock_dir" >&2
      return 1
      ;;
  esac
  case "$tokio_current_hash" in
    "$tokio_original_hash"|"$tokio_patched_hash") ;;
    *)
      echo "Refusing to overwrite an unknown TokioAsyncContext.swift edit while recovering $lock_dir" >&2
      return 1
      ;;
  esac

  cp -p "$backup_dir/AuthMessagesService.swift" "$auth_path"
  cp -p "$backup_dir/TokioAsyncContext.swift" "$tokio_path"

  if [[ "$(openburnbar_libsignal_compat_sha256 "$auth_path")" != "$auth_original_hash" \
    || "$(openburnbar_libsignal_compat_sha256 "$tokio_path")" != "$tokio_original_hash" ]]
  then
    echo "LibSignal compatibility restoration did not reproduce the original source hashes." >&2
    return 1
  fi

  local dirty
  dirty="$(
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      git -C "$libsignal_dir" status --porcelain --untracked-files=no
  )"
  if [[ -n "$dirty" ]]; then
    echo "LibSignal submodule is still dirty after compatibility restoration:" >&2
    printf '%s\n' "$dirty" >&2
    return 1
  fi

  rm -rf "$lock_dir"
}

openburnbar_libsignal_compat_acquire_lock() {
  local repo_root="$1"
  local lock_dir="$2"
  local wait_seconds="${OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_WAIT_SECONDS:-300}"
  local deadline=$((SECONDS + wait_seconds))
  local owner_pid=""

  while ! mkdir "$lock_dir" 2>/dev/null; do
    owner_pid=""
    if [[ -f "$lock_dir/pid" ]]; then
      owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    fi

    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      echo "Recovering interrupted LibSignal compatibility state from pid $owner_pid." >&2
      openburnbar_libsignal_compat_restore_lock "$repo_root" "$lock_dir"
      continue
    fi

    if ((SECONDS >= deadline)); then
      echo "Timed out after ${wait_seconds}s waiting for LibSignal compatibility lock $lock_dir (pid ${owner_pid:-unknown})." >&2
      return 1
    fi
    sleep 0.2
  done

  printf '%s\n' "${BASHPID:-$$}" >"$lock_dir/pid"
}

openburnbar_prepare_libsignal_swift_compat() {
  local repo_root="$1"
  local libsignal_dir="$repo_root/Vendor/libsignal"
  local auth_relative="swift/Sources/LibSignalClient/chat/AuthMessagesService.swift"
  local tokio_relative="swift/Sources/LibSignalClient/TokioAsyncContext.swift"
  local auth_path="$libsignal_dir/$auth_relative"
  local tokio_path="$libsignal_dir/$tokio_relative"

  if ((OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE)); then
    if [[ "$OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT" != "$repo_root" ]]; then
      echo "LibSignal compatibility is already active for a different checkout." >&2
      return 1
    fi
    return 0
  fi

  if [[ ! -f "$auth_path" || ! -f "$tokio_path" ]]; then
    echo "Pinned LibSignal Swift sources are missing under $libsignal_dir" >&2
    return 1
  fi

  local expected_commit
  expected_commit="${OPENBURNBAR_LIBSIGNAL_COMPAT_EXPECTED_COMMIT:-$OPENBURNBAR_LIBSIGNAL_COMPAT_EXPECTED_COMMIT_DEFAULT}"
  local actual_commit
  actual_commit="$(
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      git -C "$libsignal_dir" rev-parse HEAD
  )"
  if [[ "$expected_commit" != "any" && "$actual_commit" != "$expected_commit" ]]; then
    echo "LibSignal compatibility patch is reviewed for $expected_commit, found $actual_commit." >&2
    return 1
  fi

  local lock_dir
  lock_dir="$(openburnbar_libsignal_compat_lock_dir "$repo_root")"
  openburnbar_libsignal_compat_acquire_lock "$repo_root" "$lock_dir"
  OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE=1
  OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT="$repo_root"
  OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR="$lock_dir"

  local dirty
  dirty="$(
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      git -C "$libsignal_dir" status --porcelain --untracked-files=no
  )"
  if [[ -n "$dirty" ]]; then
    echo "Refusing to patch a dirty LibSignal submodule:" >&2
    printf '%s\n' "$dirty" >&2
    rm -rf "$lock_dir"
    openburnbar_libsignal_compat_clear_active_state
    return 1
  fi

  local backup_dir="$lock_dir/backup"
  local staged_dir="$lock_dir/staged"
  mkdir -p "$backup_dir" "$staged_dir"
  cp -p "$auth_path" "$backup_dir/AuthMessagesService.swift"
  cp -p "$tokio_path" "$backup_dir/TokioAsyncContext.swift"
  cp -p "$auth_path" "$staged_dir/AuthMessagesService.swift"
  cp -p "$tokio_path" "$staged_dir/TokioAsyncContext.swift"

  local patch_status=0
  python3 - \
    "$staged_dir/AuthMessagesService.swift" \
    "$staged_dir/TokioAsyncContext.swift" <<'PY' || patch_status=$?
from pathlib import Path
import sys

auth_path = Path(sys.argv[1])
tokio_path = Path(sys.argv[2])

auth = auth_path.read_text(encoding="utf-8")
auth_old = "extendLifetime(contents)"
auth_new = "withExtendedLifetime(contents) {}"
if auth.count(auth_old) != 2 or auth_new in auth:
    raise SystemExit(
        "AuthMessagesService.swift no longer matches the reviewed two-site compatibility patch"
    )
auth_path.write_text(auth.replace(auth_old, auth_new), encoding="utf-8")

tokio = tokio_path.read_text(encoding="utf-8")
tokio_old = "<Promise: PromiseStruct>"
tokio_new = "<Promise: PromiseStruct & SendableMetatype>"
if tokio.count(tokio_old) != 2 or tokio_new in tokio:
    raise SystemExit(
        "TokioAsyncContext.swift no longer matches the reviewed two-site metatype patch"
    )
tokio_path.write_text(tokio.replace(tokio_old, tokio_new), encoding="utf-8")
PY
  if ((patch_status != 0)); then
    rm -rf "$lock_dir"
    openburnbar_libsignal_compat_clear_active_state
    return "$patch_status"
  fi

  local auth_original_hash auth_patched_hash tokio_original_hash tokio_patched_hash
  auth_original_hash="$(openburnbar_libsignal_compat_sha256 "$backup_dir/AuthMessagesService.swift")"
  auth_patched_hash="$(openburnbar_libsignal_compat_sha256 "$staged_dir/AuthMessagesService.swift")"
  tokio_original_hash="$(openburnbar_libsignal_compat_sha256 "$backup_dir/TokioAsyncContext.swift")"
  tokio_patched_hash="$(openburnbar_libsignal_compat_sha256 "$staged_dir/TokioAsyncContext.swift")"

  {
    printf 'repo_root=%s\n' "$repo_root"
    printf 'libsignal_commit=%s\n' "$actual_commit"
    printf 'auth_original_sha256=%s\n' "$auth_original_hash"
    printf 'auth_patched_sha256=%s\n' "$auth_patched_hash"
    printf 'tokio_original_sha256=%s\n' "$tokio_original_hash"
    printf 'tokio_patched_sha256=%s\n' "$tokio_patched_hash"
  } >"$lock_dir/state"

  cp -p "$staged_dir/AuthMessagesService.swift" "$auth_path"
  cp -p "$staged_dir/TokioAsyncContext.swift" "$tokio_path"

  if [[ "$(openburnbar_libsignal_compat_sha256 "$auth_path")" != "$auth_patched_hash" \
    || "$(openburnbar_libsignal_compat_sha256 "$tokio_path")" != "$tokio_patched_hash" ]]
  then
    openburnbar_libsignal_compat_restore_lock "$repo_root" "$lock_dir" || true
    echo "LibSignal compatibility patch did not reproduce the reviewed hashes." >&2
    return 1
  fi

}

openburnbar_restore_libsignal_swift_compat() {
  if ((!OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE)); then
    return 0
  fi

  local repo_root="$OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT"
  local lock_dir="$OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR"
  local restore_status=0
  openburnbar_libsignal_compat_restore_lock "$repo_root" "$lock_dir" \
    || restore_status=$?
  if ((restore_status == 0)); then
    openburnbar_libsignal_compat_clear_active_state
  fi
  return "$restore_status"
}
