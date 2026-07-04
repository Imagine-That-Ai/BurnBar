using System.Text.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// Byte-parity for sealPayload / openPayload (AES-256-GCM combined + metadata /
    /// path-bound AAD, bound to the vaultKeyID) against the committed CryptoKit
    /// vectors.
    /// </summary>
    public sealed class SealPayloadParityTests
    {
        [Fact]
        public void OpenPayload_CommittedBytes_MatchesPlaintext()
        {
            foreach (var vector in KatVectors.Section("sealPayload").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var envelope = KatVectors.PayloadEnvelope(vector.GetProperty("envelope"));
                var aad = vector.Has("aadContext") ? vector.AadContext() : null;

                var opened = CloudVaultCrypto.OpenPayload(envelope, key, aad);

                Assert.Equal(vector.Str("plaintextHex"), KatVectors.ToHex(opened));
            }
        }

        [Fact]
        public void SealPayload_WithPinnedNonce_ReproducesCommittedEnvelope()
        {
            foreach (var vector in KatVectors.Section("sealPayload").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var nonce = vector.Hex("nonceHex");
                var data = vector.Hex("plaintextHex");
                var vaultKeyId = vector.Str("vaultKeyID");
                var aad = vector.Has("aadContext") ? vector.AadContext() : null;
                var expected = vector.GetProperty("envelope");

                var sealed_ = CloudVaultCrypto.SealPayload(data, key, vaultKeyId, CloudVaultCrypto.CurrentKeyVersion, aad, nonce);

                Assert.Equal(expected.Str("sealedBoxBase64"), sealed_.SealedBoxBase64);
                Assert.Equal(expected.Str("vaultKeyID"), sealed_.VaultKeyId);
                Assert.Equal(expected.Int("schemaVersion"), sealed_.SchemaVersion);
                Assert.Equal(expected.Str("algorithm"), sealed_.Algorithm);
                Assert.Equal(expected.Str("aad"), sealed_.Aad);
            }
        }

        [Fact]
        public void VaultKeyId_MatchesCommitted()
        {
            foreach (var vector in KatVectors.Section("vaultKeyId").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                Assert.Equal(vector.Str("vaultKeyID"), CloudVaultCrypto.VaultKeyId(key));
            }
        }
    }
}
