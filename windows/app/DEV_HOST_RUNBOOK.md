# WinUI 3 shell spike — dev-host runbook (WINUI-017)

**What this is.** Step-by-step instructions to **build, run, and screen-record** the OpenBurnBar
WinUI 3 shell spike (`windows/app/OpenBurnBar.App/`) on a **Windows dev host**. Executing this
runbook top-to-bottom **is** validation target **VAL-P0-WINUI-017** (the interactive end-to-end
run). The shell itself was authored on macOS under **VAL-P0-WINUI-016**, whose LIVE verdict is
explicitly **"authored; build unproven until WINUI-017"** — a WinUI 3 app **cannot** be built to
completion on macOS (the XAML compiler, `MakePri`, and the Windows App SDK MSBuild targets are
Windows-only). This document closes that gap on real hardware.

> **Honest status when you start:** never compiled or run. On macOS the C#/XAML is schema/XML-valid,
> MSBuild fully **evaluates** the project (resolving `UseWinUI=true`, `WindowsPackageType=None`, TFM
> `net8.0-windows10.0.19041.0` through the Windows App SDK import graph) with
> `EnableWindowsTargeting=true`, and `dotnet restore` is **unblocked past project evaluation** — NuGet
> resolves the exact pinned `Microsoft.WindowsAppSDK 1.7.250606001` graph from nuget.org. Without the
> `EnableWindowsTargeting` override the build correctly fails `NETSDK1100` — that gate, not a project
> defect, is why the first real **compile** (XAML compiler + `MakePri`) happens here on Windows.
> Full evidence + exact commands: `docs/windows-port/evidence/winui-016/schema-restore-evidence.md`.

---

## 1. Prerequisites (one-time, on the Windows host)

| Requirement | Notes |
|---|---|
| **Windows 11** (22H2 or newer) | Mica needs Win11; on Win10 the shell falls back to a solid backdrop (still runnable — call that out in the recording). |
| **.NET SDK 10.0+** | `winget install Microsoft.DotNet.SDK.10`. The app target is `net8.0-windows10.0.19041.0`, but shared Windows libraries multi-target `net10.0`, so the repo build/test graph needs a .NET 10 SDK. |
| **Windows App SDK / WinUI workload** | Visual Studio 2022 17.11+ with the **"Windows App SDK C# Templates"** component, **or** SDK-only: the `Microsoft.WindowsAppSDK` NuGet (restored automatically) + the **Windows App Runtime** installed so an *unpackaged* app can launch. `winget install Microsoft.WindowsAppRuntime.1.8` (match the package version in `OpenBurnBar.App.csproj`). |
| **Windows 10 SDK 10.0.19041+** | Ships with the VS "Desktop development with C++"/"WinUI" workloads; the `Microsoft.Windows.SDK.BuildTools` NuGet (pulled transitively) covers the build. |
| **Git** | To clone the branch under test. |

Confirm the toolchain:

```powershell
dotnet --info                     # SDK 10.0+ listed
winget list "Windows App Runtime" # runtime present for unpackaged launch
```

---

## 2. Get the code

```powershell
git clone https://github.com/<org>/BurnBar.git
cd BurnBar
git checkout <the WINUI-016 branch or the merged main>
cd windows
```

---

## 3. Restore + build

The app is **unpackaged** (`WindowsPackageType=None`), so a plain `dotnet build` produces a runnable
`.exe` — no MSIX packaging step required. Pick the architecture that matches the host (`x64` on Intel/AMD,
`ARM64` on Snapdragon/Surface Pro X).

```powershell
# From windows\  — restore the whole solution (or just the app project).
dotnet restore OpenBurnBar.sln

# Build the shell, Debug, x64.
dotnet build app\OpenBurnBar.App\OpenBurnBar.App.csproj -c Debug -p:Platform=x64

# ARM64 host instead:
# dotnet build app\OpenBurnBar.App\OpenBurnBar.App.csproj -c Debug -p:Platform=ARM64
```

Expected: `Build succeeded. 0 Error(s)`. The output binary lands at:

```
app\OpenBurnBar.App\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\OpenBurnBar.App.exe
```

> If `dotnet build` reports a missing WinUI/Windows App SDK component, install/repair the
> **Windows App Runtime 1.8** and open the solution once in **Visual Studio 2022** so it can install the recommended WinUI components, then re-run the CLI build.

---

## 4. Run

```powershell
# Simplest: run through the SDK (uses the launch profile in Properties\launchSettings.json).
dotnet run --project app\OpenBurnBar.App\OpenBurnBar.App.csproj -c Debug -p:Platform=x64

# Or launch the built exe directly:
.\app\OpenBurnBar.App\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\OpenBurnBar.App.exe
```

The app launches **into the tray** (no window on start — menu-bar-first parity with the macOS app). Production mode is honest-empty when SQLCipher/Firebase/Hermes credentials are absent. Demo/sample data is opt-in only: set `OPENBURNBAR_SAMPLE_MODE=1` before launch when you need a labeled demo.

---

## 5. Acceptance checklist (what the recording must show)

Tick each — these are the WINUI-016 behaviors the spike claims, proven live:

1. **Tray icon (`Shell_NotifyIcon`).** An OpenBurnBar icon appears in the notification area on launch.
2. **Primary click → Mica flyout.** Left-clicking the tray icon opens a **borderless, top-most flyout**
   at the bottom-right (above the tray). Confirm the **Mica** backdrop (translucent, desktop tint shows
   through) on Win11. Left-click again (or click away) dismisses it — transient popover behavior.
3. **Live CLI stream.** With a configured CLI command/source, the flyout appends lines **in real time**
   from the backend. Without a backend, the chat/session surfaces show explicit "connect data source"
   empty states instead of scripted fake turns. For a labeled demo, launch with `OPENBURNBAR_SAMPLE_MODE=1`.
4. **Start / Stop.** The Stop button halts the stream; Start resumes it.
5. **Context menu.** Right-click the tray icon → **Open OpenBurnBar** and **Quit**.
6. **Main window.** "Open full window" (flyout) or "Open OpenBurnBar" (tray menu) opens the **main
   window**, Mica-backed, with a custom draggable header and the same stream at full size.
7. **Quit.** Tray → Quit removes the tray icon cleanly and exits the process (verify no orphaned icon;
   hover the tray to force a repaint if needed).

---

## 6. Windows UI automation harness

After a successful build, run the full UI automation harness before doing the manual recording:

```powershell
..\scripts\windows-port\run-ui-automation.ps1 `
  -Configuration Debug `
  -Platform ARM64
```

By default the script builds the app + harness, then runs the harness through a one-shot interactive
Scheduled Task. That matters when you are connected over SSH: the WinUI process must launch in the
logged-in desktop session, not in the non-interactive SSH window station. Use `-Direct` only from an
already-interactive PowerShell prompt.

The harness writes artifacts under `.artifacts\windows-ui-automation\<timestamp>\`:

| Artifact | Purpose |
|---|---|
| `summary.json` | Redacted machine-readable verdict for the whole run. |
| `junit.xml` | CI/check-run friendly failures for each route and semantic probe. |
| `index.html` | Human evidence index with links to screenshots. |
| `route-manifest.json` | Route keys, expected root `AutomationId`s, and source XAML paths. |
| `routes\<route>\*.png` + `*-result.json` | Per-route in-app render capture and pixel stats. |
| `semantic\main-window.png` | External window bitmap capture from the persistent main-window launch. |
| `launches\*\automation-launch.json` | Proof that the app redirected state/log/config into a throwaway automation profile. |

The harness fails if a route crashes, times out, renders near-uniform/blank, the persistent main
window cannot be inspected, or UIA classifies the foreground window as a password/secure-desktop/
credential-prompt deny region. It also records the PAL input route contract: click/type/key/shortcut/
drag actions must stay on the non-bypassable ViGEm/driver path, while pointer move/scroll/inspect
remain advisory.

The older `run-route-smoke.ps1` remains useful for a narrow screenshot-only pass, but it is no longer
the release-grade Windows UI evidence path.

Set these only when the dev VM lacks optional render runtimes:

```powershell
$env:OPENBURNBAR_DISABLE_WIN2D = "1"
$env:OPENBURNBAR_DISABLE_WEBVIEW2 = "1"
```

Those switches keep the page route alive with a degraded visible state; they are not a substitute for the final visual pass on a Win2D/WebView2-capable host.

---

## 7. Screen-record the run

Record one continuous take covering the checklist above after the UI automation harness passes.

- **Xbox Game Bar (built in):** `Win + Alt + R` to start/stop; clips land in
  `%USERPROFILE%\Videos\Captures\`. (Game Bar records the focused window; for the tray + flyout
  interaction, prefer OBS full-screen capture below.)
- **OBS Studio (preferred for tray + flyout):** add a **Display Capture** source so the notification
  area, flyout, and main window are all in frame; record to MP4.
- **ffmpeg (headless/CI dev host):**
  ```powershell
  ffmpeg -f gdigrab -framerate 30 -i desktop -t 40 winui-017-shell.mp4
  ```

Save the recording + a still frame of the flyout as evidence:

```
docs\windows-port\evidence\winui-017\shell-run.mp4
docs\windows-port\evidence\winui-017\flyout-mica.png
```

Then record the go/no-go for WINUI-017 (pass = every checklist item observed).

---

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `error NETSDK1100 … EnableWindowsTargeting` | You're building on macOS/Linux. This app only **compiles** on Windows — that's the WINUI-016 → -017 boundary. |
| App exits immediately / `The app didn't start` (0x8007007E) | Install/repair the **Windows App Runtime** matching `Microsoft.WindowsAppSDK` in the csproj (`winget install Microsoft.WindowsAppRuntime.1.8`). |
| Flyout has a solid (not translucent) background | Expected on **Windows 10** — `MicaController.IsSupported()` is false there and the shell falls back to solid. Note it in the recording; re-shoot on Win11 for the Mica frame. |
| Tray icon missing after a crash | Windows caches dead tray icons; hover the notification area or restart Explorer. On a clean Quit the icon is removed via `NIM_DELETE`. |
| `dotnet build` can't find WinUI targets | Open the `.sln` in VS 2022 once to install components, or install the **"Windows App SDK C# Templates"** individual component. |
| `NETSDK1045` for `net10.0` projects | Install the .NET 10 SDK. A .NET 8-only host can target the app TFM but cannot build the shared multi-targeted Windows libraries. |
| Harness route PNG is blank/near-uniform | Open the failing route's `launches\<route>\automation-launch.json`, then inspect that profile's `logs\winui-crash.log` and `route-breadcrumbs.log`; the app records the active route and native renderer exceptions there. |

---

## 9. Contract cross-reference

- **VAL-P0-WINUI-016** — *this project + this runbook authored* (macOS). LIVE verdict: **"authored; build
  unproven until WINUI-017"**. ✅ delivered.
- **VAL-P0-WINUI-017** — *executing this runbook on a Windows host* (build succeeds + the §5 checklist
  passes on a real machine, recorded per §6). ⏳ pending a dev host.
- Related: **CI-003** wires the `windows-latest` harness/`pr-windows-fast.yml` lanes to `dotnet build`
  this project once it lands (the skeleton drop-in points the WINUI-016 scaffold left).
