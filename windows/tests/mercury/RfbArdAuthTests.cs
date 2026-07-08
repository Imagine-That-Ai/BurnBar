using System;
using System.Numerics;
using System.Security.Cryptography;
using OpenBurnBar.Integrations.Mercury.Wire;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class RfbArdAuthTests
{
    [Fact]
    public void BuildCredentialBlock_PlacesNullTerminatedFieldsByteExact()
    {
        var randomFill = new byte[RfbArdAuth.CredentialBlockSize];
        Array.Fill(randomFill, (byte)0xEE);

        var block = RfbArdAuth.BuildCredentialBlock("alberto", "hunter2", randomFill);

        Assert.Equal(128, block.Length);
        // Username C-string at [0,64): 7 bytes + NUL, remainder untouched random.
        Assert.Equal(System.Text.Encoding.UTF8.GetBytes("alberto"), block[0..7]);
        Assert.Equal(0, block[7]);
        Assert.Equal(0xEE, block[8]);
        Assert.Equal(0xEE, block[63]);
        // Password C-string at [64,128): 7 bytes + NUL, remainder untouched random.
        Assert.Equal(System.Text.Encoding.UTF8.GetBytes("hunter2"), block[64..71]);
        Assert.Equal(0, block[71]);
        Assert.Equal(0xEE, block[72]);
        Assert.Equal(0xEE, block[127]);
    }

    [Fact]
    public void BuildCredentialBlock_TruncatesOverlongFieldLeavingRoomForTerminator()
    {
        var randomFill = new byte[RfbArdAuth.CredentialBlockSize];
        var longName = new string('a', 200);

        var block = RfbArdAuth.BuildCredentialBlock(longName, "p", randomFill);

        // 63 bytes of 'a' then a NUL at index 63 (field is 64 wide).
        for (var i = 0; i < 63; i++)
        {
            Assert.Equal((byte)'a', block[i]);
        }

        Assert.Equal(0, block[63]);
    }

    [Fact]
    public void Aes128EcbEncrypt_MatchesKnownAllZeroVector()
    {
        // FIPS-197 style known answer: AES-128-ECB of 16 zero bytes under a
        // 16-zero key = 66e94bd4ef8a2c3b884cfa59ca342b2e.
        var ciphertext = RfbArdAuth.Aes128EcbEncrypt(new byte[16], new byte[16]);
        Assert.Equal("66e94bd4ef8a2c3b884cfa59ca342b2e", Convert.ToHexString(ciphertext).ToLowerInvariant());
    }

    [Fact]
    public void Aes128EcbEncrypt_RoundTripsThroughDecrypt()
    {
        var key = RandomNumberGenerator.GetBytes(16);
        var block = RfbArdAuth.BuildCredentialBlock("user", "pass", new byte[128]);

        var ciphertext = RfbArdAuth.Aes128EcbEncrypt(block, key);
        Assert.Equal(128, ciphertext.Length);

        using var aes = Aes.Create();
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.None;
        aes.Key = key;
        using var decryptor = aes.CreateDecryptor();
        var roundTrip = decryptor.TransformFinalBlock(ciphertext, 0, ciphertext.Length);

        Assert.Equal(block, roundTrip);
    }

    [Fact]
    public void Aes128EcbEncrypt_RejectsNon16ByteKey()
    {
        Assert.Throws<ArgumentException>(() => RfbArdAuth.Aes128EcbEncrypt(new byte[16], new byte[8]));
    }

    [Fact]
    public void PowMod_MatchesHandComputedVector()
    {
        // 5^6 mod 23 = 15625 mod 23 = 8.
        Assert.Equal(new BigInteger(8), RfbArdAuth.PowMod(5, 6, 23));
    }

    [Fact]
    public void PowMod_ZeroModulus_ReturnsZero()
    {
        Assert.Equal(BigInteger.Zero, RfbArdAuth.PowMod(5, 6, 0));
    }

    [Fact]
    public void PowMod_DiffieHellmanExchange_BothSidesAgree()
    {
        // The exact shape of the ARD DH: shared = serverPublic^clientPrivate mod p
        // equals clientPublic^serverPrivate mod p.
        BigInteger g = 5;
        BigInteger p = 2_147_483_647; // Mersenne prime (2^31 - 1)
        BigInteger clientPrivate = 1_234_567;
        BigInteger serverPrivate = 7_654_321;

        var clientPublic = RfbArdAuth.PowMod(g, clientPrivate, p);
        var serverPublic = RfbArdAuth.PowMod(g, serverPrivate, p);

        var clientShared = RfbArdAuth.PowMod(serverPublic, clientPrivate, p);
        var serverShared = RfbArdAuth.PowMod(clientPublic, serverPrivate, p);

        Assert.Equal(clientShared, serverShared);
    }

    [Fact]
    public void DeriveAesKey_IsMd5OfFixedWidthSharedSecret()
    {
        BigInteger shared = BigInteger.Parse("123456789012345678901234567890");
        const int keyLength = 32;

        var derived = RfbArdAuth.DeriveAesKey(shared, keyLength);

        var expected = MD5.HashData(RfbArdAuth.ToBigEndianFixed(shared, keyLength));
        Assert.Equal(16, derived.Length);
        Assert.Equal(expected, derived);
    }

    [Fact]
    public void ToBigEndianFixed_LeftPadsToWidth()
    {
        Assert.Equal(new byte[] { 0x00, 0x00, 0x01, 0x02 }, RfbArdAuth.ToBigEndianFixed(0x0102, 4));
    }

    [Fact]
    public void ToBigEndianFixed_TruncatesToLeastSignificantBytes()
    {
        // Parity: RemoteUnlockBigUInt.bigEndianData writes only the low `byteCount` slots.
        Assert.Equal(new byte[] { 0x02 }, RfbArdAuth.ToBigEndianFixed(0x0102, 1));
    }

    [Fact]
    public void FromBigEndian_RoundTripsFixedWidth()
    {
        var value = RfbArdAuth.FromBigEndian(new byte[] { 0x01, 0x02, 0x03, 0x04 });
        Assert.Equal(new BigInteger(0x01020304), value);
        Assert.Equal(new byte[] { 0x01, 0x02, 0x03, 0x04 }, RfbArdAuth.ToBigEndianFixed(value, 4));
    }
}
