# Windows Accessibility Certification Harness

This evidence lane adds a machine-readable accessibility profile to the Windows
UI automation harness. It does not certify a parity release by itself; it makes
the remaining host and physical-device runs harder to fake or conflate with a
plain route smoke.

## Scenario Profile

Run on a real Windows desktop session:

```powershell
scripts/windows-port/run-ui-automation.ps1 -CertificationProfile accessibility
```

The profile emits:

- `certification-scenarios.json` with baseline, high-contrast,
  reduced-transparency, 100% DPI, and keyboard/input contract rows.
- `route-manifest.json` for the selected routes.
- Per-scenario route screenshots/results under `routes/<scenario>/<route>/`.
- Redacted `summary.json`, `junit.xml`, and `index.html`.

High-contrast and reduced-transparency route runs seed the app's real persisted
shell state through `--automation-appearance` and
`--automation-reduce-transparency` before `ThemeService` starts.

The 100% DPI scenario records `XamlRoot.RasterizationScale` from the rendered
window and fails if it does not match the declared scenario. The keyboard
scenario is manifest/input-contract evidence and does not relabel duplicate
route screenshots as keyboard-only interaction proof.

## Local Verification

- `dotnet test windows/tests/ui-automation/OpenBurnBar.UiAutomationHarness.Tests.csproj --configuration Debug`
- `dotnet test windows/tests/shell/OpenBurnBar.App.Shell.Tests.csproj --configuration Debug`
- `dotnet build windows/tests/ui-automation-harness/OpenBurnBar.UiAutomationHarness/OpenBurnBar.UiAutomationHarness.csproj --configuration Debug -p:EnableWindowsTargeting=true`

`pwsh` is not installed on the macOS authoring host, so PowerShell parse/execution
is owned by the Windows host run.

## Remaining Release Boundary

This harness is infrastructure for the audit checklist item covering UIA,
keyboard, high contrast, reduced motion, DPI, and screenshots. The release claim
still requires real Windows host artifacts plus physical-device Narrator,
150%/200% DPI, high-contrast OS theme, and keyboard-only protocol evidence.
