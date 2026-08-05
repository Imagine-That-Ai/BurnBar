#!/bin/bash

set -euo pipefail
umask 077
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

readonly EXPECTED_ENVIRONMENT="ubuntu-24.04-gnome-x11-aarch64"
readonly EXPECTED_LABELS="self-hosted,linux,ubuntu-24.04-gnome-x11-aarch64"
readonly EXPECTED_REPOSITORY="Imagine-That-Ai/BurnBar"
readonly RUNNER_VERSION="2.336.0"
readonly RUNNER_SHA256="58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1"
readonly UNIT_NAME="openburnbar-actions-runner-ubuntu-24-04-gnome-x11-aarch64"

action="${1:-}"
environment_id="${2:-}"
runner_name="${3:-}"
current_uid="$(id -u)"
current_user="$(id -un)"
state_parent=""
state_root=""
runner_dir=""
metadata_path=""
graphical_display=""
graphical_runtime_dir=""
graphical_dbus=""
graphical_xauthority=""
graphical_desktop=""
graphical_session_desktop=""
graphical_path=""
temporary_env_file=""
temporary_install_root=""
remove_partial_state="false"

die() {
  printf 'openburnbar-utm-runner-guest: %s\n' "$*" >&2
  exit 1
}

cleanup_temporary_state() {
  if [[ -n "$temporary_env_file" ]]; then
    rm -f "$temporary_env_file"
  fi
  if [[ -n "$temporary_install_root" ]]; then
    rm -rf "$temporary_install_root"
  fi
  if [[ "$remove_partial_state" == "true" && -n "$state_root" ]]; then
    rm -rf "$state_root"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

mode_decimal() {
  local raw
  raw="$(stat -c '%a' "$1")"
  printf '%d\n' "$((8#$raw))"
}

assert_no_symlink_components() {
  local path="$1"
  local current=""
  local component
  local -a components

  [[ "$path" == /* ]] || die "trusted paths must be absolute: $path"
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    if [[ -L "$current" ]]; then
      die "trusted path contains a symlink: $current"
    fi
    [[ -e "$current" ]] || break
  done
}

assert_trusted_directory() {
  local path="$1"
  local owner mode

  assert_no_symlink_components "$path"
  [[ -d "$path" ]] || die "trusted directory is missing: $path"
  owner="$(stat -c '%u' "$path")"
  [[ "$owner" == "$current_uid" ]] || die "trusted directory has the wrong owner: $path"
  mode="$(mode_decimal "$path")"
  (( (mode & 8#022) == 0 )) || die "trusted directory is group/world writable: $path"
}

assert_trusted_file() {
  local path="$1"
  local required_mode="${2:-}"
  local owner mode

  assert_no_symlink_components "$path"
  [[ -f "$path" && ! -L "$path" ]] || die "trusted file must be a regular non-symlink: $path"
  owner="$(stat -c '%u' "$path")"
  [[ "$owner" == "$current_uid" ]] || die "trusted file has the wrong owner: $path"
  mode="$(mode_decimal "$path")"
  (( (mode & 8#022) == 0 )) || die "trusted file is group/world writable: $path"
  if [[ -n "$required_mode" ]]; then
    (( mode == required_mode )) || die "trusted file has unexpected permissions: $path"
  fi
}

create_trusted_directory() {
  local path="$1"
  local parent

  parent="$(dirname "$path")"
  assert_trusted_directory "$parent"
  if [[ -e "$path" || -L "$path" ]]; then
    assert_trusted_directory "$path"
  else
    install -d -m 700 "$path"
    assert_trusted_directory "$path"
  fi
}

os_release_value() {
  local key="$1"
  local file="$2"
  local value

  value="$(
    awk -F= -v key="$key" '
      $1 == key {
        value = substr($0, index($0, "=") + 1)
        if (value ~ /^".*"$/) {
          value = substr(value, 2, length(value) - 2)
        }
        print value
      }
    ' "$file"
  )"
  [[ "$value" != *$'\n'* ]] || die "duplicate $key entries in $file"
  printf '%s\n' "$value"
}

environment_value() {
  local key="$1"
  local file="$2"
  local count value

  count="$(grep -c "^${key}=" "$file" || true)"
  [[ "$count" == "1" ]] || die "graphical user environment must contain exactly one $key"
  value="$(grep "^${key}=" "$file" | cut -d= -f2-)"
  [[ -n "$value" && "$value" != *$'\n'* ]] || die "graphical user environment has an invalid $key"
  printf '%s\n' "$value"
}

validate_graphical_path() {
  local path_value="$1"
  local entry canonical owner mode
  local -a entries
  local -a canonical_entries=()

  IFS=':' read -r -a entries <<< "$path_value"
  ((${#entries[@]} > 0)) || die "graphical PATH is empty"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" && "$entry" == /* ]] || die "graphical PATH contains an empty or relative entry"
    canonical="$(readlink -f "$entry")"
    [[ -n "$canonical" && "$canonical" == /* ]] \
      || die "graphical PATH entry cannot be canonicalized: $entry"
    assert_no_symlink_components "$canonical"
    [[ -d "$canonical" ]] || die "graphical PATH entry is not a directory: $entry"
    owner="$(stat -c '%u' "$canonical")"
    [[ "$owner" == "0" || "$owner" == "$current_uid" ]] \
      || die "graphical PATH entry has an untrusted owner: $entry"
    mode="$(mode_decimal "$canonical")"
    (( (mode & 8#022) == 0 )) || die "graphical PATH entry is group/world writable: $entry"
    canonical_entries+=("$canonical")
  done
  graphical_path="$(IFS=:; printf '%s' "${canonical_entries[*]}")"
}

verify_guest_identity() {
  local os_release="/usr/lib/os-release"
  local distro version architecture deb_arch

  require_command awk
  require_command cut
  require_command dpkg
  require_command grep
  require_command getent
  require_command loginctl
  require_command readlink
  require_command stat
  require_command systemctl
  require_command uname

  [[ "$current_uid" != "0" ]] || die "the runner must belong to the graphical non-root user"
  [[ "$HOME" == "$(getent passwd "$current_uid" | cut -d: -f6)" ]] \
    || die "HOME does not match the authenticated user's passwd entry"
  assert_trusted_directory "$HOME"

  [[ -f "$os_release" && ! -L "$os_release" ]] || die "canonical os-release is not a regular file"
  [[ "$(stat -c '%u' "$os_release")" == "0" ]] || die "canonical os-release is not root-owned"
  (( ($(mode_decimal "$os_release") & 8#022) == 0 )) || die "canonical os-release is writable by an untrusted principal"
  distro="$(os_release_value ID "$os_release")"
  version="$(os_release_value VERSION_ID "$os_release")"
  [[ "$distro" == "ubuntu" && "$version" == "24.04" ]] \
    || die "guest must be Ubuntu 24.04"

  architecture="$(uname -m)"
  deb_arch="$(dpkg --print-architecture)"
  [[ "$architecture" == "aarch64" && "$deb_arch" == "arm64" ]] \
    || die "guest must be aarch64/arm64"
}

capture_graphical_environment() {
  local candidate name type active remote class desktop
  local runtime_dir session_count=0
  local -a sessions

  mapfile -t sessions < <(loginctl list-sessions --no-legend | awk '{print $1}')
  for candidate in "${sessions[@]}"; do
    [[ "$candidate" =~ ^[A-Za-z0-9_.-]+$ ]] || die "loginctl returned an unsafe session identifier"
    name="$(loginctl show-session "$candidate" -p Name --value)"
    type="$(loginctl show-session "$candidate" -p Type --value)"
    active="$(loginctl show-session "$candidate" -p Active --value)"
    remote="$(loginctl show-session "$candidate" -p Remote --value)"
    class="$(loginctl show-session "$candidate" -p Class --value)"
    desktop="$(loginctl show-session "$candidate" -p Desktop --value)"
    if [[ "$name" == "$current_user" && "$type" == "x11" && "$active" == "yes" \
      && "$remote" == "no" && "$class" == "user" ]]; then
      # Ubuntu 24.04 GNOME/logind often leaves Desktop empty; require GNOME via
      # XDG_CURRENT_DESKTOP below when the property is unset.
      if [[ -n "$desktop" ]]; then
        [[ "$desktop" == "GNOME" || "$desktop" == "ubuntu" || "$desktop" == "ubuntu:GNOME" ]] \
          || die "active X11 session is not GNOME"
      fi
      session_count=$((session_count + 1))
    fi
  done
  [[ "$session_count" == "1" ]] \
    || die "expected exactly one active local GNOME X11 session for $current_user"

  runtime_dir="/run/user/$current_uid"
  assert_trusted_directory "$runtime_dir"
  [[ -S "$runtime_dir/bus" ]] || die "graphical user's D-Bus socket is missing"
  [[ "$(stat -c '%u' "$runtime_dir/bus")" == "$current_uid" ]] \
    || die "graphical user's D-Bus socket has the wrong owner"

  temporary_env_file="$(mktemp "$runtime_dir/openburnbar-runner-env.XXXXXX")"
  XDG_RUNTIME_DIR="$runtime_dir" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    systemctl --user show-environment > "$temporary_env_file"
  chmod 600 "$temporary_env_file"
  assert_trusted_file "$temporary_env_file" 384

  graphical_display="$(environment_value DISPLAY "$temporary_env_file")"
  graphical_runtime_dir="$(environment_value XDG_RUNTIME_DIR "$temporary_env_file")"
  graphical_dbus="$(environment_value DBUS_SESSION_BUS_ADDRESS "$temporary_env_file")"
  graphical_xauthority="$(environment_value XAUTHORITY "$temporary_env_file")"
  graphical_desktop="$(environment_value XDG_CURRENT_DESKTOP "$temporary_env_file")"
  graphical_session_desktop="$(environment_value XDG_SESSION_DESKTOP "$temporary_env_file")"
  graphical_path="$(environment_value PATH "$temporary_env_file")"

  [[ "$graphical_display" =~ ^:[0-9]+(\.[0-9]+)?$ ]] \
    || die "graphical DISPLAY is not a local X11 display"
  [[ "$graphical_runtime_dir" == "$runtime_dir" ]] \
    || die "graphical XDG_RUNTIME_DIR does not match the authenticated user"
  [[ "$graphical_dbus" == "unix:path=$runtime_dir/bus" ]] \
    || die "graphical D-Bus address is not the authenticated user's bus"
  [[ "$graphical_desktop" == "GNOME" || "$graphical_desktop" == "ubuntu:GNOME" ]] \
    || die "XDG_CURRENT_DESKTOP is not GNOME"
  [[ "$graphical_session_desktop" == "ubuntu" || "$graphical_session_desktop" == "gnome" ]] \
    || die "XDG_SESSION_DESKTOP is not GNOME"
  assert_trusted_file "$graphical_xauthority"
  validate_graphical_path "$graphical_path"
  rm -f "$temporary_env_file"
  temporary_env_file=""
}

initialize_paths() {
  state_parent="$HOME/.local/share/openburnbar-actions-runner"
  state_root="$state_parent/$EXPECTED_ENVIRONMENT"
  runner_dir="$state_root/runner"
  metadata_path="$state_root/install.metadata"
}

prepare_state_parent() {
  if [[ ! -e "$HOME/.local" && ! -L "$HOME/.local" ]]; then
    install -d -m 700 "$HOME/.local"
  fi
  assert_trusted_directory "$HOME/.local"
  create_trusted_directory "$HOME/.local/share"
  create_trusted_directory "$state_parent"
}

validate_token() {
  local token="$1"
  ((${#token} >= 20 && ${#token} <= 512)) \
    && [[ "$token" =~ ^[A-Za-z0-9_=-]+$ ]] \
    || die "GitHub returned an invalid short-lived token"
}

validate_archive_entries() {
  local archive="$1"
  local entry normalized

  while IFS= read -r entry; do
    # Package root "./" is a normal tar directory entry.
    [[ "$entry" == "./" || "$entry" == "." ]] && continue
    normalized="${entry#./}"
    [[ -n "$normalized" && "$normalized" != /* ]] || die "runner archive contains an unsafe path"
    [[ "/$normalized/" != *"/../"* ]] || die "runner archive contains path traversal"
  done < <(tar -tzf "$archive")

  # Modern actions/runner packages ship relative Node package-manager stubs.
  # Reject hardlinks and absolute symlink targets; relative targets (including
  # ".." components that stay inside the package) are re-checked after extract.
  if tar -tvzf "$archive" | grep -Eq '^h'; then
    die "runner archive contains hardlinks"
  fi
  if tar -tvzf "$archive" | grep -E '^l' | grep -Eq ' -> /'; then
    die "runner archive contains an absolute symlink"
  fi
}

write_metadata() {
  local temp="$state_root/.install.metadata.tmp"
  {
    printf 'environment=%s\n' "$EXPECTED_ENVIRONMENT"
    printf 'labels=%s\n' "$EXPECTED_LABELS"
    printf 'repository=%s\n' "$EXPECTED_REPOSITORY"
    printf 'runner_name=%s\n' "$runner_name"
    printf 'runner_version=%s\n' "$RUNNER_VERSION"
    printf 'runner_sha256=%s\n' "$RUNNER_SHA256"
    printf 'unit=%s\n' "$UNIT_NAME"
  } > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$metadata_path"
  assert_trusted_file "$metadata_path" 384
}

verify_metadata() {
  local expected

  assert_trusted_directory "$state_parent"
  assert_trusted_directory "$state_root"
  assert_trusted_directory "$runner_dir"
  assert_trusted_file "$metadata_path" 384
  expected="$(
    printf 'environment=%s\n' "$EXPECTED_ENVIRONMENT"
    printf 'labels=%s\n' "$EXPECTED_LABELS"
    printf 'repository=%s\n' "$EXPECTED_REPOSITORY"
    printf 'runner_name=%s\n' "$runner_name"
    printf 'runner_version=%s\n' "$RUNNER_VERSION"
    printf 'runner_sha256=%s\n' "$RUNNER_SHA256"
    printf 'unit=%s\n' "$UNIT_NAME"
  )"
  [[ "$(cat "$metadata_path")" == "$expected" ]] || die "runner install metadata is dirty or untrusted"
  [[ -x "$runner_dir/bin/Runner.Listener" && ! -L "$runner_dir/bin/Runner.Listener" ]] \
    || die "pinned runner executable is missing or linked"
  [[ -x "$runner_dir/config.sh" && ! -L "$runner_dir/config.sh" ]] \
    || die "runner config script is missing or linked"
  while IFS= read -r -d "" link; do
    target="$(readlink "$link")"
    [[ "$target" != /* ]] || die "runner installation contains an absolute symlink: $link"
    resolved="$(readlink -f "$link")"
    [[ -n "$resolved" && "$resolved" == "$runner_dir"/* ]] \
      || die "runner installation symlink escapes the install tree: $link"
  done < <(find "$runner_dir" -type l -print0)
  if find "$runner_dir" ! -user "$current_user" -print -quit | grep -q .; then
    die "runner installation contains files owned by another user"
  fi
}

install_runner() {
  local archive extracted archive_url installed_version

  prepare_state_parent
  [[ ! -e "$state_root" && ! -L "$state_root" ]] \
    || die "runner state already exists; teardown it before starting another runner"
  install -d -m 700 "$state_root"
  remove_partial_state="true"
  temporary_install_root="$(mktemp -d "$state_parent/.install.XXXXXX")"
  archive="$temporary_install_root/actions-runner-linux-arm64.tgz"
  extracted="$temporary_install_root/runner"

  archive_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
  curl -fsSL --retry 3 --retry-all-errors "$archive_url" -o "$archive"
  printf '%s  %s\n' "$RUNNER_SHA256" "$archive" | sha256sum -c - >/dev/null
  validate_archive_entries "$archive"
  install -d -m 700 "$extracted"
  tar -xzf "$archive" -C "$extracted" --no-same-owner --no-same-permissions
  # Keep only relative in-tree symlinks (Node package-manager stubs). Reject
  # absolute or out-of-tree link targets.
  while IFS= read -r -d "" link; do
    target="$(readlink "$link")"
    [[ "$target" != /* ]] || die "extracted runner contains an absolute symlink: $link"
    resolved="$(readlink -f "$link")"
    [[ -n "$resolved" && "$resolved" == "$extracted"/* ]] \
      || die "extracted runner symlink escapes the install tree: $link"
  done < <(find "$extracted" -type l -print0)
  installed_version="$("$extracted/bin/Runner.Listener" --version)"
  [[ "$installed_version" == "$RUNNER_VERSION" ]] \
    || die "extracted runner version does not match the pinned release"
  mv "$extracted" "$runner_dir"
  chmod 700 "$runner_dir"
  rm -rf "$temporary_install_root"
  temporary_install_root=""
}

configure_and_launch() {
  local token config_status

  IFS= read -r token || die "registration token was not provided on stdin"
  validate_token "$token"
  install_runner
  write_metadata
  verify_metadata
  # From this point onward configuration may already have registered the
  # runner remotely. Preserve state on every failure so teardown can decide
  # whether config.sh remove is possible.
  remove_partial_state="false"

  (
    cd "$runner_dir"
    set +e
    ACTIONS_RUNNER_INPUT_TOKEN="$token" ./config.sh \
      --url "https://github.com/$EXPECTED_REPOSITORY" \
      --unattended \
      --ephemeral \
      --disableupdate \
      --no-default-labels \
      --labels "$EXPECTED_LABELS" \
      --name "$runner_name" \
      --work _work > "$state_root/configure.log" 2>&1
    config_status="$?"
    set -e
    token=""
    unset token ACTIONS_RUNNER_INPUT_TOKEN
    exit "$config_status"
  ) || {
    token=""
    unset token
    die "runner configuration failed; protected state was retained for teardown"
  }
  token=""
  unset token
  chmod 600 "$state_root/configure.log"
  verify_metadata

  systemd-run --user \
    --unit "$UNIT_NAME" \
    --collect \
    --property "WorkingDirectory=$runner_dir" \
    --property "KillMode=mixed" \
    --property "TimeoutStopSec=30s" \
    --setenv "HOME=$HOME" \
    --setenv "USER=$current_user" \
    --setenv "LOGNAME=$current_user" \
    --setenv "PATH=$graphical_path" \
    --setenv "DISPLAY=$graphical_display" \
    --setenv "XDG_RUNTIME_DIR=$graphical_runtime_dir" \
    --setenv "DBUS_SESSION_BUS_ADDRESS=$graphical_dbus" \
    --setenv "XAUTHORITY=$graphical_xauthority" \
    --setenv "XDG_CURRENT_DESKTOP=$graphical_desktop" \
    --setenv "XDG_SESSION_DESKTOP=$graphical_session_desktop" \
    --setenv "XDG_SESSION_TYPE=x11" \
    "$runner_dir/run.sh" >/dev/null
  sleep 2
  systemctl --user is-active --quiet "$UNIT_NAME.service" \
    || die "runner did not remain active after launch"
  printf 'runner=%s environment=%s state=active\n' "$runner_name" "$EXPECTED_ENVIRONMENT"
}

stop_runner_processes() {
  local pid proc_uid proc_cwd
  local -a runner_pids=()

  systemctl --user stop "$UNIT_NAME.service" >/dev/null 2>&1 || true
  for _attempt in $(seq 1 30); do
    if ! systemctl --user is-active --quiet "$UNIT_NAME.service"; then
      break
    fi
    sleep 1
  done
  systemctl --user is-active --quiet "$UNIT_NAME.service" \
    && die "runner systemd unit did not stop"

  for proc in /proc/[0-9]*; do
    [[ -d "$proc" ]] || continue
    pid="${proc##*/}"
    proc_uid="$(stat -c '%u' "$proc" 2>/dev/null || true)"
    [[ "$proc_uid" == "$current_uid" ]] || continue
    proc_cwd="$(readlink "$proc/cwd" 2>/dev/null || true)"
    [[ "$proc_cwd" == "$runner_dir" ]] || continue
    if tr '\0' ' ' < "$proc/cmdline" 2>/dev/null | grep -Fq 'Runner.Listener'; then
      runner_pids+=("$pid")
    fi
  done
  if ((${#runner_pids[@]} > 0)); then
    kill -TERM "${runner_pids[@]}"
    for _attempt in $(seq 1 30); do
      local alive=0
      for pid in "${runner_pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && alive=1
      done
      ((alive == 0)) && break
      sleep 1
    done
    for pid in "${runner_pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && die "runner process $pid did not stop"
    done
  fi
}

unregister_and_remove() {
  local token remove_status

  IFS= read -r token || die "removal token was not provided on stdin"
  validate_token "$token"
  verify_metadata
  stop_runner_processes

  [[ -f "$runner_dir/.runner" && ! -L "$runner_dir/.runner" ]] \
    || die "local runner registration is missing; refusing to claim unregistration"
  assert_trusted_file "$runner_dir/.runner"
  (
    cd "$runner_dir"
    set +e
    ACTIONS_RUNNER_INPUT_TOKEN="$token" ./config.sh remove \
      > "$state_root/remove.log" 2>&1
    remove_status="$?"
    set -e
    token=""
    unset token ACTIONS_RUNNER_INPUT_TOKEN
    exit "$remove_status"
  ) || {
    token=""
    unset token
    die "runner unregistration failed; protected state was retained"
  }
  token=""
  unset token
  rm -rf "$state_root"
  printf 'runner=%s environment=%s state=removed\n' "$runner_name" "$EXPECTED_ENVIRONMENT"
}

[[ "$#" == "3" ]] || die "expected action, canonical environment id, and runner name"
[[ "$environment_id" == "$EXPECTED_ENVIRONMENT" ]] || die "unsupported canonical environment id"
[[ "$runner_name" == "burnbar-utm-$EXPECTED_ENVIRONMENT" ]] || die "unexpected runner name"
case "$action" in
  preflight-start|start|preflight-teardown|teardown) ;;
  *) die "unsupported action: $action" ;;
esac

trap cleanup_temporary_state EXIT
verify_guest_identity
capture_graphical_environment
initialize_paths

case "$action" in
  preflight-start)
    prepare_state_parent
    [[ ! -e "$state_root" && ! -L "$state_root" ]] \
      || die "runner state already exists; teardown it first"
    ;;
  start)
    require_command curl
    require_command find
    require_command sha256sum
    require_command tar
    configure_and_launch
    ;;
  preflight-teardown)
    verify_metadata
    ;;
  teardown)
    unregister_and_remove
    ;;
esac
