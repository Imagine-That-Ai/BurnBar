# Insights — Windows port (Phase 3 · W7)

Windows render of the macOS Insights tab: a **template gallery** that stamps a canvas of
**Win2D-drawn chart widgets** laid out on a 12-column grid. This is the Windows analog of
`AgentLens/Views/Insights/*` (TemplateGallery / CanvasGrid / Workspace) plus the in-core chart
widget set + `InsightWidgetRenderer` (`OpenBurnBarCore/.../Views/Insights/*`).

## The split: portable chart MATH vs. Windows render

The parity-critical logic — chart geometry, grid packing, formatting, templates — is a
**dependency-free** managed library that is **unit-tested on the macOS authoring host** and
also ships on Windows. Only the GPU-bound draw pass is Windows-only.

| Layer | Where | Verified on macOS? |
| --- | --- | --- |
| Chart geometry (bar / line / radar / heatmap / sankey / donut / funnel / scatter / KPI-sparkline) | `OpenBurnBar.App.Presentation/Insights/Charts/` | ✅ `dotnet test` — known dataset → exact bar rects / radar points / heatmap buckets / sankey heights / line domains / donut angles |
| Grid layout (row-major first-fit packing, move/resize clamp, column reflow) | `…/Insights/InsightLayout.cs` | ✅ unit-tested |
| Formatting + color (currency/tokens/percent ramp, hex + HSB→RGB, series color) | `…/Insights/InsightFormatting.cs` | ✅ unit-tested vs. hand-computed values |
| Models + 8 built-in templates + `Instantiate()` stamping + sample data | `…/Insights/*.cs` | ✅ unit-tested (template counts, no-overlap placement, determinism) |
| Win2D chart painters + `CanvasControl` host | `OpenBurnBar.App/Insights/InsightChart*.cs` | ⛔ Windows-only (Win2D GPU) — CI/dev-host deferred |
| Template gallery, canvas panel, widget tile (XAML) | `OpenBurnBar.App/Insights/*.xaml` | ⛔ Windows-only (XamlCompiler) — CI/dev-host deferred |

`InsightChartCanvas`/`InsightChartPainters` are thin forwards: they call the parity-tested
geometry engines to get rectangles / polygons / arc angles, then issue the matching Win2D
fill/stroke/text calls. **No layout math lives in the render layer** — that is exactly what
keeps the math testable off a GPU.

## Sample data

Each built-in template ships deterministic `InsightSampleData` so the gallery → canvas flow
renders real, populated charts immediately, before the (later) Insights data engine lane wires
the live provider/session data source. The canvas shows a **"Sample data preview"** chip while
this is the case.

## Verification ceiling (honest)

- **macOS-verified:** every XAML is `xmllint` well-formed; every C# Roslyn syntax-parses clean;
  `dotnet build OpenBurnBar.App.csproj` reaches the byte-identical Windows-only `XamlCompiler.exe`
  gate with **0 MSBuild/item errors** (all referenced portable libs compile); the portable
  Insights logic passes a real `dotnet test` suite.
- **Windows-CI / dev-host deferred:** XAML compile, the Win2D GPU chart render, and the live
  visual pass. See `windows/app/DEV_HOST_RUNBOOK.md`.

## Shell registration

`insights` is wired as a live NavigationView destination in `Shell/AppShell.xaml.cs`
(replacing the parity stub for that key); the remaining keys still show the stub.
