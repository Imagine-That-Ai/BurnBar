# Shared UI components — Bucket A (foundational)

Windows/WinUI peers of the reusable macOS controls in `AgentLens/Views/Components/` and the
in-Core `Unified*` views. These are the **shared vocabulary** the Settings / Dashboard / Chat /
Quota surfaces reuse, so their API shape and parity are the contract every later surface builds on.

Every control consumes — and never reimplements — the Wave-1/2 foundation:
the **design tokens** (`Theme/Tokens.xaml`, `Theme/PensieveTokens.cs`, `Theme/ProviderBrand.cs`),
the **Mica/Acrylic glass shim** (`Theme/LiquidGlass.cs` + `Theme/LiquidGlass.xaml`), and the
particle engine where relevant.

## Two-layer split (why the logic lives apart from the XAML)

Each control is split into:

1. **A portable logic core** — `Components/Models/*.cs`, pure `System`-only C# with **zero WinUI
   dependency**. This is a faithful port of the parity-critical Swift math/classification/copy.
   It compiles **and runs on the macOS authoring host**, and every rule is asserted by
   `windows/tests/components/*` (`dotnet test`, **133 tests, all green on macOS**).
2. **A WinUI `UserControl`** — `Components/*.xaml` + `*.xaml.cs`, Windows-only. It turns the model
   values into brushes / geometry / layout and wires the tokens + glass chokepoint. WinUI XAML
   compiles only on a Windows host (the `XamlCompiler.exe` gate); see **Verification** below.

This mirrors the established `Theme/LiquidGlassTransparency.cs` (pure math) ↔ `Theme/LiquidGlass.cs`
(WinUI adapters) pattern and lets the parity-critical logic be proven off-Windows.

## Controls + API shape

| Control | Swift origin | Key API | Foundation consumed |
|---------|-------------|---------|---------------------|
| `AppLogoView` | `AppLogoView.swift` | `Size` | `Assets/AppLogo` |
| `MiniSparkline` | `MiniSparkline.swift` | `Data`, `LineColor` | `SparklineGeometry`, ember token |
| `ProviderLogoView` | `ProviderLogoView.swift` + `UnifiedProviderLogoView.swift` | `Provider`, `LogoSize`, `UseFallbackColor` | `ProviderMetadata`, `ProviderBrand` |
| `UnifiedGlassCard` | `UnifiedGlassCard.swift` | `CardContent` (ContentProperty), `Interactive` | `LiquidGlass.Surface`, radius/space tokens |
| `UnifiedSkeletonView` | `UnifiedSkeletonView.swift` | `BarHeight`, `Radius` | ember/amber tokens; Reduce-Motion aware |
| `UnifiedQuotaSignalView` | `UnifiedQuotaSignalView.swift` | `Bucket`, `Provider`, `Compact`, `DisplayMode` | `QuotaBucket`, `QuotaFill`, `ProviderBrand` |
| `UnifiedToolCallAccordion` | `UnifiedToolCallAccordion.swift` | `Calls`, `AccentColor` | `ToolCallDisplay`, `ToolCallAccordionModel` |
| `UpdateBannerCard` | `UpdateBannerCard.swift` | `State`, `Compact`, `ActionInvoked` | `UpdateBannerState`, `LiquidGlass.Surface` |
| `DashboardActionGlyph` | `DashboardActionGlyphs.swift` | `Kind`, `GlyphSize`, `GlyphStroke` | `DashboardGlyphGeometry` |
| `QuotaSourceBadge` | `ProviderQuotaStripViews.swift` | `Source`, `Confidence` | `QuotaFill.SourceLabel`, pill token |
| `QuotaWindowStrip` | `QuotaDualWindowStrip` (`ProviderQuotaStripViews.swift`) | `HourlyBucket`, `WeeklyBucket`, `FallbackBucket`, `Provider` | `QuotaBucket`, `QuotaFill`, `ProviderBrand` |
| `SessionLedgerSection` | `SessionLedgerSection.swift` | `Usages`, `Provider`, `ShowsAgentBadge`, `DisplayMode`, `FooterCaption`, `SessionSelected` | `SessionLedgerSupport`, `SessionLedgerBucketExtensions`, `ProviderBrand` |

### Portable models (`Components/Models/`)

- `ProviderMetadata` — display name, bundled-logo asset name, monochrome-backdrop decision, Segoe
  fallback glyph (keyed by the shared `Theme.AgentProviderBrand`).
- `QuotaModels` — `QuotaBucket` (`DisplayRemainingFraction`, window kind/label, unit + formatted
  text), `QuotaFill.Band`, `QuotaSignalStatus.Resolve`, `QuotaSourceKind`/`QuotaConfidence`.
- `ToolCallModels` — `ToolCallDisplay` (state classification, icon glyph, expandable detail),
  `ToolCallAccordionModel` (most-recent / additional-count / older-calls / expandable).
- `SessionLedgerModels` — `SessionLedgerBucket` + boundary/title math, `SessionLedgerSupport`
  (search + grouping).
- `UpdateBannerModels` — `UpdateBannerState` (phase → title/subtitle/icon/actionability).
- `SparklineGeometry` — normalized points + Catmull-Rom → cubic Bézier smoothing.
- `DashboardGlyphGeometry` — the exact 24×24 stroked figure tables + grid→rect transform.

## Accepted drift (documented, gated at G3 vs macOS goldens)

- **SF Symbols → Segoe glyphs.** Provider/tool/banner fallback glyphs map to a small, confident
  Segoe MDL2/Fluent palette (SF Symbols do not exist on Windows). The parity-true path for provider
  logos is the bundled asset (`Assets/ProviderLogos/<name>.png`); the control falls back to the
  glyph only when the asset is absent.
- **Glass = system backdrop.** Per the `LiquidGlass` R7 note, the frosted plate is Mica/Acrylic
  (window/desktop blur), not macOS content-refraction. Cards route through `LiquidGlass.Surface`.
- **Update channels.** macOS `directDMG / homebrew / source` → Windows `Direct download / winget /
  source` (same three-arm shape).

## Verification (macOS ceiling — stated honestly)

- **Portable logic:** `dotnet test windows/tests/components` → **133 tests pass on macOS.**
- **XAML:** `xmllint --noout` well-formed on all 12 `.xaml`.
- **C#:** Roslyn syntax-parse clean (0 errors) on all 19 `Components/*.cs`.
- **MSBuild:** `dotnet build OpenBurnBar.App.csproj` reaches the **identical `XamlCompiler.exe`
  gate** as the spike baseline (0 warnings, 1 error = `MSB3073`, the Windows-only binary that
  cannot execute on macOS) — no new MSBuild/item errors from these controls.
- **Windows-deferred:** the actual XAML compile, control instantiation, and pixel render require a
  Windows dev-host / CI runner (`windows/app/DEV_HOST_RUNBOOK.md`), plus the provider-logo asset
  pipeline.
