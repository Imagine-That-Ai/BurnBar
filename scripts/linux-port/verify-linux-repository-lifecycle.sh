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
public_base_url="${OPENBURNBAR_LINUX_REPOSITORY_PUBLIC_BASE_URL:-}"
preview_snapshot="${OPENBURNBAR_LINUX_REPOSITORY_PREVIEW_SNAPSHOT:-}"

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
closure_sha256="$(sha256sum "$repository_root/repository-closure.json" | awk '{print $1}')"
if [[ -n "$preview_snapshot" && "$preview_snapshot" != "$closure_sha256" ]]; then
  echo "OPENBURNBAR_LINUX_REPOSITORY_PREVIEW_SNAPSHOT must exactly match the local repository closure SHA-256" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for clean repository lifecycle verification" >&2
  exit 1
fi

mkdir -p "$evidence_root"
network="openburnbar-repository-${GITHUB_RUN_ID:-local}-$$"
server="$network-server"
lifecycle_mode="local"
cleanup() {
  if [[ "$lifecycle_mode" == "local" ]]; then
    docker rm -f "$server" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

network_args=()
apt_mount_args=()
rpm_mount_args=()
canonical_repository_base_url="https://downloads.burnbar.ai/linux"
if [[ -n "$preview_snapshot" ]]; then
  if [[ -n "$public_base_url" && "${public_base_url%/}" != "https://downloads.burnbar.ai" ]]; then
    echo "preview lifecycle verification is pinned to https://downloads.burnbar.ai" >&2
    exit 1
  fi
  repository_base_url="https://downloads.burnbar.ai/linux/repository-preview/$channel/$preview_snapshot"
  receipt_base_url="$repository_base_url"
  lifecycle_mode="preview"
  apt_key_url="$repository_base_url/apt/openburnbar-archive-keyring.gpg"
  apt_sources_url="$repository_base_url/apt/openburnbar-$channel.sources"
  rpm_key_url="$repository_base_url/rpm/RPM-GPG-KEY-openburnbar"
  rpm_repo_url="$repository_base_url/rpm/openburnbar-$channel.repo"
  active_snapshot_id="$preview_snapshot"
elif [[ -n "$public_base_url" ]]; then
  if [[ "${public_base_url%/}" != "https://downloads.burnbar.ai" ]]; then
    echo "public lifecycle verification is pinned to https://downloads.burnbar.ai" >&2
    exit 1
  fi
  repository_base_url="$canonical_repository_base_url"
  receipt_base_url="$repository_base_url"
  lifecycle_mode="public"
  apt_key_url="$repository_base_url/apt/openburnbar-$channel-archive-keyring.gpg"
  apt_sources_url="$repository_base_url/apt/openburnbar-$channel.sources"
  rpm_key_url="$repository_base_url/rpm/RPM-GPG-KEY-openburnbar-$channel"
  rpm_repo_url="$repository_base_url/rpm/openburnbar-$channel.repo"
  public_pointer_urls=(
    "$repository_base_url/apt/dists/$channel/InRelease"
    "$apt_key_url"
    "$apt_sources_url"
    "$rpm_key_url"
    "$rpm_repo_url"
  )
  for pointer_url in "${public_pointer_urls[@]}"; do
    active_snapshot_id="$(curl --disable --proto '=https' --max-redirs 0 -fsSI "$pointer_url" \
      | tr -d '\r' \
      | awk -F ': ' 'tolower($1) == "x-openburnbar-repository-snapshot" { print $2 }' \
      | tail -n 1)"
    if [[ "$active_snapshot_id" != "$closure_sha256" ]]; then
      echo "public repository snapshot mismatch for $pointer_url: expected $closure_sha256, received ${active_snapshot_id:-missing}" >&2
      exit 1
    fi
  done
else
  lifecycle_mode="local"
  docker network create "$network" >/dev/null
  network_args=(--network "$network")
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
  repository_base_url="http://$server:8080"
  receipt_base_url="local-read-only-repository"
  active_snapshot_id=""
  apt_key_url=""
  apt_sources_url=""
  rpm_key_url=""
  rpm_repo_url=""
  apt_mount_args=(-v "$repository_root/apt/openburnbar-archive-keyring.gpg:/openburnbar-repository.gpg:ro")
  rpm_mount_args=(-v "$repository_root/rpm/RPM-GPG-KEY-openburnbar:/openburnbar-rpm-key:ro")
fi

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
    "${network_args[@]}" \
    "${apt_mount_args[@]}" \
    -e "OPENBURNBAR_VERSION=$version" \
    -e "OPENBURNBAR_CHANNEL=$channel" \
    -e "OPENBURNBAR_APT_ARCHITECTURE=$apt_architecture" \
    -e "OPENBURNBAR_REPOSITORY_BASE_URL=$repository_base_url" \
    -e "OPENBURNBAR_REPOSITORY_LIFECYCLE_MODE=$lifecycle_mode" \
    -e "OPENBURNBAR_APT_KEY_URL=$apt_key_url" \
    -e "OPENBURNBAR_APT_SOURCES_URL=$apt_sources_url" \
    -e "OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL=$canonical_repository_base_url" \
    "$ubuntu_image" \
    bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates curl gnupg
      if [[ "$OPENBURNBAR_REPOSITORY_LIFECYCLE_MODE" != local ]]; then
        install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
        keyring=/usr/share/keyrings/openburnbar-archive-keyring.gpg
        sources=/etc/apt/sources.list.d/openburnbar.sources
        published_sources=/tmp/openburnbar.published.sources
        curl --disable --fail --silent --show-error --max-redirs 0 --proto "=https" --tlsv1.2 \
          "$OPENBURNBAR_APT_KEY_URL" --output "$keyring"
        curl --disable --fail --silent --show-error --max-redirs 0 --proto "=https" --tlsv1.2 \
          "$OPENBURNBAR_APT_SOURCES_URL" --output "$published_sources"
        test -s "$keyring"
        test -s "$published_sources"
        gpg --batch --show-keys "$keyring" >/dev/null
        printf "Types: deb\nURIs: %s/apt\nSuites: %s\nComponents: main\nArchitectures: amd64 arm64\nSigned-By: /usr/share/keyrings/openburnbar-archive-keyring.gpg\n" \
          "$OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL" "$OPENBURNBAR_CHANNEL" > /tmp/openburnbar.expected.sources
        cmp --silent /tmp/openburnbar.expected.sources "$published_sources"
        if [[ "$OPENBURNBAR_REPOSITORY_LIFECYCLE_MODE" == preview ]]; then
          sed "s|URIs: $OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL/apt|URIs: $OPENBURNBAR_REPOSITORY_BASE_URL/apt|" \
            "$published_sources" > "$sources"
        else
          cp "$published_sources" "$sources"
        fi
        printf "onboarding-key-url=%s\nonboarding-sources-url=%s\n" \
          "$OPENBURNBAR_APT_KEY_URL" "$OPENBURNBAR_APT_SOURCES_URL"
        sha256sum "$keyring" "$published_sources" "$sources"
      else
        install -d -m 0755 /etc/apt/keyrings
        cp /openburnbar-repository.gpg /etc/apt/keyrings/openburnbar-repository.gpg
        printf "deb [arch=%s signed-by=/etc/apt/keyrings/openburnbar-repository.gpg] %s/apt %s main\n" \
          "$OPENBURNBAR_APT_ARCHITECTURE" "$OPENBURNBAR_REPOSITORY_BASE_URL" "$OPENBURNBAR_CHANNEL" \
          > /etc/apt/sources.list.d/openburnbar.list
      fi
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
    "${network_args[@]}" \
    "${rpm_mount_args[@]}" \
    -e "OPENBURNBAR_VERSION=$version" \
    -e "OPENBURNBAR_RPM_ARCHITECTURE=$rpm_architecture" \
    -e "OPENBURNBAR_REPOSITORY_BASE_URL=$repository_base_url" \
    -e "OPENBURNBAR_CHANNEL=$channel" \
    -e "OPENBURNBAR_REPOSITORY_LIFECYCLE_MODE=$lifecycle_mode" \
    -e "OPENBURNBAR_RPM_KEY_URL=$rpm_key_url" \
    -e "OPENBURNBAR_RPM_REPO_URL=$rpm_repo_url" \
    -e "OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL=$canonical_repository_base_url" \
    "$fedora_image" \
    bash -euo pipefail -c '
      if [[ "$OPENBURNBAR_REPOSITORY_LIFECYCLE_MODE" != local ]]; then
        dnf --assumeyes install ca-certificates curl-minimal gnupg2
        install -d -m 0755 /etc/pki/rpm-gpg /etc/yum.repos.d
        key=/etc/pki/rpm-gpg/RPM-GPG-KEY-openburnbar
        repo=/etc/yum.repos.d/openburnbar.repo
        published_repo=/tmp/openburnbar.published.repo
        curl --disable --fail --silent --show-error --max-redirs 0 --proto "=https" --tlsv1.2 \
          "$OPENBURNBAR_RPM_KEY_URL" --output "$key"
        curl --disable --fail --silent --show-error --max-redirs 0 --proto "=https" --tlsv1.2 \
          "$OPENBURNBAR_RPM_REPO_URL" --output "$published_repo"
        test -s "$key"
        test -s "$published_repo"
        gpg --batch --show-keys "$key" >/dev/null
        cat > /tmp/openburnbar.expected.repo <<EOF
[openburnbar]
name=OpenBurnBar Linux ($OPENBURNBAR_CHANNEL)
baseurl=$OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL/rpm/$OPENBURNBAR_CHANNEL/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-openburnbar
metadata_expire=6h
EOF
        cmp --silent /tmp/openburnbar.expected.repo "$published_repo"
        if [[ "$OPENBURNBAR_REPOSITORY_LIFECYCLE_MODE" == preview ]]; then
          sed "s|baseurl=$OPENBURNBAR_CANONICAL_REPOSITORY_BASE_URL/rpm/|baseurl=$OPENBURNBAR_REPOSITORY_BASE_URL/rpm/|" \
            "$published_repo" > "$repo"
        else
          cp "$published_repo" "$repo"
        fi
        printf "onboarding-key-url=%s\nonboarding-repo-url=%s\n" \
          "$OPENBURNBAR_RPM_KEY_URL" "$OPENBURNBAR_RPM_REPO_URL"
        sha256sum "$key" "$published_repo" "$repo"
      else
        cat > /etc/yum.repos.d/openburnbar.repo <<EOF
[openburnbar]
name=OpenBurnBar
baseurl=$OPENBURNBAR_REPOSITORY_BASE_URL/rpm/$OPENBURNBAR_CHANNEL/$OPENBURNBAR_RPM_ARCHITECTURE
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///openburnbar-rpm-key
EOF
      fi
      dnf --assumeyes --refresh --setopt=install_weak_deps=False install open-burn-bar
      test "$(rpm -q --qf "%{VERSION}" open-burn-bar)" = "$OPENBURNBAR_VERSION"
      test "$(rpm -q --qf "%{ARCH}" open-burn-bar)" = "$OPENBURNBAR_RPM_ARCHITECTURE"
      test -x /usr/bin/openburnbar-linux-desktop
      test -x /usr/bin/openburnbar-daemon
      dnf --assumeyes remove open-burn-bar
      ! rpm -q open-burn-bar >/dev/null 2>&1
    ' 2>&1 | tee "$evidence_root/dnf-$architecture.txt"
done

if [[ "$lifecycle_mode" == "public" ]]; then
  for pointer_url in "${public_pointer_urls[@]}"; do
    final_snapshot_id="$(curl --disable --proto '=https' --max-redirs 0 -fsSI "$pointer_url" \
      | tr -d '\r' \
      | awk -F ': ' 'tolower($1) == "x-openburnbar-repository-snapshot" { print $2 }' \
      | tail -n 1)"
    if [[ "$final_snapshot_id" != "$closure_sha256" ]]; then
      echo "public repository snapshot changed during lifecycle verification for $pointer_url: expected $closure_sha256, received ${final_snapshot_id:-missing}" >&2
      exit 1
    fi
  done
fi

lifecycle="${OPENBURNBAR_LINUX_REPOSITORY_LIFECYCLE_RECEIPT:-$repository_root/repository-lifecycle.json}"
lifecycle_tmp="$lifecycle.tmp"
mkdir -p "$(dirname "$lifecycle")"
apt_x86_sha256="$(sha256sum "$evidence_root/apt-x86_64.txt" | awk '{print $1}')"
apt_arm_sha256="$(sha256sum "$evidence_root/apt-aarch64.txt" | awk '{print $1}')"
dnf_x86_sha256="$(sha256sum "$evidence_root/dnf-x86_64.txt" | awk '{print $1}')"
dnf_arm_sha256="$(sha256sum "$evidence_root/dnf-aarch64.txt" | awk '{print $1}')"
node - "$lifecycle_tmp" "$version" "$channel" "$closure_sha256" "$lifecycle_mode" \
  "$receipt_base_url" "$active_snapshot_id" "$apt_x86_sha256" "$apt_arm_sha256" \
  "$dnf_x86_sha256" "$dnf_arm_sha256" "$apt_key_url" "$apt_sources_url" \
  "$rpm_key_url" "$rpm_repo_url" <<'NODE'
const fs = require('node:fs');
const [output, version, channel, repositoryClosureSha256, mode, baseUrl, activeSnapshotId,
  aptX86Sha256, aptArmSha256, dnfX86Sha256, dnfArmSha256, aptKeyUrl, aptSourcesUrl,
  rpmKeyUrl, rpmRepoUrl] = process.argv.slice(2);
const value = {
  schemaVersion: 1,
  verifiedAt: new Date().toISOString(),
  version,
  channel,
  repositoryClosureSha256,
  mode,
  baseUrl,
  activeSnapshotId: mode === 'public' ? activeSnapshotId : null,
  previewSnapshotId: mode === 'preview' ? activeSnapshotId : null,
  configurationMode: mode === 'public' ? 'published-onboarding'
    : mode === 'preview' ? 'preview-onboarding-with-synthesized-base' : 'local-fixture',
  onboarding: mode !== 'local' ? {
    apt: { keyUrl: aptKeyUrl, sourcesUrl: aptSourcesUrl },
    rpm: { keyUrl: rpmKeyUrl, repoUrl: rpmRepoUrl }
  } : null,
  architectures: ['aarch64', 'x86_64'],
  operations: ['install', 'remove'],
  apt: [
    { passed: true, architecture: 'amd64', platform: 'linux/amd64', transcriptSha256: aptX86Sha256 },
    { passed: true, architecture: 'arm64', platform: 'linux/arm64', transcriptSha256: aptArmSha256 }
  ],
  rpm: [
    { passed: true, architecture: 'x86_64', platform: 'linux/amd64', transcriptSha256: dnfX86Sha256 },
    { passed: true, architecture: 'aarch64', platform: 'linux/arm64', transcriptSha256: dnfArmSha256 }
  ],
  passed: true
};
fs.writeFileSync(output, JSON.stringify(value, null, 2) + '\n');
NODE
mv "$lifecycle_tmp" "$lifecycle"
cp "$lifecycle" "$evidence_root/result.json"

echo "Clean apt/dnf install and remove passed on x86_64 and aarch64 for OpenBurnBar $version ($channel)."
