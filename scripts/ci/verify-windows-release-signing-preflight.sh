#!/usr/bin/env bash
# Fail-closed preflight for the Windows release signing boundary.
set -euo pipefail

fail=0

write_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_windows_release_tag() {
  [[ "${GITHUB_REF_TYPE:-}" == "tag" && "${GITHUB_REF_NAME:-}" == windows-v* ]]
}

emit_error() {
  printf '::error::%s\n' "$*" >&2
  fail=1
}

emit_warning() {
  printf '::warning::%s\n' "$*" >&2
}

write_output codesign false
write_output updatekey false

codesign_vars=(
  WINDOWS_CODESIGN_ENDPOINT
  WINDOWS_CODESIGN_ACCOUNT_NAME
  WINDOWS_CODESIGN_CERT_PROFILE_NAME
  WINDOWS_CODESIGN_AZURE_TENANT_ID
  WINDOWS_CODESIGN_AZURE_CLIENT_ID
  WINDOWS_CODESIGN_AZURE_CLIENT_SECRET
)

missing_codesign=()
present_codesign=()
for name in "${codesign_vars[@]}"; do
  if [[ -n "${!name:-}" ]]; then
    present_codesign+=("$name")
  else
    missing_codesign+=("$name")
  fi
done

allow_unsigned=false
if truthy "${WINDOWS_RELEASE_ALLOW_UNSIGNED:-0}"; then
  allow_unsigned=true
fi

if [[ "$allow_unsigned" == true ]]; then
  if is_windows_release_tag; then
    emit_error "Unsigned dry-run is not allowed for windows-v* tag releases. Complete Azure Trusted Signing first."
  else
    emit_warning "Unsigned Windows release dry-run requested; Authenticode signing and update-feed signing will stop at the signing boundary."
    exit 0
  fi
fi

if [[ "${#missing_codesign[@]}" -eq 0 ]]; then
  write_output codesign true
  printf 'Windows Authenticode preflight: Azure Trusted Signing configuration is complete.\n'
else
  if [[ "${#present_codesign[@]}" -eq 0 ]]; then
    emit_error "Windows Authenticode signing is not configured. Set WINDOWS_CODESIGN_* secrets before cutting a signed Windows release."
  elif [[ "${#missing_codesign[@]}" -eq 1 && "${missing_codesign[0]}" == "WINDOWS_CODESIGN_CERT_PROFILE_NAME" ]]; then
    emit_error "Azure Trusted Signing identity validation pending: WINDOWS_CODESIGN_CERT_PROFILE_NAME is missing."
    emit_error "Wait for the Azure Artifact Signing identity validation to reach Accepted, create certificate profile openburnbarwin202607-public, then set repo secret WINDOWS_CODESIGN_CERT_PROFILE_NAME."
  else
    emit_error "Windows Authenticode signing configuration is partial. Missing: ${missing_codesign[*]}"
  fi
fi

if [[ -n "${WINDOWS_UPDATE_SIGNING_KEY:-}" && -n "${WINDOWS_UPDATE_PUBLIC_KEY:-}" ]]; then
  write_output updatekey true
  printf 'Windows update-feed preflight: private signing key and public pin variable are configured.\n'
else
  if [[ -z "${WINDOWS_UPDATE_SIGNING_KEY:-}" ]]; then
    emit_error "WINDOWS_UPDATE_SIGNING_KEY is missing. Generate the Ed25519 update key and store privateKeyBase64 in that secret before a signed release."
  fi
  if [[ -z "${WINDOWS_UPDATE_PUBLIC_KEY:-}" ]]; then
    emit_error "WINDOWS_UPDATE_PUBLIC_KEY is missing. Store publicKeyBase64 as a repo variable so the release can verify the private key matches the pinned updater key."
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
