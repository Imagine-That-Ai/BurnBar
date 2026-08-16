#!/usr/bin/env bash
# publish-mirror.sh — mirror plugins/openburnbar into the thin public plugin repo.
#
# The plugin tree is mirrored to the ROOT of Imagine-That-Ai/openburnbar-cursor-plugin,
# so `.cursor-plugin/plugin.json` lands at the repo root. Only the plugin tree is
# copied (README.md, LICENSE, AUTH.md, CHANGELOG.md, mcp.json, .cursor-plugin/,
# assets/, skills/, commands/, rules/, agents/, scripts/, docs/) — Swift, Xcode,
# daemon, and BurnBar monorepo files never enter the copy set. The mirror commit is
# pushed to the thin repo's default branch.
#
# The plugin root is resolved from this script's own directory (same copy-aware idea
# as validate.mjs), so the script also works from a /tmp copy of the plugin tree.
#
# Fail-closed reuse: when SIBLING_DIR already contains .git, the script requires the
# clone's origin URL (and any configured remote.origin.pushurl) to identify the same
# repository as THIN_REPO (https, git@, or any equivalent form of the same owner/repo
# path) and requires a fully clean working tree (no staged, unstaged, or untracked
# files). Wrong-origin, wrong-pushurl, or dirty clones exit 1 before anything is
# copied. fetch / checkout / branch-resolution failures are never swallowed
# (no `|| true`, no stderr suppression on those steps): they abort the run.
#
# Before copying, every root entry except .git is removed — including untracked
# leftovers that `git rm` would miss — so nothing outside the plugin tree can be
# staged by the final `git add -A`.
#
# Env overrides: THIN_REPO (thin repo URL), SIBLING_DIR (sibling clone path).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

THIN_REPO="${THIN_REPO:-https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin}"
SIBLING_DIR="${SIBLING_DIR:-/Users/dewclaw/openburnbar-cursor-plugin}"

if [ -z "${SIBLING_DIR}" ] || [ "${SIBLING_DIR}" = "/" ]; then
  echo "publish-mirror: error: SIBLING_DIR must be a real directory path" >&2
  exit 1
fi

# Make SIBLING_DIR absolute when a relative path was supplied so every later
# comparison and the final wipe operate on exactly one, unambiguous location.
case "${SIBLING_DIR}" in
  /*) ;;
  *) SIBLING_DIR="$(pwd)/${SIBLING_DIR}" ;;
esac

# --- Pre-flight: the package must be valid and name the thin repo. ---

if [ ! -f "${PLUGIN_ROOT}/.cursor-plugin/plugin.json" ]; then
  echo "publish-mirror: error: no .cursor-plugin/plugin.json under ${PLUGIN_ROOT}" >&2
  exit 1
fi

# Fail closed: the package must be valid (AGPL, no Swift/Xcode/daemon, no
# marketplace.json, no secrets) before we publish it.
node "${PLUGIN_ROOT}/scripts/validate.mjs" >/dev/null

# The manifest repository field must name the thin repo (never the monorepo).
REPOSITORY_FIELD="$(node -e "const m = require('${PLUGIN_ROOT}/.cursor-plugin/plugin.json'); console.log(typeof m.repository === 'string' ? m.repository : ((m.repository && m.repository.url) || ''))")"
if [ "${REPOSITORY_FIELD}" != "${THIN_REPO}" ]; then
  echo "publish-mirror: error: plugin.json.repository is '${REPOSITORY_FIELD}', expected '${THIN_REPO}'" >&2
  exit 1
fi

# --- Normalize a repo URL to its owner/repo identity. ---
#
# https://github.com/Owner/Repo, https://github.com/Owner/Repo.git,
# git@github.com:Owner/Repo.git, git://github.com/Owner/Repo, and
# ssh://git@github.com/Owner/Repo all map to Owner/Repo, so any of these
# origin forms is accepted for the sibling clone (and nothing else is).
normalize_repo_id() {
  local url="$1"
  url="${url#*://}"   # drop git:// https:// ssh:// file:// ...
  url="${url#*@}"     # drop user@ (git@github.com:... -> github.com:...)
  url="${url/:/\//}"  # scp-like host:path -> host/path
  url="${url#*/}"     # drop the host, keep owner/repo[...]
  url="${url%.git}"   # drop a trailing .git
  echo "${url}"
}

THIN_REPO_ID="$(normalize_repo_id "${THIN_REPO}")"
if [ -z "${THIN_REPO_ID}" ]; then
  echo "publish-mirror: error: cannot parse THIN_REPO '${THIN_REPO}'" >&2
  exit 1
fi

# --- Clone or reuse the sibling checkout. ---

if [ ! -d "${SIBLING_DIR}/.git" ]; then
  echo "publish-mirror: cloning ${THIN_REPO} into ${SIBLING_DIR}"
  # Clone failures (bad URL, unreachable host, missing parents) abort here.
  git clone --quiet "${THIN_REPO}" "${SIBLING_DIR}"
else
  echo "publish-mirror: reusing ${SIBLING_DIR}"

  # Gate 1 — the existing clone's origin URL must identify the same repository
  # as THIN_REPO. Every configured origin URL must normalize to the same
  # owner/repo identity; a missing origin also fails closed.
  ORIGIN_MATCHES=0
  ORIGIN_MISMATCHES=0
  while IFS= read -r origin_url; do
    if [ "$(normalize_repo_id "${origin_url}")" = "${THIN_REPO_ID}" ]; then
      ORIGIN_MATCHES=1
    else
      echo "publish-mirror: error: ${SIBLING_DIR} origin '${origin_url}' does not match THIN_REPO '${THIN_REPO}'" >&2
      ORIGIN_MISMATCHES=1
    fi
  done < <(git -C "${SIBLING_DIR}" config --get-all remote.origin.url 2>/dev/null || true)
  if [ "${ORIGIN_MATCHES}" -ne 1 ] || [ "${ORIGIN_MISMATCHES}" -ne 0 ]; then
    if [ "${ORIGIN_MATCHES}" -ne 1 ]; then
      echo "publish-mirror: error: ${SIBLING_DIR} has no origin remote matching ${THIN_REPO}; refusing to reuse" >&2
    fi
    exit 1
  fi

  # Gate 1b — a configured remote.origin.pushurl must identify the same
  # repository as THIN_REPO. pushurl overrides url for pushes, so a sibling
  # clone whose pushurl points anywhere else would silently push the mirror
  # to the wrong repo. An unset pushurl is fine: url is used for pushes.
  PUSHURL_MISMATCHES=0
  while IFS= read -r pushurl; do
    if [ "$(normalize_repo_id "${pushurl}")" != "${THIN_REPO_ID}" ]; then
      echo "publish-mirror: error: ${SIBLING_DIR} remote.origin.pushurl '${pushurl}' does not match THIN_REPO '${THIN_REPO}'" >&2
      PUSHURL_MISMATCHES=1
    fi
  done < <(git -C "${SIBLING_DIR}" config --get-all remote.origin.pushurl 2>/dev/null || true)
  if [ "${PUSHURL_MISMATCHES}" -ne 0 ]; then
    exit 1
  fi

  # Gate 2 — the working tree must be completely clean (no staged, unstaged,
  # or untracked files). A dirty clone is refused before anything is written.
  if [ -n "$(git -C "${SIBLING_DIR}" status --porcelain)" ]; then
    echo "publish-mirror: error: ${SIBLING_DIR} working tree is not clean; refusing to reuse:" >&2
    git -C "${SIBLING_DIR}" status --porcelain >&2 || true
    exit 1
  fi

  # Gate 3 — fetch the remote. A fetch failure (unreachable origin, deleted
  # remote, credentials) aborts here; it is never silenced.
  git -C "${SIBLING_DIR}" fetch --quiet origin
fi

# --- Align the local checkout to the remote default branch. ---
#
# Every step below fails closed: an undetectable default branch, a missing
# branch, unpushed local history, or a non-fast-forward base all exit 1 with
# a message instead of being silently ignored.

cd "${SIBLING_DIR}"

REMOTE_DEFAULT="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##' || true)"
if [ -z "${REMOTE_DEFAULT}" ]; then
  for candidate in main master; do
    if git show-ref --verify --quiet "refs/remotes/origin/${candidate}"; then
      REMOTE_DEFAULT="${candidate}"
      break
    fi
  done
fi
if [ -z "${REMOTE_DEFAULT}" ]; then
  echo "publish-mirror: error: cannot determine the default branch of ${THIN_REPO} (no origin/HEAD, main, or master)" >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/heads/${REMOTE_DEFAULT}"; then
  git checkout --quiet "${REMOTE_DEFAULT}"
elif git show-ref --verify --quiet "refs/remotes/origin/${REMOTE_DEFAULT}"; then
  git checkout --quiet -b "${REMOTE_DEFAULT}" "refs/remotes/origin/${REMOTE_DEFAULT}"
else
  echo "publish-mirror: error: fetched ${THIN_REPO} has no branch '${REMOTE_DEFAULT}'" >&2
  exit 1
fi

# Refuse to build on top of unpushed local history (for example a stale mirror
# commit from a previously failed push), and fast-forward to the remote default
# branch so the new mirror commit has the remote tip as its parent. The clean
# working tree was already required, so a fast-forward merge cannot clobber work.
UNPUSHED="$(git rev-list --count "origin/${REMOTE_DEFAULT}..HEAD")"
if [ "${UNPUSHED}" -ne 0 ]; then
  echo "publish-mirror: error: local '${REMOTE_DEFAULT}' has ${UNPUSHED} commit(s) not on origin/${REMOTE_DEFAULT}; reconcile manually before mirroring" >&2
  exit 1
fi
git merge --ff-only --quiet "origin/${REMOTE_DEFAULT}"

BRANCH="$(git symbolic-ref --short HEAD)"

echo "publish-mirror: mirroring ${PLUGIN_ROOT} -> ${SIBLING_DIR} (${BRANCH})"

# Wipe every root entry except .git — tracked or not, ignored or not. `git rm`
# only removes tracked paths, so an untracked leftover could otherwise survive
# into the `git add -A` staged tree. Removing the root entries up front makes
# the staged tree equal exactly the freshly copied plugin tree.
for entry in "${SIBLING_DIR}"/.[!.]* "${SIBLING_DIR}"/..?* "${SIBLING_DIR}"/*; do
  case "${entry}" in
    "${SIBLING_DIR}"/.git) continue ;;
  esac
  if [ -e "${entry}" ] || [ -L "${entry}" ]; then
    rm -rf -- "${entry}"
  fi
done

# Copy the plugin-tree contents (including dot dirs such as .cursor-plugin/)
# to the clone root. Nothing outside the plugin tree is ever copied.
cp -R "${PLUGIN_ROOT}/." "${SIBLING_DIR}/"

# Fail closed: the copy must have produced the plugin manifest at the root.
if [ ! -f "${SIBLING_DIR}/.cursor-plugin/plugin.json" ]; then
  echo "publish-mirror: error: copy did not produce .cursor-plugin/plugin.json at ${SIBLING_DIR}" >&2
  exit 1
fi

git add -A

if git diff --cached --quiet; then
  echo "publish-mirror: no changes to mirror; skipping commit"
else
  git commit --quiet -m "$(cat <<'EOF'
Mirror OpenBurnBar Cursor plugin from BurnBar plugins/openburnbar

Generated by plugins/openburnbar/scripts/publish-mirror.sh. The plugin tree
lives at this repo root (.cursor-plugin/plugin.json at root), AGPL-3.0-only,
plugin-only. See docs/local-load.md for the local-load path and docs/probe/
for hosted-MCP probe transcripts.

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>
EOF
)"
fi

# A push failure (non-fast-forward, rejected, unreachable) aborts here.
git push --quiet -u origin "${BRANCH}"
echo "publish-mirror: pushed ${BRANCH} to ${THIN_REPO}"
