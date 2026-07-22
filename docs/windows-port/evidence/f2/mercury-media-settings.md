# Windows Mercury media settings evidence

**Date:** 2026-07-13  
**Lane:** F2 Mercury/media capability plane

Ledger row: computer-use-loop

## What this proves

The Settings > Media & Sharing route is now a real data-gated capability
projection rather than a placeholder. `MercuryMediaSettingsViewModel` uses the
same `MediaCapabilityEvaluator` as the session state machine and reports
entitlement, budget, quota, kill-switch, concurrent-session, requested-duration,
and Windows capture-runtime state. It re-evaluates on feature or duration
changes and never turns a missing entitlement, hard-cap budget, kill switch, or
unsupported capture host into an allowed session.

The production Windows settings composition wires the model with the host
capture signal. Cloud entitlement and live quota remain read-only account
inputs; they are not synthesized by the client.

## Validation

```text
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj --no-restore
dotnet test windows/tests/mercury/OpenBurnBar.Integrations.Mercury.Tests.csproj --no-restore
```

Results: **136 settings tests passed** and **152 Mercury tests passed**. Focused
coverage proves default entitlement denial, normal entitled admission,
per-session duration caps, and kill-switch precedence.

The app's managed projects compile with `-p:Platform=x64`; the macOS authoring
host cannot execute WinUI's Windows-only XAML compiler. Actual capture,
encoding, WNS, and cross-device transport remain Windows host/staging gates.

## Boundary

This closes the settings and admission-projection seam. It does not claim live
camera/audio/screen capture, signed-driver Computer Use, cross-device media
transport, or physical safety certification.
