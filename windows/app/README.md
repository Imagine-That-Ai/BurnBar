# `windows/app/` — WinUI 3 shell (W6)

The **WinUI 3 (C#/.NET) application shell**: `Shell_NotifyIcon` tray + borderless top-most flyout,
main window, Mica/Acrylic glass, the design-token theme, the particle backdrop, and the Pretext
markdown host. This is the Windows equivalent of the macOS `AgentLens/` app target.

**Status:** the WinUI 3 shell **spike** landed under [`OpenBurnBar.App/`](OpenBurnBar.App/) and is
registered into [`../OpenBurnBar.sln`](../OpenBurnBar.sln) (**WINUI-016**). It is **authored, not yet
built** — a WinUI 3 app compiles only on Windows; the interactive build/run/record pass is
**WINUI-017**, driven by [`DEV_HOST_RUNBOOK.md`](DEV_HOST_RUNBOOK.md).

### `OpenBurnBar.App/` — the shell spike (0-b / W6)

Unpackaged WinUI 3 (C#/.NET 8, `net8.0-windows10.0.19041.0`). What it demonstrates:

| Piece | File(s) | macOS analog |
|------|---------|--------------|
| `Shell_NotifyIcon` tray + context menu | `Tray/TrayIcon.cs`, `Tray/TrayNativeMethods.cs` | `NSStatusItem` |
| Borderless, top-most **Mica** flyout | `FlyoutWindow.xaml(.cs)`, `Interop/WindowChrome.cs` | `NSPopover` |
| Main window | `MainWindow.xaml(.cs)` | main app window |
| **Live CLI stream wired to a STUB** | `Views/LiveCliStreamView.xaml(.cs)`, `ViewModels/*`, `Cli/ICliStream.cs`, `Cli/StubCliStream.cs` | `CLIProcessStreamRunner` |
| Seeded design tokens | `Theme/Tokens.xaml` | `Theme/DesignSystem.swift` |

The **only** stub is `StubCliStream` (a canned, timed transcript); WINUI-017 / W1–W2 replace it with a
ConPTY-backed source behind the same `ICliStream` seam. See the runbook for exact build/run/record steps.

Source files here (`.cs` / `.xaml`) are ratcheted by the per-tree budget under the `app` area.

### `OpenBurnBar.App.Settings/` + `OpenBurnBar.App/Settings/` — Settings shell + search (W7)

The **Settings** surface, split into a portable core and its WinUI face — the Windows peer of
`AgentLens/Views/Settings/` (`SettingsView` / `SettingsTab` + `Search/{SettingsManifest,SettingsRouter,`
`SettingsSearchEngine,SettingsItem,SettingsSearchResultsView}`).

| Piece | Where | macOS analog |
|------|-------|--------------|
| **Portable search core** — `net8.0`, no Windows deps: manifest (104 rows), weighted ranking engine, router path logic, route-display breadcrumbs, provider identity subset | `OpenBurnBar.App.Settings/` | `Search/*.swift` + `AgentProvider` |
| **Real unit tests** — 75 xUnit tests run on macOS via `dotnet test` | [`../tests/settings/`](../tests/settings/) | search/manifest/router coverage |
| **WinUI shell + leaf pages** — `NavigationView` sidebar + `AutoSuggestBox` search + `SettingsCard`/`SettingsExpander` forms (General, Appearance, Updates) with real jump-to-anchor scroll+pulse | `OpenBurnBar.App/Settings/` | `SettingsView` sidebar/detail |

The portable core (`OpenBurnBar.App.Settings`, referenced by the app and by the test project) **builds
and is unit-tested on the macOS authoring host today**. The WinUI XAML that binds it is
XamlCompiler-deferred (same gate as WINUI-016). The `NavigationView` app-shell that will host
`SettingsPage` as a nav destination is reconciled by the shell lane (#1203).
