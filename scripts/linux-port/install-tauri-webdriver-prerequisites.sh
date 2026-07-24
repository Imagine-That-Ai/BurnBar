#!/usr/bin/env bash
set -euo pipefail

readonly TAURI_DRIVER_VERSION="2.0.6"
readonly MINIMUM_WEBKIT_DRIVER_VERSION="2.40.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT

MODE="install"
OS_RELEASE="/etc/os-release"
CARGO_LOCK="${REPO_ROOT}/apps/linux-desktop/src-tauri/Cargo.lock"

die() {
  printf 'tauri-webdriver-prerequisites: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install-tauri-webdriver-prerequisites.sh [--check|--print-plan]
       [--os-release PATH] [--cargo-lock PATH]

Default mode installs the distro-owned WebKitWebDriver and the pinned
tauri-driver, then verifies executable identity, versions, and package ownership.
--check verifies only. --print-plan emits deterministic commands without mutation.
EOF
}

while (($#)); do
  case "$1" in
    --check|--print-plan)
      [[ "${MODE}" == "install" ]] || die "only one mode may be selected"
      MODE="${1#--}"
      shift
      ;;
    --os-release|--cargo-lock)
      (($# >= 2)) || die "$1 requires a path"
      if [[ "$1" == "--os-release" ]]; then OS_RELEASE="$2"; else CARGO_LOCK="$2"; fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "${OS_RELEASE}" && ! -L "${OS_RELEASE}" ]] || die "os-release must be a regular file"
[[ -f "${CARGO_LOCK}" && ! -L "${CARGO_LOCK}" ]] || die "Cargo.lock must be a regular file"

os_value() {
  local key="$1" value
  value="$(awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${OS_RELEASE}")"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || die "${key} in os-release is missing or unsafe"
  printf '%s\n' "${value}"
}

optional_os_value() {
  local key="$1" value
  value="$(awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${OS_RELEASE}")"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  [[ -z "${value}" || "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || die "${key} in os-release is unsafe"
  printf '%s\n' "${value}"
}

tauri_version() {
  awk 'BEGIN { RS="" } /name = "tauri"/ { print; exit }' "${CARGO_LOCK}" |
    awk -F'"' '/^version = / { print $2; exit }'
}

DISTRO="$(os_value ID)"
DISTRO_VERSION="$(optional_os_value VERSION_ID)"
TAURI_VERSION="$(tauri_version)"
[[ "${TAURI_VERSION}" =~ ^2\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]] || die "Cargo.lock must pin a stable Tauri 2.x release"
[[ "${TAURI_DRIVER_VERSION%%.*}" == "${TAURI_VERSION%%.*}" ]] || die "tauri-driver ${TAURI_DRIVER_VERSION} is incompatible with Tauri ${TAURI_VERSION}"

case "${DISTRO}" in
  ubuntu)
    [[ "${DISTRO_VERSION}" == "24.04" ]] || die "only Ubuntu 24.04 is supported (found ${DISTRO_VERSION:-unknown})"
    PACKAGE_COMMANDS=(
      "apt-get update"
      "apt-get install -y --no-install-recommends webkit2gtk-driver"
    )
    EXPECTED_PACKAGE="webkit2gtk-driver"
    OWNERSHIP_PLAN="dpkg-query -S /usr/bin/WebKitWebDriver"
    ;;
  fedora)
    # Fedora's webkit2gtk4.1 file manifest omits WebKitWebDriver. The binary is
    # owned by webkitgtk6.0, while the installed Tauri application uses 4.1.
    PACKAGE_COMMANDS=(
      "dnf install -y webkit2gtk4.1 webkitgtk6.0"
    )
    EXPECTED_PACKAGE="webkitgtk6.0"
    OWNERSHIP_PLAN="rpm -qf --qf %{NAME} /usr/bin/WebKitWebDriver"
    ;;
  arch)
    # Arch likewise ships WebKitWebDriver only in webkitgtk-6.0; keep the 4.1
    # runtime beside it because that is the ABI used by Tauri/Wry.
    PACKAGE_COMMANDS=(
      "pacman -Syu --noconfirm"
      "pacman -S --needed --noconfirm webkit2gtk-4.1 webkitgtk-6.0"
    )
    EXPECTED_PACKAGE="webkitgtk-6.0"
    OWNERSHIP_PLAN="pacman -Qoq /usr/bin/WebKitWebDriver"
    ;;
  *) die "unsupported Linux distribution: ${DISTRO}" ;;
esac

print_plan() {
  printf 'distro=%s\n' "${DISTRO}"
  printf 'distro_version=%s\n' "${DISTRO_VERSION:-rolling}"
  printf 'tauri_version=%s\n' "${TAURI_VERSION}"
  printf 'tauri_driver_version=%s\n' "${TAURI_DRIVER_VERSION}"
  printf 'minimum_webkit_driver_version=%s\n' "${MINIMUM_WEBKIT_DRIVER_VERSION}"
  local command
  for command in "${PACKAGE_COMMANDS[@]}"; do printf 'root_command=%s\n' "${command}"; done
  printf 'user_command=cargo install tauri-driver --version %s --locked --force\n' "${TAURI_DRIVER_VERSION}"
  printf 'verify_command=tauri-driver --version\n'
  printf 'verify_command=WebKitWebDriver --version\n'
  printf 'ownership_command=%s\n' "${OWNERSHIP_PLAN}"
  printf 'expected_webkit_owner=%s\n' "${EXPECTED_PACKAGE}"
}

if [[ "${MODE}" == "print-plan" ]]; then
  print_plan
  exit 0
fi

as_root() {
  if ((EUID == 0)); then "$@"; else command -v sudo >/dev/null 2>&1 || die "sudo is required"; sudo -n "$@"; fi
}

version_at_least() {
  local actual="$1" minimum="$2" a b index
  IFS=. read -r -a actual_parts <<<"${actual}"
  IFS=. read -r -a minimum_parts <<<"${minimum}"
  for index in 0 1 2; do
    a="${actual_parts[index]:-0}"
    b="${minimum_parts[index]:-0}"
    [[ "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ ]] || return 1
    ((10#${a} > 10#${b})) && return 0
    ((10#${a} < 10#${b})) && return 1
  done
  return 0
}

verify_tauri_driver() {
  local binary output actual installed
  binary="$(command -v tauri-driver 2>/dev/null || true)"
  [[ -n "${binary}" && -x "${binary}" ]] || die "tauri-driver is not executable on PATH"
  binary="$(readlink -f "${binary}")"
  [[ "${binary}" == "$(readlink -f "${CARGO_HOME:-${HOME}/.cargo}/bin/tauri-driver")" ]] || die "tauri-driver is shadowed by an unexpected executable: ${binary}"
  output="$("${binary}" --version 2>&1)" || die "tauri-driver --version failed"
  actual="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"${output}" | head -1)"
  [[ "${actual}" == "${TAURI_DRIVER_VERSION}" ]] || die "tauri-driver version mismatch: expected ${TAURI_DRIVER_VERSION}, found ${actual:-unknown}"
  installed="$(cargo install --list 2>/dev/null | awk '/^tauri-driver v/ { print $2; exit }')"
  [[ "${installed}" == "v${TAURI_DRIVER_VERSION}:" ]] || die "cargo install registry does not own tauri-driver ${TAURI_DRIVER_VERSION}"
}

verify_webkit_driver() {
  local binary output actual owner ownership_output
  binary="$(command -v WebKitWebDriver 2>/dev/null || true)"
  [[ -n "${binary}" && -x "${binary}" ]] || die "WebKitWebDriver is not executable on PATH"
  binary="$(readlink -f "${binary}")"
  [[ "${binary}" == "/usr/bin/WebKitWebDriver" ]] || die "WebKitWebDriver must resolve to /usr/bin/WebKitWebDriver (found ${binary})"
  output="$("${binary}" --version 2>&1)" || die "WebKitWebDriver --version failed"
  actual="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"${output}" | head -1)"
  [[ -n "${actual}" ]] || die "WebKitWebDriver did not report a semantic version"
  version_at_least "${actual}" "${MINIMUM_WEBKIT_DRIVER_VERSION}" || die "WebKitWebDriver ${actual} is older than ${MINIMUM_WEBKIT_DRIVER_VERSION}"
  case "${DISTRO}" in
    ubuntu)
      ownership_output="$(dpkg-query -S "${binary}" 2>&1)" || die "WebKitWebDriver is not owned by dpkg"
      owner="${ownership_output%%:*}"
      ;;
    fedora)
      owner="$(rpm -qf --qf '%{NAME}\n' "${binary}" 2>&1)" || die "WebKitWebDriver is not owned by rpm"
      ;;
    arch)
      owner="$(pacman -Qoq "${binary}" 2>&1)" || die "WebKitWebDriver is not owned by pacman"
      ;;
  esac
  [[ "${owner}" == "${EXPECTED_PACKAGE}" ]] || die "WebKitWebDriver owner mismatch: expected ${EXPECTED_PACKAGE}, found ${owner}"
}

export CARGO_HOME="${CARGO_HOME:-${HOME}/.cargo}"
export PATH="${CARGO_HOME}/bin:${PATH}"
command -v cargo >/dev/null 2>&1 || die "cargo is required to install and verify tauri-driver"

if [[ "${MODE}" == "install" ]]; then
  for command_line in "${PACKAGE_COMMANDS[@]}"; do
    read -r -a command_parts <<<"${command_line}"
    as_root "${command_parts[@]}"
  done
  cargo install tauri-driver --version "${TAURI_DRIVER_VERSION}" --locked --force
fi

verify_tauri_driver
verify_webkit_driver
printf 'tauri-webdriver-prerequisites-ok distro=%s tauri=%s tauri_driver=%s\n' "${DISTRO}" "${TAURI_VERSION}" "${TAURI_DRIVER_VERSION}"
