#!/usr/bin/env bash
set -euo pipefail

version="${SENTRY_CLI_VERSION:-3.4.3}"
install_dir="${INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)" in
  Darwin) platform="Darwin" ;;
  Linux) platform="Linux" ;;
  *) echo "Unsupported sentry-cli platform: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  armv6*|armv7*) arch="armv7" ;;
  *) echo "Unsupported sentry-cli architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [[ "$platform" == "Darwin" ]]; then
  arch="universal"
fi

url="https://release-registry.services.sentry.io/apps/sentry-cli/${version}?response=download&arch=${arch}&platform=${platform}&package=sentry-cli"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

binary="$tmp_dir/sentry-cli"

case "${version}:${platform}:${arch}" in
  "3.4.3:Linux:x86_64") expected_digest="Wd59qOkLNRHAbYBaIVOwg0aO74WqVZ/sy0aMxoPaUqo=" ;;
  "3.4.3:Linux:aarch64") expected_digest="Akfwx2H/EIhcLuo8vMvzQBKJ2VY4c9XeV+u6XgaZ8w4=" ;;
  "3.4.3:Linux:armv7") expected_digest="slMl0V72HlJmWH3b4VM+G0tnaELjTg2nmDvknR5kpwo=" ;;
  "3.4.3:Darwin:universal") expected_digest="9UT9gmgEW7YARAv+YRw0tcAOvZm7Tz4VcITr7rLyIPg=" ;;
  *)
    echo "No pinned sentry-cli checksum for ${platform}-${arch} ${version}" >&2
    exit 1
    ;;
esac

curl --retry 5 --connect-timeout 10 -fsSL -o "$binary" "$url"
actual_digest="$(openssl dgst -sha256 -binary "$binary" | openssl base64 -A)"
if [[ "$actual_digest" != "$expected_digest" ]]; then
  echo "sentry-cli digest mismatch for ${platform}-${arch} ${version}" >&2
  echo "expected: $expected_digest" >&2
  echo "actual:   $actual_digest" >&2
  exit 1
fi

mkdir -p "$install_dir"
install -m 0755 "$binary" "$install_dir/sentry-cli"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$install_dir" >> "$GITHUB_PATH"
else
  export PATH="$install_dir:$PATH"
fi

"$install_dir/sentry-cli" --version
