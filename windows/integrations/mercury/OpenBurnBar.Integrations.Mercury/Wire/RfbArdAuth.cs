using System;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.Integrations.Mercury.Wire;

/// <summary>
/// Apple Remote Desktop security-type-30 authentication crypto. Byte-exact port
/// of the auth path in
/// <c>AgentLens/Services/Media/AppleRemoteDesktopRFBClient.swift</c>
/// (<c>authenticateAppleARD</c> / <c>credentialBlock</c> / <c>aes128ECBEncrypt</c>
/// / <c>RemoteUnlockBigUInt.powMod</c>).
///
/// The Diffie-Hellman modular exponentiation is delegated to
/// <see cref="BigInteger.ModPow"/> (the Swift code hand-rolls the same math in
/// <c>RemoteUnlockBigUInt</c>); a parity test cross-checks the two against small
/// vectors. Randomness is injected so the credential-block layout and the
/// end-to-end handshake bytes are deterministic and verifiable.
/// </summary>
public static class RfbArdAuth
{
    /// <summary>Fixed 128-byte credential block: username in [0,64), password in [64,128).</summary>
    public const int CredentialBlockSize = 128;

    private const int UsernameFieldSize = 64;
    private const int PasswordFieldSize = 64;

    /// <summary>
    /// Build the 128-byte ARD credential block. The 128 bytes start as caller
    /// supplied random fill; the username C-string is written into [0,64) and
    /// the password C-string into [64,128), each NUL-terminated (parity:
    /// credentialBlock + writeCString). The random remainder frustrates a
    /// known-plaintext attack on the ECB block.
    /// </summary>
    public static byte[] BuildCredentialBlock(string username, string password, ReadOnlySpan<byte> randomFill)
    {
        if (username is null)
        {
            throw new ArgumentNullException(nameof(username));
        }

        if (password is null)
        {
            throw new ArgumentNullException(nameof(password));
        }

        if (randomFill.Length != CredentialBlockSize)
        {
            throw new ArgumentException($"randomFill must be {CredentialBlockSize} bytes", nameof(randomFill));
        }

        var block = new byte[CredentialBlockSize];
        randomFill.CopyTo(block);
        WriteCString(username, block, 0, UsernameFieldSize);
        WriteCString(password, block, UsernameFieldSize, PasswordFieldSize);
        return block;
    }

    /// <summary>
    /// Write a NUL-terminated C-string into <paramref name="buffer"/> at
    /// <paramref name="start"/>, truncating the UTF-8 bytes to leave room for the
    /// terminator (parity: writeCString).
    /// </summary>
    private static void WriteCString(string value, byte[] buffer, int start, int fieldSize)
    {
        var utf8 = Encoding.UTF8.GetBytes(value);
        var maxBytes = Math.Max(0, fieldSize - 1);
        var copyCount = Math.Min(utf8.Length, maxBytes);
        Array.Copy(utf8, 0, buffer, start, copyCount);
        buffer[start + copyCount] = 0;
    }

    /// <summary>
    /// AES-128 in ECB mode with no padding (parity: aes128ECBEncrypt using
    /// CommonCrypto kCCOptionECBMode). The plaintext length must be a multiple
    /// of the 16-byte block; the 128-byte credential block satisfies that.
    /// </summary>
    public static byte[] Aes128EcbEncrypt(ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> key)
    {
        if (key.Length != 16)
        {
            throw new ArgumentException("AES-128 key must be 16 bytes", nameof(key));
        }

        if (plaintext.Length % 16 != 0)
        {
            throw new ArgumentException("ECB plaintext must be a multiple of the 16-byte block", nameof(plaintext));
        }

        using var aes = Aes.Create();
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.None;
        aes.Key = key.ToArray();
        using var encryptor = aes.CreateEncryptor();
        var input = plaintext.ToArray();
        return encryptor.TransformFinalBlock(input, 0, input.Length);
    }

    /// <summary>
    /// Derive the AES key from the DH shared secret: MD5 of the shared secret
    /// serialized big-endian to <paramref name="keyLength"/> bytes (parity:
    /// <c>Insecure.MD5.hash(sharedBytes)</c>). MD5 is dictated by the ARD wire
    /// protocol; it is a key-derivation step for a local loopback exchange, not
    /// a security primitive we chose.
    /// </summary>
    public static byte[] DeriveAesKey(BigInteger sharedSecret, int keyLength)
    {
        var sharedBytes = ToBigEndianFixed(sharedSecret, keyLength);
#pragma warning disable CA5351 // ARD protocol mandates MD5 for the shared-secret KDF.
        return MD5.HashData(sharedBytes);
#pragma warning restore CA5351
    }

    /// <summary>
    /// Modular exponentiation <c>base^exponent mod modulus</c> — the DH primitive
    /// (parity: RemoteUnlockBigUInt.powMod). Returns zero when the modulus is
    /// zero, matching the Swift guard.
    /// </summary>
    public static BigInteger PowMod(BigInteger baseValue, BigInteger exponent, BigInteger modulus)
    {
        if (modulus.IsZero)
        {
            return BigInteger.Zero;
        }

        return BigInteger.ModPow(baseValue, exponent, modulus);
    }

    /// <summary>
    /// Read a big-endian unsigned integer from wire bytes (parity:
    /// RemoteUnlockBigUInt.init(bigEndian:)).
    /// </summary>
    public static BigInteger FromBigEndian(ReadOnlySpan<byte> bytes) =>
        new BigInteger(bytes, isUnsigned: true, isBigEndian: true);

    /// <summary>
    /// Serialize an unsigned integer to a fixed-width big-endian byte array,
    /// left-padded / truncated to <paramref name="byteCount"/> (parity:
    /// RemoteUnlockBigUInt.bigEndianData(byteCount:)).
    /// </summary>
    public static byte[] ToBigEndianFixed(BigInteger value, int byteCount)
    {
        if (byteCount < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(byteCount));
        }

        var minimal = value.ToByteArray(isUnsigned: true, isBigEndian: true);
        var output = new byte[byteCount];
        if (minimal.Length >= byteCount)
        {
            // Keep the least-significant `byteCount` bytes (parity: the Swift
            // loop only writes into the low `byteCount` output slots).
            Array.Copy(minimal, minimal.Length - byteCount, output, 0, byteCount);
        }
        else
        {
            Array.Copy(minimal, 0, output, byteCount - minimal.Length, minimal.Length);
        }

        return output;
    }
}
