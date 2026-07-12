# Ledger row: settings-s1-s2-tabs

**What this proves:** Settings tab navigation routes Daemon, Agents, ModelProxy,
Alerts, Notifications, TextExpansion, ComputerUse, Pets, Account, Cloud,
DevicesAndSync, and Media to SettingsViewModelHostPage, which constructs portable
view-models via SettingsViewModelFactory. General, Updates, and DataPrivacy keep
dedicated pages. Appearance remains a real route-level page. There is no empty-leaf
fallthrough for catalog ViewModel tabs.

**Tests:** windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests
(Daemon, Account, Cloud, ComputerUse, TextExpansion, and related suites).

**Residual:** deep Mercury media XAML remains a host summary surface; still a real
settings destination, not an empty fallthrough.
