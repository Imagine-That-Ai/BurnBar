#!/usr/bin/env bash
# SettingsManagerProtocol must compose the store-matched domain protocols.
set -euo pipefail
cd "$(dirname "$0")/../.."
need=(
  AppearanceSettingsManaging
  BehaviorSettingsManaging
  IndexSettingsManaging
  CloudSyncSettingsManaging
  ChatBackendSettingsManaging
)
missing=()
for name in "${need[@]}"; do
  if ! rg -q "protocol ${name}" AgentLens/Services/Protocols; then
    missing+=("$name")
  fi
  if ! rg -q "${name}" AgentLens/Services/Protocols/SettingsManagerProtocol.swift; then
    missing+=("${name} not inherited")
  fi
done
if ((${#missing[@]})); then
  printf 'Settings protocol split missing: %s\n' "${missing[*]}" >&2
  exit 1
fi
echo "SettingsManagerProtocol domain split OK (${#need[@]} slices)"
