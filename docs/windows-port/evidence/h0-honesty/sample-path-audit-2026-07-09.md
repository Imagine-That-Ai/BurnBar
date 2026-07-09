# H0 sample / demo / stub / unavailable production-path audit

**Date:** 2026-07-09  
**Scope:** Windows app production defaults after H0 honesty work  
**Rule:** Sample/demo/stub fiction must not be production default; empty/unavailable must be explicit and labeled.

## Legend

| Tag | Meaning |
|-----|---------|
| **GATED** | Behind `RuntimeDataMode.SampleModeEnabled` / `OPENBURNBAR_SAMPLE_MODE` |
| **HONEST** | Production empty / unavailable / deferred disclosure (not demo fiction) |
| **RESIDUAL** | Still present; tracked for later phases — not claimed Real |

## Production call sites

| Site | Type | Production default | Status |
|------|------|--------------------|--------|
| `CloudSyncInsightSource` | InsightSampleData | Empty widgets when sample mode off; samples only when on | **GATED** (H0) |
| `InsightsBuiltInTemplates` | InsightSampleData fallback | `SampleFallbackEnabled` default false; empty via `InsightEmptyData` | **GATED** (H0) |
| `InsightsPage` SampleChip | UI label | Visible only when sample mode on | **GATED** (H0) |
| `ChatSurfaceViewModel` | Scripted vs Unavailable | `UnavailableChatStreamDriver` production; scripted sample-only | **GATED** / **HONEST** |
| `MissionDispatchHostFactory` | DemoHost | Demo only when sample mode; else empty/Firestore | **GATED** |
| `QuotaAccountsSource` | QuotaSampleData | Sample only when sample mode | **GATED** |
| `FlyoutWindow` | FlyoutTraySampleData | Sample only when sample mode | **GATED** |
| `DashboardPage` / Atelier layout | DashboardCommandSampleData | Sample only when sample mode | **GATED** |
| `DashboardUsageProvider` | sample summary | Sample only when sample mode | **GATED** |
| `ElderWandPage` | ElderWandSampleData | Empty groups unless sample mode | **GATED** |
| `WindowsStorageDevHost` budget/switcher | seed / SwitcherSampleData | Sample only when sample mode; empty otherwise | **GATED** |
| `WindowsStorageDevHost` session logs | was `SessionLogSampleData` | Renamed `SessionLogEmptySource` — always empty list | **HONEST** (H0 rename) |
| `CliStreamFactory` | StubCliStream | Stub on non-Windows / forced stub (design-time) | **RESIDUAL** (not chat Real path; ConPTY on Windows host) |
| `UnavailableChatStreamDriver` | Unavailable* | Explicit config guidance, not fake replies | **HONEST** (nav-chat remains Blocked until live driver) |
| Settings `PageTypeForTab` | SettingsPlaceholderPage | 13 tab defaults still placeholder | **RESIDUAL** (H6) |
| `SurfacePageResolver` database/projects | SurfaceStubPage | Explicit IA-1 deferred disclosure | **HONEST** (routes Blocked until depth) |
| `NativeShimUnavailableException` | Unavailable | Fail-closed native load | **HONEST** domain failure |
| Pretext `EngineUnavailable` | Unavailable | Fail-closed engine | **HONEST** domain failure |

## Test guards added (H0)

- `CloudSyncInsightSourceRuntimeTests` — production mode non-KPI never sample series
- `InsightsBuiltInTemplatesTests.ProductionDefault_DoesNotFabricateSampleSeriesForNonKpiWidgets`
- `InsightEmptyDataTests`
- `SessionLogEmptySourceTests`
- `DaemonSettingsViewModelTests.FinishLine_DefaultsToF1ShipPeer_WithScopeRows`

## Not claimed Real by this audit

- Insights remains **Substituted** (empty honesty ≠ full rollup parity)
- Chat remains **Blocked** until production `IChatStreamDriver` streams live assistant tokens
- Database / Projects remain **Blocked** (IA-1 keys only; stub disclosure)
- Settings placeholders remain H6 work

## Grep recipe (re-run)

```bash
rg -n 'InsightSampleData|SampleModeEnabled|DemoHost|ScriptedChat|StubCliStream|UnavailableChat|SettingsPlaceholderPage|\*SampleData' \
  windows/app --glob '*.cs'
```
