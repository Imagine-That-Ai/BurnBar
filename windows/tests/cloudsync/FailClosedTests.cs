using System.Text.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// The security invariants: every integrity / binding failure is a fail-closed
    /// refusal (throws <see cref="CloudVaultCryptoException"/>) and never returns
    /// plaintext. Covers tampered tags, wrong keys, relocated / mismatched AAD, the
    /// missing-context v2 refusal, integrity-HMAC swaps, and the legacy-v1 AAD
    /// cutover.
    /// </summary>
    public sealed class FailClosedTests
    {
        [Fact]
        public void Escrow_TamperedCiphertext_Throws()
        {
            var vector = First("escrowWrap");
            var wrapped = vector.Hex("wrappedHex");
            var recipientPrivate = vector.Hex("recipientPrivateKeyRawHex");
            wrapped[^1] ^= 0x01; // flip a tag byte

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.UnwrapVaultKey(wrapped, recipientPrivate));
        }

        [Fact]
        public void Escrow_WrongRecipientKey_Throws()
        {
            var vector = First("escrowWrap");
            var wrapped = vector.Hex("wrappedHex");
            var wrongPrivate = vector.Hex("recipientPrivateKeyRawHex");
            wrongPrivate[^1] ^= 0x01;

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.UnwrapVaultKey(wrapped, wrongPrivate));
        }

        [Fact]
        public void OpenText_TamperedTag_Throws()
        {
            var vector = First("sealText");
            var key = vector.Hex("keyHex");
            var env = KatVectors.SealedText(vector.GetProperty("envelope"));
            var tampered = env with { Tag = FlipBase64LastByte(env.Tag) };
            var aad = vector.Has("aadContext") ? vector.AadContext() : null;

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.OpenText(tampered, key, aad));
        }

        [Fact]
        public void OpenText_V2_MissingContext_Throws()
        {
            var vector = V2SealText();
            var key = vector.Hex("keyHex");
            var env = KatVectors.SealedText(vector.GetProperty("envelope"));

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.OpenText(env, key, aadContext: null));
        }

        [Fact]
        public void OpenText_V2_RelocatedContext_Throws()
        {
            var vector = V2SealText();
            var key = vector.Hex("keyHex");
            var env = KatVectors.SealedText(vector.GetProperty("envelope"));
            var original = vector.AadContext();
            var relocated = new CloudVaultAadContext(
                original.Uid, original.Collection, original.DocId + "_moved", original.Field,
                original.SchemaVersion, original.Purpose);

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.OpenText(env, key, relocated));
        }

        [Fact]
        public void OpenBlob_WrongKey_Throws()
        {
            var vector = First("sealBlob");
            var key = vector.Hex("keyHex");
            key[0] ^= 0x01;
            var env = KatVectors.BlobEnvelope(vector.GetProperty("envelope"));
            var aad = vector.Has("aadContext") ? vector.AadContext() : null;

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.OpenBlob(env, key, aad));
        }

        [Fact]
        public void OpenBlob_SwappedIntegrityHmac_Throws()
        {
            var vector = First("sealBlob");
            var key = vector.Hex("keyHex");
            var env = KatVectors.BlobEnvelope(vector.GetProperty("envelope"));
            // Valid AEAD tag, but the vault-keyed integrity HMAC no longer matches.
            var swapped = env with { PlaintextHmac = new string('0', 64) };
            var aad = vector.Has("aadContext") ? vector.AadContext() : null;

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.OpenBlob(swapped, key, aad));
        }

        [Fact]
        public void OpenPayload_WrongVaultKey_Throws()
        {
            var vector = First("sealPayload");
            var key = vector.Hex("keyHex");
            key[0] ^= 0x01; // vaultKeyID no longer matches the envelope binding
            var env = KatVectors.PayloadEnvelope(vector.GetProperty("envelope"));
            var aad = vector.Has("aadContext") ? vector.AadContext() : null;

            Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.OpenPayload(env, key, aad));
        }

        [Fact]
        public void LegacyV1Aad_RejectedWhenEnabled_AcceptedWhenDisabled()
        {
            var context = new CloudVaultAadContext("user_alice", "cloudSessions", "doc_123", "title", 2, "title");

            // Rejected (fail closed) once the cutover flag is on.
            Assert.Throws<CloudVaultCryptoException>(() =>
                CloudVaultCrypto.AadData(context.LegacyV1StringValue, context, rejectLegacyV1: true));

            // Accepted only under the emergency rollback (flag off) — returns the v1 bytes.
            var v1 = CloudVaultCrypto.AadData(context.LegacyV1StringValue, context, rejectLegacyV1: false);
            Assert.Equal(context.LegacyV1Data, v1);

            // The v2 context always resolves to its own bytes regardless of the flag.
            Assert.Equal(context.Data, CloudVaultCrypto.AadData(context.StringValue, context, rejectLegacyV1: true));

            // An unrelated AAD string is always refused.
            Assert.Throws<CloudVaultCryptoException>(() =>
                CloudVaultCrypto.AadData("some-other-aad", context, rejectLegacyV1: false));
        }

        [Fact]
        public void InvalidPublicKey_Throws_InvalidPublicKeyCode()
        {
            var vaultKey = CloudVaultCrypto.GenerateVaultKey();
            var notAPoint = new byte[65];
            notAPoint[0] = 0x04; // right prefix, but X/Y are all-zero -> not on curve

            var ex = Assert.Throws<CloudVaultCryptoException>(
                () => CloudVaultCrypto.WrapVaultKey(vaultKey, notAPoint));
            Assert.Equal(CloudVaultCryptoErrorCode.InvalidPublicKey, ex.Code);
        }

        [Fact]
        public void BadVaultKeyLength_Throws_InvalidKeyLengthCode()
        {
            var ex = Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.VaultKeyId(new byte[16]));
            Assert.Equal(CloudVaultCryptoErrorCode.InvalidKeyLength, ex.Code);
        }

        private static JsonElement First(string section)
        {
            foreach (var vector in KatVectors.Section(section).EnumerateArray())
            {
                return vector;
            }
            throw new System.InvalidOperationException($"no {section} vectors");
        }

        private static JsonElement V2SealText()
        {
            foreach (var vector in KatVectors.Section("sealText").EnumerateArray())
            {
                if (vector.Has("aadContext"))
                {
                    return vector;
                }
            }
            throw new System.InvalidOperationException("no v2 sealText vector");
        }

        private static string FlipBase64LastByte(string base64)
        {
            var bytes = System.Convert.FromBase64String(base64);
            bytes[^1] ^= 0x01;
            return System.Convert.ToBase64String(bytes);
        }
    }
}
