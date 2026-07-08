# `windows/tests/ipc/` — portable handshake unit tests (W11 / VAL-P0-CONPTY-018)

REAL macOS unit tests for the **portable** signed-nonce handshake state machine
([`../../pal/ipc/`](../../pal/ipc/)). Runs today on the macOS authoring host via
`dotnet test` with a genuine ECDSA-P256 signer/verifier and a manual clock/RNG —
no Windows APIs, no ConPTY, no named pipe.

```bash
dotnet test windows/tests/ipc/OpenBurnBar.Pal.Ipc.Tests.csproj
#   Passed! Failed: 0, Passed: 20
```

| File | Contents |
|------|----------|
| `SignedNonceHandshakeTests.cs` | accept valid · reject replay / expiry / wrong-signature · unknown / malformed / tampered · role binding · full mutual handshake · bounded replay history |
| `HandshakeTestCredentials.cs` | `EcdsaHandshakeKeyPair` (real P-256), `ManualClock`, `ScriptedNonceSource` |

The Windows-only handshake steps (real pipe transport, kernel SID, image/module
verdict, CNG/TPM keys) are genuinely un-testable off-Windows and are deferred to
VAL-P0-CONPTY-019 with a per-item justification in
[`docs/windows-port/design/0004-named-pipe-peer-auth.md`](../../../docs/windows-port/design/0004-named-pipe-peer-auth.md) §3.1.
