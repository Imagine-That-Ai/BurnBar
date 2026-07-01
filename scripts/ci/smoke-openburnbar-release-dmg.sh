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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/verify-apple-appcheck-release-env.sh"
bash "$script_dir/verify-apple-appcheck-release-artifact.sh" "$dmg_path"

uid="$(id -u)"
label_suffix="$(
  printf '%s-%s-%s' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-0}" "$$" \
    | tr -cd '[:alnum:]._-'
)"
launch_label="com.openburnbar.daemon.release-smoke.${label_suffix}"
support_dir="${RUNNER_TEMP:-/tmp}/openburnbar-release-smoke-${label_suffix}"
installed_daemon_dir="$support_dir/daemon"
installed_frameworks_dir="$support_dir/Frameworks"
installed_daemon_bin="$installed_daemon_dir/OpenBurnBarDaemon"
installed_cli_bin="$installed_daemon_dir/OpenBurnBarCLI"
mountpoint="/Volumes/OpenBurnBarReleaseSmoke-${label_suffix}"
socket_path="$support_dir/openburnbar-daemon.sock"
launch_plist="$support_dir/${launch_label}.plist"
log_path="$installed_daemon_dir/openburnbar-daemon.log"
preexisting_app_pids_path="$support_dir/preexisting-openburnbar-pids.txt"
smoke_app_pids_path="$support_dir/smoke-openburnbar-pids.txt"
socket_auth_token="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
mounted=0

positive_integer_or_default() {
  local raw="$1"
  local fallback="$2"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$fallback"
  fi
}

cli_health_timeout_seconds="$(
  positive_integer_or_default "${OPENBURNBAR_RELEASE_SMOKE_CLI_TIMEOUT_SECONDS:-}" 15
)"
health_deadline_seconds="$(
  positive_integer_or_default "${OPENBURNBAR_RELEASE_SMOKE_HEALTH_DEADLINE_SECONDS:-}" 120
)"

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
  echo "cli_health_timeout_seconds=$cli_health_timeout_seconds"
  echo "health_deadline_seconds=$health_deadline_seconds"
  launchctl print "gui/$uid/$launch_label" || true
  ls -la "$support_dir" "$installed_daemon_dir" "$installed_frameworks_dir" 2>/dev/null || true
  stat -f "socket_mode=%Sp socket_size=%z socket_path=%N" "$socket_path" 2>/dev/null || true
  pgrep -fl 'OpenBurnBar(Daemon|CLI)?|release-smoke' || true
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
echo "Mounted release DMG at $mountpoint"

app_path="$mountpoint/OpenBurnBar.app"
daemon_bin="$app_path/Contents/Helpers/OpenBurnBarDaemon"
cli_bin="$app_path/Contents/Helpers/OpenBurnBarCLI"
daemon_resource_bundle="$app_path/Contents/Resources/OpenBurnBarCore_OpenBurnBarCore.bundle"
project_code_memory_corpus="$app_path/Contents/Resources/ProjectCodeMemory/secret-pattern-corpus.json"
helper_resource_bundle="$app_path/Contents/Helpers/OpenBurnBarCore_OpenBurnBarCore.bundle"
installed_resource_bundle="$installed_daemon_dir/OpenBurnBarCore_OpenBurnBarCore.bundle"
installed_project_code_memory_corpus="$installed_daemon_dir/ProjectCodeMemory/secret-pattern-corpus.json"

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

mkdir -p "$installed_daemon_dir" "$installed_frameworks_dir" "$(dirname "$installed_project_code_memory_corpus")"
cp "$daemon_bin" "$installed_daemon_bin"
cp "$cli_bin" "$installed_cli_bin"
chmod 755 "$installed_daemon_bin" "$installed_cli_bin"
rm -rf "$installed_resource_bundle"
cp -R "$daemon_resource_bundle" "$installed_resource_bundle"
cp "$project_code_memory_corpus" "$installed_project_code_memory_corpus"
find "$installed_frameworks_dir" -mindepth 1 -maxdepth 1 -name "*.framework" -exec rm -rf {} +
for framework in "$app_path"/Contents/Frameworks/*.framework; do
  [[ -d "$framework" ]] || continue
  cp -R "$framework" "$installed_frameworks_dir/"
done

if [[ -d "$app_path/Contents/Frameworks/SQLCipher.framework" && ! -d "$installed_frameworks_dir/SQLCipher.framework" ]]; then
  echo "::error::SQLCipher.framework was not mirrored to installed daemon rpath directory $installed_frameworks_dir"
  exit 1
fi
if [[ ! -x "$installed_daemon_bin" ]]; then
  echo "::error::Installed-layout daemon helper not executable at $installed_daemon_bin"
  exit 1
fi
if [[ ! -x "$installed_cli_bin" ]]; then
  echo "::error::Installed-layout daemon CLI not executable at $installed_cli_bin"
  exit 1
fi
if [[ ! -d "$installed_resource_bundle" ]]; then
  echo "::error::Installed-layout daemon resource bundle not found at $installed_resource_bundle"
  exit 1
fi
if [[ ! -f "$installed_project_code_memory_corpus" ]]; then
  echo "::error::Installed-layout Project Code Memory corpus not found at $installed_project_code_memory_corpus"
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
echo "OpenBurnBar app launched from mounted DMG with pid(s): $(tr '\n' ' ' < "$smoke_app_pids_path")"

python3 - <<PY
from pathlib import Path
import plistlib

plist = {
    "Label": "${launch_label}",
    "ProgramArguments": [
        "${installed_daemon_bin}",
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
    "WorkingDirectory": "${installed_daemon_dir}",
    "StandardOutPath": "${log_path}",
    "StandardErrorPath": "${log_path}",
}

with Path("${launch_plist}").open("wb") as fh:
    plistlib.dump(plist, fh)
PY
chmod 600 "$launch_plist"

launchctl bootout "gui/$uid" "$launch_plist" >/dev/null 2>&1 || true
echo "Bootstrapping installed-layout daemon with launch label $launch_label"
launchctl bootstrap "gui/$uid" "$launch_plist"
launchctl kickstart -k "gui/$uid/$launch_label"

run_cli_health_probe() {
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$socket_auth_token" \
  OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_dir" \
  OPENBURNBAR_RELEASE_SMOKE_CLI_TIMEOUT_SECONDS="$cli_health_timeout_seconds" \
  python3 - "$installed_cli_bin" <<'PY'
import os
import subprocess
import sys

cli = sys.argv[1]
timeout = int(os.environ["OPENBURNBAR_RELEASE_SMOKE_CLI_TIMEOUT_SECONDS"])
try:
    completed = subprocess.run(
        [cli, "health"],
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
    )
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    if output:
        print(output, end="")
    print(f"OpenBurnBarCLI health timed out after {timeout}s", file=sys.stderr)
    sys.exit(124)

if completed.stdout:
    print(completed.stdout, end="")
sys.exit(completed.returncode)
PY
}

health_passed=0
last_health_output=""
health_deadline_epoch=$(($(date +%s) + health_deadline_seconds))
attempt=0
echo "Polling installed-layout daemon health via signed OpenBurnBarCLI"
while [[ "$(date +%s)" -lt "$health_deadline_epoch" ]]; do
  attempt=$((attempt + 1))
  if health_output="$(run_cli_health_probe 2>&1)"; then
    last_health_output="$health_output"
    if grep -q "ok=true" <<<"$health_output"; then
      echo "Authenticated daemon health RPC passed via installed-layout OpenBurnBarCLI"
      health_passed=1
      break
    fi
    last_health_output="OpenBurnBarCLI health attempt $attempt returned without ok=true: $health_output"
  else
    exit_code=$?
    last_health_output="OpenBurnBarCLI health attempt $attempt failed with exit $exit_code: $health_output"
    if [[ "$exit_code" == "124" || "$attempt" == "1" || $((attempt % 10)) -eq 0 ]]; then
      printf '%s\n' "$last_health_output"
    fi
  fi
  sleep 1
done

if [[ "$health_passed" != "1" ]]; then
  echo "::error::Timed out after ${health_deadline_seconds}s waiting for installed-layout OpenBurnBar daemon health response from signed OpenBurnBarCLI"
  if [[ -n "$last_health_output" ]]; then
    printf '%s\n' "$last_health_output"
  fi
  print_failure_diagnostics
  exit 1
fi

echo "Smoke test passed: DMG mounted, app launched, installed-layout daemon helper started, signed CLI authenticated to daemon"
