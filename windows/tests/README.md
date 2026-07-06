# `windows/tests/` — test projects (W11)

**Unit, integration, and parity test projects** for the WinUI shell, the PAL, and the native shim.
This is where the portable parser fixtures, the parser-output contract, the prompt-injection-wrap
contract, the KAT triplets ported to Windows, and the DB-compat vectors get their Windows-side
executors — the verification harness that proves Tier-A byte parity with macOS.

**Status:** test projects land here and register into
[`../OpenBurnBar.sln`](../OpenBurnBar.sln); the `windows` CI lanes run them.
Includes [`native/`](native/) (`OpenBurnBar.Native.Tests`) — the native-shim proof: hardened-locator +
NotSupported-surface + binding-shape tests run on any host, and `[NativeFact]` loopback tests drive
real FFI round-trips against cargo-built cdylibs when present (skip cleanly when absent). See
[`../native/README.md`](../native/README.md).

Source files here are ratcheted by the per-tree budget under the `tests` area.
