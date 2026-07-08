# `windows/pal/ipc/` — portable IPC handshake core (W1 / R16)

The **platform-independent** half of the app↔daemon named-pipe peer-auth
handshake: the signed-nonce challenge/response state machine and the crypto/clock/
RNG seams it depends on. Zero P/Invoke, zero OS calls — plain `net10.0` — so its
logic is unit-tested on the macOS authoring host today (VAL-P0-CONPTY-018) and
re-runs unchanged against Windows CNG later (VAL-P0-CONPTY-019).

| File | Role |
|------|------|
| `SignedNonce.cs` | `NonceChallenge`, `SignedNonceResponse`, `HandshakeVerdict`, `HandshakeRole` |
| `HandshakeCredentials.cs` | `INonceSigner` / `INonceVerifier` / `IHandshakeClock` / `INonceSource` seams + system defaults |
| `HandshakeTranscript.cs` | domain-separated, role-bound, length-prefixed signed transcript |
| `SignedNonceHandshakeVerifier.cs` | the verifier **state machine** (issue → verify; accept/replay/expiry/bad-sig/unknown/malformed) |
| `SignedNonceResponder.cs` | the responder half + `MutualHandshakeEndpoint` bundling both directions |

The Windows Win32 binding lives in [`../ipc-windows/`](../ipc-windows/); the macOS
tests live in [`../../tests/ipc/`](../../tests/ipc/). Design note:
[`docs/windows-port/design/0004-named-pipe-peer-auth.md`](../../../docs/windows-port/design/0004-named-pipe-peer-auth.md).
