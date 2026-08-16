# Paste this to Factory Droid (BurnBar Live Agent Fleet)

Continue BAU on `feat/live-agent-fleet`. Do not stop, rebase, or wait on Grok.

A Cursor/Grok session is also in this checkout (`/Users/albertonunez/Developer/AgentLens`, same branch). It will **only** add files under `tools/burnbar-mcp/**` (`fleet.py`, MCP tools `burnbar_fleet_snapshot` / `burnbar_fleet_can_launch` / `burnbar_fleet_presence_record`, sidecar `fleet-presence.json`, tests, README, `TEAM_SYNC.md`). It will **not**:

- edit Swift, `project.yml`, `BurnBarContracts.swift`, daemon, Fleet UI, or `docs/fleet/`
- touch the protected WIP files (Alternate3Dashboard, AgentLensApp, Settings*, SearchService, BurnBarSearchPlanner, those tests, pbxproj)
- push this branch
- run `xcodebuild` or BurnBar app UI
- steal M4 repair / M5 API docs / M6 hardening

If git conflicts:

1. Keep **your** Swift/daemon/`docs/fleet/` hunks.
2. Keep **theirs** only if the path is `tools/burnbar-mcp/**`.
3. Never resolve by deleting `tools/burnbar-mcp/`.
4. If unsure, skip that file and keep shipping M4 → M5 → M6.

Probes stay read-only. Do not add CloudSync to the fleet serving path (CROSS-018). Presence RPC on the daemon is **after M5**, not yours unless Alberto says otherwise.
