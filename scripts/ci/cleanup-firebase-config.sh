#!/bin/sh

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plist_path="$repo_root/AgentLens/Resources/GoogleService-Info.plist"
marker_path="$repo_root/AgentLens/Resources/.firebase-ci-injected"

if [ -f "$marker_path" ] && [ -f "$plist_path" ]; then
    rm -f "$plist_path"
    rm -f "$marker_path"
    echo "Removed injected Firebase config"
fi
