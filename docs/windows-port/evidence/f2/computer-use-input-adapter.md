# Windows Computer Use input-adapter evidence

**Date:** 2026-07-13  
**Lane:** F2 Computer Use input synthesis

Ledger row: computer-use-loop

## What this proves

The Windows `SendInputInputSynthesizer` now implements bounded keyboard and
shortcut dispatch, modifier press/release sequencing, drag/drop sequencing, and
horizontal plus vertical scroll. Virtual-key names are allowlisted; unknown
keys/modifiers, incomplete drags, zero scroll, empty text, and text over 64 KiB
fail closed before any native call. Absolute pointer coordinates account for
the Windows virtual-desktop origin and clamp to the valid `SendInput` range,
including multi-monitor layouts.

The adapter remains explicitly advisory (`RoutesThroughSignedDriver == false`).
Production interactive-desktop use is confined to the separately signed,
authenticated privileged-input broker. Secure-desktop, cross-integrity, and
lock-screen injection are explicit non-goals; supporting them would require a
purpose-built signed keyboard/mouse HID driver and separate certification.
ViGEm is not that path because it emulates game controllers, not desktop
keyboard or mouse devices.

## Validation

```text
dotnet build windows/computeruse/OpenBurnBar.ComputerUse.Windows/OpenBurnBar.ComputerUse.Windows.csproj --no-restore -p:EnableWindowsTargeting=true
dotnet test windows/tests/computeruse-windows/OpenBurnBar.ComputerUse.Windows.Tests.csproj --no-restore -p:EnableWindowsTargeting=true
```

Results: **adapter build passed** and **7 Windows-adapter tests passed**. The
tests cover the advisory route declaration and every pre-native fail-closed
branch. The actual `SendInput` delivery sequence still requires a physical
Windows host and remains part of the external Computer Use safety gate.

## Boundary

This closes the source-level keyboard/shortcut/drag/scroll adapter gap. The
production broker closes UIA target denial and watchdog composition at source
level; panic latency, real input delivery, physical display/accessibility, and
release certification remain Windows-host evidence gates.
