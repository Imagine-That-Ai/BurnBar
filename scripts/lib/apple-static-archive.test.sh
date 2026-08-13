#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/apple-static-archive.sh
source "$repo_root/scripts/lib/apple-static-archive.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-static-archive-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
chmod +x "$fake_bin/uname"

cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash

set -euo pipefail

tool="${1:-}"
shift || true

case "$tool" in
  ar)
    operation="${1:-}"
    archive="${2:-}"
    case "$operation" in
      -t)
        printf '%s\n' linkable.o empty.o
        ;;
      -x)
        printf 'linkable\n' >linkable.o
        printf 'empty\n' >empty.o
        ;;
      *)
        printf 'unexpected fake ar invocation: %s %s\n' "$operation" "$archive" >&2
        exit 97
        ;;
    esac
    ;;
  libtool)
    output=""
    filelist=""
    archive=""
    while (($#)); do
      case "$1" in
        -o)
          output="${2:-}"
          shift 2
          ;;
        -filelist)
          filelist="${2:-}"
          shift 2
          ;;
        -static)
          shift
          ;;
        *)
          archive="$1"
          shift
          ;;
      esac
    done

    if [[ -n "$filelist" ]]; then
      if [[ "$(wc -l <"$filelist" | tr -d '[:space:]')" != "1" ]] ||
        ! grep -Eq '/linkable[.]o$' "$filelist" ||
        grep -Eq '/empty[.]o$' "$filelist"; then
        printf 'unexpected normalized archive file list:\n' >&2
        cat "$filelist" >&2
        exit 95
      fi
      printf 'rebuilt\n' >"$output"
      exit 0
    fi

    printf 'classified\n' >"$output"
    case "${OPENBURNBAR_STATIC_ARCHIVE_TEST_DIAGNOSTIC:-none}" in
      none)
        ;;
      warning)
        printf "libtool: warning: '%s(empty.o)' has no symbols\n" "$archive" >&2
        ;;
      file)
        printf 'libtool: file: %s(empty.o) has no symbols\n' "$archive" >&2
        ;;
      unrelated)
        printf 'libtool: file: %s(empty.o) has no symbols\n' "$archive" >&2
        printf 'libtool: warning: archive metadata changed\n' >&2
        ;;
      malformed)
        printf 'libtool: file: %s/empty.o has no symbols\n' "$archive" >&2
        ;;
      unknown-member)
        printf 'libtool: file: %s(ghost.o) has no symbols\n' "$archive" >&2
        ;;
      *)
        printf 'unknown fixture diagnostic: %s\n' \
          "$OPENBURNBAR_STATIC_ARCHIVE_TEST_DIAGNOSTIC" >&2
        exit 98
        ;;
    esac
    ;;
  *)
    printf 'unexpected fake xcrun tool: %s\n' "$tool" >&2
    exit 96
    ;;
esac
SH
chmod +x "$fake_bin/xcrun"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_normalizer() {
  local diagnostic="$1"
  local archive="$2"
  local output="$3"

  PATH="$fake_bin:$PATH" \
    OPENBURNBAR_STATIC_ARCHIVE_TEST_DIAGNOSTIC="$diagnostic" \
    openburnbar_prune_symbol_empty_archive_members "$archive" \
    >"$output" 2>&1
}

assert_accepted_diagnostic() {
  local diagnostic="$1"
  local fixture="$fixture_root/$diagnostic archive (staged)"
  local archive="$fixture/libfixture.a"
  local output="$fixture/output.log"

  mkdir -p "$fixture"
  printf 'original\n' >"$archive"
  run_normalizer "$diagnostic" "$archive" "$output"

  grep -Fqx 'rebuilt' "$archive" ||
    fail "$diagnostic diagnostic did not install the normalized archive"
  grep -Fq 'Pruned 1 symbol-empty object members' "$output" ||
    fail "$diagnostic diagnostic did not report the pruned member"
  grep -Fq 'retained 1.' "$output" ||
    fail "$diagnostic diagnostic did not report the retained member"
}

assert_rejected_diagnostic() {
  local diagnostic="$1"
  local expected_error="$2"
  local fixture="$fixture_root/$diagnostic archive (staged)"
  local archive="$fixture/libfixture.a"
  local original="$fixture/original.a"
  local output="$fixture/output.log"

  mkdir -p "$fixture"
  printf 'original\n' >"$archive"
  cp "$archive" "$original"
  if run_normalizer "$diagnostic" "$archive" "$output"; then
    fail "$diagnostic diagnostic unexpectedly succeeded"
  fi

  cmp "$original" "$archive" ||
    fail "$diagnostic rejection replaced the original archive"
  grep -Fq "$expected_error" "$output" ||
    fail "$diagnostic rejection did not report the expected error"
}

assert_accepted_diagnostic warning
assert_accepted_diagnostic file
assert_rejected_diagnostic \
  unrelated \
  'Apple libtool emitted an unrecognized archive diagnostic'
assert_rejected_diagnostic \
  malformed \
  'Apple libtool emitted an unrecognized archive diagnostic'
assert_rejected_diagnostic \
  unknown-member \
  'Apple libtool named an unknown symbol-empty archive member: ghost.o'

fixture="$fixture_root/no-diagnostics"
archive="$fixture/libfixture.a"
output="$fixture/output.log"
mkdir -p "$fixture"
printf 'original\n' >"$archive"
run_normalizer none "$archive" "$output"
grep -Fqx 'original' "$archive" ||
  fail 'archive without symbol-empty diagnostics was unexpectedly replaced'
[[ ! -s "$output" ]] ||
  fail 'archive without symbol-empty diagnostics emitted unexpected output'

echo "Apple static-archive diagnostic fixture passed."
