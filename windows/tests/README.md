# `windows/tests/` — test projects (W11)

**Unit, integration, and parity test projects** for the WinUI shell, the PAL, and the native shim.
This is where the portable parser fixtures, the parser-output contract, the prompt-injection-wrap
contract, the KAT triplets ported to Windows, and the DB-compat vectors get their Windows-side
executors — the verification harness that proves Tier-A byte parity with macOS.

**Status:** skeleton placeholder. Test projects land here and register into
[`../OpenBurnBar.sln`](../OpenBurnBar.sln); the `windows` CI lanes run them.

Source files here are ratcheted by the per-tree budget under the `tests` area.
