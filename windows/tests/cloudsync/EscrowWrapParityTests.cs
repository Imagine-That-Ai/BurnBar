using System;
using System.Security.Cryptography;
using System.Text.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// Byte-parity for the escrow key-wrap (P-256 ECDH + HKDF-SHA256 + AES-256-GCM)
    /// against the committed CryptoKit-origin vectors, BOTH directions.
    /// </summary>
    public sealed class EscrowWrapParityTests
    {
        [Fact]
        public void Unwrap_CommittedCryptoKitBytes_MatchesVaultKey()
        {
            foreach (var vector in KatVectors.Section("escrowWrap").EnumerateArray())
            {
                var wrapped = vector.Hex("wrappedHex");
                var recipientPrivate = vector.Hex("recipientPrivateKeyRawHex");
                var expectedVaultKey = vector.Hex("vaultKeyHex");

                var unwrapped = CloudVaultCrypto.UnwrapVaultKey(wrapped, recipientPrivate);

                Assert.Equal(KatVectors.ToHex(expectedVaultKey), KatVectors.ToHex(unwrapped));
            }
        }

        [Fact]
        public void Wrap_WithPinnedEphemeralAndNonce_ReproducesCommittedBytes()
        {
            foreach (var vector in KatVectors.Section("escrowWrap").EnumerateArray())
            {
                var vaultKey = vector.Hex("vaultKeyHex");
                var recipientPublic = vector.Hex("recipientPublicKeyX963Hex");
                var ephemeralScalar = vector.Hex("ephemeralPrivateKeyRawHex");
                var nonce = vector.Hex("aesGcmNonceHex");
                var expectedWrapped = vector.Hex("wrappedHex");

                var wrapped = CloudVaultCrypto.WrapVaultKey(vaultKey, recipientPublic, ephemeralScalar, nonce);

                Assert.Equal(KatVectors.ToHex(expectedWrapped), KatVectors.ToHex(wrapped));
            }
        }

        [Fact]
        public void EphemeralPublicKey_FromPinnedScalar_MatchesCommittedX963()
        {
            var vector = FirstEscrow();
            var scalar = vector.Hex("ephemeralPrivateKeyRawHex");
            var expected = vector.Str("ephemeralPublicKeyX963Hex");

            var actual = KatVectors.ToHex(P256KeyAgreement.PublicX963FromScalar(scalar));

            Assert.Equal(expected, actual);
        }

        [Fact]
        public void EcdhSharedSecret_MatchesCommittedX_And_DotNetRawSecretAgreement()
        {
            var vector = FirstEscrow();
            var ephemeralScalar = vector.Hex("ephemeralPrivateKeyRawHex");
            var recipientPublic = vector.Hex("recipientPublicKeyX963Hex");
            var expectedSharedX = vector.Str("sharedSecretHex");

            // BouncyCastle X-coordinate agreement (used by the port).
            var bcShared = KatVectors.ToHex(P256KeyAgreement.SharedSecretX(ephemeralScalar, recipientPublic));
            Assert.Equal(expectedSharedX, bcShared);

            // Independent .NET ECDiffieHellman raw-secret agreement over the SAME
            // keys must produce the SAME X coordinate — the third parity anchor
            // (CryptoKit == WebCrypto == BouncyCastle == .NET BCL).
            using var ephemeral = ImportPrivate(ephemeralScalar, P256KeyAgreement.PublicX963FromScalar(ephemeralScalar));
            using var recipient = ImportPublic(recipientPublic);
            var bclShared = KatVectors.ToHex(ephemeral.DeriveRawSecretAgreement(recipient.PublicKey));
            Assert.Equal(expectedSharedX, bclShared);
        }

        [Fact]
        public void RoundTrip_WrapThenUnwrap_RandomEphemeral()
        {
            var vector = FirstEscrow();
            var recipientPrivate = vector.Hex("recipientPrivateKeyRawHex");
            var recipientPublic = vector.Hex("recipientPublicKeyX963Hex");
            var vaultKey = CloudVaultCrypto.GenerateVaultKey();

            var wrapped = CloudVaultCrypto.WrapVaultKey(vaultKey, recipientPublic);
            var unwrapped = CloudVaultCrypto.UnwrapVaultKey(wrapped, recipientPrivate);

            Assert.Equal(KatVectors.ToHex(vaultKey), KatVectors.ToHex(unwrapped));
            // A fresh wrap uses a fresh ephemeral + nonce, so it must differ each time.
            var wrapped2 = CloudVaultCrypto.WrapVaultKey(vaultKey, recipientPublic);
            Assert.NotEqual(KatVectors.ToHex(wrapped), KatVectors.ToHex(wrapped2));
        }

        private static JsonElement FirstEscrow()
        {
            foreach (var vector in KatVectors.Section("escrowWrap").EnumerateArray())
            {
                return vector;
            }
            throw new InvalidOperationException("no escrow vectors");
        }

        private static ECDiffieHellman ImportPrivate(byte[] scalar, byte[] publicX963)
        {
            var parameters = new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                D = scalar,
                Q = new ECPoint { X = publicX963[1..33], Y = publicX963[33..65] },
            };
            return ECDiffieHellman.Create(parameters);
        }

        private static ECDiffieHellman ImportPublic(byte[] publicX963)
        {
            var parameters = new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = publicX963[1..33], Y = publicX963[33..65] },
            };
            return ECDiffieHellman.Create(parameters);
        }
    }
}
