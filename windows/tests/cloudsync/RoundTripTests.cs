using System.Text;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// End-to-end round-trips through the public (random-nonce) API surface — seal
    /// then open must recover the exact input, and the AAD binding must hold across
    /// the v1 / v2 and default / path-bound variants.
    /// </summary>
    public sealed class RoundTripTests
    {
        private static byte[] Key() => CloudVaultCrypto.GenerateVaultKey();

        [Fact]
        public void SealText_RoundTrip_V1AndV2()
        {
            var key = Key();
            const string text = "holy shit, that's done — 🔒 with unicode";

            var v1 = CloudVaultCrypto.SealText(text, key);
            Assert.Null(v1.SchemaVersion);
            Assert.Equal(text, CloudVaultCrypto.OpenText(v1, key));

            var ctx = new CloudVaultAadContext("uid_1", "cloudSessions", "doc_42", "title");
            var v2 = CloudVaultCrypto.SealText(text, key, aadContext: ctx);
            Assert.Equal(2, v2.SchemaVersion);
            Assert.Equal(text, CloudVaultCrypto.OpenText(v2, key, ctx));
        }

        [Fact]
        public void SealBlob_RoundTrip_DefaultAndPathAad()
        {
            var key = Key();
            var data = Encoding.UTF8.GetBytes("release policy v9");

            var def = CloudVaultCrypto.SealBlob(data, key);
            Assert.Equal(CloudVaultCrypto.BlobEnvelopeAadContext, def.Aad);
            Assert.Equal(data, CloudVaultCrypto.OpenBlob(def, key));

            var ctx = new CloudVaultAadContext("uid_1", "cloudSessions", "doc_42", "body");
            var bound = CloudVaultCrypto.SealBlob(data, key, aadContext: ctx);
            Assert.Equal(data, CloudVaultCrypto.OpenBlob(bound, key, ctx));
        }

        [Fact]
        public void SealPayload_RoundTrip_DefaultAndPathAad()
        {
            var key = Key();
            var id = CloudVaultCrypto.VaultKeyId(key);
            var data = Encoding.UTF8.GetBytes("{\"mission\":\"launch\"}");

            var def = CloudVaultCrypto.SealPayload(data, key, id);
            Assert.Equal(CloudVaultCrypto.SealedPayloadAadContext, def.Aad);
            Assert.Equal(data, CloudVaultCrypto.OpenPayload(def, key));

            var ctx = new CloudVaultAadContext("uid_1", "cloudMissions", "m_9", "sealedPayload");
            var bound = CloudVaultCrypto.SealPayload(data, key, id, aadContext: ctx);
            Assert.Equal(data, CloudVaultCrypto.OpenPayload(bound, key, ctx));
        }

        [Fact]
        public void Recovery_RoundTrip()
        {
            var key = Key();
            const string recovery = "TEST-RECOVERY-KEY-ABC-234";

            var (wrapped, hash) = CloudVaultCrypto.WrapVaultKeyWithRecovery(key, recovery);
            Assert.Equal(hash, CloudVaultCrypto.RecoveryVerificationHash(recovery));
            Assert.Equal(key, CloudVaultCrypto.UnwrapVaultKeyWithRecovery(wrapped, recovery));
        }

        [Fact]
        public void SealText_UsesFreshNonce_EachSeal()
        {
            var key = Key();
            var a = CloudVaultCrypto.SealText("same text", key);
            var b = CloudVaultCrypto.SealText("same text", key);
            Assert.NotEqual(a.Nonce, b.Nonce);
            Assert.NotEqual(a.Ciphertext + a.Tag, b.Ciphertext + b.Tag);
        }
    }
}
