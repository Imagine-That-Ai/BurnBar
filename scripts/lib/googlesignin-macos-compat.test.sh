#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "GoogleSignIn macOS compatibility fixture skipped outside macOS."
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/googlesignin-macos-compat.sh
source "$repo_root/scripts/lib/googlesignin-macos-compat.sh"

fixture_root="$(mktemp -d /tmp/openburnbar-googlesignin-compat-test.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

cache_dir="$fixture_root/cache"
checkout_dir="$cache_dir/checkouts/GoogleSignIn-iOS"
header_dir="$checkout_dir/GoogleSignIn/Sources/Public/GoogleSignIn"
header_path="$header_dir/GoogleSignIn.h"
mkdir -p "$header_dir" "$fixture_root/locks"

cat >"$header_path" <<'EOF'
#import <TargetConditionals.h>

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
#import "GIDAppCheckError.h"
#endif
#import "GIDConfiguration.h"
#if TARGET_OS_IOS || TARGET_OS_MACCATALYST
#import "GIDSignInButton.h"
#endif
EOF
printf 'fixture\n' >"$checkout_dir/README"

git -C "$checkout_dir" init -q
git -C "$checkout_dir" add \
  GoogleSignIn/Sources/Public/GoogleSignIn/GoogleSignIn.h \
  README
git -C "$checkout_dir" \
  -c user.name=OpenBurnBar \
  -c user.email=tests@openburnbar.invalid \
  commit -qm fixture
chmod 0444 "$header_path"

original_copy="$fixture_root/GoogleSignIn.original.h"
cp -p "$header_path" "$original_copy"
original_hash="$(openburnbar_google_sign_in_compat_sha256 "$header_path")"
patched_hash="$(
  python3 - "$header_path" <<'PY' | shasum -a 256 | awk '{print $1}'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
text = text.replace(
    '#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST\n'
    '#import "GIDAppCheckError.h"\n'
    '#endif\n',
    '#import "GIDAppCheckError.h"\n',
)
text = text.replace(
    '#if TARGET_OS_IOS || TARGET_OS_MACCATALYST\n'
    '#import "GIDSignInButton.h"\n'
    '#endif\n',
    '#import "GIDSignInButton.h"\n',
)
sys.stdout.write(text)
PY
)"

export OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_EXPECTED_COMMIT=any
export OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_ORIGINAL_SHA256="$original_hash"
export OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_PATCHED_SHA256="$patched_hash"
export OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_TMPDIR="$fixture_root/locks"

# A parent release may carry an alternate-index Git authority. Nested package
# probes must still resolve the GoogleSignIn checkout itself.
parent_git_dir="$fixture_root/parent.git"
git clone --bare -q "$checkout_dir" "$parent_git_dir"
parent_index="$parent_git_dir/candidate-index"
GIT_DIR="$parent_git_dir" \
GIT_WORK_TREE="$fixture_root" \
GIT_INDEX_FILE="$parent_index" \
  git read-tree HEAD
export GIT_DIR="$parent_git_dir"
export GIT_WORK_TREE="$fixture_root"
export GIT_INDEX_FILE="$parent_index"

# A failed `cd` must not fall through to `pwd -P` and accidentally canonicalize
# the caller's current directory as the requested cache.
canonicalization_caller="$fixture_root/canonicalization-caller"
missing_cache="$fixture_root/does-not-exist"
mkdir -p "$canonicalization_caller"
pushd "$canonicalization_caller" >/dev/null
canonicalization_output=""
canonicalization_status=0
canonicalization_output="$(
  openburnbar_google_sign_in_compat_canonical_dir "$missing_cache" 2>/dev/null
)" || canonicalization_status=$?
popd >/dev/null
if [[ "$canonicalization_status" -eq 0 ]]; then
  echo "Missing GoogleSignIn cache unexpectedly canonicalized successfully." >&2
  exit 1
fi
if [[ -n "$canonicalization_output" ]]; then
  echo "Missing GoogleSignIn cache leaked a fallback canonical path." >&2
  printf '%s\n' "$canonicalization_output" >&2
  exit 1
fi

openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"
if [[ "$(openburnbar_google_sign_in_compat_sha256 "$header_path")" != "$patched_hash" ]]; then
  echo "GoogleSignIn compatibility fixture did not apply the reviewed patch." >&2
  exit 1
fi
has_adjacent_imports() {
  local first_import="$1"
  local second_import="$2"
  local source_path="$3"
  awk -v first="$first_import" -v second="$second_import" '
    previous == first && $0 == second { found = 1 }
    { previous = $0 }
    END { exit found ? 0 : 1 }
  ' "$source_path"
}

if ! has_adjacent_imports \
  '#import "GIDAppCheckError.h"' \
  '#import "GIDConfiguration.h"' \
  "$header_path"; then
  echo "GIDAppCheckError.h was not made an unconditional umbrella import." >&2
  exit 1
fi
if ! has_adjacent_imports \
  '#import "GIDConfiguration.h"' \
  '#import "GIDSignInButton.h"' \
  "$header_path"; then
  echo "GIDSignInButton.h was not made an unconditional umbrella import." >&2
  exit 1
fi
if [[ "$(
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    git -C "$checkout_dir" status --short --untracked-files=no
)" != " M GoogleSignIn/Sources/Public/GoogleSignIn/GoogleSignIn.h" ]]; then
  echo "Compatibility preparation changed more than the reviewed umbrella header." >&2
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    git -C "$checkout_dir" status --short --untracked-files=no >&2
  exit 1
fi

openburnbar_restore_google_sign_in_macos_compat
cmp "$original_copy" "$header_path"
if [[ "$(stat -f '%Lp' "$header_path")" != "444" ]]; then
  echo "GoogleSignIn compatibility did not restore the read-only source mode." >&2
  exit 1
fi
if [[ -n "$(
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    git -C "$checkout_dir" status --porcelain --untracked-files=no
)" ]]; then
  echo "GoogleSignIn checkout was not restored cleanly." >&2
  exit 1
fi

# Simulate a process that died after applying the known patch. The next
# invocation must recover the stale lock before applying its own patch.
openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"
stale_lock="$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_DIR"
printf '99999999\n' >"$stale_lock/pid"
openburnbar_google_sign_in_compat_clear_active_state
openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"
if [[ "$(openburnbar_google_sign_in_compat_sha256 "$header_path")" != "$patched_hash" ]]; then
  echo "Interrupted GoogleSignIn compatibility state was not recovered." >&2
  exit 1
fi
openburnbar_restore_google_sign_in_macos_compat
cmp "$original_copy" "$header_path"

# Simulate a process that died after writing complete recovery state but before
# installing the patch. Recovery must also handle an original, read-only
# checkout file.
openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"
stale_lock="$OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_LOCK_DIR"
cp -p "$original_copy" "$header_path"
printf '99999999\n' >"$stale_lock/pid"
openburnbar_google_sign_in_compat_clear_active_state
openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"
if [[ "$(openburnbar_google_sign_in_compat_sha256 "$header_path")" != "$patched_hash" ]]; then
  echo "Read-only pre-install GoogleSignIn state was not recovered." >&2
  exit 1
fi
openburnbar_restore_google_sign_in_macos_compat
cmp "$original_copy" "$header_path"
if [[ "$(stat -f '%Lp' "$header_path")" != "444" ]]; then
  echo "Read-only recovery did not restore the original source mode." >&2
  exit 1
fi

# Unknown package edits must fail closed without touching the reviewed header.
printf 'dirty\n' >>"$checkout_dir/README"
if openburnbar_prepare_google_sign_in_macos_compat "$cache_dir" 2>/dev/null; then
  echo "Dirty GoogleSignIn checkout was patched instead of rejected." >&2
  exit 1
fi
cmp "$original_copy" "$header_path"
if find "$fixture_root/locks" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  echo "Dirty-checkout rejection left a compatibility lock behind." >&2
  exit 1
fi

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
echo "GoogleSignIn macOS compatibility fixture passed."
