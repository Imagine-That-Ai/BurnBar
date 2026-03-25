#!/bin/zsh

set -euo pipefail

LOCAL_TARGET="${HOME}/Library/Caches/XcodeDerivedDataTemp"
EXTERNAL_TARGET="/Volumes/Samsung NVME/BuildCache/Xcode/DerivedData"
ACTIVE_LINK="${HOME}/Library/Caches/XcodeDerivedDataCurrent"

mkdir -p "${LOCAL_TARGET}"

if [[ -d "${EXTERNAL_TARGET}" && -w "${EXTERNAL_TARGET}" ]]; then
  TARGET="${EXTERNAL_TARGET}"
  TARGET_KIND="external"
else
  TARGET="${LOCAL_TARGET}"
  TARGET_KIND="local"
fi

if [[ -L "${ACTIVE_LINK}" || ! -e "${ACTIVE_LINK}" ]]; then
  ln -sfn "${TARGET}" "${ACTIVE_LINK}"
else
  echo "Refusing to overwrite non-symlink path: ${ACTIVE_LINK}" >&2
  exit 1
fi

defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation -string "${ACTIVE_LINK}"

printf 'Xcode DerivedData active target: %s (%s)\n' "${TARGET}" "${TARGET_KIND}"
