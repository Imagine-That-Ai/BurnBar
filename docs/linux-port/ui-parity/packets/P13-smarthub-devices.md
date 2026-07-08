# P13 — SmartHub / Cast / Home Assistant / PixelClock settings

**Wave 2 (after P07) · Surface: settings section.**

## Mission

Bring the smart-device integrations into Linux settings: connection status and configuration readout for SmartHub bridge, Google Cast, Home Assistant, AWTRIX/PixelClock. v1 is read-and-explain (like P07 settings): render daemon-reported integration state with honest capability-absent rows.

## Read first

- README §1–§2; P07 packet (SettingGroup/SettingRow idiom — reuse those components).
- macOS oracle: SmartHub/Cast/HA/PixelClock settings views (search `SmartHub`, `HomeAssistant`, `PixelClock`, `GoogleCast` under `AgentLens/Views/`).
- Daemon vocabulary: integration kinds already exist in daemon models (`smart_hub_bridge`, `google_cast`, `home_assistant`, `pixel_clock`, `awtrix_http` — see `OpenBurnBarDaemon` coding keys).

## Data contract

Bridge: `integrations_status` → `{ integrations: {kind, label, state: 'connected'|'configured'|'unavailable'|'disabled', detail}[] }` from the daemon config/tooling RPC (`BurnBarDaemonServer+RPCTooling.swift` / `+RPCConfig.swift`). Fixture covers all four kinds across all four states.

## Files

`src/state/integrationsStore.ts`; `src/surfaces/settings/IntegrationsSection.tsx` + per-kind row components + tests; mount inside P07's `SettingsSurface` (coordinate; Cross-agent receipt); `app.css` `/* ---- P13 integrations ---- */`.

## Build steps

1. One `SettingGroup` per integration kind; `StatusPill` tone per state; detail line names host/port/entity counts as the daemon reports them.
2. `unavailable` rows explain the Linux dependency (e.g. Avahi for discovery) with a docs link — reuse failure-list styling.
3. No credential entry; configuration happens daemon-side, and the row says where.

## Required states

Populated (all four kinds) / loading / empty ("No integrations configured") / error / offline; per-row capability-absent copy.

## A11y / Perf / Tests

- Rows are list semantics with named status; links have descriptive text.
- Tests: all kind×state combinations from fixture, mount inside settings, five states.

## Done / Forbidden

README §4. Forbidden: credential inputs; probing network devices from the shell (daemon's job); inventing integration kinds.
