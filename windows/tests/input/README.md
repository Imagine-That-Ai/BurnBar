# `windows/tests/input/` — ViGEm virtual-HID input path tests (W5 / R17)

macOS-runnable `dotnet test` proof of the **portable** input path
([`../../pal/input/`](../../pal/input/)). `net10.0` + xUnit, mirroring
[`../ipc/`](../ipc/). No Windows APIs, no ViGEmBus, no `SendInput` — the native sinks live in
`OpenBurnBar.Pal.Input.Windows` and are proven on a Windows dev host / Windows CI.

| File | Proves |
|------|--------|
| `InputActionClassifierTests.cs` | every action kind → correct route + canonical macOS audit-kind; the non-bypassable set is exactly the input-committing actions |
| `CapabilityTokenCanonicalizerTests.cs` | canonical signable bytes are pinned (sorted keys, nil optionals omitted, ISO8601 fractional UTC, escaping) |
| `CapabilityTokenVerifierTests.cs` | every verdict with **real Ed25519** (BouncyCastle): valid, tampered body, tampered signature, wrong issuer, expired, domain/scope/attestation/escrow, budget, **single-use nonce replay** |
| `InputKillSwitchTests.cs` | the three panic paths engage independently; **fail-closed** on RC read error + stale/absent watchdog |
| `VirtualHidInputGateTests.cs` | the three lane contracts: non-bypassable requires a valid token; advisory logs; **token-absent → rejected**; kill switch (incl. a throwing source) rejects |
| `VirtualHidInputDispatcherTests.cs` | **R17 structural guarantee**: the ViGEm sink is unreachable without a valid token; audit-before-dispatch; fail-closed audit; routes never cross |

Run: `dotnet test windows/tests/input/OpenBurnBar.Pal.Input.Tests.csproj`
