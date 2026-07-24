#!/usr/bin/env bash
set -euo pipefail

# Package maintainer scripts receive package-manager arguments (for example,
# "configure"). The explicit --root form is reserved for isolated tests.
root=/
if [[ "${1:-}" == "--root" ]]; then
  if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" != "/" ]]; then
    printf 'openburnbar-cli-migrate: --root requires an absolute path\n' >&2
    exit 2
  fi
  root="${2%/}"
  [[ -n "$root" ]] || root=/
fi

prefix=""
if [[ "$root" != "/" ]]; then
  prefix="$root"
fi

# Register the package-owned user service before any CLI-shadow migration early
# return. Maintainer scripts run as root, so `--global enable` is the only
# deterministic way to make the unit available to each user's systemd manager;
# a non-systemd/minimal installation remains valid and can start the launcher
# explicitly. Never make package installation fail solely because systemd is
# unavailable or policy-managed by the host.
enable_daemon_service() {
  [[ "$root" == "/" ]] || return 0
  [[ -f /usr/lib/systemd/user/openburnbar-daemon.service ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl --global enable openburnbar-daemon.service >/dev/null 2>&1; then
    printf 'openburnbar-cli-migrate: enabled user daemon service\n'
  else
    printf 'openburnbar-cli-migrate: unable to enable user daemon service; leaving package installed\n' >&2
  fi
}

enable_daemon_service

canonical="${prefix}/usr/bin/openburnbar-cli"
legacy="${prefix}/usr/local/bin/openburnbar-cli"

# A package upgrade must remain successful if a custom installation layout is
# incomplete or protected. The migration is deliberately best effort and
# never removes user data.
if [[ ! -f "$canonical" || ! -x "$canonical" ]]; then
  exit 0
fi
if [[ ! -e "$legacy" && ! -L "$legacy" ]]; then
  exit 0
fi

if [[ -L "$legacy" ]]; then
  canonical_realpath="$(readlink -f -- "$canonical" 2>/dev/null || true)"
  legacy_realpath="$(readlink -f -- "$legacy" 2>/dev/null || true)"
  if [[ -n "$canonical_realpath" && "$legacy_realpath" == "$canonical_realpath" ]]; then
    exit 0
  fi
elif [[ ! -f "$legacy" ]]; then
  printf 'openburnbar-cli-migrate: leaving non-regular path untouched: %s\n' "$legacy" >&2
  exit 0
fi

if [[ -f "$legacy" && -x "$legacy" ]] && cmp -s -- "$canonical" "$legacy"; then
  exit 0
fi

# Never take ownership of a path managed by another package. The migration is
# specifically for an unmanaged shadowing binary; a package-owned alternate
# CLI must be handled by its own package lifecycle.
if [[ "$root" == "/" ]]; then
  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$legacy" >/dev/null 2>&1; then
    printf 'openburnbar-cli-migrate: leaving package-owned path untouched: %s\n' "$legacy" >&2
    exit 0
  fi
  if command -v rpm >/dev/null 2>&1 && rpm -qf "$legacy" >/dev/null 2>&1; then
    printf 'openburnbar-cli-migrate: leaving package-owned path untouched: %s\n' "$legacy" >&2
    exit 0
  fi
  if command -v pacman >/dev/null 2>&1 && pacman -Qo "$legacy" >/dev/null 2>&1; then
    printf 'openburnbar-cli-migrate: leaving package-owned path untouched: %s\n' "$legacy" >&2
    exit 0
  fi
fi

package_version=""
if [[ "$root" != "/" && -n "${OPENBURNBAR_PACKAGE_VERSION:-}" ]]; then
  package_version="$OPENBURNBAR_PACKAGE_VERSION"
fi
if [[ -z "$package_version" ]] && command -v dpkg-query >/dev/null 2>&1; then
  package_version="$(dpkg-query -W -f='${Version}' open-burn-bar 2>/dev/null || true)"
fi
if [[ -z "$package_version" ]] && command -v rpm >/dev/null 2>&1; then
  package_version="$(rpm -q --qf '%{VERSION}-%{RELEASE}' open-burn-bar 2>/dev/null || true)"
fi
if [[ -z "$package_version" ]] && command -v pacman >/dev/null 2>&1; then
  package_version="$(pacman -Q openburnbar 2>/dev/null | awk '{print $2}' || true)"
fi
[[ -n "$package_version" ]] || package_version=unknown
package_version="$(printf '%s' "$package_version" | tr -c 'A-Za-z0-9._+-' '_')"
[[ -n "$package_version" ]] || package_version=unknown

backup="${legacy}.openburnbar-legacy-${package_version}"
suffix=0
while [[ -e "$backup" || -L "$backup" ]]; do
  suffix=$((suffix + 1))
  backup="${legacy}.openburnbar-legacy-${package_version}.${suffix}"
done

if mv -- "$legacy" "$backup"; then
  printf 'openburnbar-cli-migrate: moved unmanaged CLI to %s\n' "$backup"
else
  printf 'openburnbar-cli-migrate: unable to move unmanaged CLI; left untouched: %s\n' "$legacy" >&2
fi
