using System.Text;
using System.Text.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// Byte-parity for sealText / openText (AES-256-GCM detached), v1 (no AAD) and
    /// v2 (path-bound AAD), against the committed CryptoKit vectors.
    /// </summary>
    public sealed class SealTextParityTests
    {
        [Fact]
        public void OpenText_CommittedBytes_MatchesPlaintext()
        {
            foreach (var vector in KatVectors.Section("sealText").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var envelope = KatVectors.SealedText(vector.GetProperty("envelope"));
                var aad = vector.Has("aadContext") ? vector.AadContext() : null;

                var opened = CloudVaultCrypto.OpenText(envelope, key, aad);

                Assert.Equal(vector.Str("plaintextUtf8"), opened);
            }
        }

        [Fact]
        public void SealText_WithPinnedNonce_ReproducesCommittedEnvelope()
        {
            foreach (var vector in KatVectors.Section("sealText").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var nonce = vector.Hex("nonceHex");
                var text = vector.Str("plaintextUtf8");
                var aad = vector.Has("aadContext") ? vector.AadContext() : null;
                var expected = vector.GetProperty("envelope");

                var sealed_ = CloudVaultCrypto.SealText(text, key, CloudVaultCrypto.CurrentKeyVersion, aad, nonce);

                Assert.Equal(expected.Str("nonce"), sealed_.Nonce);
                Assert.Equal(expected.Str("ciphertext"), sealed_.Ciphertext);
                Assert.Equal(expected.Str("tag"), sealed_.Tag);
                Assert.Equal(expected.Str("algorithm"), sealed_.Algorithm);
                Assert.Equal(expected.Int("keyVersion"), sealed_.KeyVersion);
                if (expected.Has("schemaVersion"))
                {
                    Assert.Equal(expected.Int("schemaVersion"), sealed_.SchemaVersion);
                }
                else
                {
                    Assert.Null(sealed_.SchemaVersion);
                }
                Assert.Equal(expected.Has("aad") ? expected.Str("aad") : null, sealed_.Aad);
            }
        }

        [Fact]
        public void AeadAuthenticatedData_MatchesCommittedBytes()
        {
            foreach (var vector in KatVectors.Section("sealText").EnumerateArray())
            {
                var expectedAeadHex = vector.Str("aeadAadHex");
                var aad = vector.Has("aadContext") ? vector.AadContext() : null;
                var actual = aad == null ? "" : KatVectors.ToHex(Encoding.UTF8.GetBytes(aad.StringValue));
                Assert.Equal(expectedAeadHex, actual);
            }
        }

        [Fact]
        public void OpenText_FutureSchema_FailsClosed()
        {
            var vectors = KatVectors.Section("sealText").EnumerateArray();
            Assert.True(vectors.MoveNext());
            var vector = vectors.Current;
            var envelope = KatVectors.SealedText(vector.GetProperty("envelope")) with
            {
                SchemaVersion = CloudVaultCrypto.CurrentSealedTextSchemaVersion + 1,
            };

            Assert.Throws<CloudVaultCryptoException>(() =>
            {
                CloudVaultCrypto.OpenText(envelope, vector.Hex("keyHex"));
            });
        }
    }
}
