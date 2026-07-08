# Elder Wand configurator (Windows)

Windows render of the macOS **The Elder Wand** configurator — assemble a panel of
analysis models + a judge from the live advertised catalog, tune the research
(tool-call) budget, and save named OpenRouter "Fusion"-compatible presets.

## Parity sources (macOS)

| macOS (`AgentLens/`) | Windows |
| --- | --- |
| `Views/Chat/ElderWand/ElderWandConfiguratorModel.swift` | `…Presentation/ElderWand/ElderWandConfiguratorModel.cs` |
| `Views/Chat/ElderWand/ElderWandConfiguratorView.swift` | `ElderWand/ElderWandConfiguratorView.xaml` + grouping in `…Presentation/ElderWand/ElderWandModelGrouping.cs` |
| `Views/Chat/ElderWand/ElderWandAnalysisSection.swift` | `ElderWand/ElderWandAnalysisSection.xaml` (+ `ElderWandChipCloudViewModel`) |
| `Views/Chat/ElderWand/ElderWandJudgeSection.swift` | `ElderWand/ElderWandJudgeSection.xaml` (+ `ElderWandChipCloudViewModel`) |
| `Views/Chat/ElderWand/ElderWandPresetSection.swift` | `ElderWand/ElderWandPresetSection.xaml` (+ `ElderWandPresetListViewModel`) |
| `Views/Chat/ElderWand/ElderWandFlowLayout.swift` | `ElderWand/ElderWandFlowPanel.cs` (+ `ElderWandFlowLayoutMath`) |
| `Services/Settings/Stores/ElderWandSettings.swift` | `…Presentation/ElderWand/ElderWandSettingsModel.cs` |
| `OpenBurnBarCore/…/SharedModels/ElderWandPreset.swift` (FROZEN) | `…Presentation/ElderWand/ElderWandPreset.cs` |

## Portable / tested split

All non-UI logic lives in the dependency-free `OpenBurnBar.App.Presentation`
(`net8.0`) library under `ElderWand/`: the FROZEN preset contract, the edit-buffer
view-model, the preset store (with a `IElderWandPresetPersistence` seam and the
Fusion wire-payload lowering), the provider grouping pass, the flow-layout wrap
math, the reactive chip-cloud, and the preset-row projection. These run and are
unit-tested today on the macOS authoring host via `dotnet test`
(`windows/tests/presentation/ElderWand*Tests.cs`) — the same assemblies that ship
on Windows. The JSON wire keys match the Swift `Codable` output byte-for-byte, so a
preset store written on macOS round-trips through the Windows type.

The `.xaml` + code-behind here are the thin WinUI render (chip clouds, flow panel,
save bar, preset list, rename/delete `ContentDialog`s). Consumes the Pensieve
tokens, the Liquid-Glass surface, and `UnifiedGlassCard`.

## Reachability

On macOS this surface is gated behind `.gatedFeature(.elderWand)` and reached from
the Settings tree ("Analysis Models") or the chat header — **not** one of the 12
top-level nav destinations. It is hosted the same way here (a Settings-leaf / gated
entry the integration wave wires in), so it is intentionally **not** registered as a
`NavigationView` destination in `NavCatalog`.

## macOS verification ceiling

`net8.0-windows` XAML does not fully compile on macOS. Verified here: every XAML is
`xmllint` well-formed; every C# Roslyn-parses with 0 errors; `dotnet build` of the
app reaches the byte-identical Windows-only `XamlCompiler.exe` gate with no earlier
error; and the portable library has a real passing `dotnet test` suite. XAML
compile, render, and the WebView2/Win2D GPU paths are Windows-CI/dev-host-deferred.
