#!/bin/bash

set -euo pipefail

if (($# != 7)); then
  printf 'burnbar-turbo-guest: expected seven configuration arguments\n' >&2
  exit 64
fi

IFS= read -r registration_token
repository="$1"
runner_group="$2"
runner_labels="$3"
profile="$4"
slot="$5"
runner_version="$6"
runner_sha256="$7"

[[ "$repository" == "Imagine-That-Ai/BurnBar" ]] || exit 65
[[ "$runner_group" == "burnbar-turbo-ephemeral" ]] || exit 65
[[ "$runner_labels" =~ ^burnbar-turbo,(m4-pro|m5-max)$ ]] || exit 65
[[ "$profile" == "m4" || "$profile" == "m5" ]] || exit 65
[[ "$slot" == "1" || "$slot" == "2" ]] || exit 65
[[ "$runner_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 65
[[ "$runner_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 65
[[ -n "$registration_token" ]] || exit 65

runner_dir="$HOME/actions-runner"
guest_tmp="$(mktemp -d "$HOME/.burnbar-runner.XXXXXX")"
runner_archive="$guest_tmp/actions-runner.tgz"
trap 'rm -rf "$guest_tmp"' EXIT

# This is a fresh disposable VM. Replacing the image-provided runner avoids
# update drift and guarantees the audited release/checksum below is executed.
rm -rf "$runner_dir"
mkdir -p "$runner_dir"
curl -fsSL --retry 3 --retry-all-errors \
  "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-osx-arm64-${runner_version}.tar.gz" \
  -o "$runner_archive"
printf '%s  %s\n' "$runner_sha256" "$runner_archive" | shasum -a 256 -c -
tar -xzf "$runner_archive" -C "$runner_dir"

runner_profile="$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')"
cd "$runner_dir"
./config.sh \
  --url "https://github.com/${repository%%/*}" \
  --unattended \
  --ephemeral \
  --disableupdate \
  --no-default-labels \
  --runnergroup "$runner_group" \
  --labels "$runner_labels" \
  --name "BurnBar $runner_profile $slot" \
  --work _work \
  --token "$registration_token"
unset registration_token
