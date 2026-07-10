# Ledger row: computer-use-loop

**What this proves:** The Windows app owns a composed Computer Use runtime, and
the lower-privilege desktop path has passed exact-candidate Windows ARM64 host
certification.

1. `WindowsComputerUseRuntimeHost` owns `ComputerUseRuntimeSession` from app
   launch and injects its real readiness state into Settings.
2. `ComputerUseDesktopLoop.Dispatch` / `Click` refuse synthesis when the kill
   switch blocks dispatch.
3. The Windows adapter implements UIA inspection, Windows Graphics Capture,
   and the supported `SendInput` paths: focus/click, Unicode typing, shortcut,
   key, pointer move/click, drag/drop, and scroll.
4. Signed-driver-required actions fail closed unless the adapter reports a
   signed, non-bypassable input route. The current advisory adapter never makes
   that claim.
5. `ComputerUseAuditArchive` verifies a pinned audit head and exports a bounded
   archive without screenshots by default.

**Tests:** `windows/tests/computeruse` (119 tests at candidate certification),
`windows/tests/settings` (129 tests), and the interactive host harness under
`windows/tests/computeruse-host`.

**Host proof:**
[`../h2-host/computer-use/README.md`](../h2-host/computer-use/README.md) records
the exact candidate/import hashes, 15/15 interactive checks, content-addressed
host summary, and nonblank WGC frame.

**Operational residual:** a signed virtual HID route and physical x64/ARM64
certification remain release gates. Secure desktop and lock-screen injection are
not claimed. The app truthfully reports the current unsigned route as not ready
for signed-driver-required actions.
