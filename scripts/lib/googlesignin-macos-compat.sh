#!/usr/bin/env bash

# Xcode 27 compatibility for GoogleSignIn 8.0.0's macOS module import.
#
# GoogleSignIn.h conditionally imports two public headers whose contents are
# already protected by the same platform checks. Xcode 27 evaluates the
# umbrella after preprocessing when a Swift target imports the module on
# macOS, so it reports both headers as omitted umbrella members.
#
# Canonical Xcode entrypoints resolve the pinned package first, acquire an
# exclusive lock for that shared package cache, make the umbrella imports
# unconditional for the duration of the build, and restore the checkout
# byte-for-byte on exit. The package API remains unchanged on every platform
# because the imported headers retain their own platform guards.
#
# A SIGKILL cannot run an EXIT trap. The lock therefore stores the original
# header and the reviewed original/patched hashes. A later invocation may
# recover only those known states; unknown edits fail closed.

OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_EXPECTED_COMMIT_DEFAULT="65fb3f1aa6ffbfdc79c4e22178a55cd91561f5e9"
OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ORIGINAL_SHA256_DEFAULT="cb46fbe32639d27db6f8ba9eaaa457525a407816f82265050da211821dadecbd"
OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_PATCHED_SHA256_DEFAULT="ff4060c31e9770fc45d2a276d794543aac3adf06ecd29036336dee2484ac9026"
OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ACTIVE="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ACTIVE:-0}"
OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_CACHE_DIR="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_CACHE_DIR:-}"
OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_DIR="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_DIR:-}"

openburnbar_google_sign_in_compat_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

openburnbar_google_sign_in_compat_canonical_dir() {
  local path="$1"
  (
    cd "$path" || return 1
    pwd -P
  )
}

openburnbar_google_sign_in_compat_checkout_dir() {
  local cache_dir="$1"
  printf '%s/checkouts/GoogleSignIn-iOS\n' "$cache_dir"
}

openburnbar_google_sign_in_compat_header_path() {
  local checkout_dir="$1"
  printf '%s/GoogleSignIn/Sources/Public/GoogleSignIn/GoogleSignIn.h\n' "$checkout_dir"
}

openburnbar_google_sign_in_compat_lock_dir() {
  local cache_dir="$1"
  local cache_fingerprint
  cache_fingerprint="$(
    printf '%s' "$cache_dir" \
      | shasum -a 256 \
      | awk '{print substr($1, 1, 20)}'
  )"
  printf '%s/openburnbar-googlesignin-macos-compat-%s.lock\n' \
    "${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_TMPDIR:-/tmp}" \
    "$cache_fingerprint"
}

openburnbar_google_sign_in_compat_read_state_value() {
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

openburnbar_google_sign_in_compat_clear_active_state() {
  OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ACTIVE=0
  OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_CACHE_DIR=""
  OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_DIR=""
}

openburnbar_google_sign_in_compat_restore_lock() {
  local cache_dir="$1"
  local lock_dir="$2"
  local checkout_dir
  checkout_dir="$(openburnbar_google_sign_in_compat_checkout_dir "$cache_dir")"
  local header_path
  header_path="$(openburnbar_google_sign_in_compat_header_path "$checkout_dir")"
  local state_path="$lock_dir/state"
  local backup_path="$lock_dir/backup/GoogleSignIn.h"

  if [[ ! -f "$state_path" || ! -f "$backup_path" ]]; then
    # Preparation writes the complete state before touching the checkout. A
    # process that died earlier leaves a clean package and a discardable lock.
    if [[ -d "$checkout_dir" \
      && -z "$(
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
          git -C "$checkout_dir" status --porcelain --untracked-files=no
      )" ]]
    then
      rm -rf "$lock_dir"
      return 0
    fi
    echo "GoogleSignIn compatibility lock is incomplete and cannot be recovered safely: $lock_dir" >&2
    return 1
  fi

  local recorded_cache_dir
  recorded_cache_dir="$(
    openburnbar_google_sign_in_compat_read_state_value "$state_path" cache_dir
  )"
  if [[ "$recorded_cache_dir" != "$cache_dir" ]]; then
    echo "GoogleSignIn compatibility lock belongs to a different package cache: ${recorded_cache_dir:-<missing>}" >&2
    return 1
  fi

  local original_hash patched_hash current_hash
  original_hash="$(
    openburnbar_google_sign_in_compat_read_state_value "$state_path" original_sha256
  )"
  patched_hash="$(
    openburnbar_google_sign_in_compat_read_state_value "$state_path" patched_sha256
  )"
  current_hash="$(openburnbar_google_sign_in_compat_sha256 "$header_path")"

  case "$current_hash" in
    "$original_hash"|"$patched_hash") ;;
    *)
      echo "Refusing to overwrite an unknown GoogleSignIn.h edit while recovering $lock_dir" >&2
      return 1
      ;;
  esac

  # SwiftPM may materialize package sources read-only. Recovery must work both
  # after the reviewed patch was installed and after a process died between
  # writing the lock state and touching the checkout.
  if ! chmod u+w "$header_path"; then
    echo "GoogleSignIn compatibility restoration could not make the umbrella header writable." >&2
    return 1
  fi
  cp -p "$backup_path" "$header_path"
  if [[ "$(openburnbar_google_sign_in_compat_sha256 "$header_path")" != "$original_hash" ]]; then
    echo "GoogleSignIn compatibility restoration did not reproduce the original header hash." >&2
    return 1
  fi

  local dirty
  dirty="$(
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      git -C "$checkout_dir" status --porcelain --untracked-files=no
  )"
  if [[ -n "$dirty" ]]; then
    echo "GoogleSignIn checkout is still dirty after compatibility restoration:" >&2
    printf '%s\n' "$dirty" >&2
    return 1
  fi

  rm -rf "$lock_dir"
}

openburnbar_google_sign_in_compat_acquire_lock() {
  local cache_dir="$1"
  local lock_dir="$2"
  local wait_seconds="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_WAIT_SECONDS:-300}"
  local deadline=$((SECONDS + wait_seconds))
  local owner_pid=""

  while ! mkdir "$lock_dir" 2>/dev/null; do
    owner_pid=""
    if [[ -f "$lock_dir/pid" ]]; then
      owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    fi

    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      echo "Recovering interrupted GoogleSignIn compatibility state from pid $owner_pid." >&2
      openburnbar_google_sign_in_compat_restore_lock "$cache_dir" "$lock_dir"
      continue
    fi

    if ((SECONDS >= deadline)); then
      echo "Timed out after ${wait_seconds}s waiting for GoogleSignIn compatibility lock $lock_dir (pid ${owner_pid:-unknown})." >&2
      return 1
    fi
    sleep 0.2
  done

  printf '%s\n' "${BASHPID:-$$}" >"$lock_dir/pid"
}

openburnbar_prepare_google_sign_in_macos_compat() {
  local requested_cache_dir="$1"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi
  if [[ ! -d "$requested_cache_dir" ]]; then
    echo "GoogleSignIn compatibility requires a resolved package cache at $requested_cache_dir" >&2
    return 1
  fi

  local cache_dir
  cache_dir="$(openburnbar_google_sign_in_compat_canonical_dir "$requested_cache_dir")"
  local checkout_dir
  checkout_dir="$(openburnbar_google_sign_in_compat_checkout_dir "$cache_dir")"
  local header_path
  header_path="$(openburnbar_google_sign_in_compat_header_path "$checkout_dir")"

  if ((OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ACTIVE)); then
    if [[ "$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_CACHE_DIR" != "$cache_dir" ]]; then
      echo "GoogleSignIn compatibility is already active for a different package cache." >&2
      return 1
    fi
    return 0
  fi

  if [[ ! -d "$checkout_dir" || ! -f "$header_path" ]]; then
    echo "Pinned GoogleSignIn sources are missing under $checkout_dir; resolve packages before preparing compatibility." >&2
    return 1
  fi

  local expected_commit
  expected_commit="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_EXPECTED_COMMIT:-$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_EXPECTED_COMMIT_DEFAULT}"
  local actual_commit
  actual_commit="$(
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      git -C "$checkout_dir" rev-parse HEAD
  )"
  if [[ "$expected_commit" != "any" && "$actual_commit" != "$expected_commit" ]]; then
    echo "GoogleSignIn compatibility is reviewed for $expected_commit, found $actual_commit." >&2
    return 1
  fi

  local lock_dir
  lock_dir="$(openburnbar_google_sign_in_compat_lock_dir "$cache_dir")"
  openburnbar_google_sign_in_compat_acquire_lock "$cache_dir" "$lock_dir"
  OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ACTIVE=1
  OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_CACHE_DIR="$cache_dir"
  OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_DIR="$lock_dir"

  local dirty
  dirty="$(
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      git -C "$checkout_dir" status --porcelain --untracked-files=no
  )"
  if [[ -n "$dirty" ]]; then
    echo "Refusing to patch a dirty GoogleSignIn checkout:" >&2
    printf '%s\n' "$dirty" >&2
    rm -rf "$lock_dir"
    openburnbar_google_sign_in_compat_clear_active_state
    return 1
  fi

  local expected_original_hash expected_patched_hash
  expected_original_hash="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ORIGINAL_SHA256:-$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ORIGINAL_SHA256_DEFAULT}"
  expected_patched_hash="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_PATCHED_SHA256:-$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_PATCHED_SHA256_DEFAULT}"
  local actual_original_hash
  actual_original_hash="$(openburnbar_google_sign_in_compat_sha256 "$header_path")"
  if [[ "$actual_original_hash" != "$expected_original_hash" ]]; then
    echo "GoogleSignIn.h does not match the reviewed original hash: expected $expected_original_hash, found $actual_original_hash." >&2
    rm -rf "$lock_dir"
    openburnbar_google_sign_in_compat_clear_active_state
    return 1
  fi

  local backup_dir="$lock_dir/backup"
  local staged_dir="$lock_dir/staged"
  mkdir -p "$backup_dir" "$staged_dir"
  cp -p "$header_path" "$backup_dir/GoogleSignIn.h"
  cp -p "$header_path" "$staged_dir/GoogleSignIn.h"
  # Package-manager checkouts can be read-only. Only the private staged copy
  # needs to be writable; the backup retains the exact original mode.
  chmod u+w "$staged_dir/GoogleSignIn.h"

  local patch_status=0
  python3 - "$staged_dir/GoogleSignIn.h" <<'PY' || patch_status=$?
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
replacements = {
    '#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST\n'
    '#import "GIDAppCheckError.h"\n'
    '#endif\n': '#import "GIDAppCheckError.h"\n',
    '#if TARGET_OS_IOS || TARGET_OS_MACCATALYST\n'
    '#import "GIDSignInButton.h"\n'
    '#endif\n': '#import "GIDSignInButton.h"\n',
}
for original, replacement in replacements.items():
    if text.count(original) != 1:
        raise SystemExit(
            "GoogleSignIn.h no longer matches the reviewed two-block umbrella patch"
        )
    text = text.replace(original, replacement)
path.write_text(text, encoding="utf-8")
PY
  if ((patch_status != 0)); then
    rm -rf "$lock_dir"
    openburnbar_google_sign_in_compat_clear_active_state
    return "$patch_status"
  fi

  local staged_hash
  staged_hash="$(openburnbar_google_sign_in_compat_sha256 "$staged_dir/GoogleSignIn.h")"
  if [[ "$staged_hash" != "$expected_patched_hash" ]]; then
    echo "GoogleSignIn compatibility patch produced $staged_hash instead of the reviewed $expected_patched_hash." >&2
    rm -rf "$lock_dir"
    openburnbar_google_sign_in_compat_clear_active_state
    return 1
  fi

  {
    printf 'cache_dir=%s\n' "$cache_dir"
    printf 'googlesignin_commit=%s\n' "$actual_commit"
    printf 'original_sha256=%s\n' "$actual_original_hash"
    printf 'patched_sha256=%s\n' "$staged_hash"
  } >"$lock_dir/state"

  if ! chmod u+w "$header_path"; then
    openburnbar_google_sign_in_compat_restore_lock "$cache_dir" "$lock_dir" || true
    openburnbar_google_sign_in_compat_clear_active_state
    echo "GoogleSignIn compatibility could not make the umbrella header writable." >&2
    return 1
  fi
  cp -p "$staged_dir/GoogleSignIn.h" "$header_path"
  if [[ "$(openburnbar_google_sign_in_compat_sha256 "$header_path")" != "$staged_hash" ]]; then
    openburnbar_google_sign_in_compat_restore_lock "$cache_dir" "$lock_dir" || true
    openburnbar_google_sign_in_compat_clear_active_state
    echo "GoogleSignIn compatibility patch did not reproduce the reviewed hash." >&2
    return 1
  fi
}

openburnbar_restore_google_sign_in_macos_compat() {
  if ((!OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ACTIVE)); then
    return 0
  fi

  local cache_dir="$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_CACHE_DIR"
  local lock_dir="$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_DIR"
  local restore_status=0
  openburnbar_google_sign_in_compat_restore_lock "$cache_dir" "$lock_dir" \
    || restore_status=$?
  if ((restore_status == 0)); then
    openburnbar_google_sign_in_compat_clear_active_state
  fi
  return "$restore_status"
}
