using System.Text.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// Byte-parity for sealBlob / openBlob (AES-256-GCM combined + vault-keyed
    /// plaintext HMAC integrity) against the committed CryptoKit vectors. Covers the
    /// default-context path (AEAD authenticates EMPTY bytes while the envelope carries
    /// the sentinel AAD string) and the path-bound AAD variant.
    /// </summary>
    public sealed class SealBlobParityTests
    {
        [Fact]
        public void OpenBlob_CommittedBytes_MatchesPlaintext()
        {
            foreach (var vector in KatVectors.Section("sealBlob").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var envelope = KatVectors.BlobEnvelope(vector.GetProperty("envelope"));
                var aad = vector.Has("aadContext") ? vector.AadContext() : null;

                var opened = CloudVaultCrypto.OpenBlob(envelope, key, aad);

                Assert.Equal(vector.Str("plaintextHex"), KatVectors.ToHex(opened));
            }
        }

        [Fact]
        public void SealBlob_WithPinnedNonce_ReproducesCommittedEnvelope()
        {
            foreach (var vector in KatVectors.Section("sealBlob").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var nonce = vector.Hex("nonceHex");
                var data = vector.Hex("plaintextHex");
                var aad = vector.Has("aadContext") ? vector.AadContext() : null;
                var expected = vector.GetProperty("envelope");

                var sealed_ = CloudVaultCrypto.SealBlob(data, key, CloudVaultCrypto.CurrentKeyVersion, aad, nonce);

                Assert.Equal(expected.Str("sealedBoxBase64"), sealed_.SealedBoxBase64);
                Assert.Equal(expected.Str("plaintextHMAC"), sealed_.PlaintextHmac);
                Assert.Equal(expected.Int("integrityHashVersion"), sealed_.IntegrityHashVersion);
                Assert.Equal(expected.Int("schemaVersion"), sealed_.SchemaVersion);
                Assert.Equal(expected.Str("algorithm"), sealed_.Algorithm);
                Assert.Equal(expected.Str("aad"), sealed_.Aad);
            }
        }

        [Fact]
        public void PlaintextHmac_IsVaultKeyedAndMatchesCommitted()
        {
            foreach (var vector in KatVectors.Section("sealBlob").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var data = vector.Hex("plaintextHex");
                var expected = vector.GetProperty("envelope").Str("plaintextHMAC");
                Assert.Equal(expected, CloudVaultCrypto.BlobPlaintextHmac(data, key));
            }
        }
    }
}
