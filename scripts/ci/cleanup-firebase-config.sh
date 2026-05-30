#!/bin/sh

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

for resources_dir in \
    "$repo_root/AgentLens/Resources" \
    "$repo_root/OpenBurnBarMobile/Resources"; do
    plist_path="$resources_dir/GoogleService-Info.plist"
    marker_path="$resources_dir/.firebase-ci-injected"
    if [ -f "$marker_path" ] && [ -f "$plist_path" ]; then
        rm -f "$plist_path"
        rm -f "$marker_path"
        echo "Removed injected Firebase config at $plist_path"
    fi
done
