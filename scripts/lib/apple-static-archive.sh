#!/usr/bin/env bash

# Deterministic Apple static-archive normalization used by native FFI
# packagers. Rust staticlibs can contain object members that become entirely
# symbol-empty after release stripping. Apple's libtool warns for every such
# member whenever SwiftPM folds the binary target into another archive.
#
# The normalizer never mutates Cargo's cached output. Callers stage a copy,
# then this helper strips and, when necessary, rebuilds that staged archive
# from the original-order list of symbol-bearing object members.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "apple-static-archive.sh requires Bash." >&2
  return 64 2>/dev/null || exit 64
fi

openburnbar_require_apple_static_archive_tools() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Apple static-archive normalization requires macOS." >&2
    return 69
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "Required Apple archive command is unavailable: xcrun" >&2
    return 69
  fi
}

openburnbar_prune_symbol_empty_archive_members() {
  local archive="${1:-}"
  if [[ -z "$archive" || ! -s "$archive" ]]; then
    echo "Static archive is missing or empty: ${archive:-<empty path>}" >&2
    return 64
  fi
  openburnbar_require_apple_static_archive_tools || return $?

  local scan_dir
  scan_dir="$(mktemp -d /tmp/openburnbar-static-archive-normalize.XXXXXX)"
  local member_list="$scan_dir/members.txt"
  local object_list="$scan_dir/object-files.txt"
  local empty_member_list="$scan_dir/symbol-empty-members.txt"
  local duplicate_list="$scan_dir/duplicate-members.txt"
  local classification_archive="$scan_dir/classification.a"
  local classification_log="$scan_dir/classification.log"
  local rebuild_log="$scan_dir/rebuild.log"
  local replacement="$scan_dir/rebuilt.a"
  local member
  local member_path
  local kept_count=0
  local pruned_count=0
  local classification_line_count=0

  if ! xcrun ar -t "$archive" >"$member_list"; then
    echo "Unable to read Apple static archive members: $archive" >&2
    rm -rf "$scan_dir"
    return 65
  fi
  if [[ ! -s "$member_list" ]]; then
    echo "Apple static archive contains no members: $archive" >&2
    rm -rf "$scan_dir"
    return 65
  fi

  LC_ALL=C awk '$0 != "__.SYMDEF" && $0 != "__.SYMDEF SORTED"' "$member_list" \
    | LC_ALL=C sort \
    | LC_ALL=C uniq -d >"$duplicate_list"
  if [[ -s "$duplicate_list" ]]; then
    echo "Refusing to normalize an archive with duplicate member names: $archive" >&2
    cat "$duplicate_list" >&2
    rm -rf "$scan_dir"
    return 65
  fi

  if ! ZERO_AR_DATE=1 xcrun libtool \
    -static \
    -o "$classification_archive" \
    "$archive" \
    >"$classification_log" 2>&1; then
    echo "Unable to classify Apple static archive members: $archive" >&2
    cat "$classification_log" >&2
    rm -rf "$scan_dir"
    return 65
  fi
  # Xcode toolchains emit the same member diagnostic in both quoted-warning
  # and unquoted-file forms. Keep the accepted grammar exact: every log line
  # must still parse as one symbol-empty archive member below.
  LC_ALL=C sed -n \
    -e "s/^libtool: warning: '.*(\\(.*\\))' has no symbols$/\\1/p" \
    -e "s/^libtool: file: .*(\\(.*\\)) has no symbols$/\\1/p" \
    "$classification_log" >"$empty_member_list"
  classification_line_count="$(
    wc -l <"$classification_log" | tr -d '[:space:]'
  )"
  pruned_count="$(
    wc -l <"$empty_member_list" | tr -d '[:space:]'
  )"
  if ((classification_line_count != pruned_count)); then
    echo "Apple libtool emitted an unrecognized archive diagnostic: $archive" >&2
    cat "$classification_log" >&2
    rm -rf "$scan_dir"
    return 65
  fi
  if ((pruned_count == 0)); then
    rm -rf "$scan_dir"
    return 0
  fi
  while IFS= read -r member; do
    if ! grep -Fqx -- "$member" "$member_list"; then
      echo "Apple libtool named an unknown symbol-empty archive member: $member" >&2
      rm -rf "$scan_dir"
      return 65
    fi
  done <"$empty_member_list"
  rm -f "$classification_archive"

  if ! (
    cd "$scan_dir"
    xcrun ar -x "$archive"
  ); then
    echo "Unable to extract Apple static archive members: $archive" >&2
    rm -rf "$scan_dir"
    return 65
  fi

  : >"$object_list"
  while IFS= read -r member; do
    case "$member" in
      "__.SYMDEF" | "__.SYMDEF SORTED")
        continue
        ;;
    esac
    if [[ -z "$member" || "$member" == */* ]]; then
      echo "Unsafe Apple static archive member name in $archive: ${member:-<empty>}" >&2
      rm -rf "$scan_dir"
      return 65
    fi
    member_path="$scan_dir/$member"
    if [[ ! -f "$member_path" ]]; then
      echo "Extracted Apple static archive member is missing: $member" >&2
      rm -rf "$scan_dir"
      return 65
    fi

    if grep -Fqx -- "$member" "$empty_member_list"; then
      continue
    fi
    printf '%s\n' "$member_path" >>"$object_list"
    kept_count=$((kept_count + 1))
  done <"$member_list"

  if ((kept_count == 0)); then
    echo "Refusing to replace an Apple static archive with no symbol-bearing members: $archive" >&2
    rm -rf "$scan_dir"
    return 65
  fi
  if ! ZERO_AR_DATE=1 xcrun libtool \
    -static \
    -o "$replacement" \
    -filelist "$object_list" \
    >"$rebuild_log" 2>&1; then
    echo "Unable to rebuild normalized Apple static archive: $archive" >&2
    cat "$rebuild_log" >&2
    rm -rf "$scan_dir"
    return 65
  fi
  if grep -Fq "warning:" "$rebuild_log"; then
    echo "Normalized Apple static archive still emits libtool warnings: $archive" >&2
    cat "$rebuild_log" >&2
    rm -rf "$scan_dir"
    return 65
  fi
  if [[ ! -s "$replacement" ]]; then
    echo "Normalized Apple static archive output is missing or empty: $archive" >&2
    rm -rf "$scan_dir"
    return 65
  fi

  if ! mv -f "$replacement" "$archive"; then
    echo "Unable to install normalized Apple static archive: $archive" >&2
    rm -rf "$scan_dir"
    return 65
  fi
  rm -rf "$scan_dir"
  printf 'Pruned %d symbol-empty object members from %s; retained %d.\n' \
    "$pruned_count" \
    "$archive" \
    "$kept_count"
}

openburnbar_verify_apple_static_archive_has_no_empty_members() {
  local archive="${1:-}"
  if [[ -z "$archive" || ! -s "$archive" ]]; then
    echo "Static archive is missing or empty: ${archive:-<empty path>}" >&2
    return 64
  fi
  # Linux fast-feedback validates the shell contract and fixture policy, while
  # the macOS builder/release lanes execute the Mach-O-specific proof.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi
  openburnbar_require_apple_static_archive_tools || return $?

  local verify_dir
  verify_dir="$(mktemp -d /tmp/openburnbar-static-archive-verify.XXXXXX)"
  local rebuilt_archive="$verify_dir/rebuilt.a"
  local libtool_log="$verify_dir/libtool.log"
  local libtool_status=0

  ZERO_AR_DATE=1 xcrun libtool \
    -static \
    -o "$rebuilt_archive" \
    "$archive" \
    >"$libtool_log" 2>&1 || libtool_status=$?
  if ((libtool_status != 0)); then
    echo "Apple libtool could not read static archive: $archive" >&2
    cat "$libtool_log" >&2
    rm -rf "$verify_dir"
    return 65
  fi
  if grep -Fq "has no symbols" "$libtool_log"; then
    echo "Apple static archive contains symbol-empty object members: $archive" >&2
    cat "$libtool_log" >&2
    rm -rf "$verify_dir"
    return 65
  fi
  if grep -Fq "warning:" "$libtool_log"; then
    echo "Apple static archive emits libtool warnings: $archive" >&2
    cat "$libtool_log" >&2
    rm -rf "$verify_dir"
    return 65
  fi
  if [[ ! -s "$rebuilt_archive" ]]; then
    echo "Apple libtool verification output is missing or empty: $archive" >&2
    rm -rf "$verify_dir"
    return 65
  fi

  rm -rf "$verify_dir"
}
