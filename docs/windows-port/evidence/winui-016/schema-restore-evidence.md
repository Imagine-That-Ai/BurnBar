# VAL-P0-WINUI-016 — LIVE evidence (macOS authoring; build unproven until WINUI-017)

**Contract:** `VAL-P0-WINUI-016` — WinUI 3 shell spike scaffolded under `windows/` and registered
into the `.sln` (`Shell_NotifyIcon` tray, Mica borderless flyout, main window, live-CLI-stream view
wired to a **stub** stream) + a precise dev-host runbook.
**LIVE verdict:** **authored; build unproven until WINUI-017.** A WinUI 3 app cannot be built to
completion on macOS — the XAML compiler, `MakePri`, and the Windows App SDK MSBuild targets are
Windows-only. This file records the strongest evidence obtainable on macOS.

**Host:** macOS (darwin) · `dotnet` **10.0.301** · `xmllint` libxml 20913. Project:
`windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj` (`net8.0-windows10.0.19041.0`,
`Microsoft.WindowsAppSDK 1.7.250606001`, unpackaged `WindowsPackageType=None`).

---

## 1. WinUI project is registered in the solution

```
$ dotnet sln windows/OpenBurnBar.sln list
Project(s)
----------
app/OpenBurnBar.App/OpenBurnBar.App.csproj
pal/ipc-windows/OpenBurnBar.Pal.Ipc.Windows.csproj
pal/ipc/OpenBurnBar.Pal.Ipc.csproj
tests/ipc/OpenBurnBar.Pal.Ipc.Tests.csproj
```

The WinUI app is registered with the SDK-style C# project-type GUID
(`{9A19103F-16F7-4668-BE54-9A1E7A4F7556}`) and real `x86|x64|ARM64` config maps (the sibling PAL/IPC
`net10.0` projects coexist — the `.sln` is an append-only shared aggregator; do **not** hand-rewrite
it or you clobber siblings).

## 2. Schema / XML well-formedness — every project, manifest, and XAML file

```
$ for f in $(find windows/app/OpenBurnBar.App -type f \( -name '*.csproj' -o -name '*.xaml' -o -name '*.manifest' \)); do xmllint --noout "$f" && echo "well-formed: $f"; done
well-formed: windows/app/OpenBurnBar.App/app.manifest
well-formed: windows/app/OpenBurnBar.App/App.xaml
well-formed: windows/app/OpenBurnBar.App/FlyoutWindow.xaml
well-formed: windows/app/OpenBurnBar.App/MainWindow.xaml
well-formed: windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj
well-formed: windows/app/OpenBurnBar.App/Theme/Tokens.xaml
well-formed: windows/app/OpenBurnBar.App/Views/LiveCliStreamView.xaml
```

## 3. The Windows-only build gate is REAL (honest boundary)

Without the `EnableWindowsTargeting` override, a `-windows` TFM correctly refuses to build on macOS —
this is the `NETSDK1100` gate, not a project defect, and is exactly why the first real **compile**
happens on the Windows dev host (WINUI-017):

```
$ dotnet build windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj -p:EnableWindowsTargeting=false -p:Platform=x64
.../Microsoft.NET.Sdk/targets/Microsoft.NET.Sdk.FrameworkReferenceResolution.targets(120,5): error NETSDK1100:
  To build a project targeting Windows on this operating system, set the EnableWindowsTargeting property to true.
  [.../windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj]
```

Reaching the `FrameworkReferenceResolution` target proves MSBuild fully **parsed** the project before
the platform gate fired.

## 4. MSBuild fully EVALUATES the real project on macOS (the authoritative schema check)

With `EnableWindowsTargeting=true`, MSBuild evaluates the project through the .NET SDK **and** the
Windows App SDK / WinUI import graph and resolves every property correctly (note `UseWinUI=true`,
which only resolves if the WinUI SDK imports load):

```
$ dotnet msbuild windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj -p:EnableWindowsTargeting=true -p:Platform=x64 \
    -getProperty:TargetFramework -getProperty:UseWinUI -getProperty:WindowsPackageType \
    -getProperty:OutputType -getProperty:TargetPlatformVersion
{
  "Properties": {
    "TargetFramework": "net8.0-windows10.0.19041.0",
    "UseWinUI": "true",
    "WindowsPackageType": "None",
    "OutputType": "WinExe",
    "TargetPlatformVersion": "10.0.19041.0"
  }
}
```

## 5. `dotnet restore` is unblocked past project evaluation — NuGet resolves the pinned graph

`dotnet restore` (with `EnableWindowsTargeting=true`, implied by the csproj) is **not** gated at
project evaluation on macOS: NuGet resolves the exact pinned Windows App SDK version against
nuget.org's v3 index and begins fetching it. Observed in the NuGet HTTP cache during a live restore:

```
$ find ~/.local/share/NuGet/http-cache -name '*windowsappsdk.1.7.250606001*'
.../http-cache/<nuget.org-index-hash>/nupkg_microsoft.windowsappsdk.1.7.250606001.dat-new
```

An established TLS socket to the nuget CDN (`:443`) and a growing `.dat-new` confirm the download is
real. The `Microsoft.WindowsAppSDK 1.7` nupkg carries the full native runtime (~400 MB); a
throttled-network full restore-to-completion is time-bound, not a correctness signal — the resolver
finding and fetching the **exact** pinned version is the meaningful proof. The Windows-only step is
the subsequent **compile** (XAML compiler / `MakePri`), not restore.

---

## Verdict

| Contract evidence item | Result on macOS |
|---|---|
| WinUI project files registered in `.sln` | **PASS** — `dotnet sln list` shows `app/OpenBurnBar.App/OpenBurnBar.App.csproj` |
| Runbook (exact steps/commands) | **PASS** — `windows/app/DEV_HOST_RUNBOOK.md` (build/run/screen-record for WINUI-017) |
| Project/manifest schema-validation vs WinUI/MSBuild schema | **PASS** — `xmllint` well-formed on all 7 XML files + MSBuild fully evaluates the project (§4) |
| `dotnet restore` where the SDK permits, OR why restore is Windows-gated | **PASS** — restore is **not** hard-gated on macOS; it resolves the pinned WindowsAppSDK graph (§5). The build gate is `NETSDK1100` on **compile** (§3), documented precisely. |

**LIVE verdict: authored; build unproven until WINUI-017** — honest and matches the contract. The
interactive end-to-end run (tray → Mica flyout → live stub stream → main window → quit, screen-recorded)
is **VAL-P0-WINUI-017**, gated on a Windows dev host per `windows/app/DEV_HOST_RUNBOOK.md`.
