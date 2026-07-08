using System;
using System.Security.Cryptography;

namespace OpenBurnBar.CloudSync.AppCheck.Attestation;

/// <summary>
/// Supplies single-use, replay-defeating nonces for attestation claims. Abstracted
/// so tests can inject a deterministic sequence while production uses a CSPRNG.
/// </summary>
public interface INonceSource
{
    /// <summary>Return a fresh nonce (16..256 chars, per the server bounds).</summary>
    string NextNonce();
}

/// <summary>
/// Default cryptographically-random nonce source: 32 random bytes rendered as
/// lowercase hex (64 chars — comfortably inside the server's 16..256 bound and
/// well above the birthday-collision floor for the replay set).
/// </summary>
public sealed class RandomNonceSource : INonceSource
{
    private readonly int _byteLength;

    public RandomNonceSource(int byteLength = 32)
    {
        // 16 hex chars is the server minimum; 8 bytes -> 16 hex is the floor.
        if (byteLength < 8)
        {
            throw new ArgumentOutOfRangeException(
                nameof(byteLength),
                byteLength,
                "Nonce must be at least 8 bytes (16 hex chars) to satisfy the server minimum.");
        }
        _byteLength = byteLength;
    }

    public string NextNonce()
    {
        var buffer = RandomNumberGenerator.GetBytes(_byteLength);
        return Convert.ToHexString(buffer).ToLowerInvariant();
    }
}
