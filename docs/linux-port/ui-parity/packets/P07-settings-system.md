# P07 — Settings, database, projects, memory

**Wave 1 · Routes: `settings`, `database`, `projects`, `memory`.**

## Mission

Turn four thin surfaces into real system pages: grouped settings with Linux-specific sections (paths, Secret Service, telemetry, privacy), database health (SQLCipher status, migration state, size), project workspaces, and memory recall boundaries. Settings copy carries the Linux trust story — every toggle names what it grants.

## Read first

- README §1–§2; existing `SettingsSurface.tsx`, `SystemStatusSection.tsx` (keep the failure-state rows — they are evidence-pinned via `[data-failure-state]`).
- macOS oracle: `AgentLens/Views/Settings/` tree, `ComputerUseSettingsView.swift` (structure only — Computer Use itself is out of scope), memory views under `AgentLens/Views/` (`MemoryCitationChipView.swift` for chip idiom).
- Failure-state canon: `src/shellEvidenceModel.ts` `failureStateCases()` — settings/account rows there must keep rendering.
- Daemon: `BurnBarDaemonServer+RPCConfig.swift`, `+RPCMemory.swift`.

## Data contract

1. Bridge: `config_snapshot` (read-only settings state: paths, secret-store status, telemetry flags), `db_status` (`{ sqlcipherOk, migrationVersion, sizeBytes, walMode }`), `project_list`, `memory_boundaries` — all mapped from real RPC methods.
2. v1 settings are **read + explain**: toggles that the daemon does not yet expose as writable render disabled with "managed by daemon config" copy. Never fake a writable control.
3. Fixtures for all four routes (append to `FIXTURE_ROWS` and add typed fixture functions).

## Files

`src/state/systemStore.ts`; `src/surfaces/settings/` (`SettingsSurface.tsx` rework, `SettingGroup.tsx`, `SettingRow.tsx`), `src/surfaces/database/DatabaseSurface.tsx`, `src/surfaces/projects/ProjectsSurface.tsx`, `src/surfaces/memory/MemorySurface.tsx` + tests; four `SurfaceRouter` line edits; `app.css` `/* ---- P07 system ---- */`.

## Build steps

1. `SettingGroup`/`SettingRow`: label + description + control column; description text explains the Linux permission/path implication (reuse tone from `onboardingSteps.ts`).
2. Settings sections: Paths (XDG dirs, socket, provider log paths with copy buttons), Secret Service (status + unlock guidance), Privacy & telemetry (explicit opt-in copy), Danger zone (links to Support diagnostics; no destructive actions in v1).
3. `DatabaseSurface`: status grid (`.fact`-style) + migration table + honest degraded when locked/unavailable.
4. `ProjectsSurface`/`MemorySurface`: `DataTable`-based lists with recall-boundary copy; memory rows show scope chips.
5. Keep `SystemStatusSection` at the top of settings (evidence contract).

## Required states

Each of the four routes: populated / loading / empty / error / offline. Settings additionally: secret-store-locked and permission-denied rows (already in `failureStateCases()`; keep ids stable).

## A11y / Perf / Tests

- Disabled controls carry `aria-disabled` + explanation; copy buttons announce "Copied".
- Tests: read-only enforcement (no writable control without a daemon write method), failure-state ids still present, four routes × five states.

## Done / Forbidden

README §4. Forbidden: removing `[data-failure-state]` rows or changing their ids; fake writable toggles; destructive actions.
