# Windows General settings persistence evidence

**Date:** 2026-07-13  
**Lane:** F2 settings/runtime composition

Ledger row: nav-settings

## What this proves

The Windows General page no longer renders inert default controls. Time range,
usage display mode, refresh interval, indexing enablement, auto summaries,
embedding provider, and OpenAI embedding model now share a portable
`GeneralSettingsViewModel` and a JSON-backed Windows store. Values are loaded
and normalized at page startup, persisted on change, and reloaded across page
instances. The provider key action writes only to protected storage and clears
the input control after a successful save; errors expose an unavailable state
without logging the secret.

The default values match macOS: Today, currency, 10-minute refresh, indexing
off, auto summaries on, deterministic embeddings, and
`text-embedding-3-small`.

## Validation

```text
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj --no-restore
```

Result: **141 tests passed**. The new General suite covers defaults, enum and
refresh normalization, embedding-model normalization, persistence round trips,
and malformed stored snapshots.

The Windows app managed build reaches the known macOS boundary at the
Windows-only WinUI `XamlCompiler.exe`; all portable dependencies and the new
settings view-model compile before that boundary.

## Boundary

This closes the local settings persistence and provider-selection gap. It does
not prove a live Windows UIA/Narrator pass, staging cloud lifecycle, physical
performance, or public update/Store certification.
