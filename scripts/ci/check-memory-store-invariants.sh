#!/usr/bin/env bash
# Fail CI if memory migrations introduce a forbidden fourth memory store.
set -euo pipefail
cd "$(dirname "$0")/../.."

ROOTS=(
  AgentLens/Services/DataStore/OpenBurnBarDatabase+MemoryMigrations.swift
  OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+MemoryMigrations.swift
  docs/SCHEMA_SQLITE.sql
)

if rg -i 'CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?(memories|memory_embeddings|memory_events)\\b' "${ROOTS[@]}"; then
  echo "check-memory-store-invariants: forbidden parallel memory store table detected" >&2
  exit 1
fi

if rg -i 'CREATE[[:space:]]+VIRTUAL[[:space:]]+TABLE[[:space:]]+.*agent_memories_fts' "${ROOTS[@]}"; then
  echo "check-memory-store-invariants: forbidden plaintext body FTS in memory migrations" >&2
  exit 1
fi

echo "check-memory-store-invariants: ok"
