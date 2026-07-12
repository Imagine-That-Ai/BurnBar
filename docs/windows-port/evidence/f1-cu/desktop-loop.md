# Ledger row: computer-use-loop

**What this proves:** Production desktop Computer Use dispatch loop exists in Core:
kill-switch leaf check → input synthesis via injected `IInputSynthesizer`.

1. `ComputerUseDesktopLoop.Dispatch` / `Click` refuse synthesis when
   `KillSwitchStateMachine.ShouldBlockDispatch()` is true.
2. Otherwise synthesizes `MacInputAction` through the adapter seam.
3. Windows production adapter: `SendInputInputSynthesizer` in
   `OpenBurnBar.ComputerUse.Windows` (UIA/WGC adapters also present).

**Tests:** `windows/tests/computeruse/DesktopLoopTests.cs` (kill-switch deny +
successful synthesize), plus existing gate/kill-switch/audit suites.

**Operational residual:** full session orchestration UI + live GPU capture on a
specific machine; Core loop is production-real and fail-closed.
