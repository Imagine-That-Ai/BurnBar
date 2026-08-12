#!/usr/bin/env bash

resolve_repo_path() {
  if [[ $# -ne 2 ]]; then
    echo "usage: resolve_repo_path REPO_ROOT PATH" >&2
    return 2
  fi

  local repo_root="$1"
  local path="$2"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "${repo_root%/}" "$path"
  fi
}

resolve_fresh_release_output_dir() {
  if [[ $# -ne 3 ]]; then
    echo "usage: resolve_fresh_release_output_dir REPO_ROOT PATH LABEL" >&2
    return 2
  fi

  local repo_root="$1"
  local raw_path="$2"
  local label="$3"
  local resolved_path

  if [[ -z "$raw_path" || "$raw_path" == *$'\n'* || "$raw_path" == *$'\r'* ]]; then
    echo "ERROR: $label must be a non-empty single-line path." >&2
    return 1
  fi
  resolved_path="$(resolve_repo_path "$repo_root" "$raw_path")" || return

  python3 - "$repo_root" "$resolved_path" "${HOME:-}" "$label" <<'PY'
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path


repo_raw, output_raw, home_raw, label = sys.argv[1:]
repo = Path(repo_raw).resolve(strict=True)
output = Path(os.path.abspath(output_raw))
home = Path(home_raw).resolve(strict=True) if home_raw else None
repo_build = repo / "build"


def contained_by(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


if output == Path("/"):
    raise SystemExit(f"ERROR: {label} must not be the filesystem root.")
if output == repo or output == repo_build:
    raise SystemExit(
        f"ERROR: {label} must be a dedicated directory, not {output}."
    )
if contained_by(repo, output):
    raise SystemExit(
        f"ERROR: {label} must not contain the repository: {output}."
    )
if home is not None and (output == home or contained_by(home, output)):
    raise SystemExit(
        f"ERROR: {label} must not be or contain the home directory: {output}."
    )

if contained_by(output, repo):
    if not contained_by(output, repo_build):
        raise SystemExit(
            f"ERROR: {label} inside the repository must be under {repo_build}."
        )
else:
    if not output.name.startswith("openburnbar-"):
        raise SystemExit(
            f"ERROR: external {label} must use a dedicated openburnbar-* leaf: "
            f"{output}."
        )

current = Path("/")
for component in output.parts[1:]:
    current /= component
    try:
        metadata = os.lstat(current)
    except FileNotFoundError:
        continue
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(
            f"ERROR: {label} must not traverse a symlink: {current}."
        )
    if current != output and not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(
            f"ERROR: {label} parent component is not a directory: {current}."
        )

if output.exists():
    raise SystemExit(
        f"ERROR: {label} must be a fresh path that does not already exist: "
        f"{output}."
    )

print(output)
PY
}
