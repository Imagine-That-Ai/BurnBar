#!/usr/bin/env bash

# The committed OpenBurnBar project is generated with this exact XcodeGen
# release. Newer generators can change source and target discovery without a
# project.yml change, so release builds must never consume a moving Homebrew
# installation implicitly.
readonly OPENBURNBAR_XCODEGEN_VERSION="2.45.4"
readonly OPENBURNBAR_XCODEGEN_ARCHIVE_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"

openburnbar_verify_pinned_xcodegen_archive() {
  local archive_path="$1"
  local expected_sha256="${2:-$OPENBURNBAR_XCODEGEN_ARCHIVE_SHA256}"
  local actual_sha256

  if [[ ! -f "$archive_path" ]]; then
    echo "ERROR: XcodeGen archive does not exist at $archive_path." >&2
    return 1
  fi
  actual_sha256="$(shasum --algorithm 256 "$archive_path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "ERROR: XcodeGen ${OPENBURNBAR_XCODEGEN_VERSION} archive checksum mismatch at $archive_path." >&2
    return 1
  fi
}

openburnbar_resolve_pinned_xcodegen() {
  local candidate="${OPENBURNBAR_XCODEGEN_BIN:-}"
  local version_output
  local actual_version

  if [[ -z "$candidate" ]]; then
    candidate="$(command -v xcodegen 2>/dev/null || true)"
  fi
  if [[ -z "$candidate" || ! -x "$candidate" ]]; then
    echo "ERROR: XcodeGen ${OPENBURNBAR_XCODEGEN_VERSION} is required. Set OPENBURNBAR_XCODEGEN_BIN to the exact executable." >&2
    return 1
  fi

  version_output="$("$candidate" --version 2>&1)" || {
    echo "ERROR: Could not execute XcodeGen candidate at $candidate." >&2
    return 1
  }
  actual_version="$(
    printf "%s\n" "$version_output" |
      sed -nE 's/^[[:space:]]*(Version:[[:space:]]*)?([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\2/p' |
      head -n 1
  )"
  if [[ "$actual_version" != "$OPENBURNBAR_XCODEGEN_VERSION" ]]; then
    echo "ERROR: XcodeGen ${OPENBURNBAR_XCODEGEN_VERSION} is required; $candidate reported '${version_output//$'\n'/ }'." >&2
    return 1
  fi

  printf "%s\n" "$candidate"
}

openburnbar_generate_xcode_project() {
  local spec_path="${1:-project.yml}"
  local xcodegen_bin

  xcodegen_bin="$(openburnbar_resolve_pinned_xcodegen)"
  "$xcodegen_bin" generate --spec "$spec_path"
}

openburnbar_verify_xcode_project_sync() {
  local repo_root="${1:-$PWD}"
  local spec_relative="${2:-project.yml}"
  local project_relative="${3:-OpenBurnBar.xcodeproj}"
  local drift_verifier="${OPENBURNBAR_XCODEGEN_DRIFT_VERIFIER:-$repo_root/scripts/ci/verify-xcodegen-pbxproj-drift.py}"
  local xcodegen_bin

  if [[ ! -d "$repo_root" || -L "$repo_root" ]]; then
    echo "ERROR: XcodeGen verification root must be a real directory: $repo_root" >&2
    return 1
  fi
  case "$spec_relative:$project_relative" in
    /* | *:/* | *..*)
      echo "ERROR: XcodeGen verification paths must be safe repository-relative paths." >&2
      return 1
      ;;
  esac
  if [[ ! -f "$repo_root/$spec_relative" || -L "$repo_root/$spec_relative" ]]; then
    echo "ERROR: XcodeGen spec is missing or symlinked: $repo_root/$spec_relative" >&2
    return 1
  fi
  if [[ ! -d "$repo_root/$project_relative" || -L "$repo_root/$project_relative" ]]; then
    echo "ERROR: Committed Xcode project is missing or symlinked: $repo_root/$project_relative" >&2
    return 1
  fi
  if [[ ! -f "$repo_root/$project_relative/project.pbxproj" ]]; then
    echo "ERROR: Committed Xcode project is missing project.pbxproj." >&2
    return 1
  fi
  if [[ ! -f "$drift_verifier" || -L "$drift_verifier" ]]; then
    echo "ERROR: XcodeGen semantic drift verifier is missing or symlinked: $drift_verifier" >&2
    return 1
  fi

  xcodegen_bin="$(openburnbar_resolve_pinned_xcodegen)"
  (
    set -euo pipefail

    local verification_root
    local original_project
    local generated_project
    local project_path="$repo_root/$project_relative"
    local status_before=""
    local status_after=""
    local -a generated_info_paths=(
      "AgentLens/Resources/OpenBurnBar-Info.plist"
      "OpenBurnBarSafariExtension/Info.plist"
      "OpenBurnBarMobile/Info.plist"
      "OpenBurnBarWidget/Info.plist"
      "OpenBurnBarKeyboard/Info.plist"
    )

    verification_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-xcodegen-sync.XXXXXX")"
    original_project="$verification_root/original.xcodeproj"
    generated_project="$verification_root/generated.xcodeproj"

    restore_original_inputs() {
      local relative_path
      local backup_path

      set +e
      if [[ -d "$original_project" ]]; then
        if [[ -d "$project_path" || -L "$project_path" ]]; then
          mv "$project_path" "$verification_root/interrupted-generated.xcodeproj"
        fi
        mv "$original_project" "$project_path"
      fi
      for relative_path in "${generated_info_paths[@]}"; do
        backup_path="$verification_root/info/$relative_path"
        if [[ -f "$backup_path" ]]; then
          cp -p "$backup_path" "$repo_root/$relative_path"
        fi
      done
      rm -rf "$verification_root"
    }
    trap restore_original_inputs EXIT

    if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      status_before="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"
    fi

    for relative_path in "${generated_info_paths[@]}"; do
      if [[ ! -f "$repo_root/$relative_path" || -L "$repo_root/$relative_path" ]]; then
        echo "ERROR: XcodeGen-managed Info.plist is missing or symlinked: $repo_root/$relative_path" >&2
        exit 1
      fi
      mkdir -p "$verification_root/info/$(dirname "$relative_path")"
      cp -p "$repo_root/$relative_path" "$verification_root/info/$relative_path"
    done

    mv "$project_path" "$original_project"
    (
      cd "$repo_root"
      "$xcodegen_bin" generate --spec "$spec_relative"
    )
    if [[ ! -f "$project_path/project.pbxproj" ]]; then
      echo "ERROR: Pinned XcodeGen did not emit $project_relative/project.pbxproj." >&2
      exit 1
    fi
    mv "$project_path" "$generated_project"
    mv "$original_project" "$project_path"
    for relative_path in "${generated_info_paths[@]}"; do
      cp -p "$verification_root/info/$relative_path" "$repo_root/$relative_path"
    done

    if [[ -n "$status_before" ]] || git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      status_after="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"
      if [[ "$status_after" != "$status_before" ]]; then
        echo "ERROR: XcodeGen verification changed repository state outside its restored project inputs." >&2
        diff -u <(printf "%s\n" "$status_before") <(printf "%s\n" "$status_after") >&2 || true
        exit 1
      fi
    fi

    python3 "$drift_verifier" \
      "$project_path/project.pbxproj" \
      "$generated_project/project.pbxproj"
  )
}
