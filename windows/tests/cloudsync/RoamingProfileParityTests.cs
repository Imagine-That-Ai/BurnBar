using System;
using System.Text.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// Pins the roaming-profile CloudVault envelope to the Swift vector generator.
    /// The payload stays opaque JSON to C#; this test proves the AAD domain,
    /// vault-key binding, and tamper-fail behavior remain byte-compatible.
    /// </summary>
    public sealed class RoamingProfileParityTests
    {
        [Fact]
        public void OpenRoamingProfile_CommittedVector_MatchesPlaintext()
        {
            var vector = FirstRoamingProfileVector();
            var key = vector.Hex("keyHex");
            var envelope = KatVectors.PayloadEnvelope(vector.GetProperty("envelope"));

            var opened = CloudVaultCrypto.OpenRoamingProfile(envelope, key, "user_alice");

            Assert.Equal(vector.Str("plaintextHex"), KatVectors.ToHex(opened));
            Assert.Equal(CloudVaultCrypto.RoamingProfileAadContext("user_alice").StringValue, envelope.Aad);

            using var doc = JsonDocument.Parse(opened);
            var root = doc.RootElement;
            Assert.Equal(1, root.GetProperty("schemaVersion").GetInt32());
            Assert.Equal("same_model_failover", root.GetProperty("routerMode").GetString());
            Assert.False(root.GetProperty("crossProviderFailoverEnabled").GetBoolean());
            Assert.Equal("anthropic-primary", root.GetProperty("accountOrder")[0].GetString());
            Assert.Equal("bearer", root.GetProperty("providerAccounts")[0].GetProperty("credentialKind").GetString());
            Assert.False(root.TryGetProperty("apiKey", out _));
            Assert.False(root.TryGetProperty("token", out _));
            Assert.False(root.TryGetProperty("cookie", out _));
            Assert.False(root.TryGetProperty("password", out _));
        }

        [Fact]
        public void OpenRoamingProfile_WithWrongUid_FailsClosed()
        {
            var vector = FirstRoamingProfileVector();
            var key = vector.Hex("keyHex");
            var envelope = KatVectors.PayloadEnvelope(vector.GetProperty("envelope"));

            Assert.Throws<CloudVaultCryptoException>(() =>
                CloudVaultCrypto.OpenRoamingProfile(envelope, key, "user_bob"));
        }

        [Fact]
        public void SealRoamingProfile_WithPinnedNonce_ReproducesCommittedEnvelope()
        {
            var vector = FirstRoamingProfileVector();
            var key = vector.Hex("keyHex");
            var nonce = vector.Hex("nonceHex");
            var data = vector.Hex("plaintextHex");
            var expected = vector.GetProperty("envelope");

            var sealed_ = CloudVaultCrypto.SealPayload(
                data,
                key,
                CloudVaultCrypto.VaultKeyId(key),
                CloudVaultCrypto.CurrentKeyVersion,
                CloudVaultCrypto.RoamingProfileAadContext("user_alice"),
                nonce);

            Assert.Equal(expected.Str("sealedBoxBase64"), sealed_.SealedBoxBase64);
            Assert.Equal(expected.Str("vaultKeyID"), sealed_.VaultKeyId);
            Assert.Equal(expected.Int("schemaVersion"), sealed_.SchemaVersion);
            Assert.Equal(expected.Str("algorithm"), sealed_.Algorithm);
            Assert.Equal(expected.Str("aad"), sealed_.Aad);
        }

        private static JsonElement FirstRoamingProfileVector()
        {
            foreach (var vector in KatVectors.Section("roamingProfile").EnumerateArray())
            {
                return vector;
            }
            throw new InvalidOperationException("no roamingProfile vectors");
        }
    }
}
