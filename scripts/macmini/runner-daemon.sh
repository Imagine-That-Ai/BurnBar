#!/usr/bin/env bash

set -euo pipefail

RUNNER_ROOT="${RUNNER_ROOT:-${1:-$HOME/OpenBurnBarUIRunner}}"
QUEUE_DIR="$RUNNER_ROOT/queue"
RESULTS_DIR="$RUNNER_ROOT/results"
LOG_DIR="$RUNNER_ROOT/logs"
BIN_DIR="$RUNNER_ROOT/bin"

mkdir -p "$QUEUE_DIR" "$RESULTS_DIR" "$LOG_DIR" "$BIN_DIR"

daemon_log="$LOG_DIR/runner-daemon.log"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$daemon_log"
}

write_status() {
    local status_path="$1"
    local exit_code="$2"
    local started_at="$3"
    local ended_at="$4"
    local kind="$5"
    python3 - "$status_path" "$exit_code" "$started_at" "$ended_at" "$kind" <<'PY'
import json
import os
import sys

path, exit_code, started_at, ended_at, kind = sys.argv[1:]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump({
        "exitCode": int(exit_code),
        "startedAt": started_at,
        "endedAt": ended_at,
        "kind": kind,
    }, handle, sort_keys=True)
    handle.write("\n")
os.replace(tmp, path)
PY
}

job_field() {
    local job_json="$1"
    local field="$2"
    python3 - "$job_json" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    job = json.load(handle)
value = job
for part in sys.argv[2].split("."):
    value = value.get(part, "")
if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local child_pid
    "$@" &
    child_pid="$!"

    local deadline=$((SECONDS + timeout_seconds))
    while kill -0 "$child_pid" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            log "timeout after ${timeout_seconds}s; terminating pid $child_pid"
            kill -TERM "-$child_pid" 2>/dev/null || kill -TERM "$child_pid" 2>/dev/null || true
            sleep 3
            kill -KILL "-$child_pid" 2>/dev/null || kill -KILL "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
    done
    wait "$child_pid"
}

# Payloads are built with CODE_SIGNING_ALLOWED=NO on the controller, so on the
# mini they carry linker ad-hoc signatures without entitlements and with stale
# CodeResources after transfer. testmanagerd SIGKILLs runners without
# get-task-allow, so re-sign everything ad-hoc here, deepest-first, and stamp
# app bundles with the get-task-allow entitlement a local Debug build would have.
resign_payload() {
    local payload="$1"
    local ents="$BIN_DIR/get-task-allow.plist"
    cat > "$ents" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
PLIST

    local marker="$payload/.openburnbar-resigned"
    if [[ -f "$marker" ]]; then
        log "payload already re-signed; skipping"
        return 0
    fi

    log "re-signing payload bundles (ad-hoc + get-task-allow)"
    # transferred files carry provenance/quarantine xattrs that make codesign
    # fail with "Operation not permitted" — strip them first
    xattr -cr "$payload" 2>/dev/null || true
    local item
    while IFS= read -r item; do
        codesign --force --sign - "$item" 2>/dev/null || true
    done < <(find "$payload" \( -name '*.framework' -o -name '*.xctest' -o -name '*.dylib' -o -name '*.bundle' \) -not -path '*.app/*' -not -path '*.framework/*.framework*' | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

    local app
    while IFS= read -r app; do
        # inner code first, then the container with entitlements
        while IFS= read -r item; do
            codesign --force --sign - "$item" 2>/dev/null || true
        done < <(find "$app" \( -name '*.framework' -o -name '*.xctest' -o -name '*.dylib' -o -name '*.bundle' -o -path '*/Contents/Helpers/*' -type f -perm +111 \) | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
        if ! codesign --force --sign - --entitlements "$ents" "$app"; then
            # The LaunchAgent context lacks the App Management TCC grant, so
            # this can fail with EPERM even when the ssh path succeeds. The
            # canonical fix is controller-side signing before rsync; keep this
            # best-effort and let the test run surface any real problem.
            printf 'warning: re-sign failed for %s; continuing with existing signature\n' "$app" >&2
        fi
    done < <(find "$payload" -maxdepth 2 -name '*.app')

    touch "$marker"
}

run_xcuitest_job() {
    local job_json="$1"
    local result_dir="$2"
    local timeout_seconds="$3"
    local payload
    payload="$(job_field "$job_json" "payload.path")"

    local xctestrun
    xctestrun="$(find "$payload" -name '*.xctestrun' -type f | head -1)"
    if [[ -z "$xctestrun" ]]; then
        printf 'No .xctestrun found under %s\n' "$payload" >&2
        return 66
    fi

    resign_payload "$payload" || return $?

    run_with_timeout "$timeout_seconds" xcodebuild \
        test-without-building \
        -xctestrun "$xctestrun" \
        -destination "platform=macOS,arch=arm64" \
        -resultBundlePath "$result_dir/tests.xcresult"
}

run_axsmoke_job() {
    local job_json="$1"
    local result_dir="$2"
    local timeout_seconds="$3"
    local app_path
    local scenario
    app_path="$(job_field "$job_json" "payload.appPath")"
    scenario="$(job_field "$job_json" "payload.scenario")"
    scenario="${scenario:-openburnbar}"

    if [[ ! -x "$BIN_DIR/CUClickSmoke" ]]; then
        printf 'CUClickSmoke is missing or not executable at %s\n' "$BIN_DIR/CUClickSmoke" >&2
        return 66
    fi

    run_with_timeout "$timeout_seconds" "$BIN_DIR/CUClickSmoke" \
        --scenario "$scenario" \
        --app-path "$app_path" \
        --evidence-path "$result_dir/openburnbar-ax-smoke.png"
}

log_permission_probe() {
    if [[ -x "$BIN_DIR/CUClickSmoke" ]]; then
        "$BIN_DIR/CUClickSmoke" --probe-permissions >> "$daemon_log" 2>&1 || true
    else
        log "CUClickSmoke not installed; permission probe skipped"
    fi
}

process_job() {
    local queued_job="$1"
    local basename
    local id
    basename="$(basename "$queued_job")"
    id="${basename%.job}"

    local result_dir="$RESULTS_DIR/$id"
    mkdir -p "$result_dir"

    local claimed_job="$result_dir/job.json"
    if ! mv "$queued_job" "$claimed_job" 2>/dev/null; then
        return 0
    fi

    local kind
    local timeout_seconds
    kind="$(job_field "$claimed_job" "kind")"
    timeout_seconds="$(job_field "$claimed_job" "timeoutSeconds")"
    timeout_seconds="${timeout_seconds:-1800}"

    local started_at
    local ended_at
    local exit_code
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "picked up job id=$id kind=$kind timeout=${timeout_seconds}s"

    set +e
    {
        printf '[runner] id=%s kind=%s startedAt=%s\n' "$id" "$kind" "$started_at"
        log_permission_probe
        case "$kind" in
            xcuitest)
                run_xcuitest_job "$claimed_job" "$result_dir" "$timeout_seconds"
                ;;
            axsmoke)
                run_axsmoke_job "$claimed_job" "$result_dir" "$timeout_seconds"
                ;;
            *)
                printf 'Unknown job kind: %s\n' "$kind" >&2
                exit 64
                ;;
        esac
    } > >(tee -a "$result_dir/runner.log") 2> >(tee -a "$result_dir/runner.log" >&2)
    exit_code=$?
    set -e

    if [[ "$exit_code" -ne 0 ]]; then
        screencapture -x "$result_dir/failure-desktop.png" >/dev/null 2>&1 || true
    fi
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_status "$result_dir/status.json" "$exit_code" "$started_at" "$ended_at" "$kind"
    log "finished job id=$id kind=$kind exit=$exit_code"
}

log "runner daemon starting root=$RUNNER_ROOT"
log_permission_probe

while true; do
    shopt -s nullglob
    jobs=("$QUEUE_DIR"/*.job)
    shopt -u nullglob
    for job in "${jobs[@]}"; do
        process_job "$job"
    done
    sleep 2
done
