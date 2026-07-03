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
