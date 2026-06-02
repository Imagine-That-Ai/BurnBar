#!/usr/bin/env bash
set -euo pipefail

version="${FACTORY_DROID_VERSION:-0.138.0}"
install_dir="${INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)" in
  Darwin) platform="darwin" ;;
  Linux) platform="linux" ;;
  *) echo "Unsupported Factory Droid platform: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) architecture="x64" ;;
  arm64|aarch64) architecture="arm64" ;;
  *) echo "Unsupported Factory Droid architecture: $(uname -m)" >&2; exit 1 ;;
esac

arch_suffix=""
if [[ "$architecture" == "x64" ]]; then
  has_avx2=false
  if [[ "$platform" == "linux" ]] && grep -qi avx2 /proc/cpuinfo 2>/dev/null; then
    has_avx2=true
  elif [[ "$platform" == "darwin" ]] && sysctl -a 2>/dev/null | grep -q "machdep.cpu.*AVX2"; then
    has_avx2=true
  fi
  if [[ "$has_avx2" == "false" ]]; then
    arch_suffix="-baseline"
  fi
fi

droid_architecture="${architecture}${arch_suffix}"
base_url="https://downloads.factory.ai/factory-cli/releases/${version}/${platform}/${droid_architecture}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

binary="$tmp_dir/droid"

case "${version}:${platform}:${droid_architecture}" in
  "0.138.0:linux:x64") expected="dd780b82fc67fec363d44dbdbdfea442569c63fc424540c8eb39f6ae2c7a2d7a" ;;
  "0.138.0:linux:x64-baseline") expected="a504995086497dc3301b95c36a218089c38697b68d4f36c304119ed1acf47802" ;;
  "0.138.0:linux:arm64") expected="533a157180570186175bbd573bd518586f23097e6914cd934b9c6f8281377459" ;;
  "0.138.0:darwin:x64") expected="d91c2fe2311ab6607c78f87ee84ef61a4dd2aaeb2fbf1ccad3e7f5c6855f68d9" ;;
  "0.138.0:darwin:x64-baseline") expected="36c389125f3f67c1737d3e0a0e024da1a8d1d45a9e33c95932e306c824c9feb8" ;;
  "0.138.0:darwin:arm64") expected="1b69138cae1fa336c246e1d9cc4f2c332a781345d489f3a26230046a0563dd81" ;;
  *)
    echo "No pinned Factory Droid checksum for ${platform}-${droid_architecture} ${version}" >&2
    exit 1
    ;;
esac

curl --retry 5 --connect-timeout 10 -fsSL -o "$binary" "${base_url}/droid"
actual="$(shasum -a 256 "$binary" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo "Factory Droid checksum mismatch for ${platform}-${droid_architecture} ${version}" >&2
  echo "expected: $expected" >&2
  echo "actual:   $actual" >&2
  exit 1
fi

mkdir -p "$install_dir"
install -m 0755 "$binary" "$install_dir/droid"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$install_dir" >> "$GITHUB_PATH"
else
  export PATH="$install_dir:$PATH"
fi

"$install_dir/droid" --version
