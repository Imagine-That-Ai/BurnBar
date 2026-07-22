# Windows General settings persistence evidence

**Date:** 2026-07-13  
**Lane:** F2 settings/runtime composition

Ledger row: nav-settings

## What this proves

The Windows General page no longer renders inert default controls. The exact
macOS time-range set (Today, Last 7 Days, Last 30 Days, This Month, All Time),
usage display mode, refresh interval, indexing enablement, auto summaries,
embedding provider, and OpenAI embedding model now share a portable
`GeneralSettingsViewModel` and a JSON-backed Windows store. Values are loaded
and normalized at page startup, persisted on change, and reloaded across page
instances. The provider key action writes only to protected storage and clears
the input control after a successful save; errors expose an unavailable state
without logging the secret.

Legacy `week` and `month` values migrate deterministically to Last 7 Days and
Last 30 Days. New values use stable storage keys rather than enum-name casing,
so later UI copy changes do not corrupt the persisted contract. The previously
inert **Run wizard** action now routes back to the real onboarding flow.

The default values match macOS: Today, currency, 10-minute refresh, indexing
off, auto summaries on, deterministic embeddings, and
`text-embedding-3-small`.

The app composition root now consumes the same normalized snapshot. The
dashboard's local SQLCipher aggregate and cloud fallback apply one selected
window to cost, tokens, and distinct sessions; an empty bounded window stays
empty instead of silently falling back to all-time data. The live usage runtime
applies the same window and Dollars/Tokens mode to dashboard totals, provider
and model ranking, flyout metrics, session counts, and sparklines. The shell
BURN capsule is now subscribed to that live runtime rather than remaining a
sample-or-empty ornament. Sample mode remains explicitly labeled.

The usage runtime also receives the persisted refresh cadence at startup, and
both the companion project-memory service and Projects page honor the indexing
toggle. The usage scan request suppresses conversation bodies whenever
indexing is off, matching the macOS privacy boundary rather than merely hiding
the index UI. Changing the cadence applies on the next app launch; changing
indexing applies when the project-memory surface is recreated.

## Architecture and performance

Range math and usage projection live in the dependency-light Presentation
assembly, so the same code ships under WinUI and runs in portable xUnit tests.
WinUI owns only settings persistence and composition. Local totals use one
parameterized aggregate query for cost, token, and distinct-session totals;
the cloud path filters its existing bounded response once. No per-provider or
per-model network calls were added. Live provider/model projection remains a
single bounded in-memory grouping pass over the runtime snapshot.

## Validation

```text
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj --no-restore
```

Result: **146 settings tests passed**. The General suite covers defaults, enum
and refresh normalization, embedding-model normalization, persistence round
trips, legacy range migration, stable keys, normalized snapshots, and malformed
stored snapshots. The usage-runtime suite also verifies that a configured
ten-minute cadence is retained by the runtime.

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --nologo -v:minimal -m:1
dotnet test windows/tests/storage/OpenBurnBar.App.Storage.Tests.csproj --no-restore --nologo -v:minimal -m:1
dotnet test windows/tests/cloudsync-app/OpenBurnBar.App.CloudSync.Tests.csproj --no-restore --nologo -v:minimal -m:1
```

Results: **770 presentation**, **18 storage**, and **61 CloudSync tests passed**.
Focused cases prove bounded-window exclusion without all-time fallback, token
units and ranking, flyout scoping/sparkline units, exact window names and UTC
floors, SQLCipher month/all-time aggregates, and matching cloud totals.

The Windows app managed build reaches the known macOS boundary at the
Windows-only WinUI `XamlCompiler.exe`; all 26 referenced managed projects,
including the new settings, usage-runtime, and presentation assemblies, compile
with zero warnings before that boundary. The stopped UTM Windows guest could
not be started through its automation interface because macOS returned
`OSStatus -10004`; therefore this evidence does not claim a fresh Windows-host
XAML compile for this increment.

## Boundary

This closes the local General-settings persistence/consumption gap and the
sample-only shell telemetry gap. It does not prove a live Windows UIA/Narrator
pass, staging cloud lifecycle, physical performance, or public update/Store
certification. A Windows-host build and interaction pass remains the next
refinement for this exact UI increment; the broader external certification
gates remain unchanged.
