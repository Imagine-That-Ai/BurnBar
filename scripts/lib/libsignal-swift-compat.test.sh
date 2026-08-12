#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source "$repo_root/scripts/lib/libsignal-swift-compat.sh"

fixture_root="$(mktemp -d "${OPENBURNBAR_LIBSIGNAL_COMPAT_TMPDIR:-/tmp}/openburnbar-libsignal-compat-test.XXXXXX")"

cleanup() {
  openburnbar_restore_libsignal_swift_compat >/dev/null 2>&1 || true
  rm -rf "$fixture_root"
}
trap cleanup EXIT

libsignal_dir="$fixture_root/Vendor/libsignal"
auth_path="$libsignal_dir/swift/Sources/LibSignalClient/chat/AuthMessagesService.swift"
tokio_path="$libsignal_dir/swift/Sources/LibSignalClient/TokioAsyncContext.swift"
mkdir -p "$(dirname "$auth_path")" "$(dirname "$tokio_path")"

cat >"$auth_path" <<'SWIFT'
func first() {
    extendLifetime(contents)
}
func second() {
    extendLifetime(contents)
}
SWIFT

cat >"$tokio_path" <<'SWIFT'
private final class AsyncBodyHandoff<Promise: PromiseStruct> {}
internal func invokeAsyncFunction<Promise: PromiseStruct>() {}
SWIFT

git -C "$libsignal_dir" init -q
git -C "$libsignal_dir" add .
git -C "$libsignal_dir" \
  -c user.name="OpenBurnBar Fixture" \
  -c user.email="fixture@openburnbar.invalid" \
  commit -qm "fixture"

export OPENBURNBAR_LIBSIGNAL_COMPAT_EXPECTED_COMMIT
OPENBURNBAR_LIBSIGNAL_COMPAT_EXPECTED_COMMIT="$(git -C "$libsignal_dir" rev-parse HEAD)"

auth_original_hash="$(openburnbar_libsignal_compat_sha256 "$auth_path")"
tokio_original_hash="$(openburnbar_libsignal_compat_sha256 "$tokio_path")"

openburnbar_prepare_libsignal_swift_compat "$fixture_root"
rg -qF "withExtendedLifetime(contents) {}" "$auth_path"
rg -qF "<Promise: PromiseStruct & SendableMetatype>" "$tokio_path"
[[ -n "$(git -C "$libsignal_dir" status --porcelain --untracked-files=no)" ]]

openburnbar_restore_libsignal_swift_compat
[[ "$(openburnbar_libsignal_compat_sha256 "$auth_path")" == "$auth_original_hash" ]]
[[ "$(openburnbar_libsignal_compat_sha256 "$tokio_path")" == "$tokio_original_hash" ]]
[[ -z "$(git -C "$libsignal_dir" status --porcelain --untracked-files=no)" ]]

# A trap-style `restore || status=$?` caller must receive a failed low-level
# restoration instead of silently clearing the only recovery coordinates.
openburnbar_prepare_libsignal_swift_compat "$fixture_root"
active_lock="$OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR"
printf '\n// unknown edit during active compatibility window\n' >>"$auth_path"
restore_status=0
openburnbar_restore_libsignal_swift_compat >/dev/null 2>&1 || restore_status=$?
if [[ "$restore_status" -eq 0 ]]; then
  echo "Expected unknown-edit restoration to return a nonzero status." >&2
  exit 1
fi
[[ "$OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE" == "1" ]]
[[ "$OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT" == "$fixture_root" ]]
[[ "$OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR" == "$active_lock" ]]
[[ -d "$active_lock" ]]
rg -qF "// unknown edit during active compatibility window" "$auth_path"

# Put back one of the two checksum-authorized states and prove the retained
# lock can still restore both files and release itself cleanly.
cp -p "$active_lock/staged/AuthMessagesService.swift" "$auth_path"
openburnbar_restore_libsignal_swift_compat
[[ "$OPENBURNBAR_LIBSIGNAL_COMPAT_ACTIVE" == "0" ]]
[[ -z "$OPENBURNBAR_LIBSIGNAL_COMPAT_REPO_ROOT" ]]
[[ -z "$OPENBURNBAR_LIBSIGNAL_COMPAT_LOCK_DIR" ]]
[[ ! -e "$active_lock" ]]
[[ "$(openburnbar_libsignal_compat_sha256 "$auth_path")" == "$auth_original_hash" ]]
[[ "$(openburnbar_libsignal_compat_sha256 "$tokio_path")" == "$tokio_original_hash" ]]
[[ -z "$(git -C "$libsignal_dir" status --porcelain --untracked-files=no)" ]]

# Simulate a hard-killed prior owner: patch in a child shell without cleanup,
# then prove the next prepare recovers that exact known state before proceeding.
bash -c '
  set -euo pipefail
  source "$1"
  export OPENBURNBAR_LIBSIGNAL_COMPAT_EXPECTED_COMMIT="$2"
  openburnbar_prepare_libsignal_swift_compat "$3"
' _ \
  "$repo_root/scripts/lib/libsignal-swift-compat.sh" \
  "$OPENBURNBAR_LIBSIGNAL_COMPAT_EXPECTED_COMMIT" \
  "$fixture_root"

openburnbar_prepare_libsignal_swift_compat "$fixture_root"
openburnbar_restore_libsignal_swift_compat
[[ -z "$(git -C "$libsignal_dir" status --porcelain --untracked-files=no)" ]]

# Unknown edits are never overwritten.
printf '\n// local owner edit\n' >>"$auth_path"
if openburnbar_prepare_libsignal_swift_compat "$fixture_root" >/dev/null 2>&1; then
  echo "Expected dirty-submodule preparation to fail closed." >&2
  exit 1
fi
rg -qF "// local owner edit" "$auth_path"

echo "LibSignal Swift compatibility fixture passed."
