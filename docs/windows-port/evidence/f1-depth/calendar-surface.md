# Ledger row: nav-calendar

**What this proves:** The Windows Calendar surface reaches parity with the macOS
oracle (`AgentLens/Views/Calendar/` + `AgentLens/Services/Charts/CalendarDataService.swift`)
for the whole selection→analytics pipeline, with the portable decision logic
living in `windows/app/OpenBurnBar.App.Presentation/Calendar/` (net8.0) so it is
unit-testable off-host.

The Presentation assembly owns every behaviour that can produce a wrong number:

- `CalendarLocalTime` / `CalendarBucketing` — local-timezone `startOfDay`
  attribution by row start time. The UTC `DATE(startTime)` SQL path is
  deliberately not used, matching the macOS convention, so a 23:30 local row
  stays on its own day instead of drifting forward.
- `CalendarMonthGridModel` — whole-week grids, locale first-weekday, leading and
  trailing overflow cells, month-boundary and leap-year day counts.
- `CalendarMonthSnapshot` — per-day cost rollup, top-3 provider ranking per day,
  and the month **peak** that is the heatmap intensity denominator (overflow
  cells paint but are excluded from the month total).
- `CalendarSelectionModel` — single click, inclusive shift-range, ctrl-toggle,
  and drag-paint, mirroring the macOS `CalendarSelectionModel` gesture contract.
- `CalendarSelectionSnapshot` — selection analytics: gap-filled per-day burn,
  distinct-session counting, provider/model/project ranking, 7×24 weekday-hour
  matrix, and the cache-ROI / reasoning-share ratios.
- `CalendarPageLayout` — card order, visibility, and S/M/L span persistence with
  forward/backward-compatible JSON decoding (unknown kinds dropped, newly added
  kinds appended).
- `CalendarUsageSource` — the honest data ladder (live local runtime → cloud
  Firestore REST → labeled sample → empty), patterned on
  `DashboardUsageProvider`.

**Tests:** `windows/tests/presentation/Calendar/` — 9 test classes, **76 tests,
0 failures**, executed on macOS against `net10.0`:

```
$ dotnet test windows/tests/presentation --filter "FullyQualifiedName~Calendar"
Passed!  - Failed: 0, Passed: 76, Skipped: 0, Total: 76 - OpenBurnBar.App.Presentation.Tests.dll (net10.0)
```

The full presentation suite is green with the Calendar surface added:

```
$ dotnet test windows/tests/presentation
Passed!  - Failed: 0, Passed: 872, Skipped: 0, Total: 872 - OpenBurnBar.App.Presentation.Tests.dll (net10.0)
```

Nav registration is complete across the fail-closed triple, so the surface
resolver guard covers this route:

- `windows/app/OpenBurnBar.App/Shell/NavDestination.cs` — `calendar` catalog entry.
- `windows/app/OpenBurnBar.App/Shell/SurfaceRouteMap.cs` — `"calendar" → "CalendarPage"`.
- `windows/app/OpenBurnBar.App/Shell/SurfacePageResolver.cs` — `CalendarPage` type binding.

**Operational residual (host-gated):** `CalendarPage.xaml` / `CalendarPage.xaml.cs`
are WinUI and therefore compile only through XamlCompiler on a Windows host.
This evidence covers the portable presentation logic and the route registration,
which is where the parity risk lives; the XAML compile and the on-device visual
pass ride the standard Win11 host validation run
(`docs/windows-port/evidence/h2-host/`) like every other WinUI page. No numbers
rendered by that page are computed in XAML — the page binds to the Presentation
types proven above.
