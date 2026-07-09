#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/macmini/lib.sh
source "$script_dir/lib.sh"

load_macmini_config

pass_count=0
fail_count=0

record() {
    local name="$1"
    local status="$2"
    local detail="$3"
    printf '%-28s %-6s %s\n' "$name" "$status" "$detail"
    if [[ "$status" == "PASS" ]]; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
}

check() {
    local name="$1"
    shift
    local output
    if output="$("$@" 2>&1)"; then
        record "$name" "PASS" "$output"
    else
        record "$name" "FAIL" "$output"
    fi
}

ssh_echo() {
    mini_ssh "printf ok"
}

runner_root="$(mini_resolve_runner_root 2>/dev/null || true)"
if [[ -z "$runner_root" ]]; then
    runner_root="$MACMINI_RUNNER_ROOT"
fi
runner_root_q="$(printf "%q" "$runner_root")"
uid="$(mini_ssh "id -u" 2>/dev/null || true)"

printf '%-28s %-6s %s\n' "CHECK" "STATE" "DETAIL"
printf '%-28s %-6s %s\n' "-----" "-----" "------"

check "ssh" ssh_echo
check "arch" mini_ssh "uname -m"
check "xcodebuild" mini_ssh "xcodebuild -version | tr '\n' ' '"
if [[ -n "$uid" ]]; then
    check "gui session" mini_ssh "launchctl print gui/$uid >/dev/null && printf gui/$uid"
    check "LaunchAgent" mini_ssh "launchctl print gui/$uid/com.openburnbar.uitest-runner >/dev/null && printf loaded"
else
    record "gui session" "FAIL" "could not resolve uid"
    record "LaunchAgent" "FAIL" "could not resolve uid"
fi
check "permission probe" mini_ssh "$runner_root_q/bin/CUClickSmoke --probe-permissions"
check "disk free" mini_ssh "df -h $runner_root_q | tail -1"
check "queue writable" mini_ssh "test -w $runner_root_q/queue && printf writable"
check "results writable" mini_ssh "test -w $runner_root_q/results && printf writable"

printf '\nPASS=%d FAIL=%d\n' "$pass_count" "$fail_count"
if ((fail_count > 0)); then
    exit 1
fi
