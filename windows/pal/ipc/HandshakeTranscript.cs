// Portable signed-nonce handshake — the signed transcript.
//
// Both ends compute the exact same bytes from a challenge and sign/verify those,
// never the bare nonce. Domain separation (a fixed protocol label) stops a
// signature minted here from being replayed against any other protocol that
// happens to sign a random blob with the same key; binding the challenger role
// stops a challenge from being reflected back at its issuer.

using System;
using System.Buffers.Binary;
using System.Text;

namespace OpenBurnBar.Pal.Ipc;

/// <summary>
/// Builds the canonical byte string a peer signs to answer a challenge.
/// </summary>
/// <remarks>
/// Layout (all fixed-order, length-prefixed so no field can bleed into the next):
/// <code>
///   label-len (u16 LE) | label bytes ("OpenBurnBar/pipe-peer-auth/v1")
///   role (1 byte)      | challenger role (1 = Initiator, 2 = Responder)
///   nonce-len (u16 LE) | nonce bytes
/// </code>
/// The length prefixes make the encoding unambiguous: two different
/// (role, nonce) inputs can never serialize to the same transcript.
/// </remarks>
public static class HandshakeTranscript
{
    /// <summary>The protocol domain-separation label. Bumping the version suffix
    /// is a breaking handshake change and must be coordinated across app and
    /// daemon.</summary>
    public const string ProtocolLabel = "OpenBurnBar/pipe-peer-auth/v1";

    private static readonly byte[] LabelBytes = Encoding.ASCII.GetBytes(ProtocolLabel);

    /// <summary>
    /// Serializes the transcript for <paramref name="challenge"/>.
    /// </summary>
    public static byte[] Build(NonceChallenge challenge)
    {
        if (challenge is null)
        {
            throw new ArgumentNullException(nameof(challenge));
        }

        return Build(challenge.ChallengerRole, challenge.Nonce);
    }

    /// <summary>
    /// Serializes the transcript for a (role, nonce) pair. Exposed for the
    /// responder, which signs a received challenge, and for tests.
    /// </summary>
    public static byte[] Build(HandshakeRole challengerRole, ReadOnlySpan<byte> nonce)
    {
        if (nonce.Length == 0)
        {
            throw new ArgumentException("Nonce must be non-empty.", nameof(nonce));
        }

        if (nonce.Length > ushort.MaxValue || LabelBytes.Length > ushort.MaxValue)
        {
            throw new ArgumentException("Field exceeds the u16 length prefix.", nameof(nonce));
        }

        int total = 2 + LabelBytes.Length + 1 + 2 + nonce.Length;
        var buffer = new byte[total];
        var span = buffer.AsSpan();
        int offset = 0;

        BinaryPrimitives.WriteUInt16LittleEndian(span.Slice(offset, 2), (ushort)LabelBytes.Length);
        offset += 2;
        LabelBytes.CopyTo(span.Slice(offset, LabelBytes.Length));
        offset += LabelBytes.Length;

        span[offset] = (byte)challengerRole;
        offset += 1;

        BinaryPrimitives.WriteUInt16LittleEndian(span.Slice(offset, 2), (ushort)nonce.Length);
        offset += 2;
        nonce.CopyTo(span.Slice(offset, nonce.Length));

        return buffer;
    }
}
