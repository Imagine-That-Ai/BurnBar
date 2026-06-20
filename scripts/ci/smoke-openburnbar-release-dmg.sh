#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/OpenBurnBar-<version>-macOS.dmg" >&2
  exit 64
fi

dmg_path="$1"
if [[ ! -f "$dmg_path" ]]; then
  echo "DMG not found at $dmg_path" >&2
  exit 66
fi

uid="$(id -u)"
label_suffix="$(
  printf '%s-%s-%s' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-0}" "$$" \
    | tr -cd '[:alnum:]._-'
)"
launch_label="com.openburnbar.daemon.release-smoke.${label_suffix}"
support_dir="${RUNNER_TEMP:-/tmp}/openburnbar-release-smoke-${label_suffix}"
mountpoint="/Volumes/OpenBurnBarReleaseSmoke-${label_suffix}"
socket_path="$support_dir/openburnbar-daemon.sock"
launch_plist="$support_dir/${launch_label}.plist"
log_path="$support_dir/openburnbar-daemon.log"
preexisting_app_pids_path="$support_dir/preexisting-openburnbar-pids.txt"
smoke_app_pids_path="$support_dir/smoke-openburnbar-pids.txt"
socket_auth_token="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
mounted=0

cleanup() {
  launchctl bootout "gui/$uid" "$launch_plist" >/dev/null 2>&1 || true
  if [[ -f "$smoke_app_pids_path" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done < "$smoke_app_pids_path"
  fi
  if [[ "$mounted" == "1" ]]; then
    hdiutil detach "$mountpoint" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$support_dir"
}
trap cleanup EXIT

print_failure_diagnostics() {
  echo "::group::OpenBurnBar release smoke diagnostics"
  echo "launch_label=$launch_label"
  echo "mountpoint=$mountpoint"
  echo "support_dir=$support_dir"
  echo "socket_path=$socket_path"
  pgrep -x OpenBurnBar >/dev/null 2>&1 && echo "OpenBurnBar process: running" || echo "OpenBurnBar process: not running"
  if [[ -f "$log_path" ]]; then
    echo "--- daemon log tail ---"
    tail -200 "$log_path" || true
  else
    echo "daemon log not found at $log_path"
  fi
  echo "::endgroup::"
}

mkdir -p "$support_dir"
chmod 700 "$support_dir"
rm -f "$socket_path" "$log_path" "$launch_plist"
pgrep -x OpenBurnBar > "$preexisting_app_pids_path" 2>/dev/null || true

hdiutil attach "$dmg_path" \
  -mountpoint "$mountpoint" \
  -nobrowse \
  -readonly
mounted=1

app_path="$mountpoint/OpenBurnBar.app"
daemon_bin="$app_path/Contents/Helpers/OpenBurnBarDaemon"
cli_bin="$app_path/Contents/Helpers/OpenBurnBarCLI"
daemon_resource_bundle="$app_path/Contents/Resources/OpenBurnBarCore_OpenBurnBarCore.bundle"
project_code_memory_corpus="$app_path/Contents/Resources/ProjectCodeMemory/secret-pattern-corpus.json"
helper_resource_bundle="$app_path/Contents/Helpers/OpenBurnBarCore_OpenBurnBarCore.bundle"
helper_project_code_memory_corpus="$app_path/Contents/Helpers/ProjectCodeMemory/secret-pattern-corpus.json"

if [[ ! -d "$app_path" ]]; then
  echo "::error::OpenBurnBar app bundle not found at $app_path"
  exit 1
fi
if [[ ! -x "$daemon_bin" ]]; then
  echo "::error::Embedded daemon helper not found at $daemon_bin"
  exit 1
fi
if [[ ! -x "$cli_bin" ]]; then
  echo "::error::Embedded daemon CLI helper not found at $cli_bin"
  exit 1
fi
if [[ ! -d "$daemon_resource_bundle" ]]; then
  echo "::error::Embedded daemon resource bundle not found at $daemon_resource_bundle"
  exit 1
fi
if [[ ! -f "$project_code_memory_corpus" ]]; then
  echo "::error::Embedded Project Code Memory corpus not found at $project_code_memory_corpus"
  exit 1
fi
if [[ ! -d "$helper_resource_bundle" ]]; then
  echo "::error::Helper-side daemon resource bundle not found at $helper_resource_bundle"
  exit 1
fi
if [[ ! -f "$helper_project_code_memory_corpus" ]]; then
  echo "::error::Helper-side Project Code Memory corpus not found at $helper_project_code_memory_corpus"
  exit 1
fi

open -n "$app_path"
for _ in {1..30}; do
  pgrep -x OpenBurnBar \
    | while IFS= read -r pid; do
        if ! grep -qx "$pid" "$preexisting_app_pids_path"; then
          echo "$pid"
        fi
      done > "$smoke_app_pids_path" || true
  if [[ -s "$smoke_app_pids_path" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -s "$smoke_app_pids_path" ]]; then
  echo "::error::OpenBurnBar app failed to launch from the mounted DMG"
  print_failure_diagnostics
  exit 1
fi

python3 - <<PY
from pathlib import Path
import plistlib

plist = {
    "Label": "${launch_label}",
    "ProgramArguments": [
        "${daemon_bin}",
        "--socket-path",
        "${socket_path}",
        "--version",
        "release-smoke",
    ],
    "EnvironmentVariables": {
        "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "${socket_auth_token}",
        "OPENBURNBAR_DAEMON_SUPPORT_DIR": "${support_dir}",
    },
    "RunAtLoad": True,
    "KeepAlive": False,
    "WorkingDirectory": "${support_dir}",
    "StandardOutPath": "${log_path}",
    "StandardErrorPath": "${log_path}",
}

with Path("${launch_plist}").open("wb") as fh:
    plistlib.dump(plist, fh)
PY
chmod 600 "$launch_plist"

launchctl bootout "gui/$uid" "$launch_plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$launch_plist"
launchctl kickstart -k "gui/$uid/$launch_label"

health_passed=0
last_health_output=""
for _ in {1..150}; do
  if health_output="$(
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$socket_auth_token" \
    OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_dir" \
    "$cli_bin" health 2>&1
  )"; then
    last_health_output="$health_output"
    if grep -q "ok=true" <<<"$health_output"; then
      echo "Authenticated daemon health RPC passed via packaged OpenBurnBarCLI"
      health_passed=1
      break
    fi
    last_health_output="OpenBurnBarCLI health returned without ok=true: $health_output"
  else
    last_health_output="$health_output"
  fi
  sleep 0.2
done

if [[ "$health_passed" != "1" ]]; then
  echo "::error::Timed out waiting for packaged OpenBurnBar daemon health response from signed OpenBurnBarCLI"
  if [[ -n "$last_health_output" ]]; then
    printf '%s\n' "$last_health_output"
  fi
  print_failure_diagnostics
  exit 1
fi

echo "Smoke test passed: DMG mounted, app launched, packaged daemon helper started, signed CLI authenticated to daemon"
