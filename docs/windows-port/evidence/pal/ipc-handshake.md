# Evidence — Named-pipe signed-nonce IPC handshake (Real)

**Ledger row:** `pal-ipc-named-pipe`
**Status claim:** Real
**Date recorded:** 2026-07-09
**Design:** `docs/windows-port/design/0004-named-pipe-peer-auth.md`

## What this proves

The portable signed-nonce peer-auth handshake (Windows substitute for macOS unix-socket + codesign) verifies correctly under unit tests: transcript binding, responder/verifier roles, and credential material plumbing.

## Artifacts

| Artifact | Location |
|----------|----------|
| Nonce / transcript / verifier | `windows/pal/ipc/SignedNonce.cs`, `HandshakeTranscript.cs`, `SignedNonceHandshakeVerifier.cs`, `SignedNonceResponder.cs`, `HandshakeCredentials.cs` |
| Tests | `windows/tests/ipc/SignedNonceHandshakeTests.cs` |
| Design note | `docs/windows-port/design/0004-named-pipe-peer-auth.md` |

## Explicit non-claims

- Does **not** by itself prove ConPTY session IO on a physical Windows host (see ConPTY runbook).
- CNG/TPM-backed production key material on Win11 Pro is additional evidence, not required to call the portable handshake Real.
