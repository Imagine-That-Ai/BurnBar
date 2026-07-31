# `windows/app/` — WinUI 3 shell (W6)

The **WinUI 3 (C#/.NET) application shell**: `Shell_NotifyIcon` tray + borderless top-most flyout,
main window, Mica/Acrylic glass, the design-token theme, the particle backdrop, and the Pretext
markdown host. This is the Windows equivalent of the macOS `AgentLens/` app target.

**Status:** the WinUI 3 shell **spike** landed under [`OpenBurnBar.App/`](OpenBurnBar.App/) and is
registered into [`../OpenBurnBar.sln`](../OpenBurnBar.sln) (**WINUI-016**). It is **authored, not yet
built** — a WinUI 3 app compiles only on Windows; the interactive build/run/record pass is
**WINUI-017**, driven by [`DEV_HOST_RUNBOOK.md`](DEV_HOST_RUNBOOK.md).

### `OpenBurnBar.App/SharedUi/` + `OpenBurnBar.App.SharedUi/` — the Linux-parity shell

The app's **primary window** is the `SharedUiHostWindow`: a WebView2 hosting the exact React
bundle the Linux desktop renders (`apps/linux-desktop` → `dist-windows`), bridged to the
portable `OpenBurnBar.App.SharedUi` dispatcher that serves the full `LinuxShellBridge` command
surface from the in-process Windows stores. Full contract: [`../../docs/windows-port/SHARED_UI_HOST.md`](../../docs/windows-port/SHARED_UI_HOST.md).
Rebuild the bundle with `node_modules/.bin/vite build --mode windows` in `apps/linux-desktop`;
run the contract suite with `dotnet test ../tests/shared-ui`.

### `OpenBurnBar.App/` — the shell spike (0-b / W6)

Unpackaged WinUI 3 (C#/.NET 8, `net8.0-windows10.0.19041.0`). What it demonstrates:

| Piece | File(s) | macOS analog |
|------|---------|--------------|
| `Shell_NotifyIcon` tray + context menu | `Tray/TrayIcon.cs`, `Tray/TrayNativeMethods.cs` | `NSStatusItem` |
| Borderless, top-most **Mica** flyout | `FlyoutWindow.xaml(.cs)`, `Interop/WindowChrome.cs` | `NSPopover` |
| Main window | `MainWindow.xaml(.cs)` | main app window |
| **Live CLI stream wired to a STUB** | `Views/LiveCliStreamView.xaml(.cs)`, `ViewModels/*`, `Cli/ICliStream.cs`, `Cli/StubCliStream.cs` | `CLIProcessStreamRunner` |
| Seeded design tokens | `Theme/Tokens.xaml` | `Theme/DesignSystem.swift` |
| **First-run onboarding wizard** (Frame-navigated, 7 steps) | `Onboarding/*` + `Onboarding/Steps/*` | `AgentLens/Views/Onboarding/*` |

The **only** stub is `StubCliStream` (a canned, timed transcript); WINUI-017 / W1–W2 replace it with a
ConPTY-backed source behind the same `ICliStream` seam. See the runbook for exact build/run/record steps.

Source files here (`.cs` / `.xaml`) are ratcheted by the per-tree budget under the `app` area.

### Theme system (Aurora / liquid glass — see `docs/windows-port/MAC_GLASS_PARITY_PASS.md`)

The shell renders the **macOS Aurora design language** (the design oracle), not a Fluent recolor:

| Layer | File(s) | What it carries |
|------|---------|-----------------|
| Token pipeline output (generated — **do not edit**; regenerate via `packages/design-tokens`) | `Theme/Tokens.xaml`, `Theme/PensieveTokens.cs` | Pensieve + Aurora color/glass/type tokens as `Color`/`Brush`/`x:Double`/… |
| Aurora shell overrides, theme-aware (`ThemeDictionaries`: Default=dark slate, Light=coral dust) | `Theme/PensieveShell.xaml` | Fluent system brushes, NavigationView chrome, `Aurora*` alias brushes |
| Liquid-glass vocabulary + transparency math | `Theme/LiquidGlass.xaml`, `Theme/LiquidGlass.cs` | card/toolbar/pill/interactive glass styles; Mica/Acrylic/solid plate resolution |
| Brand fonts + macOS type scale | `Theme/Typography.xaml`, `Assets/Fonts/*.ttf` (OFL) | Outfit/Geist/JetBrains Mono/Fraunces + named TextBlock styles |
| Glass component library | `Theme/GlassControls.xaml` | cards, prominent/regular/cool buttons, inputs, alerts, dialogs, implicit `SettingsCard`/`SettingsExpander` |
| Code-behind font chokepoint | `Theme/BrandFonts.cs` | `BrandFonts.Mono/Body/Display` with safe fallbacks |

**Rule:** surfaces consume tokens/styles — no raw hex colors or hardcoded `FontFamily`
outside `Theme/`. Enforced by `scripts/windows-port/check-xaml-token-discipline.sh`
(documented exceptions: `scripts/windows-port/xaml-token-allowlist.txt`), which runs in
`pr-windows-fast.yml`.


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

### `Onboarding/` — first-run wizard (W7 · Bucket A)

Windows port of `AgentLens/Views/Onboarding/*`. An `OnboardingWindow` (the macOS 520×620 first-run
window) hosts `OnboardingPage`, a Frame-navigated step wizard: a gradient progress bar, the seven step
Pages (`Steps/`) with slide transitions, and a Back / Skip / Continue footer. `FlowLayout.swift` becomes
`FlowLayoutPanel` (a wrap `Panel`); the provider pill, the Hermes setup `ContentDialog`, and the analytics
consent `ContentDialog` round out the surface. Everything consumes the shared design tokens
(`Theme/Tokens.xaml`, `PensieveTokens`, `ProviderBrand`) and the LiquidGlass chokepoint.

The parity-critical logic is a **portable, unit-tested** core (System-only, NO WinUI): the wizard step
machine, the chat-backend model, the wrapping-flow math, and the Hermes reachability derivation. It is
asserted off-Windows by `windows/tests/onboarding/OpenBurnBar.App.Onboarding.Tests` (net10.0, xUnit) —
`dotnet test` runs today on the macOS host. The XAML views are Windows-only and are type-checked at the
XamlCompiler gate (WINUI-017 / dev-host).
