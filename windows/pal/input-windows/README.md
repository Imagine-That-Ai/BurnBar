# `windows/pal/input-windows/` — ViGEm + SendInput adapter (W5 / R17)

The **Windows-native** half of the ViGEm virtual-HID input path: the two
`IVirtualHidInputSink` implementations the portable `VirtualHidInputDispatcher`
([`../input/`](../input/)) routes into, plus the factory that assembles them with the gate.

| File | Route | Backend |
|------|-------|---------|
| `ViGEmVirtualHidInputSink.cs` | **NonBypassable** | ViGEmBus virtual HID (`ViGEmClient.dll`) — a kernel virtual-HID device a user-mode `SendInput` hook cannot forge |
| `SendInputAdvisoryInputSink.cs` | **Advisory** | Win32 `SendInput` (user32) — pointer move / scroll only |
| `ViGEmInputRouting.cs` | — | assembles the portable gate + both sinks into a ready `VirtualHidInputDispatcher` |
| `Interop/ViGEmClientNative.cs`, `Interop/SendInputNative.cs` | — | declarations-only P/Invoke, pinned to the OS **safe-directories** search path (DLL-planting mitigation, R19) |

## Target framework + macOS ceiling

`net8.0-windows10.0.19041.0` — a genuine Windows-native TFM. This code **RUNS only on Windows**
(ViGEmBus + `SendInput`). `EnableWindowsTargeting` lets the macOS authoring host **restore +
Roslyn-compile** it (no WinRT/XAML here, so the compile is *complete* on macOS: 0 C# errors),
while real execution stays on a Windows dev host / Windows CI.

- **macOS, default build** → full Roslyn compile, `0 Warning(s) 0 Error(s)`.
- **macOS, `-p:EnableWindowsTargeting=false`** → the byte-identical **Windows-only gate**
  (`NETSDK1100`) with **0 earlier errors** — the honest "this only truly builds on Windows"
  boundary.
- **Windows CI / dev host** → real compile + run against ViGEmBus.

## v1 vs v1.1 (honest scope)

- **v1 (this adapter):** ViGEmBus provides the **non-bypassable virtual-HID bus** and a virtual
  target — a real kernel HID device. The capability-token + audit + triple-kill-switch gates are
  **fully enforced** in the portable core before any report reaches it.
- **v1.1 (deferred):** full mouse/keyboard cursor+keystroke fidelity **and secure-desktop /
  lock-screen input injection** require a **WHQL-signed virtual mouse/keyboard driver** (master
  plan **§15.1, R6**). It drops in behind the same `IVirtualHidInputSink` seam **without changing
  the gate or the dispatcher**. Until then, the ViGEm target report is a documented pressed-state
  translation; secure-desktop injection is out of scope for v1.

Source files here are ratcheted by the per-tree budget under the `pal` area.
