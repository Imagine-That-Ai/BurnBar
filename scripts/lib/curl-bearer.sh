#!/usr/bin/env bash
# Shared curl helpers for bearer-token APIs.
#
# The helpers put secret headers in a 0600 curl config file, never in argv.
# That keeps `ps`/debug logs from exposing bearer tokens and still leaves stdin
# available for callers that stream JSON with `--data-binary @-`.

obb_curl_validate_config_value() {
  local label="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "ERROR: ${label} is empty" >&2
    return 1
  fi

  case "${value}" in
    *$'\n'*|*$'\r'*|*$'\t'*|*\"*|*\\*)
      echo "ERROR: ${label} contains unsupported characters for curl config" >&2
      return 1
      ;;
  esac
}

obb_curl_with_bearer() {
  local token="$1"
  shift

  obb_curl_validate_config_value "bearer token" "${token}" || return $?

  local config_path
  config_path="$(mktemp "${TMPDIR:-/tmp}/openburnbar-curl-bearer.XXXXXX")" || return $?
  chmod 600 "${config_path}"
  printf 'header = "Authorization: Bearer %s"\n' "${token}" >"${config_path}"

  local status=0
  curl --config "${config_path}" "$@" || status=$?
  rm -f "${config_path}"
  return "${status}"
}

obb_curl_with_bearer_user_project() {
  local token="$1"
  local user_project="$2"
  shift 2

  obb_curl_validate_config_value "bearer token" "${token}" || return $?
  obb_curl_validate_config_value "x-goog-user-project" "${user_project}" || return $?

  local config_path
  config_path="$(mktemp "${TMPDIR:-/tmp}/openburnbar-curl-bearer.XXXXXX")" || return $?
  chmod 600 "${config_path}"
  {
    printf 'header = "Authorization: Bearer %s"\n' "${token}"
    printf 'header = "x-goog-user-project: %s"\n' "${user_project}"
  } >"${config_path}"

  local status=0
  curl --config "${config_path}" "$@" || status=$?
  rm -f "${config_path}"
  return "${status}"
}
