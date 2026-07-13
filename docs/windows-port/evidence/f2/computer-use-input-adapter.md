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
Secure-desktop, cross-integrity, lock-screen, and other non-bypassable actions
still require the signed virtual-HID path; this change does not claim that
`SendInput` can satisfy that safety boundary.

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

This closes the source-level keyboard/shortcut/drag/scroll adapter gap. It does
not close signed-driver installation, UIA target denial, panic-kill timing,
physical display/accessibility testing, or release certification.
