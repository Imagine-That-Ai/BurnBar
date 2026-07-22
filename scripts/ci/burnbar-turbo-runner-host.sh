#!/bin/bash

set -euo pipefail
umask 077

readonly EXPECTED_REPOSITORY="Imagine-That-Ai/BurnBar"
readonly RUNNER_GROUP="burnbar-turbo-ephemeral"
readonly BASE_VM="burnbar-ci-xcode-26.5"
readonly BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:61f6e857a3d65dd2f8daf9c51c7b837fa458bcc9181ae8556e645b534dab6bf6"
readonly RUNNER_VERSION="2.336.0"
readonly RUNNER_SHA256="8e8839c49b7060b6b2154f4931f815df330c27f167d53ef2239ee3dfce28b079"

profile=""
slot=""
continuous="false"
log_root="${BURNBAR_TURBO_LOG_ROOT:-$HOME/Library/Logs/BurnBarTurbo}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guest_setup_script="$script_dir/burnbar-turbo-runner-guest.sh"
vm_name=""
vm_pid=""
lock_dir=""

usage() {
  cat <<'USAGE'
Usage: scripts/ci/burnbar-turbo-runner-host.sh --profile m4|m5 --slot N [--continuous]

Runs one disposable BurnBar GitHub Actions worker at a time. The physical host
keeps the GitHub credential; the guest receives only a short-lived runner
registration token over stdin. The guest has no host mounts and is destroyed
after exactly one job.
USAGE
}

die() {
  printf 'burnbar-turbo: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --profile)
      (($# >= 2)) || die "--profile requires m4 or m5"
      profile="$2"
      shift 2
      ;;
    --slot)
      (($# >= 2)) || die "--slot requires a positive integer"
      slot="$2"
      shift 2
      ;;
    --continuous)
      continuous="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$profile" in
  m4)
    [[ "$slot" == "1" ]] || die "the M4 profile supports only --slot 1"
    runner_labels="burnbar-turbo,m4-pro"
    ;;
  m5)
    [[ "$slot" == "1" || "$slot" == "2" ]] || die "the M5 profile supports --slot 1 or 2"
    runner_labels="burnbar-turbo,m5-max"
    ;;
  *)
    die "--profile must be m4 or m5"
    ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || die "runner hosts must be macOS"
[[ "$(uname -m)" == "arm64" ]] || die "runner hosts must be Apple silicon"
command -v tart >/dev/null 2>&1 || die "Tart is required"
command -v gh >/dev/null 2>&1 || die "GitHub CLI is required on the physical host"
[[ -f "$guest_setup_script" ]] || die "guest setup script is missing: $guest_setup_script"

actual_repository="$(gh repo view "$EXPECTED_REPOSITORY" --json nameWithOwner --jq .nameWithOwner)"
[[ "$actual_repository" == "$EXPECTED_REPOSITORY" ]] || die "authenticated GitHub account cannot inspect $EXPECTED_REPOSITORY"

if ! tart list -q --source local | grep -Fxq "$BASE_VM"; then
  die "base VM $BASE_VM is missing; clone and provision $BASE_IMAGE first"
fi

softnet_path="$(command -v softnet || true)"
[[ -n "$softnet_path" ]] || die "Softnet is required"
softnet_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$softnet_path")"
softnet_owner="$(stat -f '%u' "$softnet_path")"
# macOS %OLp reports only the ordinary permission bits and drops setuid. Use
# the full numeric mode so the 04000 trust bit is actually observable.
softnet_mode="$(stat -f '%p' "$softnet_path")"
if [[ "$softnet_owner" != "0" ]] || ! (( (0$softnet_mode & 04000) != 0 )); then
  die "Softnet is not root-owned setuid; run: sudo chown root '$softnet_path' && sudo chmod u+s '$softnet_path'"
fi

mkdir -p "$log_root" "${TART_HOME:-$HOME/.tart}/locks"
lock_dir="${TART_HOME:-$HOME/.tart}/locks/burnbar-${profile}-${slot}.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  die "worker $profile/$slot already has an active controller lock"
fi

cleanup_vm() {
  local cleanup_name="$vm_name"
  local cleanup_pid="$vm_pid"

  if [[ -n "$cleanup_name" ]] && tart list -q --source local | grep -Fxq "$cleanup_name"; then
    tart exec "$cleanup_name" /usr/bin/sudo /sbin/shutdown -h now >/dev/null 2>&1 || true
    if [[ -n "$cleanup_pid" ]]; then
      local attempt
      for ((attempt = 1; attempt <= 20; attempt += 1)); do
        if ! kill -0 "$cleanup_pid" 2>/dev/null; then
          break
        fi
        sleep 1
      done
      if kill -0 "$cleanup_pid" 2>/dev/null; then
        tart stop "$cleanup_name" >/dev/null 2>&1 || true
      fi
      wait "$cleanup_pid" 2>/dev/null || true
    fi
    tart delete "$cleanup_name"
  fi
  vm_name=""
  vm_pid=""
}

cleanup_all() {
  cleanup_vm
  if [[ -n "$lock_dir" ]]; then
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}

trap cleanup_all EXIT
trap 'exit 130' INT TERM

wait_for_guest() {
  local attempt
  for ((attempt = 1; attempt <= 120; attempt += 1)); do
    if tart exec "$vm_name" /usr/bin/true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

archive_diagnostics() {
  local archive_dir="$log_root/$profile-$slot"
  local archive_path="$archive_dir/${vm_name}.tgz"
  mkdir -p "$archive_dir"
  if tart exec "$vm_name" /usr/bin/tar -C /Users/admin/actions-runner -czf /tmp/burnbar-runner-diag.tgz _diag >/dev/null 2>&1; then
    tart exec "$vm_name" /bin/cat /tmp/burnbar-runner-diag.tgz > "$archive_path"
    chmod 600 "$archive_path"
  else
    printf 'burnbar-turbo: runner diagnostics unavailable for %s\n' "$vm_name" >&2
  fi
}

run_worker() {
  local run_stamp registration_token runner_exit
  run_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  vm_name="burnbar-${profile}-${slot}-${run_stamp}-$$"
  runner_exit=0

  tart clone "$BASE_VM" "$vm_name"
  tart run --no-graphics --net-softnet "$vm_name" > "$log_root/${vm_name}.vm.log" 2>&1 &
  vm_pid="$!"
  wait_for_guest || die "guest $vm_name did not become ready within 120 seconds"

  tart exec "$vm_name" /bin/zsh -lc '
    set -euo pipefail
    source "$HOME/.zprofile"
    test "$(uname -m)" = arm64
    xcodebuild -version
    protoc --version
    rustc --version
  '

  registration_token="$(gh api --method POST "/orgs/Imagine-That-Ai/actions/runners/registration-token" --jq .token)"
  [[ -n "$registration_token" ]] || die "GitHub returned an empty runner registration token"

  tart exec -i "$vm_name" /bin/bash -c \
    'umask 077; /bin/cat > /tmp/burnbar-turbo-runner-guest.sh; /bin/chmod 700 /tmp/burnbar-turbo-runner-guest.sh' \
    < "$guest_setup_script"
  printf '%s\n' "$registration_token" | tart exec -i "$vm_name" \
    /tmp/burnbar-turbo-runner-guest.sh \
    "$EXPECTED_REPOSITORY" "$RUNNER_GROUP" "$runner_labels" "$profile" "$slot" \
    "$RUNNER_VERSION" "$RUNNER_SHA256"
  unset registration_token

  tart exec "$vm_name" /bin/zsh -lc 'source "$HOME/.zprofile"; cd "$HOME/actions-runner"; ./run.sh' || runner_exit="$?"
  archive_diagnostics
  cleanup_vm

  if [[ "$runner_exit" != "0" ]]; then
    printf 'burnbar-turbo: runner exited with status %s\n' "$runner_exit" >&2
    return "$runner_exit"
  fi
}

while true; do
  run_worker
  if [[ "$continuous" != "true" ]]; then
    break
  fi
done
