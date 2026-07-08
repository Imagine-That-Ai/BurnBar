# OpenBurnBar.App.Settings.ViewModels

Portable (net8.0) view-models for the Windows Settings tabs that previously fell
through to `SettingsPlaceholderPage`. Same assembly the WinUI shell links; unit-tested
on the macOS authoring host (`windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests`).

The macOS app has 16 settings tabs. On Windows, **General / Updates / Data & Privacy
(+ Appearance)** already resolved to real leaf pages. This library adds portable
view-models for the placeholder tabs whose feature cores exist on `main`.

## Tabs → view-model → macOS oracle → backing core

| Tab | View-model | macOS oracle | Backing core | Gating |
|---|---|---|---|---|
| Engine Room (Daemon) | `Daemon/DaemonSettingsViewModel` | `DaemonSettingsView.swift` + WPD-0006 | WPD-0006 matrix (34 rows) | Live |
| Agents | `Agents/AgentsSettingsViewModel` | `AgentsSettingsView.swift` | `AgentProvider`, ManagedAgentRuntime (#1301), CursorConnector (#1303) | Live |
| Model Proxy | `ModelProxySettingsViewModel` | `ModelProxySettingsView.swift` | GatewaySettings model | Live |
| Alerts | `AlertsSettingsViewModel` | `AlertsAndNotificationsViews.swift` | AlertSettings model | Live |
| Notifications | `NotificationsSettingsViewModel` | `AlertsAndNotificationsViews.swift` | ControllerSettings model | Live |
| Text Expansion | `TextExpansionSettingsViewModel` | `TextExpansionSettingsView.swift` | `OpenBurnBar.App.TextExpansion` (#1302) | Live |
| Computer Use | `ComputerUseSettingsViewModel` | `ComputerUseSettingsView.swift` | `OpenBurnBar.ComputerUse.Core` | Live |
| Pets | `PetsSettingsViewModel` | `SettingsView.swift` (`PetCompanionSettingsView`) | `OpenBurnBar.App.Pet` (via `IPetCompanionHost`) | Live |
| Account | `AccountSettingsViewModel` | `AccountSettingsView.swift` | OAuth credential gate (#1304) | Data-gated |
| Cloud | `CloudSettingsViewModel` | `CloudStoreSettingsView.swift` | CloudSyncSettings + OAuth gate | Data-gated |
| Devices & Sync | `DevicesAndSyncSettingsViewModel` | `DevicesAndSyncSettingsView.swift` | Device-trust host + OAuth gate | Data-gated |

`Media` stays a placeholder (its Mercury core is deferred).

## Conventions

- Hand-rolled `INotifyPropertyChanged` via `ObservableSettingsViewModel` (`Set<T>` +
  `OnPropertyChanged`), matching the Windows-port VM idiom.
- Everything OS/data-bound is behind an injectable seam (an interface here). Tests wire
  in-memory fakes; the WinUI shell wires the real Windows core.
- Injectable clock is `Func<DateTimeOffset>? now` (Presentation-layer precedent).
- `SettingsTabViewModelCatalog` is the portable source of truth for "which tab resolves
  to a real view-model" — the seam the WinUI `SettingsPage` consults instead of the
  placeholder fallthrough.

The WinUI XAML leaf pages that `x:Bind` these view-models are bucket-B / dev-host-
deferred at the XamlCompiler gate.
