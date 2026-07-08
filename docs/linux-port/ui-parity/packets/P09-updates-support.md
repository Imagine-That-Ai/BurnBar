# P09 — Updates + Support diagnostics

**Wave 1 · Routes: `updates`, `support`.**

## Mission

Updates: package-channel status, current version, restart guidance. Support: the operator cockpit — daemon diagnostics, perf sample table (exists), redacted diagnostics export, tray status, fixture toggle (exists). Support is where honesty lives; raw errors appear here and only here.

## Read first

- README §1–§2; existing `UpdatesSurface.tsx`, `SupportSurface.tsx` (fixture toggle, perf table, tray note, and `showRawDiagnostic` are contracts to keep).
- macOS oracle: `AgentLens/Views/Components/UpdateBannerCard.swift`; support/diagnostics views.
- Release reality: `docs/linux-port/release-runbook.md` — Linux updates flow through the package channel, not an in-app updater; copy must reflect that.

## Data contract

1. Bridge: `app_version_info` → `{ shellVersion, daemonVersion, packageChannel: 'deb'|'appimage'|'unknown', updateCheck: 'unavailable-in-shell' }`; `export_diagnostics` → writes a redacted JSON bundle via Tauri dialog/save and returns the path.
2. Redaction is daemon-side or bridge-side: provider payloads, tokens, and socket auth material never enter the export. List what IS included in the UI before exporting.
3. Keep existing failure-state rows (`channel-unavailable`, `restart-required`).

## Files

`src/state/supportStore.ts`; `src/surfaces/updates/UpdatesSurface.tsx` rework, `src/surfaces/support/` (`SupportSurface.tsx` rework, `DiagnosticsExportCard.tsx`, `VersionGrid.tsx`) + tests; `SurfaceRouter` edits; `app.css` `/* ---- P09 support ---- */`.

## Build steps

1. `VersionGrid`: shell/daemon/package-channel facts (`.fact` grid); mismatch between shell and daemon version renders a degraded banner.
2. `UpdatesSurface`: channel card + restart guidance + the existing failure list; explicitly states "updates are delivered by your package manager".
3. `DiagnosticsExportCard`: contents manifest (what's included/excluded), export button, success row with the written path, failure banner with the raw error.
4. Perf table: keep, add the `Sparkline` per repeated sample name (group rows by name, sparkline of ms values).

## Required states

Both routes: populated / loading / error / offline. Support extra: export-in-flight, export-success, export-failed; tray-degraded row (exists). Updates extra: version-mismatch degraded.

## A11y / Perf / Tests

- Export progress announced; manifest is a real list, not a tooltip.
- Tests: export flow (success/failure with fake bridge), version-mismatch banner, existing contracts intact (fixture toggle flips store + localStorage, perf table renders samples).

## Done / Forbidden

README §4. Forbidden: exporting unredacted payloads; promising in-app updates; removing the fixture toggle or raw-diagnostic line.
