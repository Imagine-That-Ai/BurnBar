# Memory kill-switch drill runbook

Operator drill to verify fail-closed memory extraction and authority writes.

## Preconditions

- macOS app build with memory consent granted (`Settings → Privacy → Memory`).
- At least one pending extraction job or active chat session.

## Drill steps

1. **Fleet extraction kill** — set Remote Config `memory_extraction_enabled` to `false` (or toggle off in debug). Confirm:
   - `MemoryExtractionEngine` drain does not claim jobs (`memory_extraction_launch_skipped` log).
   - No new `agent_memories` rows appear after a terminal chat commit.

2. **Authority writes kill** — set Remote Config `memory_authority_writes_enabled` to `false`. Confirm:
   - Extraction may still run LLM (if extraction RC is on) but worker writes zero durable rows.
   - `MemoryAuthorityWritesSwitchRegistry.isAllowed()` returns false.

3. **Combined recovery** — re-enable both RC keys. Confirm:
   - `launchDrain()` processes backlog.
   - Pending inbox items appear for new extractions.

## Automated coverage

- `MemorySettingsAndKillSwitchTests` — gate matrix + registry propagation.
- `MemoryActivationEndToEndTests` — quarantine → approve → recall path.

## Rollback

Re-enable RC defaults (`memory_extraction_enabled=true`, `memory_authority_writes_enabled=true`). No schema migration required.
