#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/macmini/lib.sh
source "$script_dir/lib.sh"

export FIREBASE_SOURCE_FIRESTORE="${FIREBASE_SOURCE_FIRESTORE:-1}"

usage() {
    cat <<'EOF'
Usage: scripts/macmini/run-remote-ui-tests.sh [options]

Options:
  --dry-run                  Print the controller/mini plan without SSH.
  --ax-smoke <OpenBurnBar.app>
                             Push a built app and run CUClickSmoke openburnbar.
  --timeout-seconds <n>      Job timeout on the mini (default 1800).
  --poll-timeout-seconds <n> Controller polling timeout (default 1800).
  -only-testing:<target>     Forward one XCUITest filter.
  -only-testing <target>     Forward one XCUITest filter.
  -h, --help                 Show this help.

Environment:
  OPENBURNBAR_UI_TEST_FILTER=<target>
      Default -only-testing target when CLI filters are absent.
  OPENBURNBAR_UI_ARTIFACT_DIR=<path>
      Local artifact root (default .artifacts/macmini).
  OPENBURNBAR_UI_DERIVED_DATA_ROOT=<path>
      Controller derived-data root (default TMPDIR/openburnbar-ui-tests).
EOF
}

dry_run=0
ax_smoke_app=""
timeout_seconds="${OPENBURNBAR_UI_TIMEOUT_SECONDS:-1800}"
poll_timeout_seconds="${OPENBURNBAR_UI_POLL_TIMEOUT_SECONDS:-1800}"
cli_filters=()

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --dry-run)
            dry_run=1
            shift
            ;;
        --ax-smoke)
            shift
            [[ "$#" -gt 0 ]] || die "--ax-smoke requires an app path"
            ax_smoke_app="$1"
            shift
            ;;
        --timeout-seconds)
            shift
            [[ "$#" -gt 0 ]] || die "--timeout-seconds requires a value"
            timeout_seconds="$1"
            shift
            ;;
        --poll-timeout-seconds)
            shift
            [[ "$#" -gt 0 ]] || die "--poll-timeout-seconds requires a value"
            poll_timeout_seconds="$1"
            shift
            ;;
        -only-testing:*)
            cli_filters+=("${1#-only-testing:}")
            shift
            ;;
        -only-testing)
            shift
            [[ "$#" -gt 0 ]] || die "-only-testing requires a target"
            cli_filters+=("$1")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unsupported argument '$1'"
            ;;
    esac
done

filters=()
if ((${#cli_filters[@]})); then
    filters=("${cli_filters[@]}")
elif [[ -n "${OPENBURNBAR_UI_TEST_FILTER:-}" ]]; then
    filters=("$OPENBURNBAR_UI_TEST_FILTER")
fi

artifact_root="${OPENBURNBAR_UI_ARTIFACT_DIR:-$repo_root/.artifacts/macmini}"
derived_data_root="${OPENBURNBAR_UI_DERIVED_DATA_ROOT:-${TMPDIR:-/tmp}/openburnbar-ui-tests}"
cache_dir="$repo_root/.spm-cache-new"
job_id="ui-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -d- -f1)"

build_args=(
    -project "$repo_root/OpenBurnBar.xcodeproj"
    -scheme "OpenBurnBarUITests"
    -destination "platform=macOS,arch=arm64"
    -clonedSourcePackagesDirPath "$cache_dir"
    SWIFT_ENABLE_EXPLICIT_MODULES=NO
    SWIFT_COMPILATION_MODE=singlefile
    SWIFT_ENABLE_BATCH_MODE=NO
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
)
if ((${#filters[@]})); then
    for filter in "${filters[@]}"; do
        build_args+=("-only-testing:$filter")
    done
fi

if [[ "$dry_run" == "1" ]]; then
    cat <<EOF
Dry run: no SSH, rsync, xcodebuild, or filesystem mutation outside temp planning.

Mode: $([[ -n "$ax_smoke_app" ]] && printf 'axsmoke' || printf 'xcuitest')
Job id: $job_id
Controller artifact root: $artifact_root
Controller derived-data root: $derived_data_root
Remote runner root: configured by scripts/macmini/config.env (default ~/OpenBurnBarUIRunner)
Timeout seconds: $timeout_seconds
Poll timeout seconds: $poll_timeout_seconds

Build command for XCUITest mode:
  xcodebuild build-for-testing \\
EOF
    printf '    %q \\\n' "${build_args[@]}"
    cat <<'EOF'

Live flow:
  1. Build for testing on the controller.
  2. xattr -cr Build/Products.
  3. rsync payload to mini payloads/<job-id>/.
  4. atomically queue queue/<job-id>.job.
  5. poll results/<job-id>/status.json every 10s.
  6. rsync results back to .artifacts/macmini/<job-id>/.
EOF
    exit 0
fi

load_macmini_config
runner_root="$(mini_resolve_runner_root)"
runner_root_q="$(printf "%q" "$runner_root")"
remote_payload="$runner_root/payloads/$job_id"
remote_payload_q="$(printf "%q" "$remote_payload")"
remote_result="$runner_root/results/$job_id"
remote_result_q="$(printf "%q" "$remote_result")"
remote_queue_tmp="$runner_root/queue/$job_id.job.tmp"
remote_queue_job="$runner_root/queue/$job_id.job"
remote_queue_tmp_q="$(printf "%q" "$remote_queue_tmp")"
remote_queue_job_q="$(printf "%q" "$remote_queue_job")"
local_artifact_dir="$artifact_root/$job_id"

mkdir -p "$artifact_root" "$derived_data_root" "$cache_dir"
derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-ui-tests.XXXXXX")"
job_json="$(mktemp "${TMPDIR:-/tmp}/openburnbar-ui-job.XXXXXX.json")"
trap 'rm -f "$job_json"; rm -rf "$derived_data_dir"' EXIT

if [[ -n "$ax_smoke_app" ]]; then
    [[ -d "$ax_smoke_app" ]] || die "app path does not exist: $ax_smoke_app"
    log "building CUClickSmoke release binary"
    swift build -c release --package-path "$repo_root/tools/CUClickSmoke"

    log "preparing remote payload $remote_payload"
    mini_ssh "rm -rf $remote_payload_q && mkdir -p $remote_payload_q $runner_root_q/bin"
    mini_rsync "$ax_smoke_app" "$MACMINI_USER@$MACMINI_HOST:$remote_payload/"
    mini_rsync "$repo_root/tools/CUClickSmoke/.build/release/CUClickSmoke" "$MACMINI_USER@$MACMINI_HOST:$runner_root/bin/CUClickSmoke"
    app_basename="$(basename "$ax_smoke_app")"
    remote_app_path="$remote_payload/$app_basename"

    python3 - "$job_json" "$job_id" "$timeout_seconds" "$remote_app_path" <<'PY'
import json
import sys

path, job_id, timeout, app_path = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "id": job_id,
        "kind": "axsmoke",
        "payload": {"appPath": app_path, "scenario": "openburnbar"},
        "timeoutSeconds": int(timeout),
    }, handle, sort_keys=True)
    handle.write("\n")
PY
else
    build_args+=(
        -derivedDataPath "$derived_data_dir"
        -resultBundlePath "$derived_data_dir/build-for-testing.xcresult"
    )
    log "building OpenBurnBarUITests for testing on the controller"
    xcodebuild build-for-testing "${build_args[@]}"

    products_dir="$derived_data_dir/Build/Products"
    xctestrun="$(find "$products_dir" -name '*.xctestrun' -type f | head -1)"
    [[ -n "$xctestrun" ]] || die "no .xctestrun found under $products_dir"
    xattr -cr "$products_dir" || true

    log "preparing remote payload $remote_payload"
    mini_ssh "rm -rf $remote_payload_q && mkdir -p $remote_payload_q"
    mini_rsync "$products_dir/" "$MACMINI_USER@$MACMINI_HOST:$remote_payload/"

    python3 - "$job_json" "$job_id" "$timeout_seconds" "$remote_payload" <<'PY'
import json
import sys

path, job_id, timeout, payload = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "id": job_id,
        "kind": "xcuitest",
        "payload": {"path": payload},
        "timeoutSeconds": int(timeout),
    }, handle, sort_keys=True)
    handle.write("\n")
PY
fi

log "queueing remote job $job_id"
mini_ssh "cat > $remote_queue_tmp_q && mv $remote_queue_tmp_q $remote_queue_job_q" < "$job_json"

poll_started="$SECONDS"
last_log_size=-1
last_growth="$SECONDS"
while true; do
    if mini_ssh "test -f $remote_result_q/status.json" >/dev/null 2>&1; then
        break
    fi
    if ((SECONDS - poll_started >= poll_timeout_seconds)); then
        warn "poll timeout after ${poll_timeout_seconds}s for $job_id"
        break
    fi

    current_log_size="$(mini_ssh "if [[ -f $remote_result_q/runner.log ]]; then wc -c < $remote_result_q/runner.log; else printf 0; fi" 2>/dev/null || printf 0)"
    if [[ "$current_log_size" != "$last_log_size" ]]; then
        last_log_size="$current_log_size"
        last_growth="$SECONDS"
    elif ((SECONDS - last_growth >= 300)); then
        warn "runner.log has not grown for $((SECONDS - last_growth))s"
        last_growth="$SECONDS"
    fi
    sleep 10
done

log "pulling remote results to $local_artifact_dir"
mkdir -p "$local_artifact_dir"
mini_rsync "$MACMINI_USER@$MACMINI_HOST:$remote_result/" "$local_artifact_dir/"

status_path="$local_artifact_dir/status.json"
if [[ ! -f "$status_path" ]]; then
    warn "missing status.json; treating as infrastructure failure"
    exit 124
fi

exit_code="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["exitCode"])' "$status_path")"
kind="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["kind"])' "$status_path")"

printf '\nRemote UI job summary\n'
printf '  id: %s\n' "$job_id"
printf '  kind: %s\n' "$kind"
printf '  exitCode: %s\n' "$exit_code"
printf '  artifacts: %s\n' "$local_artifact_dir"
if [[ -d "$local_artifact_dir/tests.xcresult" ]]; then
    printf '  xcresult: %s\n' "$local_artifact_dir/tests.xcresult"
fi
find "$local_artifact_dir" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' \) -print | sed 's/^/  screenshot: /'

exit "$exit_code"
