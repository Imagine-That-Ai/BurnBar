#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/xcode-source-classification.sh
source "$repo_root/scripts/lib/xcode-source-classification.sh"

set +e
non_bash_output="$(
  zsh -c 'source "$1"' zsh "$repo_root/scripts/lib/xcode-source-classification.sh" 2>&1
)"
non_bash_status=$?
set -e
if ((non_bash_status != 64)); then
  echo "The shared Xcode helper did not fail closed outside Bash." >&2
  exit 1
fi
if [[ "$non_bash_output" != *"xcode-source-classification.sh requires Bash."* ]]; then
  echo "The non-Bash rejection did not report the expected contract." >&2
  exit 1
fi

if [[ "$OPENBURNBAR_XCODE_REPOSITORY_ROOT" != "$repo_root" ]]; then
  echo "The shared Xcode repository root does not match the source root." >&2
  exit 1
fi

if [[ "${GIT_CEILING_DIRECTORIES:-}" != "$repo_root" ]]; then
  echo "The Xcode Git discovery ceiling must equal the source root." >&2
  exit 1
fi

local_package_paths=(
  "$repo_root/tools/DebugBridge"
  "$repo_root/OpenBurnBarCore"
  "$repo_root/Vendor/GRDB-SQLCipher"
)
for local_package_path in "${local_package_paths[@]}"; do
  if [[ ! -d "$local_package_path" || -e "$local_package_path/.git" ]]; then
    echo "Expected a non-repository local package at $local_package_path." >&2
    exit 1
  fi
done

canonical_xcode_entrypoints=(
  "$repo_root/scripts/build.sh"
  "$repo_root/scripts/ci/headless-app-build.sh"
  "$repo_root/scripts/check-openburnbar-swift-warnings.sh"
  "$repo_root/scripts/dev-mac.sh"
  "$repo_root/scripts/build-macos-app-store-release.sh"
  "$repo_root/scripts/build-macos-website-release.sh"
  "$repo_root/scripts/test-openburnbar-app.sh"
)
for canonical_xcode_entrypoint in "${canonical_xcode_entrypoints[@]}"; do
  if ! grep -Fq "xcode-source-classification.sh" "$canonical_xcode_entrypoint"; then
    echo "Canonical Xcode entrypoint bypasses the shared compatibility boundary: $canonical_xcode_entrypoint" >&2
    exit 1
  fi
done

python3 - "$repo_root" "${local_package_paths[@]}" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

repo_root = Path(sys.argv[1]).resolve()
local_packages = [Path(path).resolve() for path in sys.argv[2:]]
environment = os.environ.copy()
for variable in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    environment.pop(variable, None)


def run_git(*arguments: str) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            ["git", *arguments],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
            timeout=5,
        )
    except subprocess.TimeoutExpired as error:
        raise SystemExit(
            f"Git discovery exceeded five seconds under the repository ceiling: {error.cmd}"
        ) from error


root_probe = run_git("-C", str(repo_root), "rev-parse", "--show-toplevel")
if root_probe.returncode != 0:
    raise SystemExit(
        "Git invoked at the repository root could not discover the repository:\n"
        f"{root_probe.stderr}"
    )
if Path(root_probe.stdout.strip()).resolve() != repo_root:
    raise SystemExit(
        "Git invoked at the repository root discovered an unexpected worktree: "
        f"{root_probe.stdout.strip()}"
    )

for package_path in local_packages:
    package_probe = run_git(
        "-C",
        str(package_path),
        "describe",
        "--exact-match",
        "--tags",
    )
    if package_probe.returncode != 128:
        raise SystemExit(
            "A non-repository local package unexpectedly discovered a parent "
            f"repository (path={package_path}, status={package_probe.returncode}, "
            f"stdout={package_probe.stdout!r}, stderr={package_probe.stderr!r})."
        )
    if "not a git repository" not in package_probe.stderr.lower():
        raise SystemExit(
            "Local-package Git discovery failed for an unexpected reason "
            f"(path={package_path}, stderr={package_probe.stderr!r})."
        )
PY

if ((${#OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]} != 2)); then
  echo "Expected exactly one -xcconfig argument pair." >&2
  exit 1
fi

if [[ "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[0]}" != "-xcconfig" ]]; then
  echo "Expected the compatibility argument to use Xcode's xcconfig parser." >&2
  exit 1
fi

if [[ "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[1]}" != "$OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_XCCONFIG" \
  || ! -f "$OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_XCCONFIG" ]]; then
  echo "The source-classification xcconfig path is missing or inconsistent." >&2
  exit 1
fi

if ! rg -qF 'EXCLUDED_SOURCE_FILE_NAMES = *.inc *.lds *.podspec.gen.py' \
  "$OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_XCCONFIG"; then
  echo "The Abseil source-classification contract is missing." >&2
  exit 1
fi

if ! declare -F openburnbar_prepare_google_sign_in_macos_compat >/dev/null \
  || ! declare -F openburnbar_restore_google_sign_in_macos_compat >/dev/null
then
  echo "The GoogleSignIn umbrella compatibility lifecycle is not loaded." >&2
  exit 1
fi

if ! declare -F openburnbar_configure_xcode_process_tmpdir >/dev/null; then
  echo "The launch-safe Xcode TMPDIR helper is not loaded." >&2
  exit 1
fi

if rg -q 'GIDAppCheckError|GIDSignInButton' \
  "$OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_XCCONFIG"; then
  echo "GoogleSignIn headers must not be hidden from Xcode's source inventory." >&2
  exit 1
fi

if rg \
  --no-filename \
  --no-line-number \
  '^-|^[A-Z_].*=' \
  "$OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_XCCONFIG" \
  | rg -q -- '-Wno-|CLANG_WARN_.*=NO|SWIFT_SUPPRESS_WARNINGS'; then
  echo "Source classification must not become a broad warning suppression." >&2
  exit 1
fi

echo "Xcode source-classification compatibility fixture passed."
