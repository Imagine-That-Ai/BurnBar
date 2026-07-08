// Test doubles for the portable handshake seams.
//
// These are REAL crypto (ECDSA over NIST P-256, fully supported in the .NET BCL
// on macOS) plus a controllable clock and a deterministic nonce source. Using a
// real signature algorithm — not a mock — is deliberate: the wrong-signature and
// tampered-transcript tests must exercise genuine verification, and P-256 is
// available cross-platform so the exact same assertions can later run against a
// CNG-backed signer on Windows (VAL-P0-CONPTY-019) without touching the tests.

using System;
using System.Security.Cryptography;
using OpenBurnBar.Pal.Ipc;

namespace OpenBurnBar.Pal.Ipc.Tests;

/// <summary>
/// An ECDSA-P256 key pair exposed as an <see cref="INonceSigner"/> (private key)
/// and a matching <see cref="INonceVerifier"/> (public key). Two instances model
/// two distinct principals, so a signature from one is rejected by the other.
/// </summary>
internal sealed class EcdsaHandshakeKeyPair : IDisposable
{
    private readonly ECDsa _key;

    public EcdsaHandshakeKeyPair()
    {
        _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    }

    /// <summary>A signer bound to this key pair's private key.</summary>
    public INonceSigner Signer => new EcdsaSigner(_key);

    /// <summary>A verifier bound to this key pair's public key.</summary>
    public INonceVerifier Verifier => new EcdsaVerifier(_key);

    public void Dispose() => _key.Dispose();

    private sealed class EcdsaSigner : INonceSigner
    {
        private readonly ECDsa _key;

        public EcdsaSigner(ECDsa key) => _key = key;

        public byte[] Sign(ReadOnlySpan<byte> message) =>
            _key.SignData(message, HashAlgorithmName.SHA256);
    }

    private sealed class EcdsaVerifier : INonceVerifier
    {
        private readonly ECDsa _key;

        public EcdsaVerifier(ECDsa key) => _key = key;

        public bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature) =>
            _key.VerifyData(message, signature, HashAlgorithmName.SHA256);
    }
}

/// <summary>
/// A hand-driven clock. <see cref="Advance"/> moves virtual time forward so
/// expiry can be tested without sleeping.
/// </summary>
internal sealed class ManualClock : IHandshakeClock
{
    public ManualClock(long startUnixMs = 1_000_000_000_000)
    {
        UnixTimeMilliseconds = startUnixMs;
    }

    public long UnixTimeMilliseconds { get; private set; }

    public void Advance(long deltaMs) => UnixTimeMilliseconds += deltaMs;
}

/// <summary>
/// A deterministic nonce source that emits a caller-supplied sequence of nonces,
/// so tests can force a nonce collision or assert exact bytes. Falls back to a
/// counter-derived pattern once the scripted nonces are exhausted.
/// </summary>
internal sealed class ScriptedNonceSource : INonceSource
{
    private readonly byte[][] _scripted;
    private int _index;
    private byte _counter;

    public ScriptedNonceSource(params byte[][] scripted)
    {
        _scripted = scripted ?? Array.Empty<byte[]>();
    }

    public void Fill(Span<byte> buffer)
    {
        if (_index < _scripted.Length)
        {
            byte[] next = _scripted[_index++];
            if (next.Length != buffer.Length)
            {
                throw new InvalidOperationException(
                    $"Scripted nonce #{_index - 1} is {next.Length} bytes; expected {buffer.Length}.");
            }

            next.CopyTo(buffer);
            return;
        }

        // Deterministic, distinct-per-call fallback so unscripted IssueChallenge
        // calls never collide accidentally.
        buffer.Fill(unchecked(_counter++));
        if (buffer.Length > 0)
        {
            buffer[0] = unchecked((byte)(0xF0 | _counter));
        }
    }
}
