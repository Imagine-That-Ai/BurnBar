#!/usr/bin/env bash
set -euo pipefail

# Resolve a release tag to a signed, annotated tag object whose commit is on the
# trusted base branch. This script must run before checking out release code or
# exposing release/deploy secrets to repository scripts.

tag="${INPUT_TAG:-}"
base_branch="${RELEASE_BASE_BRANCH:-main}"
require_github_verification="${REQUIRE_GITHUB_TAG_VERIFICATION:-true}"

if [[ -z "$tag" ]]; then
  tag="${GITHUB_REF_NAME:-}"
fi

if [[ ! "$tag" =~ ^v[0-9][0-9A-Za-z._-]*$ ]]; then
  echo "::error::Invalid release tag '${tag}'. Expected a version-like v* tag with no path separators." >&2
  exit 1
fi

if [[ ! "$base_branch" =~ ^[A-Za-z0-9._/-]+$ || "$base_branch" == *..* || "$base_branch" == /* ]]; then
  echo "::error::Invalid release base branch '${base_branch}'." >&2
  exit 1
fi

git fetch --force --tags origin "refs/tags/${tag}:refs/tags/${tag}"
git fetch --no-tags origin "+refs/heads/${base_branch}:refs/remotes/origin/${base_branch}"

tag_ref="refs/tags/${tag}"
if ! git rev-parse -q --verify "${tag_ref}^{tag}" >/dev/null; then
  echo "::error::Release tag '${tag}' must be an annotated tag, not a lightweight tag." >&2
  exit 1
fi

tag_object_sha="$(git rev-parse "${tag_ref}^{tag}")"
commit_sha="$(git rev-list -n 1 "$tag_ref")"

if ! git merge-base --is-ancestor "$commit_sha" "refs/remotes/origin/${base_branch}"; then
  echo "::error::Release tag '${tag}' commit ${commit_sha} is not reachable from origin/${base_branch}." >&2
  exit 1
fi

if [[ "$require_github_verification" == "true" ]]; then
  python3 - "$tag" "$tag_object_sha" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

tag, expected_tag_sha = sys.argv[1:3]
repo = os.environ.get("GITHUB_REPOSITORY")
token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
if not repo or not token:
    raise SystemExit("::error::GITHUB_REPOSITORY and GH_TOKEN/GITHUB_TOKEN are required for tag signature verification.")

base = f"https://api.github.com/repos/{repo}"
headers = {
    "Accept": "application/vnd.github+json",
    "Authorization": f"Bearer {token}",
    "X-GitHub-Api-Version": "2022-11-28",
}

def github_json(path: str) -> dict:
    request = urllib.request.Request(base + path, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"::error::GitHub API verification request failed: HTTP {exc.code}: {detail}") from exc

ref = github_json(f"/git/ref/tags/{tag}")
obj = ref.get("object") or {}
if obj.get("type") != "tag":
    raise SystemExit(f"::error::Release tag '{tag}' must resolve to an annotated tag object; GitHub reported {obj.get('type')!r}.")
if obj.get("sha") != expected_tag_sha:
    raise SystemExit(f"::error::Local tag object {expected_tag_sha} does not match GitHub tag object {obj.get('sha')}.")

tag_obj = github_json(f"/git/tags/{expected_tag_sha}")
verification = tag_obj.get("verification") or {}
if verification.get("verified") is not True:
    reason = verification.get("reason") or "unknown"
    raise SystemExit(f"::error::Release tag '{tag}' is not GitHub-verified: {reason}.")

print(f"GitHub verified annotated release tag {tag} ({expected_tag_sha}).")
PY
fi

version="${tag#v}"
{
  printf 'tag_name=%s\n' "$tag"
  printf 'version=%s\n' "$version"
  printf 'commit_sha=%s\n' "$commit_sha"
  printf 'tag_object_sha=%s\n' "$tag_object_sha"
  printf 'base_branch=%s\n' "$base_branch"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

echo "Trusted release tag ${tag} resolves to ${commit_sha} on origin/${base_branch}."
