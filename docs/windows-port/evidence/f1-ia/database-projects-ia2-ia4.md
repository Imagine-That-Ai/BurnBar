# Ledger row: nav-database / nav-projects

**What this proves:** Windows ships IA-2 Database System browse and IA-4 Projects
list-level grouping over the same SQLCipher session-log read seam as Session Logs.
Production defaults use `WindowsStorageDevHost.CreateSessionLogReadSource()` which
falls back to honest empty (`SessionLogEmptySource`) when credentials are absent —
never demo session fiction. Projects UI discloses WPD-0003 static-parser deferral.

**Tests:** `windows/tests/presentation/Database/DatabaseBrowseViewModelTests.cs`,
`windows/tests/presentation/Projects/ProjectsListViewModelTests.cs`,
`windows/tests/shell/NavCatalogTests.cs` (product routes, not stubs).

**Host residual:** Live Mac-produced SQLCipher open on Win11 remains H2 evidence
under storage proofs; portable empty/list logic is proven on the authoring host.
