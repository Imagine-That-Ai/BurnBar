#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

release_out="${OPENBURNBAR_LINUX_RELEASE_OUT:-$repo_root/.linux-release}"
repository_root="${OPENBURNBAR_LINUX_REPOSITORY_OUT:-$release_out/repositories}"
evidence_root="${OPENBURNBAR_LINUX_EVIDENCE_OUT:-$repo_root/.linux-evidence}/repository-lifecycle"
version="${OPENBURNBAR_LINUX_REPOSITORY_VERSION:-}"
channel="${OPENBURNBAR_LINUX_REPOSITORY_CHANNEL:-}"
toolchain_image="${OPENBURNBAR_LINUX_TOOLCHAIN_IMAGE:-openburnbar-linux-toolchain:mission-001}"
ubuntu_image="${OPENBURNBAR_LINUX_APT_CLIENT_IMAGE:-ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90}"
fedora_image="${OPENBURNBAR_LINUX_DNF_CLIENT_IMAGE:-fedora:42@sha256:99e203b80b1c3d8f7e161ec10a68fd02b081ef83a3963553e513c82846b97814}"

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "OPENBURNBAR_LINUX_REPOSITORY_VERSION must be strict X.Y.Z semver" >&2
  exit 1
fi
case "$channel" in
  stable|prerelease|nightly) ;;
  *)
    echo "OPENBURNBAR_LINUX_REPOSITORY_CHANNEL must be stable, prerelease, or nightly" >&2
    exit 1
    ;;
esac
for required in \
  "$repository_root/repository-closure.json" \
  "$repository_root/apt/openburnbar-archive-keyring.gpg" \
  "$repository_root/rpm/RPM-GPG-KEY-openburnbar"; do
  if [[ ! -f "$required" ]]; then
    echo "signed repository input is missing: $required" >&2
    exit 1
  fi
done
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for clean repository lifecycle verification" >&2
  exit 1
fi

mkdir -p "$evidence_root"
network="openburnbar-repository-${GITHUB_RUN_ID:-local}-$$"
server="$network-server"
cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker network create "$network" >/dev/null
docker run --rm -d \
  --name "$server" \
  --network "$network" \
  -v "$repository_root:/srv/repositories:ro" \
  "$toolchain_image" \
  python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/repositories >/dev/null
for attempt in 1 2 3 4 5 6; do
  if docker exec "$server" curl -fsS http://127.0.0.1:8080/repository-closure.json >/dev/null; then
    break
  fi
  if [[ "$attempt" -eq 6 ]]; then
    echo "local repository server did not become ready" >&2
    exit 1
  fi
  sleep 1
done

architectures=(x86_64 aarch64)
platforms=(linux/amd64 linux/arm64)
apt_architectures=(amd64 arm64)
rpm_architectures=(x86_64 aarch64)
for index in "${!architectures[@]}"; do
  architecture="${architectures[$index]}"
  platform="${platforms[$index]}"
  apt_architecture="${apt_architectures[$index]}"
  rpm_architecture="${rpm_architectures[$index]}"

  docker run --rm \
    --platform "$platform" \
    --network "$network" \
    -e "OPENBURNBAR_VERSION=$version" \
    -e "OPENBURNBAR_CHANNEL=$channel" \
    -e "OPENBURNBAR_APT_ARCHITECTURE=$apt_architecture" \
    "$ubuntu_image" \
    bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates curl gnupg
      install -d -m 0755 /etc/apt/keyrings
      curl -fsS http://'"$server"':8080/apt/openburnbar-archive-keyring.gpg \
        -o /etc/apt/keyrings/openburnbar-repository.gpg
      printf "deb [arch=%s signed-by=/etc/apt/keyrings/openburnbar-repository.gpg] http://'"$server"':8080/apt %s main\n" \
        "$OPENBURNBAR_APT_ARCHITECTURE" "$OPENBURNBAR_CHANNEL" \
        > /etc/apt/sources.list.d/openburnbar.list
      apt-get update
      apt-get install -y --no-install-recommends open-burn-bar
      test "$(dpkg-query -W -f="\${Version}" open-burn-bar)" = "$OPENBURNBAR_VERSION"
      test "$(dpkg-query -W -f="\${Architecture}" open-burn-bar)" = "$OPENBURNBAR_APT_ARCHITECTURE"
      test -x /usr/bin/openburnbar-linux-desktop
      test -x /usr/bin/openburnbar-daemon
      apt-get remove -y open-burn-bar
      test "$(dpkg-query -W -f="\${db:Status-Status}" open-burn-bar 2>/dev/null || true)" != installed
    ' 2>&1 | tee "$evidence_root/apt-$architecture.txt"

  docker run --rm \
    --platform "$platform" \
    --network "$network" \
    -e "OPENBURNBAR_VERSION=$version" \
    -e "OPENBURNBAR_RPM_ARCHITECTURE=$rpm_architecture" \
    "$fedora_image" \
    bash -euo pipefail -c '
      cat > /etc/yum.repos.d/openburnbar.repo <<EOF
[openburnbar]
name=OpenBurnBar
baseurl=http://'"$server"':8080/rpm/'"$channel"'/$OPENBURNBAR_RPM_ARCHITECTURE
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=http://'"$server"':8080/rpm/RPM-GPG-KEY-openburnbar
EOF
      dnf --assumeyes --refresh --setopt=install_weak_deps=False install open-burn-bar
      test "$(rpm -q --qf "%{VERSION}" open-burn-bar)" = "$OPENBURNBAR_VERSION"
      test "$(rpm -q --qf "%{ARCH}" open-burn-bar)" = "$OPENBURNBAR_RPM_ARCHITECTURE"
      test -x /usr/bin/openburnbar-linux-desktop
      test -x /usr/bin/openburnbar-daemon
      dnf --assumeyes remove open-burn-bar
      ! rpm -q open-burn-bar >/dev/null 2>&1
    ' 2>&1 | tee "$evidence_root/dnf-$architecture.txt"
done

closure_sha256="$(sha256sum "$repository_root/repository-closure.json" | awk '{print $1}')"
lifecycle="$repository_root/repository-lifecycle.json"
lifecycle_tmp="$lifecycle.tmp"
node - "$lifecycle_tmp" "$version" "$channel" "$closure_sha256" <<'NODE'
const fs = require('node:fs');
const [output, version, channel, repositoryClosureSha256] = process.argv.slice(2);
const value = {
  schemaVersion: 1,
  version,
  channel,
  repositoryClosureSha256,
  architectures: ['aarch64', 'x86_64'],
  operations: ['install', 'remove'],
  apt: [
    { passed: true, architecture: 'amd64', platform: 'linux/amd64' },
    { passed: true, architecture: 'arm64', platform: 'linux/arm64' }
  ],
  rpm: [
    { passed: true, architecture: 'x86_64', platform: 'linux/amd64' },
    { passed: true, architecture: 'aarch64', platform: 'linux/arm64' }
  ],
  passed: true
};
fs.writeFileSync(output, JSON.stringify(value, null, 2) + '\n');
NODE
mv "$lifecycle_tmp" "$lifecycle"
cp "$lifecycle" "$evidence_root/result.json"

echo "Clean apt/dnf install and remove passed on x86_64 and aarch64 for OpenBurnBar $version ($channel)."
