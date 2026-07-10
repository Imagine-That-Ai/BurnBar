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

## Exact-Candidate Host Evidence

The Windows 11 ARM64 UTM run for candidate `d8fc5675568f` passed exact import
verification (`10,255 / 10,255` files, zero mismatches), the ARM64 WinUI build,
all `25 / 25` route/scenario captures, semantic UI Automation, and all nine
input-route contract rows. The three DPI scenarios measured 100% through
`XamlRoot.RasterizationScale` rather than trusting the scenario label.

The compact receipt is
[`host-run-d8fc567556.json`](host-run-d8fc567556.json). The full 200-file bundle
is retained outside git as
`openburnbar-accessibility-evidence-d8fc5675568f.zip`; its SHA-256 is
`ea53024c64534edc3fe6a731c2a9b501b0a5c04d80d74f755b15654fbe728275`.
An independent Gitleaks scan reported no leaks.

## Local Verification

- `dotnet test windows/tests/ui-automation/OpenBurnBar.UiAutomationHarness.Tests.csproj --configuration Debug`
- `dotnet test windows/tests/shell/OpenBurnBar.App.Shell.Tests.csproj --configuration Debug`
- `dotnet build windows/tests/ui-automation-harness/OpenBurnBar.UiAutomationHarness/OpenBurnBar.UiAutomationHarness.csproj --configuration Debug -p:EnableWindowsTargeting=true`

`pwsh` is not installed on the macOS authoring host, so PowerShell parse/execution
is owned by the Windows host run.

## Remaining Release Boundary

This host run closes the ARM64 VM baseline, app-seeded high-contrast and
reduced-transparency scenarios, measured 100% DPI, semantic UIA, screenshots,
and input-route contract evidence. The release claim still requires physical
x64/ARM64 devices, Narrator, 150%/200% DPI, Windows OS high-contrast theme, and
manual keyboard-only protocol evidence.
