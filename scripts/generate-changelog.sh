#!/bin/bash
# BurnBar Changelog Generator
# Generates a human-readable changelog from git commits between two tags
# Usage: ./scripts/generate-changelog.sh <from_tag> <to_tag>

set -euo pipefail

FROM_TAG="${1:?Usage: generate-changelog.sh <from_tag> <to_tag>}"
TO_TAG="${2:-HEAD}"

echo "# Changelog"
echo ""
echo "## ${TO_TAG} (from ${FROM_TAG})"
echo ""
echo "_Generated $(date -u '+%Y-%m-%d')_"
echo ""

# Categorize commits by conventional commit prefixes
categorize() {
  local prefix="$1"
  local title="$2"
  local commits
  commits=$(git log "${FROM_TAG}..${TO_TAG}" --pretty=format:"- %s (%h)" --grep="^${prefix}" 2>/dev/null || true)
  if [ -n "$commits" ]; then
    echo "### ${title}"
    echo ""
    echo "$commits"
    echo ""
  fi
}

# Breaking changes first
breaking=$(git log "${FROM_TAG}..${TO_TAG}" --pretty=format:"- %s (%h)" --all-match --grep="BREAKING CHANGE" 2>/dev/null || true)
if [ -n "$breaking" ]; then
  echo "### BREAKING CHANGES"
  echo ""
  echo "$breaking"
  echo ""
fi

categorize "feat" "Features"
categorize "fix" "Bug Fixes"
categorize "perf" "Performance"
categorize "docs" "Documentation"
categorize "refactor" "Refactoring"
categorize "chore" "Maintenance"
categorize "ci" "CI/CD"
categorize "test" "Tests"

# Other commits that don't match conventional commit prefixes
other=$(git log "${FROM_TAG}..${TO_TAG}" --pretty=format:"- %s (%h)" \
  --invert-grep \
  --regexp-ignore-case \
  --grep='^feat(\(|:)|^fix(\(|:)|^docs(\(|:)|^refactor(\(|:)|^perf(\(|:)|^chore(\(|:)|^style(\(|:)|^test(\(|:)|^ci(\(|:)|^build(\(|:)' 2>/dev/null || true)
if [ -n "$other" ]; then
  echo "### Other"
  echo ""
  echo "$other"
  echo ""
fi

# Contributor summary
echo "---"
echo ""
contributors=$(git log "${FROM_TAG}..${TO_TAG}" --format='%aN' 2>/dev/null | sort -u | grep -v 'github-actions\|dependabot' || true)
contrib_count=$(echo "$contributors" | grep -c . 2>/dev/null || echo 0)
commit_count=$(git log "${FROM_TAG}..${TO_TAG}" --oneline 2>/dev/null | wc -l | tr -d ' ')

if [ "$contrib_count" -gt 0 ]; then
  echo "**${commit_count} commits** by **${contrib_count} contributors**:"
  echo ""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    echo "- @${name}"
  done <<< "$contributors"
fi
