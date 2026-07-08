# Data & Privacy Control Center (Windows)

Windows render of the macOS governance workbench
`AgentLens/Views/Settings/DataControlCenter/*.swift`. The single surface where a member governs
every facet of their data: a tier-grouped domain sidebar, a sortable inventory, the mercury Basin,
the yours↔server flip, the domain inspector, and the recovery / panic / delete governance dialogs.

## Architecture (portable core + thin Windows shell)

The parity-critical logic lives in the **platform-agnostic** presentation library
`OpenBurnBar.App.Presentation/DataControlCenter/` (net8.0, no WinUI) and is **unit-tested on macOS**
(`windows/tests/presentation/`, 67 tests):

| Portable (tested on macOS)                       | Swift parity source |
| ------------------------------------------------ | ------------------- |
| `DataDomainRegistry.cs` — 12-domain registry + tiers | `packages/data-domains/gen/DataDomains.swift` |
| `DataControlModels.cs` — rows, limits, results, enums | `DataControlCenterViewModel.swift` (nested types) |
| `DataControlSorting.cs` — inventory sort + tier grouping + sealed fraction | `DataControlCenterView.swift` Table sort + `sealedFraction` |
| `BasinModel.cs` — mercury meniscus / sheen / bead geometry | `DataControlCenterBasin.swift` |
| `IDataControlCallableHub.cs` — Firebase callable seam | the 9 callables in `DataControlCenterViewModel.swift` |
| `DataControlDecoding.cs` — usage/audit/recovery parse + `userFacing` distillation | `applyUsage` / `parseAuditEvent` / `userFacing` |
| `DataControlCenterViewModel.cs` — orchestration | `DataControlCenterViewModel.swift` |

The **WinUI shell** here binds that core:

| View | Swift parity source |
| ---- | ------------------- |
| `DataControlCenterView.xaml` — tier-grouped NavigationView + toolbar + Basin + sortable inventory + inspector | `DataControlCenterView.swift` |
| `MercuryBasinView` + `MercuryBasinHost.cs` — Win2D `CanvasAnimatedControl` mercury swirl | `DataControlCenterBasin.swift` |
| `YoursVsServerFlip.xaml` — PlaneProjection flip card | `DataControlCenterFlip.swift` |
| `DomainInspectorView.xaml` — header, flip, footprint, Pensieve caps, audit, paths, actions | `DataControlCenterInspector.swift` |
| `RecoverySetupDialog` / `PanicRevokeDialog` / `DeleteDomainDialog` | `DataControlCenterActions.swift` |
| `DataControlConverters.cs` — tier palette + glyph + format converters | `DataControlCenterTheme.swift` (`PensieveTheme`) |

Registered in the shell via `AppShell.ResolvePageType("dataControlCenter")` →
`DataControlCenterPage` (the existing `NavCatalog` "dataControlCenter" destination).

## Verification (macOS ceiling)

`net8.0-windows` XAML cannot fully compile on macOS. Verified here:

1. **xmllint** well-formed on every `*.xaml`.
2. **Roslyn syntax-parse** clean (0 errors) on every `*.cs`.
3. `dotnet build OpenBurnBar.App.csproj` reaches the byte-identical **Windows-only `XamlCompiler.exe`
   gate** (exit 126 / MSB3073) with **0 earlier MSBuild/item errors** — every C# project reference
   compiles, and no unresolved-symbol/missing-foundation error precedes the gate.
4. The portable core builds (`net8.0`, warnings-as-errors, 0/0) and **`dotnet test` passes** (128/128).

**Windows-CI / dev-host deferred:** the actual XAML compile, render, WebView2/Win2D GPU pass, and the
real Firebase-callable hub (the workbench runs against `SignedOutCallableHub` until one is injected;
the recovery-KEY crypto envelope is the CloudVault key-wrap seam wired on the dev host).
