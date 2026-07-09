# H0 sample / demo / stub / unavailable production-path audit

**Date:** 2026-07-09 (refreshed after IA-2/IA-4 + F2 finish-line reclassification)  
**Scope:** Windows app production defaults after H0 honesty + chat driver + Database/Projects product pages  
**Rule:** Sample/demo/stub fiction must not be production default; empty/deferred/unavailable must be explicit and labeled.

## Legend

| Tag | Meaning |
|-----|---------|
| **GATED** | Behind `RuntimeDataMode.SampleModeEnabled` / `OPENBURNBAR_SAMPLE_MODE` |
| **HONEST** | Production empty / unavailable / deferred disclosure (not demo fiction) |
| **RESIDUAL** | Still present; tracked for later phases — not claimed Real without host proof |

## Production call sites

| Site | Type | Production default | Status |
|------|------|--------------------|--------|
| `CloudSyncInsightSource` | InsightSampleData | Empty widgets when sample mode off; samples only when sample mode on **and** no live usage (fail-closed hybrid) | **GATED** (H0) |
| `InsightEmptyData` | Empty chrome | KPI/non-KPI use `EmptyData` (not numeric `$0` KPI shells) | **HONEST** (H0) |
| `InsightsBuiltInTemplates` | InsightSampleData fallback | `SampleFallbackEnabled` default false; empty via `InsightEmptyData`; production prefers RealDataResolver | **GATED** (H0) |
| `InsightsPage` SampleChip | UI label | Visible only when sample payloads install (`SampleModeEnabled && !HasData` via `ShowsSamplePreviewChip`); hidden under hybrid live+sample mode | **GATED** (H0) |
| `InsightsProductionComposition` | stamp wiring | Re-Installs resolver + fresh usage summary on every stamp/Back | **HONEST** (H0 audit fix) |
| `ChatStreamDriverFactory` | composition | Sample → scripted; `OPENBURNBAR_CLI_COMMAND` set → `CliJsonLineChatStreamDriver`; else honest unavailable | **HONEST** / **GATED** |
| `CliJsonLineChatStreamDriver` | stream-json | Maps NDJSON lines through `ClaudeCodeStreamJsonParser` (shipped H3 portable path) | **HONEST** production path when CLI configured |
| `UnavailableChatStreamDriver` | Unavailable* | Explicit config guidance when CLI not configured (not scripted demo) | **HONEST** (nav-chat **DeferredApproved** WPD-0010 until Win11 live stream) |
| `MissionDispatchHostFactory` | DemoHost | Demo only when sample mode; else empty/Firestore | **GATED** |
| `QuotaAccountsSource` | QuotaSampleData | Sample only when sample mode | **GATED** |
| `FlyoutWindow` | FlyoutTraySampleData | Sample only when sample mode | **GATED** |
| `DashboardPage` / Atelier layout | DashboardCommandSampleData | Sample only when sample mode | **GATED** |
| `DashboardUsageProvider` | sample summary | Sample only when sample mode | **GATED** |
| `BurnHeroControl` (shell chrome capsule) | DashboardUsageSampleData spend | Sample spend only when sample mode; labeled Sample chip when sample | **GATED** |
| `ElderWandPage` | ElderWandSampleData | Empty groups unless sample mode | **GATED** |
| `WindowsStorageDevHost` budget/switcher | seed / SwitcherSampleData | Sample only when sample mode; empty otherwise | **GATED** |
| `WindowsStorageDevHost` session logs | SessionLogEmptySource | Always empty list when unconfigured | **HONEST** (H0 rename) |
| `CliStreamFactory` | StubCliStream | Stub on non-Windows / forced stub (design-time) | **RESIDUAL** (ConPTY on Windows host) |
| Settings `PageTypeForTab` | SettingsPlaceholderPage | Multiple tab defaults still placeholder | **RESIDUAL** (ledger `settings-s1-s2-tabs` DeferredApproved WPD-0010) |
| `SurfacePageResolver` database/projects | **DatabasePage / ProjectsPage** | Product pages (IA-2 / IA-4); **not** SurfaceStubPage | **Real** ledger rows |
| `SurfaceStubPage` | unknown keys only | Defensive fallback for unregistered keys | **HONEST** unknown-route host |
| `NativeShimUnavailableException` | Unavailable | Fail-closed native load | **HONEST** domain failure |
| Pretext `EngineUnavailable` | Unavailable | Fail-closed engine | **HONEST** domain failure |

## Test guards (H0 + F1 follow-on)

- `CloudSyncInsightSourceRuntimeTests` — production non-KPI never sample series; hybrid sample+live; sample chip/copy honesty; composition re-install
- `InsightsBuiltInTemplatesTests.ProductionDefault_DoesNotFabricateSampleSeries_AndKpisAreEmptyChrome`
- `InsightsBuiltInTemplatesTests.SampleFallbackEnabled_DefaultsFalse_FailClosed`
- `InsightEmptyDataTests` / `SessionLogEmptySourceTests`
- `ClaudeCodeStreamJsonParserTests` + `ChatStreamDriverRuntimeTests` (factory + CliJson line driver)
- `DatabaseBrowseViewModelTests` / `ProjectsListViewModelTests`
- Shell `NavCatalogTests` + `SurfaceRouteMap` product-logical completeness (DatabasePage/ProjectsPage)

## Not claimed Real by this audit (ledger authority)

- Insights / most nav surfaces → **DeferredApproved** (WPD-0010 depth) — empty honesty ≠ full Mac peer
- Chat → **DeferredApproved** (WPD-0010) until configured Win11 host streams live tokens through `ChatSurfaceViewModel`
- Database / Projects → **Real** for list-level System/IA-4 paths (Story/Atlas + static parser residual)
- Settings placeholders / H8 integrations → **DeferredApproved** (`settings-s1-s2-tabs`, mercury-media, etc.)
- Host-gated OAuth/TPM/CU/MSIX/CI → **DeferredApproved** (WPD-0008)

## Grep recipe (re-run)

```bash
rg -n 'InsightSampleData|SampleModeEnabled|DemoHost|ScriptedChat|StubCliStream|UnavailableChat|SettingsPlaceholderPage|\*SampleData' \
  windows/app --glob '*.cs'
```
