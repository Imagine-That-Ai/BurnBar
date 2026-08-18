#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# This is a local full-process Release smoke. Release daemon self-verification
# and RPC peer authentication intentionally reject ad-hoc binaries, so fail
# before the expensive suites unless the machine can produce the same
# first-party development signatures used by the installed local candidate.
signing_identity="${OPENBURNBAR_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1 \
      || true
  )"
fi
if [[ -z "$signing_identity" ]]; then
  echo "ERROR: OpenBurnBar Release smoke requires an Apple Development code-signing identity." >&2
  echo "Install one in the login keychain or set OPENBURNBAR_SIGNING_IDENTITY." >&2
  exit 1
fi
export OPENBURNBAR_SIGNING_IDENTITY="$signing_identity"

# Keep every Xcode package-resolution stage on the repository's supported
# source-built Firestore graph. The prebuilt grpc-binary graph crashes on
# supported iOS 27 devices and must not be written back by a macOS smoke run.
export FIREBASE_SOURCE_FIRESTORE="${FIREBASE_SOURCE_FIRESTORE:-1}"

# shellcheck source=scripts/lib/openburnbar-release-app-test-filters.sh
source "$repo_root/scripts/lib/openburnbar-release-app-test-filters.sh"

node --test "$repo_root/scripts/ci/macos-rust-static-link-boundary.test.mjs"

# Standalone SwiftPM test/daemon executables cannot link BurnBarRemote and Iroh
# as two Rust static archives in one process. The Xcode app graph still owns
# BurnBarRemote, so scope the seam to this stage and clear it before every app
# and Release-build proof below.
OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK=1 \
  "$repo_root/scripts/test-openburnbar-swift.sh"
unset OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK

OPENBURNBAR_APP_TEST_ATTEMPTS="${OPENBURNBAR_APP_TEST_ATTEMPTS:-2}" \
OPENBURNBAR_APP_TEST_DEFAULT_ALLOWANCE="${OPENBURNBAR_APP_TEST_DEFAULT_ALLOWANCE:-180}" \
OPENBURNBAR_APP_TEST_MAX_ALLOWANCE="${OPENBURNBAR_APP_TEST_MAX_ALLOWANCE:-360}" \
OPENBURNBAR_APP_TEST_FILTERS="${OPENBURNBAR_APP_TEST_FILTERS:-$(openburnbar_release_app_test_filters_env)}" \
  "$repo_root/scripts/test-openburnbar-app.sh"
"$repo_root/scripts/test-openburnbar-retrieval-evals.sh"
"$repo_root/scripts/test-openburnbar-ts.sh"
"$repo_root/scripts/test-openburnbar-replay-evals.sh"
"$repo_root/scripts/test-openburnbar-extension-host.sh"
npm --prefix "$repo_root/extensions/openburnbar" run test:cursor-smoke

uid="$(id -u)"
app_path="$repo_root/.derived-data/Build/Products/Release/OpenBurnBar.app"
app_bin="$app_path/Contents/MacOS/OpenBurnBar"
daemon_bin="$app_path/Contents/Helpers/OpenBurnBarDaemon"
cli_bin="$app_path/Contents/Helpers/OpenBurnBarCLI"
daemon_core_dylib="$app_path/Contents/Helpers/libOpenBurnBarCore.dylib"
app_core_framework="$app_path/Contents/Frameworks/OpenBurnBarCore.framework"
daemon_resource_bundle="$app_path/Contents/Resources/OpenBurnBarCore_OpenBurnBarCore.bundle"
daemon_kernel_resource_bundle="$app_path/Contents/Resources/OpenBurnBarCore_OpenBurnBarKernel.bundle"
project_code_memory_corpus="$app_path/Contents/Resources/ProjectCodeMemory/secret-pattern-corpus.json"
socket_auth_token="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "::add-mask::$socket_auth_token"
fi
support_dir="$(mktemp -d "/tmp/openburnbar-release-smoke-support-$uid.XXXXXX")"
installed_daemon_dir="$support_dir/daemon"
installed_frameworks_dir="$support_dir/Frameworks"
installed_daemon_bin="$installed_daemon_dir/OpenBurnBarDaemon"
installed_cli_bin="$installed_daemon_dir/OpenBurnBarCLI"
installed_resource_bundle="$installed_daemon_dir/OpenBurnBarCore_OpenBurnBarCore.bundle"
installed_kernel_resource_bundle="$installed_daemon_dir/OpenBurnBarCore_OpenBurnBarKernel.bundle"
installed_project_code_memory_corpus="$installed_daemon_dir/ProjectCodeMemory/secret-pattern-corpus.json"
socket_path="$support_dir/openburnbar-daemon.sock"
socket_auth_token_file="$support_dir/openburnbar-daemon.socket-token"
launch_label="com.openburnbar.daemon.release-smoke.$uid.$$"
launch_plist="$support_dir/$launch_label.plist"
log_path="$installed_daemon_dir/openburnbar-daemon.log"
chmod 700 "$support_dir"

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
  positive_integer_or_default "${OPENBURNBAR_RELEASE_SMOKE_CLI_TIMEOUT_SECONDS:-}" 45
)"
health_deadline_seconds="$(
  positive_integer_or_default "${OPENBURNBAR_RELEASE_SMOKE_HEALTH_DEADLINE_SECONDS:-}" 180
)"

cleanup() {
  launchctl bootout "gui/$uid" "$launch_plist" >/dev/null 2>&1 || true
  rm -rf "$support_dir"
}
trap cleanup EXIT

print_launchd_state_without_environment() {
  launchctl print "gui/$uid/$launch_label" 2>&1 \
    | awk '
      /^[[:space:]]*[^=]*environment = \{/ {
        print "\tenvironment = <redacted>"
        in_environment = 1
        next
      }
      in_environment && /^[[:space:]]*}/ {
        in_environment = 0
        next
      }
      !in_environment { print }
    ' \
    || true
}

print_failure_diagnostics() {
  echo "OpenBurnBar Release smoke diagnostics"
  echo "launch_label=$launch_label"
  echo "support_dir=$support_dir"
  echo "socket_path=$socket_path"
  echo "cli_health_timeout_seconds=$cli_health_timeout_seconds"
  echo "health_deadline_seconds=$health_deadline_seconds"
  print_launchd_state_without_environment
  ls -la "$support_dir" "$installed_daemon_dir" "$installed_frameworks_dir" 2>/dev/null || true
  stat -f "socket_mode=%Sp socket_size=%z socket_path=%N" "$socket_path" 2>/dev/null || true
  pgrep -fl 'OpenBurnBar(Daemon|CLI)?|release-smoke' || true
  if [[ -f "$log_path" ]]; then
    echo "daemon log tail:"
    tail -200 "$log_path" || true
  else
    echo "daemon log not found at $log_path"
  fi
}

printf '%s\n' "$socket_auth_token" > "$socket_auth_token_file"
chmod 600 "$socket_auth_token_file"

make -C "$repo_root" build-signed

if [[ ! -d "$app_path" ]]; then
  echo "Release app bundle not found at $app_path" >&2
  exit 1
fi
if [[ ! -x "$app_bin" ]]; then
  echo "Release app executable not found at $app_bin" >&2
  exit 1
fi
if [[ ! -x "$daemon_bin" ]]; then
  echo "Embedded daemon helper not found at $daemon_bin" >&2
  exit 1
fi
if [[ ! -x "$cli_bin" ]]; then
  echo "Embedded daemon CLI helper not found at $cli_bin" >&2
  exit 1
fi
if [[ ! -d "$daemon_resource_bundle" ]]; then
  echo "Embedded daemon resource bundle not found at $daemon_resource_bundle" >&2
  exit 1
fi
if [[ ! -d "$daemon_kernel_resource_bundle" ]]; then
  echo "Embedded daemon Kernel resource bundle not found at $daemon_kernel_resource_bundle" >&2
  exit 1
fi
if [[ ! -f "$project_code_memory_corpus" ]]; then
  echo "Embedded Project Code Memory corpus not found at $project_code_memory_corpus" >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$app_path"
codesign --verify --strict --verbose=2 "$daemon_bin"
codesign --verify --strict --verbose=2 "$cli_bin"

verify_optional_runtime_dependency() {
  local binary="$1"
  local dependency_fragment="$2"
  local embedded_path="$3"
  local description="$4"

  if otool -L "$binary" | grep -Fq "$dependency_fragment"; then
    if [[ ! -e "$embedded_path" ]]; then
      echo "$description is linked by $binary but missing at $embedded_path" >&2
      exit 1
    fi
    echo "Verified dynamically linked $description at $embedded_path"
  else
    echo "Verified $description is statically linked into $binary"
  fi
}

verify_optional_runtime_dependency \
  "$daemon_bin" \
  "libOpenBurnBarCore.dylib" \
  "$daemon_core_dylib" \
  "daemon OpenBurnBarCore runtime"
verify_optional_runtime_dependency \
  "$app_bin" \
  "OpenBurnBarCore.framework" \
  "$app_core_framework" \
  "app OpenBurnBarCore runtime"

mkdir -p "$installed_daemon_dir" "$installed_frameworks_dir" "$(dirname "$installed_project_code_memory_corpus")"
cp "$daemon_bin" "$installed_daemon_bin"
cp "$cli_bin" "$installed_cli_bin"
chmod 755 "$installed_daemon_bin" "$installed_cli_bin"
cp -R "$daemon_resource_bundle" "$installed_resource_bundle"
cp -R "$daemon_kernel_resource_bundle" "$installed_kernel_resource_bundle"
cp "$project_code_memory_corpus" "$installed_project_code_memory_corpus"
for framework in "$app_path"/Contents/Frameworks/*.framework; do
  [[ -d "$framework" ]] || continue
  cp -R "$framework" "$installed_frameworks_dir/"
done

if [[ -d "$app_path/Contents/Frameworks/SQLCipher.framework" && ! -d "$installed_frameworks_dir/SQLCipher.framework" ]]; then
  echo "SQLCipher.framework was not mirrored to installed daemon rpath directory $installed_frameworks_dir" >&2
  exit 1
fi
if [[ ! -x "$installed_daemon_bin" || ! -x "$installed_cli_bin" ]]; then
  echo "Installed-layout daemon or CLI helper is not executable under $installed_daemon_dir" >&2
  exit 1
fi

python3 - <<PY
from pathlib import Path
import plistlib

plist = {
    "Label": "${launch_label}",
    "ProgramArguments": [
        "${installed_daemon_bin}",
        "--socket-path",
        "${socket_path}",
        "--socket-auth-token-file",
        "${socket_auth_token_file}",
        "--version",
        "release-smoke",
    ],
    "EnvironmentVariables": {
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
if ! launchctl bootstrap "gui/$uid" "$launch_plist"; then
  echo "Failed to bootstrap signed installed-layout OpenBurnBar daemon" >&2
  print_failure_diagnostics
  exit 1
fi
if ! launchctl kickstart -k "gui/$uid/$launch_label"; then
  echo "Failed to kickstart signed installed-layout OpenBurnBar daemon" >&2
  print_failure_diagnostics
  exit 1
fi

run_cli_health_probe() {
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$socket_auth_token" \
  OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE="$socket_auth_token_file" \
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
echo "Polling signed installed-layout daemon health via signed OpenBurnBarCLI"
while [[ "$(date +%s)" -lt "$health_deadline_epoch" ]]; do
  attempt=$((attempt + 1))
  if health_output="$(run_cli_health_probe 2>&1)"; then
    last_health_output="$health_output"
    if grep -q "ok=true" <<<"$health_output"; then
      printf '%s\n' "$health_output"
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
  echo "Timed out after ${health_deadline_seconds}s waiting for signed installed-layout OpenBurnBar daemon health" >&2
  if [[ -n "$last_health_output" ]]; then
    printf '%s\n' "$last_health_output" >&2
  fi
  print_failure_diagnostics
  exit 1
fi

echo "OpenBurnBar Release smoke passed: signed app built, signed daemon launched from private installed layout, signed CLI authenticated"
