# Windows indexed-search plane evidence

WPD-0006 row: 31 (`Indexed search service`)

Disposition: **SUB-DONE** (app-side encrypted index)

## Production path

- `SettingsSearchEngine` performs weighted token search over the settings manifest.
- `CommandPalette` opens `WindowsStorageDevHost.CreateSessionLogReadSource()` and loads a bounded 200-record working set from the encrypted local conversation store.
- `StorageSessionLogReadSource.SearchMatchingIdsAsync` queries the conversation FTS index and returns ranked record ids without copying the index into a second store.
- `SessionLogSearch.Rank` preserves FTS order, bounds results, and provides deterministic title, project, provider, session-id, full-text, and subsequence fallback for older databases without a usable FTS table.
- Each new query cancels stale search work. The palette renders loading, empty, and unavailable states and carries the selected session id through shell navigation to the session-log detail pane.

The Windows substitution is intentionally app-side because WPD-0007 does not create a monolithic Windows daemon. The encrypted storage read seam remains the source of truth.

## Verification

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --filter FullyQualifiedName~SessionLogSearchTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --filter FullyQualifiedName~StorageSessionLogReadSourceTests
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj
```

`SessionLogSearchTests` covers recency and stable ties, FTS rank preservation, authoritative FTS behavior, metadata/subsequence fallback, multi-term matching, and result limits. `StorageSessionLogReadSourceTests` covers the real encrypted-store FTS adapter. The settings suite pins the 34-row substitution matrix and the row-31 promotion.
