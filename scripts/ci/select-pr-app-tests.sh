#!/usr/bin/env bash
# select-pr-app-tests.sh — wave 3.8 impact-based app test selection for the PR door.
#
# Prints the OPENBURNBAR_APP_TEST_FILTERS value for this PR: the release smoke
# catalog ALWAYS, plus OpenBurnBarTests classes impacted by the base...head
# diff. Post-merge/nightly still runs the full corpus; this is the split test
# plan's PR side.
#
# Mapping (deterministic; mirrors project.yml bundle membership):
#   AgentLensTests/Active/**/*.swift  -> every *Tests class declared in the file
#   AgentLens/**, OpenBurnBarCore/**, OpenBurnBarDaemon/** (sources)
#     -> <Stem>Tests + <Stem>MattersTests when those files exist under
#        AgentLensTests/Active (extension files Foo+Bar.swift also try Foo).
#   Everything else (mobile, workflows, configs, docs) -> smoke only. The
#   xcodebuild build itself is the signal for build-affecting changes.
#
# Usage:
#   scripts/ci/select-pr-app-tests.sh [<base> <head>]
#   Base/head default to PR_BASE_SHA/PR_HEAD_SHA, then to the pull_request
#   merge parents HEAD^1/HEAD^2. An unresolvable diff is a HARD error (exit 1):
#   a PR that cannot be classified must not silently run smoke-only.
#
# Output: the ';'-joined filter list on stdout, plus filters=<list> appended
#   to $GITHUB_OUTPUT when set. Diagnostics go to stderr.
set -euo pipefail

repo_root="${SELECT_PR_APP_TESTS_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

# shellcheck source=scripts/lib/openburnbar-release-app-test-filters.sh
source "$repo_root/scripts/lib/openburnbar-release-app-test-filters.sh"

resolve_range() {
    if [[ $# -eq 2 && -n "${1:-}" && -n "${2:-}" ]]; then
        printf '%s\n%s\n' "$1" "$2"
        return 0
    fi
    if [[ -n "${PR_BASE_SHA:-}" && -n "${PR_HEAD_SHA:-}" ]]; then
        printf '%s\n%s\n' "$PR_BASE_SHA" "$PR_HEAD_SHA"
        return 0
    fi
    if git -C "$repo_root" cat-file -e "HEAD^1^{commit}" 2>/dev/null && \
       git -C "$repo_root" cat-file -e "HEAD^2^{commit}" 2>/dev/null; then
        printf 'HEAD^1\nHEAD^2\n'
        return 0
    fi
    echo "select-pr-app-tests: cannot resolve base/head (pass <base> <head>, set PR_BASE_SHA/PR_HEAD_SHA, or run on a merge commit)" >&2
    return 1
}

# Print every *Tests class declared in a Swift test file (one per line).
test_classes_in_file() {
    grep -oE 'class [A-Za-z0-9_]+Tests\b' "$1" 2>/dev/null | awk '{print $2}' | sort -u
}

if [[ $# -eq 0 ]]; then
    range_lines="$(resolve_range)" || exit 1
elif [[ $# -eq 2 ]]; then
    range_lines="$(resolve_range "$1" "$2")" || exit 1
else
    echo "usage: select-pr-app-tests.sh [<base> <head>]" >&2
    exit 2
fi
base="$(sed -n '1p' <<<"$range_lines")"
head="$(sed -n '2p' <<<"$range_lines")"

changed="$(git -C "$repo_root" diff --name-only "$base" "$head" --)" || {
    echo "select-pr-app-tests: git diff $base...$head failed" >&2
    exit 1
}
if [[ -z "$changed" ]]; then
    echo "select-pr-app-tests: empty diff $base...$head" >&2
    exit 1
fi

# Order-preserving dedup without associative arrays (macOS ships bash 3.2).
# Quadratic, but the list holds dozens of entries at most.
filters=()
add_filter() {
    local existing
    for existing in ${filters[@]+"${filters[@]}"}; do
        if [[ "$existing" == "$1" ]]; then return 0; fi
    done
    filters+=("$1")
}

# Smoke catalog first, always.
for smoke in "${OPENBURNBAR_RELEASE_APP_TEST_FILTERS[@]}"; do
    add_filter "$smoke"
done
impacted_count=0

while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
        AgentLensTests/Quarantine/*)
            # Not compiled into the bundle; nothing to run.
            continue
            ;;
        AgentLensTests/*)
            if [[ "$path" != *.swift ]]; then continue; fi
            if [[ ! -f "$repo_root/$path" ]]; then continue; fi  # deleted file
            while IFS= read -r class; do
                [[ -n "$class" ]] || continue
                add_filter "OpenBurnBarTests/$class"
                impacted_count=$((impacted_count + 1))
            done < <(test_classes_in_file "$repo_root/$path")
            ;;
        AgentLens/*|OpenBurnBarCore/*|OpenBurnBarDaemon/*)
            if [[ "$path" != *.swift ]]; then continue; fi
            stem="$(basename "$path" .swift)"
            candidates=("$stem")
            if [[ "$stem" == *+* ]]; then
                candidates+=("${stem%%+*}")
            fi
            for candidate in "${candidates[@]}"; do
                for suffix in Tests MattersTests; do
                    test_file="$repo_root/AgentLensTests/Active/${candidate}${suffix}.swift"
                    if [[ -f "$test_file" ]]; then
                        while IFS= read -r class; do
                            [[ -n "$class" ]] || continue
                            add_filter "OpenBurnBarTests/$class"
                            impacted_count=$((impacted_count + 1))
                        done < <(test_classes_in_file "$test_file")
                    fi
                done
            done
            ;;
        *)
            # Mobile, workflows, configs, docs: smoke covers the build signal.
            continue
            ;;
    esac
done <<<"$changed"

joined="$(IFS=';'; printf '%s' "${filters[*]}")"
printf '%s\n' "$joined"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'filters=%s\n' "$joined" >>"$GITHUB_OUTPUT"
fi
echo "select-pr-app-tests: ${#OPENBURNBAR_RELEASE_APP_TEST_FILTERS[@]} smoke + $impacted_count impacted filter(s) from $base...$head" >&2
