# Windows Switcher shell production-composition evidence

WPD-0006 row: 30 (`Switcher shell`)

Disposition: **SUB-DONE** (guarded ConPTY profile shell)

## Production path

- `SwitcherSettingsView` loads the same encrypted `SwitcherProfileWriteSeam` used by its view model and exposes a launch command only for profiles with a supported CLI type.
- `SwitcherShellLaunchPlanner` maps each supported profile type to a fixed executable. It never accepts an executable path from profile data, rejects control characters and missing directories, limits argument count and length, and maps only the CLI-specific configuration variables.
- `WindowsCreateProcessCommandLine` implements the `CommandLineToArgvW` inverse quoting rules so empty arguments, spaces, quotes, and trailing backslashes retain their exact argv boundaries.
- `ChildProcessLaunchPolicy` applies the reviewed `Switcher` process profile. Only the explicit profile variables and a small ambient terminal/editor allowlist survive; secrets and unrelated parent-process state do not.
- `ConPtyCliStream` launches the plan without a command shell, streams the live pseudoconsole into `LiveCliStreamView`, propagates cancellation, and terminates the process tree during disposal.
- Planning and launch failures remain on the Switcher page as a keyboard-accessible error `InfoBar` and are written to redacted app diagnostics.

## Verification

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj
dotnet test windows/tests/configuration/OpenBurnBar.App.Configuration.Tests.csproj
dotnet test windows/tests/shell/OpenBurnBar.App.Shell.Tests.csproj
bash scripts/ci/check-no-suppressions.sh
bash scripts/debt/check-windows-tree-budget.sh
```

Focused planner and quoting tests cover every supported CLI mapping, unsupported profiles, missing working/config directories, control characters, argument bounds, exact Windows quoting, environment isolation, and the reviewed process inventory. Local affected suites passed 795 presentation, 191 Settings view-model, 56 configuration, and 49 shell tests. The shell suite passed 20 consecutive runs after process-wide environment tests were serialized.

Hosted PR run `29354295472` passed the native x64 WinUI XAML build, security checks, and Windows skeleton suite at commit `2e8331c25bbef2966e1f0dee1cb0035e1ad66f66`. Full-suite run `29354295622` passed x64; its ARM64 job completed the solution/WinUI build and the Switcher tests before an unrelated Elder Wand timing assertion failed. That timing assertion is tracked and fixed separately; it is not counted as an ARM64 full-suite pass for this commit.
