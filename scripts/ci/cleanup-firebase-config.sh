#!/bin/sh

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
config_paths="$repo_root/AgentLens/Resources/GoogleService-Info.plist:$repo_root/OpenBurnBarMobile/Resources/GoogleService-Info.plist:$repo_root/android/app/google-services.json:$repo_root/android/app/google-services.json"
marker_paths="$repo_root/AgentLens/Resources/.firebase-ci-injected:$repo_root/OpenBurnBarMobile/Resources/.firebase-ci-injected:$repo_root/android/app/.firebase-ci-injected:$repo_root/android/app/.firebase-unit-test-injected"

old_ifs="$IFS"
IFS=:
set -- $config_paths
config_one="${1:-}"
config_two="${2:-}"
config_three="${3:-}"
config_four="${4:-}"
set -- $marker_paths
marker_one="${1:-}"
marker_two="${2:-}"
marker_three="${3:-}"
marker_four="${4:-}"
IFS="$old_ifs"

remove_marker_owned_config() {
    marker_path="$1"
    config_path="$2"
    if [ -f "$marker_path" ] && [ -f "$config_path" ]; then
        rm -f "$config_path"
        rm -f "$marker_path"
        removed=1
    fi
}

removed=0
remove_marker_owned_config "$marker_one" "$config_one"
remove_marker_owned_config "$marker_two" "$config_two"
remove_marker_owned_config "$marker_three" "$config_three"

if [ -f "$marker_four" ]; then
    if [ -f "$config_four" ]; then
        if python3 - "$config_four" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
project_id = payload.get("project_info", {}).get("project_id")
client = (payload.get("client") or [{}])[0]
app_id = client.get("client_info", {}).get("mobilesdk_app_id")
api_key = ((client.get("api_key") or [{}])[0]).get("current_key")
if (
    project_id == "openburnbar-unit-tests"
    and app_id == "1:000000000000:android:0000000000000000000000"
    and api_key == "AIza000000000000000000000000000000000"
):
    raise SystemExit(0)
raise SystemExit(1)
PY
        then
            rm -f "$config_four"
            removed=1
        else
            echo "Refusing to remove android/app/google-services.json: unit-test marker exists but config is not the deterministic unit-test file" >&2
            exit 1
        fi
    fi
    rm -f "$marker_four"
    removed=1
fi

if [ "$removed" -eq 1 ]; then
    echo "Removed injected Firebase config"
fi
