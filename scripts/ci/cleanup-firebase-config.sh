#!/bin/sh

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plist_paths="$repo_root/AgentLens/Resources/GoogleService-Info.plist:$repo_root/OpenBurnBarMobile/Resources/GoogleService-Info.plist"
marker_paths="$repo_root/AgentLens/Resources/.firebase-ci-injected:$repo_root/OpenBurnBarMobile/Resources/.firebase-ci-injected"

old_ifs="$IFS"
IFS=:
set -- $plist_paths
plist_one="${1:-}"
plist_two="${2:-}"
set -- $marker_paths
marker_one="${1:-}"
marker_two="${2:-}"
IFS="$old_ifs"

removed=0
for pair in "$marker_one:$plist_one" "$marker_two:$plist_two"; do
    marker_path="${pair%%:*}"
    plist_path="${pair#*:}"
    if [ -f "$marker_path" ] && [ -f "$plist_path" ]; then
        rm -f "$plist_path"
        rm -f "$marker_path"
        removed=1
    fi
done

if [ "$removed" -eq 1 ]; then
    echo "Removed injected Firebase config"
fi
