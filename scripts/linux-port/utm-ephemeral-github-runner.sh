#!/bin/bash

set -euo pipefail
umask 077

readonly EXPECTED_REPOSITORY="Imagine-That-Ai/BurnBar"
readonly EXPECTED_ENVIRONMENT="ubuntu-24.04-gnome-x11-aarch64"
readonly EXPECTED_VM_NAME="OpenBurnBar Linux"
readonly EXPECTED_VM_UUID="7923D0DD-6367-45EA-9064-152EECC1AC65"
readonly DEFAULT_SSH_HOST="127.0.0.1"
readonly DEFAULT_SSH_USER="burnbar"
readonly DEFAULT_SSH_KEY="$HOME/.ssh/openburnbar_linux_vm"
readonly DEFAULT_KNOWN_HOSTS="$HOME/.ssh/known_hosts"
readonly DEFAULT_SSH_PORT="2222"
readonly GUEST_SCRIPT_SHA256="cc29dceac54115f1db08487630c03e9ef5ad7a4f47688b806ce2ad9f3aa899c3"
readonly REMOTE_HELPER_PATH="\$HOME/.cache/openburnbar-utm-runner/guest.sh"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guest_script="$script_dir/utm-ephemeral-github-runner-guest.sh"
operation=""
vm_id=""
environment_id=""
ssh_host="$DEFAULT_SSH_HOST"
ssh_user="$DEFAULT_SSH_USER"
ssh_key="$DEFAULT_SSH_KEY"
known_hosts="$DEFAULT_KNOWN_HOSTS"
ssh_port="$DEFAULT_SSH_PORT"
short_lived_token=""
helper_staged="false"
runner_name="burnbar-utm-$EXPECTED_ENVIRONMENT"
declare -a ssh_options=()

usage() {
  cat <<'USAGE'
Usage:
  scripts/linux-port/utm-ephemeral-github-runner.sh start \
    --vm "OpenBurnBar Linux"|7923D0DD-6367-45EA-9064-152EECC1AC65 \
    --environment ubuntu-24.04-gnome-x11-aarch64 \
    [--ssh-host HOST] [--ssh-user USER] [--ssh-key PATH] \
    [--known-hosts PATH] [--ssh-port PORT]

  scripts/linux-port/utm-ephemeral-github-runner.sh teardown [same options]

The VM must already be running. This controller never starts or resumes UTM.
It obtains a repository-scoped short-lived registration/removal token only
after the host, SSH, guest identity, and graphical-session preflights pass.
USAGE
}

die() {
  printf 'openburnbar-utm-runner: %s\n' "$*" >&2
  exit 1
}

expand_home_path() {
  case "$1" in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${1:2}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

assert_trusted_host_file() {
  local path="$1"
  local label="$2"
  local check_parents="${3:-true}"
  local secret_file="${4:-true}"

  python3 - "$path" "$label" "$(id -u)" "$check_parents" "$secret_file" <<'PY'
import os
import stat
import sys

path, label, expected_uid, check_parents, secret_file = (
    sys.argv[1],
    sys.argv[2],
    int(sys.argv[3]),
    sys.argv[4] == "true",
    sys.argv[5] == "true",
)
if not os.path.isabs(path):
    raise SystemExit(f"{label} must be an absolute path")
lexical = os.path.abspath(path)
if lexical != path:
    raise SystemExit(f"{label} must be lexically canonical")
if os.path.realpath(path) != lexical:
    raise SystemExit(f"{label} path must not contain symlinks")
info = os.lstat(path)
if not stat.S_ISREG(info.st_mode):
    raise SystemExit(f"{label} must be a regular file")
if info.st_uid != expected_uid:
    raise SystemExit(f"{label} must be owned by the invoking user")
forbidden_mode = 0o077 if secret_file else 0o022
if stat.S_IMODE(info.st_mode) & forbidden_mode:
    access = "accessible by" if secret_file else "writable by"
    raise SystemExit(f"{label} must not be {access} group or world")

if check_parents:
    parent = os.path.dirname(path)
    while parent != os.path.dirname(parent):
        parent_info = os.lstat(parent)
        if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode):
            raise SystemExit(f"{label} parent path is not a trusted directory")
        if stat.S_IMODE(parent_info.st_mode) & 0o022:
            raise SystemExit(f"{label} parent directory is group/world writable: {parent}")
        parent = os.path.dirname(parent)
PY
}

validate_arguments() {
  [[ "$operation" == "start" || "$operation" == "teardown" ]] \
    || die "operation must be start or teardown"
  [[ "$vm_id" == "$EXPECTED_VM_NAME" || "$vm_id" == "$EXPECTED_VM_UUID" ]] \
    || die "VM must be the documented OpenBurnBar Linux name or UUID"
  [[ "$environment_id" == "$EXPECTED_ENVIRONMENT" ]] \
    || die "unsupported canonical environment id: $environment_id"
  [[ "$ssh_host" =~ ^([A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|[0-9A-Fa-f:]+)$ ]] \
    || die "SSH host is invalid"
  [[ "$ssh_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SSH user is invalid"
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || die "SSH port must be numeric"
  ((ssh_port >= 1 && ssh_port <= 65535)) || die "SSH port is out of range"
}

cleanup_helper() {
  local cleanup_command
  [[ "$helper_staged" == "true" ]] || return 0
  cleanup_command='
set -euo pipefail
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
target="$HOME/.cache/openburnbar-utm-runner/guest.sh"
base="$HOME/.cache/openburnbar-utm-runner"
uid="$(id -u)"
if [[ -e "$target" || -L "$target" ]]; then
  [[ -f "$target" && ! -L "$target" && "$(stat -c "%u" "$target")" == "$uid" ]] || exit 1
  mode="$(stat -c "%a" "$target")"
  (( (8#$mode & 8#022) == 0 )) || exit 1
  rm -f "$target"
fi
if [[ -d "$base" && ! -L "$base" && "$(stat -c "%u" "$base")" == "$uid" ]]; then
  rmdir "$base" 2>/dev/null || true
fi
'
  ssh "${ssh_options[@]}" "$ssh_user@$ssh_host" "$cleanup_command" \
    </dev/null >/dev/null 2>&1 || true
  helper_staged="false"
}

cleanup_all() {
  short_lived_token=""
  unset short_lived_token
  cleanup_helper
}

stage_guest_helper() {
  local install_command
  install_command="
set -euo pipefail
umask 077
PATH=\"/usr/sbin:/usr/bin:/sbin:/bin\"
export PATH
uid=\"\$(id -u)\"
home=\"\$(getent passwd \"\$uid\" | cut -d: -f6)\"
[[ \"\$HOME\" == \"\$home\" && \"\$uid\" != 0 ]]
[[ -d \"\$HOME\" && ! -L \"\$HOME\" && \"\$(stat -c '%u' \"\$HOME\")\" == \"\$uid\" ]]
home_mode=\"\$(stat -c '%a' \"\$HOME\")\"
(( (8#\$home_mode & 8#022) == 0 ))
cache=\"\$HOME/.cache\"
if [[ ! -e \"\$cache\" && ! -L \"\$cache\" ]]; then install -d -m 700 \"\$cache\"; fi
[[ -d \"\$cache\" && ! -L \"\$cache\" && \"\$(stat -c '%u' \"\$cache\")\" == \"\$uid\" ]]
cache_mode=\"\$(stat -c '%a' \"\$cache\")\"
(( (8#\$cache_mode & 8#022) == 0 ))
base=\"\$cache/openburnbar-utm-runner\"
if [[ ! -e \"\$base\" && ! -L \"\$base\" ]]; then install -d -m 700 \"\$base\"; fi
[[ -d \"\$base\" && ! -L \"\$base\" && \"\$(stat -c '%u' \"\$base\")\" == \"\$uid\" ]]
base_mode=\"\$(stat -c '%a' \"\$base\")\"
(( (8#\$base_mode & 8#022) == 0 ))
target=\"\$base/guest.sh\"
if [[ -e \"\$target\" || -L \"\$target\" ]]; then
  [[ -f \"\$target\" && ! -L \"\$target\" && \"\$(stat -c '%u' \"\$target\")\" == \"\$uid\" ]]
  target_mode=\"\$(stat -c '%a' \"\$target\")\"
  (( (8#\$target_mode & 8#022) == 0 ))
  printf '%s  %s\n' '$GUEST_SCRIPT_SHA256' \"\$target\" | sha256sum -c - >/dev/null
  rm -f \"\$target\"
fi
tmp=\"\$(mktemp \"\$base/.guest.XXXXXX\")\"
trap 'rm -f \"\$tmp\"' EXIT
cat > \"\$tmp\"
chmod 700 \"\$tmp\"
printf '%s  %s\n' '$GUEST_SCRIPT_SHA256' \"\$tmp\" | sha256sum -c - >/dev/null
mv \"\$tmp\" \"\$target\"
trap - EXIT
"
  helper_staged="true"
  ssh "${ssh_options[@]}" "$ssh_user@$ssh_host" "$install_command" < "$guest_script"
}

run_guest_action() {
  local guest_action="$1"
  local remote_command
  remote_command="\"$REMOTE_HELPER_PATH\" $guest_action $EXPECTED_ENVIRONMENT $runner_name"
  ssh "${ssh_options[@]}" "$ssh_user@$ssh_host" "$remote_command" </dev/null
}

run_guest_action_with_token() {
  local guest_action="$1"
  local remote_command
  local ssh_status
  remote_command="\"$REMOTE_HELPER_PATH\" $guest_action $EXPECTED_ENVIRONMENT $runner_name"
  set +e
  printf '%s\n' "$short_lived_token" \
    | ssh "${ssh_options[@]}" "$ssh_user@$ssh_host" "$remote_command"
  ssh_status="$?"
  set -e
  short_lived_token=""
  unset short_lived_token
  return "$ssh_status"
}

fetch_short_lived_token() {
  local endpoint
  case "$operation" in
    start) endpoint="repos/$EXPECTED_REPOSITORY/actions/runners/registration-token" ;;
    teardown) endpoint="repos/$EXPECTED_REPOSITORY/actions/runners/remove-token" ;;
  esac
  short_lived_token="$(gh api --method POST "$endpoint" --jq .token)"
  ((${#short_lived_token} >= 20 && ${#short_lived_token} <= 512)) \
    && [[ "$short_lived_token" =~ ^[A-Za-z0-9_=-]+$ ]] \
    || die "GitHub returned an invalid short-lived runner token"
}

operation="${1:-}"
[[ -n "$operation" ]] || {
  usage
  exit 64
}
shift
while (($# > 0)); do
  case "$1" in
    --vm)
      (($# >= 2)) || die "--vm requires a value"
      vm_id="$2"
      shift 2
      ;;
    --environment)
      (($# >= 2)) || die "--environment requires a value"
      environment_id="$2"
      shift 2
      ;;
    --ssh-host)
      (($# >= 2)) || die "--ssh-host requires a value"
      ssh_host="$2"
      shift 2
      ;;
    --ssh-user)
      (($# >= 2)) || die "--ssh-user requires a value"
      ssh_user="$2"
      shift 2
      ;;
    --ssh-key)
      (($# >= 2)) || die "--ssh-key requires a value"
      ssh_key="$2"
      shift 2
      ;;
    --known-hosts)
      (($# >= 2)) || die "--known-hosts requires a value"
      known_hosts="$2"
      shift 2
      ;;
    --ssh-port)
      (($# >= 2)) || die "--ssh-port requires a value"
      ssh_port="$2"
      shift 2
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

validate_arguments
[[ "$(uname -s)" == "Darwin" ]] || die "UTM runner controller requires macOS"
[[ "$(uname -m)" == "arm64" ]] || die "UTM runner controller requires Apple silicon"
for command in gh python3 ssh utmctl; do
  command -v "$command" >/dev/null 2>&1 || die "required host command is missing: $command"
done

ssh_key="$(expand_home_path "$ssh_key")"
known_hosts="$(expand_home_path "$known_hosts")"
assert_trusted_host_file "$ssh_key" "SSH private key"
assert_trusted_host_file "$known_hosts" "SSH known-hosts file" true false
assert_trusted_host_file "$guest_script" "pinned guest helper" false false
printf '%s  %s\n' "$GUEST_SCRIPT_SHA256" "$guest_script" | shasum -a 256 -c - >/dev/null \
  || die "pinned guest helper checksum does not match"

ssh_options=(
  -F /dev/null
  -T
  -p "$ssh_port"
  -i "$ssh_key"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$known_hosts"
  -o ConnectTimeout=10
  -o ConnectionAttempts=1
  -o LogLevel=ERROR
)

trap cleanup_all EXIT
trap 'exit 130' INT TERM

vm_status="$(utmctl status "$vm_id")"
[[ "$vm_status" == "started" ]] || die "documented UTM guest is not already running"
actual_repository="$(gh repo view "$EXPECTED_REPOSITORY" --json nameWithOwner --jq .nameWithOwner)"
[[ "$actual_repository" == "$EXPECTED_REPOSITORY" ]] \
  || die "authenticated GitHub account cannot inspect $EXPECTED_REPOSITORY"

stage_guest_helper
run_guest_action "preflight-$operation"
fetch_short_lived_token
if [[ "$operation" == "start" ]]; then
  if ! run_guest_action_with_token start; then
    operation="teardown"
    if run_guest_action preflight-teardown; then
      fetch_short_lived_token
      if run_guest_action_with_token teardown; then
        die "runner start failed; registered state was unregistered and removed"
      fi
    fi
    die "runner start failed; teardown could not be completed and guest state was retained"
  fi
else
  run_guest_action_with_token teardown
fi
