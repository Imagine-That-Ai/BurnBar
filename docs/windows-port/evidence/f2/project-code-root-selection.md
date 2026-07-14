# Windows Project Code workspace selection evidence

**Date:** 2026-07-13
**Lane:** F2 project-code product reachability and lifecycle safety

Ledger rows: `f2-project-code-lexical`, `f2-project-code-memory-store`,
`project-code-static-parser`

## What this proves

The Windows product has a user-reachable, durable Project Code workspace
selection. The Projects page opens the Windows folder picker with the real app
window owner, persists the normalized non-secret path, explicitly enables code
indexing, and reuses the same long-lived `ProjectCodeMemoryService` as the
authenticated companion plane. A developer environment variable is no longer
required for the normal product path.

## Implementation

- `ProjectCodeRootSettingsViewModel` normalizes paths, rejects filesystem roots
  and symbolic-link/junction roots, preserves a missing saved folder as a visible
  recovery state, and repairs malformed persisted values.
- `WindowsProjectCodeRootStore` writes `projectCode.root` through the existing
  typed Windows settings persistence. Per-root JSON fallback indexes use a
  case-normalized SHA-256 identity under
  `%LOCALAPPDATA%\OpenBurnBar\ProjectCode\indexes`; the app does not add
  `.openburnbar` metadata to a selected repository.
- Folder changes are transactional. The replacement service restores any valid
  checkpoint and completes an initial refresh before it is atomically published.
  A failed change leaves the previous live service in place and restores the
  previous root and indexing preference.
- The Projects page reads the app-owned service rather than creating and
  disposing a second page-local index. The companion handler holds the service
  lifecycle gate for each operation, and app shutdown/restart uses the same gate.
- `ProjectCodeSymbolIndex` serializes synchronous, parser-backed, and watcher
  refreshes. Disposal stops new callbacks and waits for an in-flight refresh
  before closing the encrypted durable store.
- `ProjectCodeFileEnumerator` deterministically skips directory and file reparse
  points. The lexical inventory, symbol index, and durable metadata scan share
  that traversal, preventing a nested junction from escaping the chosen root.
  Reference and context-pack reads revalidate the root and every path component,
  so a stale checkpoint cannot follow a link introduced after indexing.
- If every attempted parser request fails because the configured parser process
  is unavailable, the refresh performs the bounded lexical fallback and reports
  `lexical` rather than returning a misleading empty Tree-sitter snapshot.
- The root controls adapt below 640 pixels so the choose/clear commands move
  below the path instead of compressing or covering it. Selection, unavailable,
  applying, success, and failure states remain visible and keyboard reachable.

`OPENBURNBAR_PROJECT_ROOT` remains only as a non-persisted compatibility override
when the user has never saved a root. Parser and LSP executable configuration are
separate deployment concerns.

## Validation

```text
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj --no-restore --nologo
Passed: 166, Failed: 0, Skipped: 0

dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --nologo
Passed: 778, Failed: 0, Skipped: 0

dotnet format windows/app/OpenBurnBar.App.Settings.ViewModels/OpenBurnBar.App.Settings.ViewModels.csproj --no-restore --verify-no-changes --include <changed settings files>
Exit: 0

dotnet format windows/app/OpenBurnBar.App.Presentation/OpenBurnBar.App.Presentation.csproj --no-restore --verify-no-changes --include <changed project-code files and tests>
Exit: 0

dotnet format windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj --no-restore --verify-no-changes --include <changed app files>
Exit: 0 (workspace-load warnings only)

xmllint --noout windows/app/OpenBurnBar.App/Projects/ProjectsPage.xaml
Exit: 0

dotnet build windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj --nologo -v:minimal -m:1
Expected macOS boundary: every referenced managed assembly compiled, then the
host could not execute Windows XamlCompiler.exe. One existing Win2D AnyCPU copy
warning preceded the boundary; no C# or project-reference error did.

PR Windows Fast Gate run 29299426816 at commit
6c5abc8bd81cb9a87003f4a029d87acac293a88e
Windows x64 restore: PASS
Transitive NuGet vulnerability audit: PASS
Full Windows solution build, including WinUI XAML: PASS
Windows test suite: PASS (37 projects; 3,315 passed, 14 skipped, 3,329 total)
Parity ledger and aggregate Windows gate: PASS
PR Windows Full Suite run 29299426779: PASS on x64 and native-hosted ARM64
with the same 37-project result on each architecture.
Project Code Static Parser run 29299426836: PASS for x64 tests/build/smoke and
ARM64 MSVC build.
```

Authoritative runs: [PR Windows Fast Gate 29299426816](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426816),
[PR Windows Full Suite 29299426779](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426779),
and [Project Code Static Parser 29299426836](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426836).
The skipped tests remain explicitly reported; this evidence does not relabel
them as passes.

The new tests prove durable selection and repair, unavailable-folder honesty,
filesystem-root and reparse-root rejection, nested/stale reparse traversal denial,
metadata-only persistence, parser-unavailable lexical fallback, and disposal
waiting for an active parser refresh.

## Boundary

The exact current branch now has authoritative Windows x64 compile and automated
test evidence for the adaptive XAML and code-behind. It is not a Windows UI
interaction claim. A signed installed build must still exercise choose, persist,
restart, unavailable, clear, keyboard, Narrator, high-contrast, and DPI behavior;
the current Project Code increment also needs an ARM64 compile before those host
gates can be promoted. Live language-server availability, learned macOS
NaturalLanguage/BGE embedding quality, physical performance, staging cloud,
advanced Computer Use/media safety, and Store/update certification remain
separate gates.
