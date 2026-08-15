#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_root/scripts/lib/resolve-repo-path.sh"

relative="$(resolve_repo_path "/repo/root" "build/release")"
if [[ "$relative" != "/repo/root/build/release" ]]; then
  echo "FAIL: Relative release path resolved to $relative" >&2
  exit 1
fi

absolute="$(resolve_repo_path "/repo/root" "/private/tmp/release")"
if [[ "$absolute" != "/private/tmp/release" ]]; then
  echo "FAIL: Absolute release path was incorrectly prefixed: $absolute" >&2
  exit 1
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-release-paths.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
mkdir -p "$repo"
repo="$(cd "$repo" && pwd -P)"
fixture_root="$(cd "$fixture_root" && pwd -P)"

relative_release="$(
  resolve_fresh_release_output_dir \
    "$repo" \
    "build/macos-website-1.2.3-456" \
    "Website release directory"
)"
if [[ "$relative_release" != "$repo/build/macos-website-1.2.3-456" ]]; then
  echo "FAIL: Fresh relative release path resolved to $relative_release" >&2
  exit 1
fi

external_release="$(
  resolve_fresh_release_output_dir \
    "$repo" \
    "$fixture_root/openburnbar-mas-candidate" \
    "Mac App Store release directory"
)"
if [[ "$external_release" != "$fixture_root/openburnbar-mas-candidate" ]]; then
  echo "FAIL: Fresh external release path resolved to $external_release" >&2
  exit 1
fi

mkdir -p "$repo/build"
created_release="$repo/build/macos-website-created"
create_fresh_release_output_dir \
  "$repo" \
  "$created_release" \
  "Website release directory"
if [[ ! -d "$created_release" || -L "$created_release" ]]; then
  echo "FAIL: Atomic release-root creation did not create a real directory." >&2
  exit 1
fi
# GNU stat (-c) vs BSD stat (-f): probe the GNU form first because feeding the
# BSD argument order to GNU stat partially succeeds and pollutes the capture.
if stat -c '%a' "$created_release" >/dev/null 2>&1; then
  created_release_mode="$(stat -c '%a' "$created_release")"
else
  created_release_mode="$(stat -f '%Lp' "$created_release")"
fi
if [[ "$created_release_mode" != "700" ]]; then
  echo "FAIL: Atomic release-root creation did not preserve mode 0700." >&2
  exit 1
fi

expect_rejected() {
  local path="$1"
  local expected="$2"
  local output
  if output="$(
    resolve_fresh_release_output_dir "$repo" "$path" "Release directory" 2>&1
  )"; then
    echo "FAIL: Unsafe release path was accepted: $path" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "FAIL: Unsafe release path '$path' did not report '$expected':" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

expect_rejected "/" "filesystem root"
expect_rejected "$repo" "dedicated directory"
expect_rejected "$repo/build" "dedicated directory"
expect_rejected "$fixture_root" "must not contain the repository"
expect_rejected "$repo/docs/release" "inside the repository must be under"

mkdir -p "$repo/build/existing" "$fixture_root/real-parent"
expect_rejected "$repo/build/existing" "fresh path"

ln -s "$fixture_root/real-parent" "$fixture_root/symlink-parent"
expect_rejected \
  "$fixture_root/symlink-parent/openburnbar-release" \
  "must not traverse a symlink"

substitution_target="$fixture_root/substitution-target"
mkdir -m 700 "$substitution_target"
substitution_release="$repo/build/macos-substituted"
mock_bin="$fixture_root/mock-bin"
mkdir -m 700 "$mock_bin"
cat > "$mock_bin/mkdir" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
target="${@: -1}"
/bin/mkdir "$@"
/bin/rmdir "$target"
/bin/ln -s "$OPENBURNBAR_SUBSTITUTION_TARGET" "$target"
SH
chmod +x "$mock_bin/mkdir"

set +e
substitution_output="$(
  PATH="$mock_bin:$PATH" \
  OPENBURNBAR_SUBSTITUTION_TARGET="$substitution_target" \
    create_fresh_release_output_dir \
      "$repo" \
      "$substitution_release" \
      "Substitution release directory" \
      2>&1
)"
substitution_status=$?
set -e
if [[ "$substitution_status" -eq 0 ]]; then
  echo "FAIL: A release root substituted after mkdir was accepted." >&2
  exit 1
fi
if [[ "$substitution_output" != *"physical path changed after mkdir"* \
  && "$substitution_output" != *"must not traverse a symlink"* \
  && "$substitution_output" != *"real directory, not a substituted entry"* ]]; then
  echo "FAIL: Substitution rejection was not explicit:" >&2
  printf '%s\n' "$substitution_output" >&2
  exit 1
fi

echo "PASS: Release paths are anchored, atomically created mode 0700, fresh, dedicated, and substitution/symlink-safe."
